#!/usr/bin/perl 
# by mixedforest<at>gmail.com v2020-02-19.1

use strict;
use warnings;
use feature 'state';
use Curses;
use Time::HiRes qw/sleep time usleep/;
#use POSIX qw(strftime round);
#use Data::Dumper;
#use Storable;

my ($port, $portname, $portspeed, $os);

BEGIN
{  # This must be in a BEGIN in order for the 'use' to be conditional
   if ($^O eq "MSWin32") { eval "use Win32::SerialPort";  die "$@\n" if ($@);
                           $portname = 'COM5';          $os = 'win32'; }
   else                  { eval "use Device::SerialPort"; die "$@\n" if ($@);
                           $portname = '/dev/ttyUSB0';  $os = 'linux'; }
}

my ($win, $monwin, $bmonwin, $msgwin, $bmsgwin); 
my ($cfgwin, $statwin, $stiwin, $manwin, $bmacwin, $macwin);
my ($bdbgwin, $dbgwin, $gstwin, $bregwin, $regwin);
my ($row, $col);

my @gcmd; my @gcmd_save;
my @gfile; my @histcmd;

my $resp_ok = 0;
my $total_line = 0; my $n_line = 0; 
my $total_path = 1; my $cur_path = 0; 
my $total_time = 0; my $work_time = 0; my $remain_time;

my $grbl_state = ''; 
my ($grbl_ovf, $grbl_ovr, $grbl_ovs)   = (0, 0, 0);
my ($grbl_fr,  $grbl_ss,  $grbl_buf)   = (0, 0, 0);
my @wco = (0,0,0,0,0,0); 
my @mpos = (0,0,0,0,0,0); 
my @wpos = (0,0,0,0,0,0);

my $man_mult = 1; my $man_inn = ''; 
my $man_fr = 300;  # initial G0 feedrate in manual mode 
my $man_ss = 1000; # initial Spindle speed in manual mode

my $prompt_grbl = 'GRBL>';
my $prompt_dbg  = 'DBG >';

my $lt = 0; my $wt = 0;

my $cmd_str = ''; my %macstr;
my $mode = 'idle';
my $len_file_field;

my %gst;
# initial values for gstwin_fill
($gst{TLO}, $gst{PRB}, $gst{GC} ) = ('0,0,0', '0,0,0', '0,0,0', '0,0,0');
($gst{G54}, $gst{G55}, $gst{G56}) = ('0,0,0', '0,0,0', '0,0,0', '0,0,0');
($gst{G57}, $gst{G58}, $gst{G59}) = ('0,0,0', '0,0,0', '0,0,0', '0,0,0');
($gst{G28}, $gst{G30}, $gst{G92}) = ('0,0,0', '0,0,0', '0,0,0', '0,0,0');

my $cfg_file = 'ncgcs.cfg';
my $cfg; 
my @axis = ('X', 'Y', 'Z', 'A', 'B', 'C');

local $SIG{INT} = sub { endwin(); @{$cfg->{HISTORY}} = @histcmd; save_cfg_file($cfg, $cfg_file); $port->close(); exit; }; # handled ^C
local $SIG{WINCH} = sub { endwin(); refresh(); clear(); init_gscr(); }; # handled resize
local $SIG{__WARN__} = sub { my $msg = shift; open(WARN, '>>', 'ncgcs.warn') && print(WARN $msg); close(WARN); }; # store warnings

$cfg = load_cfg_file($cfg_file);

@histcmd = defined($cfg->{HISTORY}) ? @{$cfg->{HISTORY}} : ();
$portname  = $cfg->{COM}{port}  || '/dev/ttyUSB0';
$portspeed = $cfg->{COM}{speed} || 115200;
my $naxis = my $default_axis = $cfg->{MAIN}{default_axis} || 3; # default axis num
my $timeout_poll_state = $cfg->{MAIN}{timeout_poll_state} || 0.2; # sec
my $timeout_resp       = $cfg->{MAIN}{timeout_resp}       || 2;   # sec
my $timeout_init       = $cfg->{MAIN}{timeout_init}       || 5;   # sec

if (!init_serial()) { print "Can't open serial port $portname. Sorry\n"; exit; }

my $file_gcode = $ARGV[0] || '';

init_gscr();

if (init_grbl())    { msg("\n$prompt_dbg Init GRBL OK"); $resp_ok = 1 } 
    else 	    { endwin(); print "No init GRBL. Sorry\n"; exit }
if (cmd_resp('$$')) { msg("$prompt_dbg Init reg OK") }
if (cmd_resp('?'))  { msg("$prompt_dbg Detect axis: $naxis") }
    else	    { msg("$prompt_dbg Axis not detected, use default: $naxis") }

@axis = @axis[0..$naxis-1]; # truncate to available axis

if ($naxis != $default_axis) { init_gscr() } # redraw

if (cmd_resp('$I')) { msg("$prompt_dbg VER: ". $gst{VER} ." OPT: ". $gst{OPT}); 
		      msg("$prompt_dbg rxBufferSize: ". $gst{RXBS}) }
if (cmd_resp('$N')) { foreach (0..1) { msg("$prompt_dbg Startup block: \$N$_=". $gst{N}[$_]) } }
    else	    { msg("$prompt_dbg Startup block not found") }
if (cmd_resp('$G') &&
    cmd_resp('$#')) { msg("$prompt_dbg Init gstate OK"); gstwin_fill() }

if ($file_gcode ne '') { @gfile = load_gcode_file($file_gcode) }

#open(CFG, ">", "ncgcs_cfg.dbg") && print(CFG Dumper $cfg); close(CFG);
#open(GST, ">", "ncgcs.gst") && print(GST Dumper \%gst); close(GST);
#store(\%gst, 'ncgcs_gst.store');

#################### MAIN CYCLE #################### 
my @gb = ();   # gbuff = 128b
my $gbl=0;     # gbuff length;
my $gbsize = defined($gst{RXBS}) ? $gst{RXBS} : 128; # default! danger!!

while (1) {
    my $nlt = time();

    if ($nlt-$lt >= $timeout_poll_state) {
	$lt = $nlt; $port->write("?");
    }

    if (my $rcv = $port->lookfor()) {
	parse_grbl_resp($rcv);
    }

    if ($resp_ok) { 
	$resp_ok = 0;
	$gbl -= @gb ? length(shift(@gb))+1 : 0;		# count sent buff
    }

    while (@gcmd) {
	if ($gbl+length($gcmd[0])+1 > $gbsize) { last }	# sent buff full
	my $gstr = shift(@gcmd);
	push(@gb, $gstr);				# store to sent buff
	$gbl += length($gstr)+1; 			#\r count sent buff
	
	$n_line++;

    	$monwin->addstr("> $gstr"); $monwin->refresh(); 
    	$port->write("$gstr\r");
    }

    $mode = key_manager($grbl_state, $mode);
        
    if ($nlt-$wt >=1 && $grbl_state eq 'Run') {	# work time
	$wt = $nlt; $work_time++; 
    }

    stiwin_fill(); # for work_time ticks & n_line
}

endwin();
#################### NCGCS_KEYS #################### 
sub key_manager
{
my  ($state, # grbl state
     $mode)  # ncgcs mode
     = @_;

my @akey = (
    [ q/\x18/, q/.*/, q/.*/, sub { $port->write(chr(0x18)); 			# [Ctrl+X] GRBL soft-reset
				   @gcmd=(); @gb=(); $gbl=0 } ],
    [ q/\x7E/, q/.*/, q/.*/, sub { $port->write('~') } ],			# [~] GRBL resume
    [ q/\x21/, q/.*/, q/.*/, sub { $port->write('!') } ],			# [!] GRBL hold
    [ q/\x3A/, q/.*/, q/.*/, sub { show_cmd() } ],				# [:] cmd
    [ q/\x55/, q/.*/, q/.*/, sub { push(@gcmd, '$X') } ],			# [U] $X - unlock
    [ q/\x4F/, q/.*/, q/.*/, sub { push(@gcmd, '$H') } ],			# [O] $H - home
    [ q/\x52/, q/.*/, q/.*/, sub { init_gstatistic(\@gfile) } ],		# [R] reload file (init statistic)

    # Feed Overrides
    [ q/\x1B\x12/, q/.*/, q/.*/, sub { $port->write(chr(0x90)) } ],		# [Ctrl+Alt+r] (100%)
    [ q/\x1B\x06/, q/.*/, q/.*/, sub { $port->write(chr(0x90)) } ],		# [Ctrl+Alt+f] (100%)
    [ q/\x1B\x52/, q/.*/, q/.*/, sub { $port->write(chr(0x91)) } ],		# [Alt+R] (+10%)
    [ q/\x1B\x46/, q/.*/, q/.*/, sub { $port->write(chr(0x92)) } ],		# [Alt+F] (-10%)
    [ q/\x1B\x72/, q/.*/, q/.*/, sub { $port->write(chr(0x93)) } ],		# [Alt+r] (+1%)
    [ q/\x1B\x66/, q/.*/, q/.*/, sub { $port->write(chr(0x94)) } ],		# [Alt+f] (-1%)
    # Rapid Overrides
    [ q/\x1B\x05/, q/.*/, q/.*/, sub { $port->write(chr(0x95)) } ],		# [Ctrl+Alt+e] (100%)
    [ q/\x1B\x04/, q/.*/, q/.*/, sub { $port->write(chr(0x95)) } ],		# [Ctrl+Alt+d] (100%)
    [ q/\x1B\x65/, q/.*/, q/.*/, sub { $port->write(chr(0x96)) } ],		# [Alt+e] (50%)
    [ q/\x1B\x64/, q/.*/, q/.*/, sub { $port->write(chr(0x97)) } ],		# [Alt+d] (25%)
    # Spindle Speed Overrides
    [ q/\x1B\x14/, q/.*/, q/.*/, sub { $port->write(chr(0x99)) } ],		# [Ctrl+Alt+t] (100%)
    [ q/\x1B\x07/, q/.*/, q/.*/, sub { $port->write(chr(0x99)) } ],		# [Ctrl+Alt+g] (100%)
    [ q/\x1B\x54/, q/.*/, q/.*/, sub { $port->write(chr(0x9A)) } ],		# [Alt+T] (+10%)
    [ q/\x1B\x47/, q/.*/, q/.*/, sub { $port->write(chr(0x9B)) } ],		# [Alt+G] (-10%)
    [ q/\x1B\x74/, q/.*/, q/.*/, sub { $port->write(chr(0x9C)) } ],		# [Alt+t] (+1%)
    [ q/\x1B\x67/, q/.*/, q/.*/, sub { $port->write(chr(0x9D)) } ],		# [Alt+g] (-1%)

    [ q/\x3F/, q/Idle|Hold|Jog|Alarm|Door|Check|Home|Sleep/, q/.*/,             # [?] help
		sub { show_help() } ],
    [ q/\x53/, q/Idle|Check/, q/idle|stop/,                                     # [S] start send g-code
		sub {
		    @gcmd = @gfile; init_gstatistic(\@gcmd)
		} ],
    [ q/\x12/, q/Idle|Jog|Door|Check|Home|Sleep/, q/.*/,			# [Ctrl+R] regedit
		sub { cmd_resp('$$') && show_reg() } ],
    [ q/\x2A/, q/Idle|Jog|Door|Check|Home|Sleep/, q/.*/,			# [*] reload gstate
		sub { cmd_resp('$G') && cmd_resp('$#') && gstwin_fill() } ],
    [ q/\x50/, q/.*/, q/idle|stop|jog_/,					# [P] pause/resume send G-code
		sub {
		    if    (@gcmd != 0 && @gcmd_save == 0) { @gcmd_save = @gcmd; @gcmd = (); $mode = 'stop' }
                    elsif (@gcmd == 0 && @gcmd_save != 0) { @gcmd = @gcmd_save; @gcmd_save =(); init_gstatistic(\@gcmd); $mode = 'idle' } # only elsif!
                } ],
    [ q/\x4E/, q/.*/, q/.*/,							# [N] input g-file
		sub {
    		    if (defined(my $file = textfield_file($cfgwin, 0, 30+6, $file_gcode, 100, $len_file_field))) { # 100 <- max length of filename
    			$file_gcode = $file;
			@gfile = load_gcode_file($file_gcode);
		    }
		    cfgwin_fill();
		} ],
    [ q/\x54/, q/Idle/, q/.*/,							# [T] set origin
		sub {
    		    push(@gcmd, 'G92'. join '', map { $_.'0' } @axis[0..$naxis-1]); # G92G0X0Y0...
		    # make macros 0 for goto XY.. origin, 1 for goto Z origin
		    init_gstatistic(\@gcmd);
		    $cfg->{MACROS}{'@0'} = ''; 
		    $cfg->{MACROS}{'@1'} = '';

		    for (my $i=0; $i<$naxis; $i++) {
		        $cfg->{MACROS}{'@'.(($i == 2) ? 1 : 0)} .= "G90G0" . $axis[$i] . $mpos[$i]. ';'
		    }
		    macwin_fill();
		    push(@gcmd, '$#');
		} ],
    [ q/\x4A/, q/Idle/, q/idle|stop/,						# [J] Jog-mode
		sub { $mode = 'jog_' } ],
    [ q/[qwergb0-9]/, q/Idle/, q/jog_/,						# [J] Jog-mode input
		sub { 
		    my $ch = shift;
		    if ($ch =~ /[qwer]/) 	{ $man_mult = 0.1 * 10**(index('qwer', $ch)) }
		    elsif ($ch =~ /[0-9]/)	{ $man_inn .= (length($man_inn) < 4) ? $ch : '' }
    		    elsif ($ch eq 'g')          { if ($man_inn ne '') { $man_fr = $man_inn; $man_inn = '' } }
    		    elsif ($ch eq 'b')          { if ($man_inn ne '') { $man_ss = $man_inn; $man_inn = '' } }
		    manwin_fill();
		} ],
    [ q/[azsxdcfvhjklAZSXDCFVHJKL]/, q/Idle|Jog/, q/jog_/,			# [J] Jog-mode input axis & go
		sub {
		    my $ch = shift;
		    my $g; my $dir; my $gline;

		    if ($ch =~ /[azsxdcfvhjkl]/) { $g = 0 }
		    if ($ch =~ /[AZSXDCFVHJKL]/) { $g = 1 }
		    if ($ch =~ /[zxcvhjZXCVHJ]/) { $dir = -1 }
		    if ($ch =~ /[asdfklASDFKL]/) { $dir =  1 }

		    my $ax = $ch;
		    $ax =~ tr[hlHLjkJKazAZsxSXdcDCfvFV]
		             [XXXXYYYYZZZZAAAABBBBCCCC];
		    if (index(join('',@axis), $ax) == -1) { return }
		    
    		    $gline = "G91" . $ax . $man_mult*$dir*(($man_inn eq '') ? 1 : $man_inn);
    		    $man_inn = '';

		    manwin_fill();
		    my $i = index(join('', @axis), $ax);
		    $gline .= 'F'. ($g == 0 ? $gst{R}[110+$i] : $man_fr);

		    if (!@gcmd) { # jog cmd send only to empty buffer
			push(@gcmd, '$J='.$gline); init_gstatistic(\@gcmd)
		    }
		} ],
    [ q/\x1B/, q/.*/, q/mac_|mace/,                             # [ESC] Exit mac-mode
		sub {
		    $mode = 'idle';
		} ],
    [ q/\x1B/, q/.*/, q/jog_/,                                  # [ESC] Exit Jog-mode
		sub {
		    $man_inn = ''; manwin_fill();
		    $mode = 'idle';
		} ],
    [ q/\x1B/, q/Jog/, q/jog_/,					# [ESC] Stop Jogging
		sub {
		    msg('Jog ESC');
		    @gcmd = (); init_gstatistic(\@gcmd);
		    $port->write(chr(0x85));
		} ],
    [ q/\x40/, q/Idle/, q/idle|jog_/,				# [@] Macro-mode
		sub { $mode = 'mac_' } ],
    [ q/[0-9a-z]/, q/Idle/, q/mac_/,				# [] Macro-mode
		sub { my $ch = shift;
    		    if (defined($cfg->{MACROS}{'@'.$ch})) {
        		push(@gcmd,  split(/;/, $cfg->{MACROS}{'@'.$ch})); init_gstatistic(\@gcmd);
		    }
		    $mode = 'idle';
		} ],
    [ q/\x22/, q/Idle/, q/mac_/,				# ["] Macro-edit mode
		sub { $mode = 'mace' } ],
    [ q/[0-9a-z]/, q/Idle/, q/mace/,				# [] Macro-edit mode
		sub { my $ch = shift;
    		    if (!defined($cfg->{MACROS}{'@'.$ch})) { # add new macros
			$cfg->{MACROS}{'@'.$ch} = ''; macwin_fill();
		    }

    		    my $textmac = textfield($macwin, $macstr{'@'.$ch}, 6, $cfg->{MACROS}{'@'.$ch}, 200, 31); # 200 <- max length of macros string
		    if (defined($textmac)) { $cfg->{MACROS}{'@'.$ch} = $textmac }
		    macwin_fill();

		    $mode = 'idle';
		} ],
);
    
    my $c; my $ch = undef;
    while (($c = $win->getch()) ne ERR) { $ch .= $c }

    if (!defined($ch) || $ch eq ERR) { return $mode; }

    foreach (@akey) {
	my ($mask_ch, $mask_state, $mask_mode, $sub) = @{$_};
	if ($ch =~ /^$mask_ch$/ && $state =~ /$mask_state/ && $mode =~ /$mask_mode/) {
	    $sub->($ch); last
	}
    }

    return $mode;
}

################### GRBL #################### 
sub parse_grbl_resp
{
my $str = shift; my $t;

    $str =~ s/\n|\r//g;

    if    ($str =~ /^<.*>/) 			{ parse_grbl_stat($str); statwin_fill(); return; }

    if    ($str =~ /^ok/)			{ $resp_ok = 1 }
    elsif ($str =~ /Grbl/) 			{ $resp_ok = 1 } # for Ctrl+x (soft reset)

    elsif (($t) = $str =~ /^ALARM:(\d+)$/)	{ $resp_ok = 1; msg(msg_alarm($t)) }
    elsif (($t) = $str =~ /^error:(\d+)$/)	{ $resp_ok = 1; msg(msg_error($t)) }

    elsif (($t) = $str =~ /^\[MSG:(.*)\]$/)	{ msg($t) }

    #$0=10
    elsif (my ($r, $v) = $str =~ /^\$([0-9]*)=([0-9\.-]*)$/) { $gst{R}[$r] = $v }
    #[HLP:
    elsif (($t) = $str =~ /^\[HLP:(.*)\]$/)	{ msg($t) }
    #[VER:1.1d.20161014:]
    elsif (($t) = $str =~ /^\[VER:(.*)\]$/)	{ $gst{VER} = $t }
    #[OPT:,15,128]
    elsif (my ($opt, undef, $rxbl, $rxbs) = $str =~ /^\[OPT:(([^,]*),(\d*),(\d*))\]$/)	{ $gst{OPT} = $opt; $gst{RXBS} = $rxbs }
    #[echo:
    elsif (($t) = $str =~ /^\[echo:(.*)\]$/)	{ msg($t) }
    #[Gxxx
    elsif (my ($gc, $gv) = $str =~ /^\[(GC|G[0-9]{2}|TLO|PRB):(.*)\]$/)	{ $gst{$gc} = $gv; gstwin_fill() }
    elsif (my ($n, $sv) = $str =~ /\$N([0-2])=(.*)$/) { $gst{N}[$n] = $sv }
    $monwin->attron(A_BOLD);
    $monwin->addstr(" < $str\n");
    $monwin->attroff(A_BOLD);
    $monwin->refresh();
}

sub parse_grbl_stat
{
my $str = shift;
my $tpos = ''; my $all_pos; my $all_wco;
my @pos;

#<Idle|WPos:-20.000,0.000,0.000|Bf:15,128|FS:0,0|WCO:20.000,0.000,0.000>
#<Idle|WPos:-20.000,0.000,0.000|Bf:15,128|FS:0,0|Ov:100,100,100>

    $grbl_buf = '';
    $str =~ s/<|>//g;
    my @fstat = split(/\|/, $str);

    $grbl_state = $fstat[0];
    foreach my $f (@fstat) {
        if ($f =~ /^WPos|^MPos/) {
	    ($tpos, $all_pos) = ($f =~ /^([^:]*):([\d\.,-]*)/);
	    @pos = split(/,/, $all_pos);
        }
        if ($f =~ /^WCO/) {
	    (undef, $all_wco) = ($f =~ /^([^:]*):([\d\.,-]*)/);
	    @wco = split(/,/, $all_wco);
        }
	if ($f =~ /^Bf/) {
	    (undef, $grbl_buf) = ($f =~ /^([^:]*):([\d\.,-]*)/) 
	}
        if ($f =~ /^FS/) {
	    (undef, $grbl_fr, $grbl_ss) = ($f =~ /^(.*):([\d\.-]*),([\d\.-]*)/);
        }
        if ($f =~ /^Ov/) {
	    (undef, $grbl_ovf, $grbl_ovr, $grbl_ovs) = ($f =~ /^(.*):([\d\.-]*),([\d\.-]*),([\d\.-]*)/);
        }
    }

    for (my $i=0; $i<$naxis; $i++) {
        if ($tpos eq 'WPos') { $wpos[$i] = $pos[$i]; $mpos[$i] = $wpos[$i]+$wco[$i]; }
        if ($tpos eq 'MPos') { $mpos[$i] = $pos[$i]; $wpos[$i] = $mpos[$i]-$wco[$i]; }
    }
}

sub cmd_resp
{
    my $cmd = shift;

    my $timeout = time() + $timeout_resp; # sec timeout execute poll

    $port->write("$cmd\r"); 
    $monwin->addstr("> $cmd\n"); $monwin->refresh();
    
    while ($timeout >= time()) {
        if (my $s = $port->lookfor) { 
            $s =~ s/\n|\r//g;
	    parse_grbl_resp($s);
            if ( $s =~ m/ok/) { $port->lookclear; return 1 }
        }
    }
    return 0
}

sub init_grbl
{
    while (my $t = $port->lookfor) { sleep 0.1 }; $port->lookclear;
                
    $msgwin->addstr($prompt_dbg." ");
    $port->write("\r\r"); # для stm32, он иногда error присылает на \n

    my $timeout = time() + $timeout_init; # sec timeout execute poll
    while ($timeout >= time()) {
        if (my $s = $port->lookfor) { 
            $s =~ s/\n|\r//g; 
            if (length($s)) { $monwin->addstr("$s\n"); $monwin->refresh(); }
            if ( $s =~ m/Grbl/) { $port->write("\r"); } # Eсли есть надпись Grbl, то \n не отработает, нужен этот
	    if ( $s =~ m/error|ALARM/) { parse_grbl_resp($s); }
	    if ( $s =~ m/^ok/) { $port->lookclear; return(1); }
        }
    }
    return(0);
}
#################### COMM #################### 
sub init_serial
{
    if ($os eq 'win32') { $port = Win32::SerialPort->new($portname); $port->initialize(); }
    if ($os eq 'linux') { $port = Device::SerialPort->new($portname); }
    if (!$port) { return 0 }

    $|=1; # disable buffering

    $port->handshake("none");
    $port->baudrate($portspeed);
    $port->databits(8);
    $port->parity("none");
    $port->stopbits(1);
    return 1;
}
#################### NCGCS #################### 
sub init_gstatistic
{
my $g = shift;
my @gcode = @{$g};

    $n_line = 0;
    $work_time = 0;

    my $line = $total_line = $#gcode+1;
    $total_path = 0; $total_time = 0;

# stub
}

sub load_cfg_file
{
my $cfg_file = shift;
my $h; my $d = ''; my ($th, $ta);

    if (!open(CONFIG, '<', $cfg_file)) { warn "Cannot open $cfg_file"; return }

    while (<CONFIG>) {
        chomp;
        if (/^\s*\#/ || /^$/) { next; }

        if (/\[(.*)\]/) { $d = $1; $d =~ s/\s+$//; $d =~ s/^\s+//; $ta = $th = undef; next }    # section
        if (/^([0-9]+)\s*=\s*(.+)$/) { push(@$ta, $2); $h->{$d} = $ta; next };                  # array
        if (/^([@\w]+)\s*=\s*(.+)$/) { $th->{$1} = $2; $h->{$d} = $th; next }                   # hash
#       if (/^(.*)$/) { push(@$ta, $1); $h->{$d} = $ta };                                       # array
    }

    close(CONFIG);
    return($h); 
}

sub save_cfg_file
{
my $h = shift;
my $cfg_file = shift;

    if (!rename("$cfg_file", "$cfg_file.bak")) { warn "Cannot rename $cfg_file"; }
    if (!open(CONFIG, '>', $cfg_file)) { warn "Cannot open $cfg_file"; return }

    foreach my $section ('MAIN', 'COM', 'MACROS', 'HISTORY') {
        print CONFIG "[$section]\n";

        if ($section eq 'HISTORY') {
            my $n = 0;
            foreach (@{$h->{$section}}) {
                print CONFIG $n++. " = ". $_. "\n";
            }
        } else {
            foreach (sort keys %{$h->{$section}}) {
                print CONFIG $_ . " = ". $h->{$section}{$_}. "\n";
            }
        }
        print CONFIG "\n";
    }

    close(CONFIG);
}

sub load_gcode_file
{
my $file = shift;
my @gfile = ();

    if (!open(INFILE, "<", $file)) { 
	msg("File open error: $file"); open(INFILE, "<", '/dev/null');
    } else {
	 msg("File open ok: $file");
    }
    local $/;
    push(@gfile, split("\r\n|\r|\n", <INFILE>));
    close(INFILE);

    return @gfile;
}
#################### WIN #################### 
sub init_gscr
{ 
    endwin(); initscr();
    $win = Curses->new();
    cbreak(); $win->timeout(0); noecho(); curs_set(0);

    $win->getmaxyx($row, $col); # 40x127 (my eepc)
    
    my $w2c = 40; # ширина колонок
    my $w3c = 40;
    my $w1c = $col-$w2c-$w3c;

    my $msgrow = 10;
    my $statrow = 13;
    my $stirow = 6;
    my $manrow = 4;
    my $macrow = $row-$statrow-$stirow-$manrow-1; # 14
    my $gstrow = ($naxis+1)*3+6+2;
    my $dbgrow = $row-$gstrow-1;
        
# monitor window
    $bmonwin = $win->derwin($row-$msgrow-1, $w1c, 1, 0);
    if (!defined($bmonwin)) { err_win_size(); return }
    $bmonwin->box(0, 0);
    $bmonwin->addstr(0, 2, ' monitor ');
    $monwin = $bmonwin->derwin($row-$msgrow-1-2, $w1c-2, 1, 1);
    $monwin->scrollok(1);

# message window
    $bmsgwin = $win->derwin($msgrow, $w1c, $row-$msgrow, 0);
    if (!defined($bmsgwin)) { err_win_size(); return }
    $bmsgwin->box(0, 0);
    $bmsgwin->addstr(0, 2, ' messages ');
    $msgwin = $bmsgwin->derwin($msgrow-2, $w1c-2, 1, 1);
    $msgwin->scrollok(1);

# cfg window
    $cfgwin = $win->derwin(1, $col, 0, 0);
    if (!defined($cfgwin)) { err_win_size(); return }
    cfgwin_fill();

# status window
    $statwin = $win->derwin($statrow, $w2c, 1, $w1c);
    if (!defined($statwin)) { err_win_size(); return }
    $statwin->box(0, 0);
    $statwin->addstr(0, 2, ' status ');
    statwin_fill();

# statistic window
    $stiwin = $win->derwin($stirow, $w2c, $statrow+1, $w1c);
    if (!defined($stiwin)) { err_win_size(); return }
    $stiwin->box(0, 0);
    $stiwin->addstr(0, 2, ' statistic ');
    stiwin_fill();    

# manual_mode window
    $manwin = $win->derwin($manrow, $w2c, $statrow+$stirow+1 , $w1c);
    if (!defined($manwin)) { err_win_size(); return }
    $manwin->box(0, 0);
    $manwin->addstr(0, 2, ' manual ');
    manwin_fill();    

# macro window
    $bmacwin = $win->derwin($macrow, $w2c, $statrow+$stirow+$manrow+1, $w1c);
    if (!defined($bmacwin)) { err_win_size(); return }
    $bmacwin->box(0, 0);
    $bmacwin->addstr(0, 2, ' macros ');
    $macwin = $bmacwin->derwin($macrow-2, $w2c-2, 1, 1);
    macwin_fill();
    
# gstate window
    $gstwin = $win->derwin($gstrow, $w3c, 1, $w1c+$w2c);
    if (!defined($gstwin)) { err_win_size(); return }
    $gstwin->box(0, 0);
    $gstwin->addstr(0, 2, ' gstate ');
    #gstwin_fill();
    
# debug window
    $bdbgwin = $win->derwin($dbgrow, $w3c, $gstrow+1, $w1c+$w2c);
    $bdbgwin->box(0,0);
    $bdbgwin->addstr(0, 2, ' debug ');
    $dbgwin = $bdbgwin->derwin($dbgrow-2, $w3c-2, 1, 1);
    $dbgwin->scrollok(1);

    $win->refresh();
}

sub gstwin_fill
{
    if (!defined($gstwin)) { return }
    
    $gstwin->addstr( 1, 2, sprintf("GC: ". join ' ', grep {/^G/} split / /, $gst{GC} ));    # only G*
    $gstwin->addstr( 2, 2, sprintf("GC: ". join ' ', grep {/^[^G]/} split / /, $gst{GC} )); # only ^G*
    $gstwin->addstr( 4, 2, sprintf("       G54:       G55:       G56:"));
    foreach (0..$#axis) {
        $gstwin->addstr( 5+$_, 2, sprintf('%s: %10.3f %10.3f %10.3f', $axis[$_], 
    				  (split(/,/, $gst{G54}))[$_], (split(/,/, $gst{G55}))[$_], (split(/,/, $gst{G56}))[$_] ));
    }
    $gstwin->addstr( 4+($naxis+1)*1, 2, sprintf("       G57:       G58:       G59:"));
    foreach (0..$#axis) {
        $gstwin->addstr( 5+($naxis+1)*1+$_, 2, sprintf('%s: %10.3f %10.3f %10.3f', $axis[$_], 
    				  (split(/,/, $gst{G57}))[$_], (split(/,/, $gst{G58}))[$_], (split(/,/, $gst{G59}))[$_] ));
    }
    $gstwin->addstr( 4+($naxis+1)*2, 2, sprintf("       G28:       G30:       G92:"));
    foreach (0..$#axis) {
        $gstwin->addstr( 5+($naxis+1)*2+$_, 2, sprintf('%s: %10.3f %10.3f %10.3f', $axis[$_],
    				  (split(/,/, $gst{G28}))[$_], (split(/,/, $gst{G30}))[$_], (split(/,/, $gst{G92}))[$_] ));
    }
    $gstwin->addstr(5+($naxis+1)*3, 2, sprintf("TLO: ". $gst{TLO}));
    $gstwin->addstr(6+($naxis+1)*3, 2, sprintf("PRB: ". $gst{PRB}));

    $gstwin->refresh();
}

sub statwin_fill
{
my $attr = A_NORMAL;

    if (!defined($statwin)) { return }
    
    $statwin->addstr( 1, 3, sprintf('       MPos:      WPos:      WCO:'));
    for (my $i=0; $i<$naxis; $i++) {
	$statwin->addstr( 2+$i, 3, sprintf('%s: %10.3f %10.3f %10.3f', $axis[$i], $mpos[$i], $wpos[$i], $wco[$i]));
    }

    $statwin->addstr( 8, 2, sprintf('Buffer State: %6s', $grbl_buf));
    $statwin->addstr( 9, 2, sprintf('Override feeds: %3u %%  State: ', $grbl_ovf));
    #Idle, Run, Hold, Jog, Alarm, Door, Check, Home, Sleep
    if    ($grbl_state =~ /Idle/)  { $attr = A_BOLD }
    elsif ($grbl_state =~ /Run/)   { $attr = A_BOLD | A_REVERSE }
    elsif ($grbl_state =~ /Hold/)  { $attr = A_BOLD | A_BLINK }
    elsif ($grbl_state =~ /Jog/)   { $attr = A_BOLD | A_REVERSE }
    elsif ($grbl_state =~ /Alarm/) { $attr = A_BOLD | A_STANDOUT | A_BLINK }
    elsif ($grbl_state =~ /Door/)  { $attr = A_BOLD }
    elsif ($grbl_state =~ /Check/) { $attr = A_BOLD | A_DIM }
    elsif ($grbl_state =~ /Home/)  { $attr = A_BOLD | A_BLINK }
    elsif ($grbl_state =~ /Sleep/) { $attr = A_BOLD | A_DIM }
    $statwin->attron($attr);
        $statwin->addstr(sprintf('%6s', $grbl_state));
    $statwin->attroff($attr);
    $statwin->addstr(10, 2, sprintf('        rapids: %3u %%     FR: %5u', $grbl_ovr, $grbl_fr));
    $statwin->addstr(11, 2, sprintf(' spindle speed: %3u %%     SS: %5u', $grbl_ovs, $grbl_ss));

    $statwin->refresh();
}

sub stiwin_fill 
{ 
my $attr = A_NORMAL;

    if (!defined($stiwin)) { return }

    my $remain_time = ($total_time > $work_time) ? $total_time - $work_time : 0;

    $stiwin->addstr(1, 2, sprintf("lines:%6d  current:%6d  %4u %%", $total_line, $n_line, $n_line*100/(($total_line == 0) ? 1 : $total_line))); 
#   $stiwin->addstr(2, 2, sprintf("path: %6d  current:%6d  %%:%3d", $total_path, $cur_path, $cur_path*100/$total_path)); 
    $stiwin->addstr(3, 2, sprintf("work time:   %02d:%02d:%02d", ($work_time/(60*60))%24,   ($work_time/60)%60, $work_time%60 )); 
    $stiwin->addstr(4, 2, sprintf("remain time: %02d:%02d:%02d", ($remain_time/(60*60))%24, ($remain_time/60)%60, $remain_time%60 )); 
    $stiwin->addstr(3, 33, sprintf("mode:")); 

    if ($mode !~ /idle/)  { $attr = A_BOLD | A_BLINK }
    $stiwin->attron($attr);
	$stiwin->addstr(4, 33, sprintf("%s", $mode)); 
    $stiwin->attroff($attr);

    $stiwin->refresh();
}

sub manwin_fill
{
    if (!defined($manwin)) { return }

    $manwin->addstr(1, 2, sprintf('Mult:   x%3s             G1 FR: %4s', $man_mult, $man_fr));
    $manwin->addstr(2, 2, sprintf(' InN: [%5s]            G1 SS: %4s', $man_inn, $man_ss));

    $manwin->refresh();
}

sub macwin_fill
{
    if (!defined($macwin)) { return }

    my $nstr = 0; 
    foreach my $key (sort(keys %{$cfg->{MACROS}})) {
	$macstr{$key} = $nstr;
	$macwin->addstr($nstr++, 1, sprintf("$key = ". substr($cfg->{MACROS}{$key}, 0, 31) . ((length($cfg->{MACROS}{$key})>31) ? '>' : '' ) ));
    }

    $macwin->refresh();
}

sub cfgwin_fill
{
    if (!defined($cfgwin)) { return }

    $cfgwin->clear();
    $cfgwin->addstr(0, 0, "Port: [$portspeed] $portname"); # len field = 30
    $len_file_field = $col-6-30-1; # 6 = length 'File: '
    $cfgwin->addstr(0, 30, "File: ". substr($file_gcode, 0, $len_file_field). 
					((length($file_gcode)>$len_file_field) ? '>' : '')  );
    $cfgwin->refresh();
}

sub dbgwin_fill
{
    #if (!defined($dbgwin)) { return }
    #$dbgwin->clear();
    #foreach (0..$#gb) {
	#$dbgwin->addstr($_+1, 0, $_ . ' : ' . $gb[$_] );
    #}
    #$dbgwin->refresh();
}

sub err_win_size # заглушка
{ }
#################### INTERFACE #################### 
sub msg
{
my $txt = shift;

    foreach (split(/\n/, $txt)) { $msgwin->addstr("$prompt_grbl $_\n") }
    $msgwin->refresh();
}

sub msg_alarm
{
my $alarm = shift;
my %msg = (
    1 => {  msg   => "Hard limit triggered", 
	    rem   => "Machine position is likely lost due to sudden and immediate halt.\nRe-homing is highly recommended." },
    2 => {  msg   => "G-code motion target exceeds machine travel",
	    rem   => "Machine position safely retained.\nAlarm may be unlocked." },
    3 => {  msg   => "Reset while in motion",
	    rem   => "Grbl cannot guarantee position.\nLost steps are likely. Re-homing is highly recommended." },
    4 => {  msg   => "Probe fail",
	    rem   => "The probe is not in the expected initial state before starting probe cycle,\nwhere G38.2 and G38.3 is not triggered and G38.4 and G38.5 is triggered." },
    5 => {  msg   => "Probe fail",
	    rem   => "Probe did not contact the workpiece within the programmed travel for G38.2 and G38.4." },
    6 => {  msg   => "Homing fail",
	    rem   => "Reset during active homing cycle." },
    7 => {  msg   => "Homing fail", 
	    rem	  => "Safety door was opened during active homing cycle." },
    8 => {  msg   => "Homing fail",
	    rem   => "Cycle failed to clear limit switch when pulling off.\nTry increasing pull-off setting or check wiring." },
    9 => {  msg   => "Homing fail",
	    rem   => "Could not find limit switch within search distance.\nDefined as 1.5 * max_travel on search and 5 * pulloff on locate phases."}
    );
    if (!defined($msg{$alarm})) { return '' }
    return "ALARM:$alarm: ". $msg{$alarm}{msg}. "\n(". $msg{$alarm}{rem}. ")";
}

sub msg_error
{
my $error = shift;
my %msg = (
    1  => "G-code words consist of a letter and a value. Letter was not found.",
    2  => "Numeric value format is not valid or missing an expected value.",
    3  => "Grbl '$' system command was not recognized or supported.",
    4  => "Negative value received for an expected positive value.",
    5  => "Homing cycle is not enabled via settings.",
    6  => "Minimum step pulse time must be greater than 3usec",
    7  => "EEPROM read failed. Reset and restored to default values.",
    8  => "Grbl '$' command cannot be used unless Grbl is IDLE. Ensures smooth operation during a job.",
    9  => "G-code locked out during alarm or jog state",
    10 => "Soft limits cannot be enabled without homing also enabled.",
    11 => "Max characters per line exceeded. Line was not processed and executed.",
    12 => "(Compile Option) Grbl '$' setting value exceeds the maximum step rate supported.",
    13 => "Safety door detected as opened and door state initiated.",
    14 => "(Grbl-Mega Only) Build info or startup line exceeded EEPROM line length limit.",
    15 => "Jog target exceeds machine travel. Command ignored.",
    16 => "Jog command with no '=' or contains prohibited g-code",
    17 => "Laser mode requires PWM output.",
    20 => "Unsupported or invalid g-code command found in block.",
    21 => "More than one g-code command from same modal group found in block.",
    22 => "Feed rate has not yet been set or is undefined.",
    23 => "G-code command in block requires an integer value.",
    24 => "Two G-code commands that both require the use of the XYZ axis words were detected in the block.",
    25 => "A G-code word was repeated in the block.",
    26 => "A G-code command implicitly or explicitly requires XYZ axis words in the block, but none were detected.",
    27 => "N line number value is not within the valid range of 1 - 9,999,999.",
    28 => "A G-code command was sent, but is missing some required P or L value words in the line.",
    29 => "Grbl supports six work coordinate systems G54-G59. G59.1, G59.2, and G59.3 are not supported.",
    30 => "The G53 G-code command requires either a G0 seek or G1 feed motion mode to be active. A different motion was active.",
    31 => "There are unused axis words in the block and G80 motion mode cancel is active.",
    32 => "A G2 or G3 arc was commanded but there are no XYZ axis words in the selected plane to trace the arc.",
    33 => "The motion command has an invalid target. G2, G3, and G38.2 generates this error, if the arc is impossible to generate or if the probe target is the current position.",
    34 => "A G2 or G3 arc, traced with the radius definition, had a mathematical error when computing the arc geometry. Try either breaking up the arc into semi-circles or quadrants, or redefine them with the arc offset definition.",
    35 => "A G2 or G3 arc, traced with the offset definition, is missing the IJK offset word in the selected plane to trace the arc.",
    36 => "There are unused, leftover G-code words that aren\'t used by any command in the block.",
    37 => "The G43.1 dynamic tool length offset command cannot apply an offset to an axis other than its configured axis. The Grbl default axis is the Z-axis.",
    38 => "Tool number greater than max supported value."
);
    if (!defined($msg{$error})) { return '' }
    return "error:$error: ". $msg{$error};
}

sub show_cmd
{
    my $cmdwin = newwin(1, $col, 0, 0);
       $cmdwin->addstr(0, 0, ': ');

    my $gline = textfield_hist($cmdwin, 0, 2, '', 100, $col-2, \@histcmd);
    if (defined($gline)) {
	push(@gcmd, $gline); 
	push(@histcmd, $gline); 
	init_gstatistic(\@gcmd);
    }

    $cmdwin->delwin();

    $win->touchwin();
    $win->refresh();

    flushinp(); # flush input buff for Fkeys
}

sub show_reg
{
    if (!@{$gst{R}}) { return }

    my $rcol = 19; # необходимая ширина и высота окна
    my $rrow = 0;

    foreach (@{$gst{R}}) { if (defined($_)) { $rrow++ } }
    if ($rrow > $row) { warn "rrow: $rrow, row: $row"; return } # screen too small
    
    my $regwin = newwin($rrow+2, $rcol+2, ($row-($rrow+2))>>1, ($col-$rcol)>>1);
       $regwin->box(0, 0);
       $regwin->addstr(0, 2, ' GRBL reg ');
    my $bregwin = $regwin->derwin($rrow, $rcol, 1, 1);
       $regwin->timeout(0);

    my $n=0; my @rnstr;
    foreach (0..$#{$gst{R}}) {
	if (defined($gst{R}[$_])) { 
	    $rnstr[$_] = $n; # store reg and string position
	    $bregwin->addstr($n++, 1, sprintf('%4s = %-1.3f', '$'.$_, $gst{R}[$_])) 
	}
    }    
    $regwin->refresh();

    my $inreg = '';
    while (1) {
	my $ch = $regwin->getch();

	if ($ch eq ERR) { next }

	if (ord($ch) == 0x1B) { $ch = $regwin->getch(); if ($ch eq ERR || ord($ch) == 0x1B) { last }} # ESC+ESC
	if (ord($ch) == 0x12) { last } # Ctrl+R

	if ($ch =~ /^[0-9\.-]$/) { $inreg .= $ch }

	if (ord($ch) == 0x0A) { # Enter
	    if ($inreg ne '' && defined($gst{R}[$inreg])) {
	        my $reg_value = textfield($regwin, $rnstr[$inreg]+1, 9, sprintf('%-1.3f', $gst{R}[$inreg]), 10, 10);
	        if (defined($reg_value) && cmd_resp("\$$inreg=$reg_value")) { cmd_resp('$$') }
	    }
	    last;
	}
    }

    $regwin->delwin();

    $win->touchwin();
    $win->refresh();

    flushinp(); # flush input buff for Fkeys
}

sub show_help
{
    my $bhlpwin = newwin($row-5*2, $col-25*2, 5, 25);
       $bhlpwin->box(0,0);  $bhlpwin->addstr(0, 2, ' help ');
    my $hlpwin = $bhlpwin->derwin($row-5*2-4, $col-25*2-4, 2, 2);

       $hlpwin->addstr('
Ctrl+C - program exit     Mode: @ = macro      Jog mode:
ESC - mode exit ||              : = command    h,H - left, l,L - right, j,J - down, k,K - up (like vi)
      cancel jogging ||         J = jog        a,A - axis Z up, z,Z - axis Z down (h,j,k,l,a,z for F<frg0>)
      cancel input                                                                (H,J,K,L,A,Z for F<frg1>)
				               (s-x, d-c, f-v - key for A,B,C axis)
Ctrl+X - soft reset (reset gcmd)               q - mult = 0.1 mm(inch)/step
! - hold                                       w - mult = 1   mm(inch)/step (default)
~ - resume                                     e - mult = 10  mm(inch)/step
O - home ($H)                                  r - mult = 100 mm(inch)/step
U - unlock ($X)                                g - set feedrate for G1
S - start send g-code                          b - set value for S
P - pause/resume send G-code                    ie:  100f = set 100 for feedrate G1 <frg1>
T - set origin (G92X0Y0Z0)                          w124L = $J=G91X124F<frg1> , 
* - refresh GRBL state                              q133J = $J=G91Y-13.3F<frg1> , 
R - reload file statistic                             r2k = $J=G91Y200F<frg0> etc...
N - input filename .gcode                      

: = cmd mode (the up and down arrow keys are   @<key>  - exec macros <key>
    available to access the command history)   @"<key> - edit macros <key>

Ctrl+R - regedit mode:
  <Ctrl+R>REGNUM<Enter> - edit register (Enter = Save it)
'); 
    $bhlpwin->refresh();
    $bhlpwin->getch();
    $bhlpwin->delwin();

    $win->touchwin();
    $win->refresh();

    flushinp(); # flush input buff for Fkeys
}

sub textfield 
{
my ($win,  # window
    $sty, $stx, # coords begin of field
    $str,  # initial string
    $smax, # max input string length
    $vmax, # max field length
    $sub   # addition key sub or undef
    ) = (@_);
my $vp; # visual position
my $sp; # string position = cursor

my $first = 1; # first step

    cbreak(); $win->timeout(0); $win->keypad(1); noecho(); curs_set(1);
    while(1) { 
	# init cursor position:
	#$sp = 0;                                 # begin str
	#$sp = defined($sp) ? $sp : length($str); # stay
	$sp = length($str);                       # end str

	if ($sp>=$vmax) { $vp=$sp-$vmax } else { $vp=0 }

	while (1) {
	    my $vstr = substr($str, $vp, $vmax);

	    $win->attron(A_BOLD);
	    # for show border:
	    #$win->addstr($sty, $stx-1, (($vp==0) ? '[':'<'). $vstr .' 'x($vmax-length($vstr)). ((length($str)-$vp<=$vmax) ? ']':'>'));
	    $win->addstr($sty, $stx-1, (($vp==0) ? ' ':'<'). $vstr .' 'x($vmax-length($vstr)). ((length($str)-$vp<=$vmax) ? ' ':'>'));
	    # or don't show border:
	    #$win->addstr($sty, $stx, $vstr .' 'x($vmax-length($vstr))); 
	    $win->attroff(A_BOLD);
	    
	    $win->move($sty, $stx+$sp-$vp);
	    $win->refresh();

	    my $ch = $win->getch();

	    if ($ch eq ERR) { next }

	    if ($first) { $first = 0; if ($ch eq KEY_DC) { $str = ''; last } if ($ch =~ /^[[:print:]]$/) { $str = $ch; last } }

    	    if (ord($ch) == 0x1B) { $ch = $win->getch(); if ($ch eq ERR || ord($ch) == 0x1B) { curs_set(0); return undef; } } # ESC
    	    if (ord($ch) == 0x0A) { curs_set(0); return $str; } # ENTER

    	    if ($ch =~ /^[[:print:]]$/) { if (length($str)+1 <= $smax) { substr($str, $sp, 0, $ch); $sp++; if ($sp>$vp+$vmax) { $vp++ } } }

    	    if ($ch eq KEY_HOME)      { $sp = 0; $vp = 0; }
    	    if ($ch eq KEY_END)       { $sp = length($str); $vp = $sp-$vmax; if ($vp<0) { $vp = 0 } }
    	    if ($ch eq KEY_RIGHT)     { if ($sp+1 <= length($str)) { $sp++ }; if ($sp>=$vp+$vmax+1) { $vp++ } } #
    	    if ($ch eq KEY_LEFT)      { if ($sp-1 >= 0) { $sp--;} if ($sp<$vp) { $vp-- } }
    	    if ($ch eq KEY_BACKSPACE) { if ($sp-1 >= 0) { $sp--; substr($str, $sp, 1) = ''; if ($vp>0) { $vp-- }} }
    	    if ($ch eq KEY_DC)        { substr($str, $sp, 1) = ''; }

	    if (defined($sub)) 	      { my $ret = $sub->($ch, $str); if (defined($ret)) { $str = $ret; last; } }
	}
    }
}

sub textfield_file 
{
my ($win,  # window
    $sty, $stx, # coords begin of field
    $str,  # initial string
    $smax, # max input string length
    $vmax, # max field length
    ) = (@_);

    $str = textfield($win, $sty, $stx, $str, $smax, $vmax, sub
	{
	my $ch = shift;
	my $str = shift;
	state $mask; state $cut;
    
	if (ord($ch) eq 0x09)  { # TAB show file names in current dir
    			         $mask = defined($mask) ? $mask : $str;
				 my @af = (sort(glob "'$mask*'"));
				 #if ($#af==1) { $mask = $str }
				 
    				 $str = defined($af[$cut]) ? $af[$cut] : $str;
				 if (-d $str && $str !~ /\/$/) { $str .= '/' }
				 if (!defined($cut) || $cut++ >= $#af) { $cut=0 }
				    
				 return $str;
    			       }
	else   { $cut = 0; $mask = undef; }
	return undef;
	}
    );
}

sub textfield_hist
{
my ($win,  # window
    $sty, $stx, # coords begin of field
    $str,  # initial string
    $smax, # max input string length
    $vmax, # max field length
    $ahist,# ref to array of hist
    ) = (@_);
            
    $str = textfield($win, $sty, $stx, $str, $smax, $vmax, sub
      {
        my $ch = shift;
        my $str = shift;
        state $nhist; state $store;

        if (!defined $nhist) { $nhist = $#{$ahist}+1 }

        if ($ch eq KEY_UP)      {
            if ($nhist == $#{$ahist}+1)	{ $store = $str }
            if ($nhist > 0) 		{ $nhist -= 1; }
            return ${$ahist}[$nhist]
        }
        if ($ch eq KEY_DOWN)    {
            if ($nhist  < $#{$ahist}) { $nhist += 1; return ${$ahist}[$nhist]  }
            if ($nhist == $#{$ahist}) { $nhist += 1; return $store; }
        }
        return undef;
      }
    );
}

