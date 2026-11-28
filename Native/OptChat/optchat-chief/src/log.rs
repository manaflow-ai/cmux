//! One plain line per event on stderr, which the app sends to
//! `$MUX_HOME/host.log` (section 10: plain output, the terminal's scrollback works).

/// Writes `line` with a local timestamp.
pub fn log(line: impl AsRef<str>) {
    let now = chrono::Local::now().format("%Y-%m-%d %H:%M:%S%.3f");
    eprintln!("{now} optchat-chief: {}", line.as_ref());
}
