use std::env;
use std::ffi::c_int;
use std::fs;
use std::io::{self, Read, Write};
use std::mem::MaybeUninit;
use std::process;
use std::thread;
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const STDIN_FILENO: c_int = 0;
const STDOUT_FILENO: c_int = 1;
const TIOCGWINSZ: u64 = 0x4008_7468;
const TCSAFLUSH: c_int = 2;
const SIGINT: c_int = 2;
const SIGTERM: c_int = 15;

const ICANON: u64 = 0x0000_0100;
const ECHO: u64 = 0x0000_0008;
const IEXTEN: u64 = 0x0000_0400;
const ISIG: u64 = 0x0000_0080;
const IXON: u64 = 0x0000_0200;
const ICRNL: u64 = 0x0000_0100;
const OPOST: u64 = 0x0000_0001;
const VMIN: usize = 16;
const VTIME: usize = 17;

static mut ORIGINAL_TERMIOS: Option<Termios> = None;
static mut NEEDS_RESTORE: bool = false;

#[repr(C)]
#[derive(Clone, Copy)]
struct Winsize {
    ws_row: u16,
    ws_col: u16,
    ws_xpixel: u16,
    ws_ypixel: u16,
}

#[repr(C)]
#[derive(Clone, Copy)]
struct Termios {
    c_iflag: u64,
    c_oflag: u64,
    c_cflag: u64,
    c_lflag: u64,
    c_cc: [u8; 20],
    c_ispeed: u64,
    c_ospeed: u64,
}

unsafe extern "C" {
    fn ioctl(fd: c_int, request: u64, ...) -> c_int;
    fn tcgetattr(fd: c_int, termios_p: *mut Termios) -> c_int;
    fn tcsetattr(fd: c_int, optional_actions: c_int, termios_p: *const Termios) -> c_int;
    fn signal(signum: c_int, handler: extern "C" fn(c_int)) -> extern "C" fn(c_int);
}

#[derive(Clone)]
struct Config {
    interval: Duration,
    once: bool,
    report_path: Option<String>,
    probe_pattern: bool,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
struct Size {
    rows: usize,
    cols: usize,
}

impl Size {
    fn clamped(rows: usize, cols: usize) -> Self {
        Self {
            rows: rows.max(1),
            cols: cols.max(1),
        }
    }
}

extern "C" fn handle_signal(_: c_int) {
    restore_terminal();
    process::exit(130);
}

fn main() {
    if let Err(error) = run() {
        let _ = writeln!(io::stderr(), "cmux-size-tui: {error}");
        restore_terminal();
        process::exit(1);
    }
}

fn run() -> io::Result<()> {
    let config = parse_args()?;
    let size = terminal_size();

    if config.once {
        write_report(&config, size)?;
        println!("cmux-size-tui cols={} rows={}", size.cols, size.rows);
        return Ok(());
    }

    install_signal_handlers();
    enter_terminal_mode()?;

    let result = run_loop(&config);
    restore_terminal();
    result
}

fn usage() -> &'static str {
    "Usage: cmux-size-tui [--once] [--probe-pattern] [--interval seconds] [--report-path path]\n\n\
Draws a full-terminal border and live size readout. Resize the containing pane;\n\
the border should stay pinned to every edge and cols x rows should update.\n\n\
Keys: q or Esc exits."
}

fn parse_args() -> io::Result<Config> {
    let mut interval = Duration::from_millis(16);
    let mut once = false;
    let mut report_path = None;
    let mut probe_pattern = false;
    let mut args = env::args().skip(1);

    while let Some(arg) = args.next() {
        match arg.as_str() {
            "--once" => once = true,
            "--probe-pattern" => probe_pattern = true,
            "--interval" => {
                let value = args.next().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "--interval requires a value")
                })?;
                let seconds = value.parse::<f64>().map_err(|_| {
                    io::Error::new(io::ErrorKind::InvalidInput, "invalid --interval value")
                })?;
                let millis = (seconds.max(0.005) * 1000.0).round() as u64;
                interval = Duration::from_millis(millis.max(5));
            }
            "--report-path" => {
                report_path = Some(args.next().ok_or_else(|| {
                    io::Error::new(io::ErrorKind::InvalidInput, "--report-path requires a path")
                })?);
            }
            "-h" | "--help" => {
                println!("{}", usage());
                process::exit(0);
            }
            _ => {
                return Err(io::Error::new(
                    io::ErrorKind::InvalidInput,
                    format!("unknown argument: {arg}\n{}", usage()),
                ));
            }
        }
    }

    Ok(Config {
        interval,
        once,
        report_path,
        probe_pattern,
    })
}

fn install_signal_handlers() {
    unsafe {
        let _ = signal(SIGINT, handle_signal);
        let _ = signal(SIGTERM, handle_signal);
    }
}

fn enter_terminal_mode() -> io::Result<()> {
    let mut termios = MaybeUninit::<Termios>::uninit();
    let rc = unsafe { tcgetattr(STDIN_FILENO, termios.as_mut_ptr()) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }

    let original = unsafe { termios.assume_init() };
    let mut raw = original;
    raw.c_lflag &= !(ECHO | ICANON | IEXTEN | ISIG);
    raw.c_iflag &= !(IXON | ICRNL);
    raw.c_oflag &= !OPOST;
    raw.c_cc[VMIN] = 0;
    raw.c_cc[VTIME] = 0;

    let rc = unsafe { tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }

    unsafe {
        ORIGINAL_TERMIOS = Some(original);
        NEEDS_RESTORE = true;
    }

    write_all("\x1b[?1049h\x1b[?25l\x1b[?7l\x1b[2J\x1b[H")
}

fn restore_terminal() {
    unsafe {
        if NEEDS_RESTORE {
            if let Some(original) = ORIGINAL_TERMIOS {
                let _ = tcsetattr(STDIN_FILENO, TCSAFLUSH, &original);
            }
            let _ = write_all("\x1b[?7h\x1b[?25h\x1b[?1049l");
            NEEDS_RESTORE = false;
        }
    }
}

fn run_loop(config: &Config) -> io::Result<()> {
    let mut last_size = Size::clamped(0, 0);
    let mut last_reported_size = Size::clamped(0, 0);
    let mut last_reported_at: Option<Instant> = None;
    let mut frames: u64 = 0;
    let started = Instant::now();

    loop {
        let size = terminal_size();
        if size != last_reported_size
            || last_reported_at
                .map(|instant| instant.elapsed() >= Duration::from_secs(1))
                .unwrap_or(true)
        {
            write_report(config, size)?;
            last_reported_size = size;
            last_reported_at = Some(Instant::now());
        }

        let force_clear = size != last_size;
        draw(config, size, frames, started.elapsed(), force_clear)?;
        last_size = size;
        frames += 1;

        if should_exit(config.interval)? {
            break;
        }
    }

    Ok(())
}

fn should_exit(timeout: Duration) -> io::Result<bool> {
    let deadline = Instant::now() + timeout;
    let mut stdin = io::stdin();
    let mut buf = [0_u8; 32];

    loop {
        match stdin.read(&mut buf) {
            Ok(0) => {}
            Ok(count) => {
                for byte in &buf[..count] {
                    if matches!(*byte, b'q' | b'Q' | 0x1b | 0x03) {
                        return Ok(true);
                    }
                }
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {}
            Err(error) if error.kind() == io::ErrorKind::Interrupted => {}
            Err(error) => return Err(error),
        }

        let now = Instant::now();
        if now >= deadline {
            return Ok(false);
        }
        thread::sleep((deadline - now).min(Duration::from_millis(4)));
    }
}

fn terminal_size() -> Size {
    let mut winsize = Winsize {
        ws_row: 0,
        ws_col: 0,
        ws_xpixel: 0,
        ws_ypixel: 0,
    };
    let rc = unsafe { ioctl(STDOUT_FILENO, TIOCGWINSZ, &mut winsize) };
    if rc == 0 && winsize.ws_row > 0 && winsize.ws_col > 0 {
        return Size::clamped(winsize.ws_row as usize, winsize.ws_col as usize);
    }

    let rows = env::var("LINES")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(24);
    let cols = env::var("COLUMNS")
        .ok()
        .and_then(|value| value.parse::<usize>().ok())
        .unwrap_or(80);
    Size::clamped(rows, cols)
}

fn draw(
    config: &Config,
    size: Size,
    frames: u64,
    elapsed: Duration,
    force_clear: bool,
) -> io::Result<()> {
    let mut out = String::with_capacity(size.rows.saturating_mul(size.cols + 16) + 128);
    if force_clear {
        out.push_str("\x1b[2J");
    }
    out.push_str("\x1b[H");

    for row in 0..size.rows {
        out.push_str(&format!("\x1b[{};1H", row + 1));
        if config.probe_pattern {
            push_probe_row(&mut out, size, row);
        } else {
            out.push_str(&line_for_row(size, row, frames, elapsed));
        }
    }

    write_all(&out)
}

#[derive(Clone, Copy, Eq, PartialEq)]
enum ProbeCell {
    Background,
    Border,
    Red,
    Green,
    Blue,
}

impl ProbeCell {
    fn ansi_background(self) -> &'static str {
        match self {
            ProbeCell::Background => "\x1b[48;2;21;21;21m",
            ProbeCell::Border => "\x1b[48;2;0;180;255m",
            ProbeCell::Red => "\x1b[48;2;255;64;32m",
            ProbeCell::Green => "\x1b[48;2;0;255;80m",
            ProbeCell::Blue => "\x1b[48;2;40;80;255m",
        }
    }
}

fn push_probe_row(out: &mut String, size: Size, row: usize) {
    let mut current = None;
    for col in 0..size.cols {
        let cell = probe_cell(size, row, col);
        if current != Some(cell) {
            out.push_str(cell.ansi_background());
            current = Some(cell);
        }
        out.push(' ');
    }
    out.push_str("\x1b[0m");
}

fn probe_cell(size: Size, row: usize, col: usize) -> ProbeCell {
    if row == 0 || row + 1 == size.rows || col == 0 || col + 1 == size.cols {
        return ProbeCell::Border;
    }

    if point_in_rect(row, col, scaled_rect(size, 5, 24, 9, 8, 10, 7)) {
        return ProbeCell::Red;
    }

    if point_in_rect(row, col, scaled_rect(size, 13, 42, 8, 11, 10, 6)) {
        return ProbeCell::Green;
    }

    if point_in_rect(row, col, scaled_rect(size, 22, 28, 8, 10, 9, 6)) {
        return ProbeCell::Blue;
    }

    ProbeCell::Background
}

fn scaled_rect(
    size: Size,
    top_floor: usize,
    left_percent: usize,
    width_floor: usize,
    height_floor: usize,
    width_divisor: usize,
    height_divisor: usize,
) -> (usize, usize, usize, usize) {
    let top = top_floor.min(size.rows.saturating_sub(2));
    let left = ((size.cols * left_percent) / 100).min(size.cols.saturating_sub(2));
    let width = width_floor
        .max(size.cols / width_divisor)
        .min(size.cols.saturating_sub(left + 1));
    let height = height_floor
        .max(size.rows / height_divisor)
        .min(size.rows.saturating_sub(top + 1));
    (top, left, width.max(1), height.max(1))
}

fn point_in_rect(row: usize, col: usize, rect: (usize, usize, usize, usize)) -> bool {
    let (top, left, width, height) = rect;
    row >= top && row < top + height && col >= left && col < left + width
}

fn line_for_row(size: Size, row: usize, frames: u64, elapsed: Duration) -> String {
    if size.cols == 1 {
        return "|".to_string();
    }

    if size.rows == 1 {
        return fit_text(
            &format!("cmux-size-tui {}x{} q=exit", size.cols, size.rows),
            size.cols,
        );
    }

    if row == 0 || row + 1 == size.rows {
        return border_line(size.cols);
    }

    let label = match row {
        1 => format!(" CMUX SIZE TUI  {} cols x {} rows", size.cols, size.rows),
        3 => " Pane fit: border must touch every visible terminal edge".to_string(),
        4 => " Resize canvas card or outer window; readout should update immediately".to_string(),
        6 => format!(
            " Surface: {}",
            env::var("CMUX_SURFACE_ID").unwrap_or_else(|_| "unknown".into())
        ),
        7 => format!(
            " Workspace: {}",
            env::var("CMUX_WORKSPACE_ID").unwrap_or_else(|_| "unknown".into())
        ),
        9 => format!(" Frames: {}  Uptime: {:.2}s", frames, elapsed.as_secs_f64()),
        _ if row + 2 == size.rows => " q/Esc exits".to_string(),
        _ => String::new(),
    };

    content_line(size.cols, &label)
}

fn border_line(cols: usize) -> String {
    if cols == 1 {
        return "+".to_string();
    }
    let mut line = String::with_capacity(cols);
    line.push('+');
    line.extend(std::iter::repeat('-').take(cols.saturating_sub(2)));
    line.push('+');
    line
}

fn content_line(cols: usize, label: &str) -> String {
    if cols == 1 {
        return "|".to_string();
    }
    let inner_width = cols.saturating_sub(2);
    let mut line = String::with_capacity(cols);
    line.push('|');
    line.push_str(&fit_text(label, inner_width));
    line.push('|');
    line
}

fn fit_text(value: &str, width: usize) -> String {
    let mut text: String = value.chars().take(width).collect();
    let used = text.chars().count();
    if used < width {
        text.extend(std::iter::repeat(' ').take(width - used));
    }
    text
}

fn write_report(config: &Config, size: Size) -> io::Result<()> {
    let Some(path) = &config.report_path else {
        return Ok(());
    };
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let surface_id = env::var("CMUX_SURFACE_ID").unwrap_or_default();
    let workspace_id = env::var("CMUX_WORKSPACE_ID").unwrap_or_default();
    let body = format!(
        "{{\"cols\":{},\"rows\":{},\"surface_id\":\"{}\",\"workspace_id\":\"{}\",\"time\":{}}}\n",
        size.cols,
        size.rows,
        json_escape(&surface_id),
        json_escape(&workspace_id),
        timestamp
    );
    let tmp = format!("{path}.{}.tmp", process::id());
    fs::write(&tmp, body)?;
    fs::rename(tmp, path)
}

fn json_escape(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if c < ' ' => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

fn write_all(value: &str) -> io::Result<()> {
    let mut stdout = io::stdout();
    stdout.write_all(value.as_bytes())?;
    stdout.flush()
}
