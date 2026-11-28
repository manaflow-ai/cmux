//! `claude setup-token` in a pty of our own: [`TokenFilter`] takes the `sk-ant-oat` token out of its
//! output, [`find_url`] reads the sign-in link out of it, and [`command`] is how both the daemon
//! (`claude_token::Service`) and `cmux cloud connect claude` start it.

#[cfg(unix)]
use std::os::fd::{FromRawFd as _, OwnedFd, RawFd};
#[cfg(unix)]
use std::os::unix::ffi::OsStrExt as _;
use std::path::{Path, PathBuf};

use zeroize::{Zeroize as _, Zeroizing};

/// What every `claude setup-token` token starts with.
pub const TOKEN_PREFIX: &str = "sk-ant-oat";
/// The shortest token taken as whole (`sk-ant-oat01-` and a long body): anything shorter was cut.
pub const MIN_TOKEN: usize = 40;
/// At least this many columns, so neither the link nor the token wraps onto a second line.
pub const MIN_COLUMNS: u16 = 200;
/// Variables the child must not see: with either set, `claude setup-token` first warns that
/// authentication is already configured.
pub const CLEARED_ENV: &[&str] = &["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN"];

/// The token bytes after the prefix: `claude setup-token` tokens are base64url with dashes.
fn token_byte(byte: u8) -> bool {
    byte.is_ascii_alphanumeric() || byte == b'-' || byte == b'_'
}

/// The child's output with the token taken out of it.
#[derive(Default)]
pub struct TokenFilter {
    /// Bytes not yet shown that may be the start of the token.
    held: Vec<u8>,
    /// The token so far, once its prefix was seen.
    token: Option<Zeroizing<Vec<u8>>>,
    /// The token ended: nothing more is shown or taken.
    done: bool,
}

impl TokenFilter {
    /// The part of `chunk` (and what was held before it) that is safe to show now.
    pub fn push(&mut self, chunk: &[u8]) -> Vec<u8> {
        if self.done {
            return Vec::new();
        }
        if self.token.is_some() {
            self.take_token(chunk);
            return Vec::new();
        }
        self.held.extend_from_slice(chunk);
        let prefix = TOKEN_PREFIX.as_bytes();
        if let Some(at) = self.held.windows(prefix.len()).position(|w| w == prefix) {
            let shown = self.held.get(..at).unwrap_or_default().to_vec();
            let mut rest = self.held.split_off(at);
            self.held.clear();
            let mut token = Zeroizing::new(Vec::with_capacity(256));
            token.extend_from_slice(prefix);
            self.token = Some(token);
            self.take_token(rest.get(prefix.len()..).unwrap_or_default());
            rest.zeroize();
            return shown;
        }
        let keep = (1..prefix.len())
            .rev()
            .find(|&k| prefix.get(..k).is_some_and(|p| self.held.ends_with(p)))
            .unwrap_or(0);
        let show = self.held.len() - keep;
        self.held.drain(..show).collect()
    }

    fn take_token(&mut self, bytes: &[u8]) {
        let Some(token) = self.token.as_mut() else { return };
        for &byte in bytes {
            if !token_byte(byte) {
                self.done = true;
                return;
            }
            token.push(byte);
        }
    }

    /// Whether the whole token has been read.
    pub fn done(&self) -> bool {
        self.done
    }

    /// At the end: what was still held (it was no token), and the token if one came.
    pub fn finish(mut self) -> (Vec<u8>, Option<Zeroizing<String>>) {
        let held = std::mem::take(&mut self.held);
        let token = self.token.take().and_then(|mut bytes| {
            let text = String::from_utf8(std::mem::take(&mut *bytes)).ok()?;
            Some(Zeroizing::new(text))
        });
        (held, token)
    }
}

/// `text` without terminal escapes: CSI (`ESC [ ... final`), OSC (`ESC ] ... BEL` or `ESC \`,
/// an OSC 8 hyperlink's target with it) and two-byte escapes. An escape cut off at the end is
/// dropped; the next read brings it whole.
pub fn strip_ansi(text: &[u8]) -> Vec<u8> {
    let mut out = Vec::with_capacity(text.len());
    let mut i = 0;
    while let Some(&byte) = text.get(i) {
        if byte != 0x1b {
            out.push(byte);
            i += 1;
            continue;
        }
        match text.get(i + 1) {
            Some(b'[') => {
                i += 2;
                while text.get(i).is_some_and(|b| !(0x40..=0x7e).contains(b)) {
                    i += 1;
                }
                i += 1;
            }
            Some(b']') => {
                i += 2;
                loop {
                    match text.get(i) {
                        None => break,
                        Some(0x07) => {
                            i += 1;
                            break;
                        }
                        Some(0x1b) if text.get(i + 1) == Some(&b'\\') => {
                            i += 2;
                            break;
                        }
                        Some(_) => i += 1,
                    }
                }
            }
            Some(_) => i += 2,
            None => i += 1,
        }
    }
    out
}

/// A URL byte as a terminal prints one: printable ASCII but space and quotes.
fn url_byte(byte: u8) -> bool {
    byte.is_ascii_graphic() && !matches!(byte, b'"' | b'\'' | b'<' | b'>' | b'`')
}

/// The sign-in link in `output` (raw, escapes and all), once it is whole: a claude.ai or
/// claude.com `https://` URL with `oauth/authorize` in it, ended by a byte no URL has.
pub fn find_url(output: &[u8]) -> Option<String> {
    let text = strip_ansi(output);
    let mut from = 0;
    while let Some(at) = text.get(from..)?.windows(8).position(|w| w == b"https://") {
        let start = from + at;
        let rest = text.get(start..)?;
        let len = rest.iter().position(|&b| !url_byte(b));
        from = start + 8;
        let len = len?;
        let url = std::str::from_utf8(rest.get(..len)?).ok()?;
        let host = url.trim_start_matches("https://").split('/').next().unwrap_or_default();
        if matches!(host, "claude.ai" | "claude.com") && url.contains("oauth/authorize") {
            return Some(url.to_owned());
        }
    }
    None
}

/// The `claude` this daemon runs: `CMUX_CLAUDE_BIN` when set, else `claude` on the login PATH or
/// in `~/.local/bin` (as a launcher is found).
pub fn program() -> PathBuf {
    match std::env::var("CMUX_CLAUDE_BIN").ok().filter(|p| !p.is_empty()) {
        Some(program) => program.into(),
        None => crate::config::user_program("claude"),
    }
}

/// `program setup-token` on the pty slave at `slave`, a new session's leader so the pty is its
/// controlling terminal, without [`CLEARED_ENV`]. `BROWSER` is `true` so it opens no browser of
/// its own when `no_browser` (the app opens the link where the person is).
pub fn command(program: &Path, slave: &Path, no_browser: bool) -> cmux_process::Command {
    let mut command = cmux_process::Command::new(program);
    command.arg("setup-token").new_session().open_stdin_path(slave);
    for key in CLEARED_ENV {
        command.env_remove(key);
    }
    if no_browser {
        command.env("BROWSER", "/usr/bin/true");
    }
    if let Some(path) = crate::login_env::path() {
        command.env("PATH", path);
    }
    command.env("TERM", "xterm-256color");
    command
}

#[cfg(unix)]
/// A new pty `columns` wide: its master, its slave and the slave's path, both close-on-exec.
pub fn open_pty(columns: u16) -> Result<(OwnedFd, OwnedFd, PathBuf), String> {
    let mut name = [0 as libc::c_char; 128];
    let mut master: libc::c_int = -1;
    let mut slave: libc::c_int = -1;
    let size = libc::winsize { ws_row: 40, ws_col: columns, ws_xpixel: 0, ws_ypixel: 0 };
    // SAFETY: openpty fills both fds and the slave's name (a short /dev path); termios may be null.
    let opened = unsafe {
        libc::openpty(
            &mut master,
            &mut slave,
            name.as_mut_ptr(),
            std::ptr::null_mut(),
            &size as *const _ as *mut _,
        )
    };
    if opened != 0 {
        return Err(format!(
            "cannot open a terminal for claude: {}",
            std::io::Error::last_os_error()
        ));
    }
    for fd in [master, slave] {
        // SAFETY: sets close-on-exec on our own fds, so the child keeps only its stdio copies.
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    // SAFETY: openpty returned two fds this process now owns, each wrapped once.
    let (master, slave) = unsafe { (OwnedFd::from_raw_fd(master), OwnedFd::from_raw_fd(slave)) };
    // SAFETY: openpty wrote a NUL-terminated name into `name`.
    let path = unsafe { std::ffi::CStr::from_ptr(name.as_ptr()) };
    let path = PathBuf::from(std::ffi::OsStr::from_bytes(path.to_bytes()));
    Ok((master, slave, path))
}

#[cfg(unix)]
/// All of `bytes` to `fd`; false when it stops taking them.
pub fn write_all(fd: RawFd, bytes: &[u8]) -> bool {
    let mut written = 0usize;
    while written < bytes.len() {
        let rest = bytes.get(written..).unwrap_or_default();
        // SAFETY: writes from our own buffer to an fd the caller owns.
        let w = unsafe { libc::write(fd, rest.as_ptr().cast(), rest.len()) };
        if w < 0 && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
            continue;
        }
        if w <= 0 {
            return false;
        }
        written += w as usize;
    }
    true
}

#[cfg(unix)]
/// Ends `child`'s process group (it leads one: [`command`] starts a new session), then `child`
/// if it is still there 2 s later. Only for a child this process spawned and has not reaped.
pub fn stop(child: &mut cmux_process::Child) {
    if child.try_wait().ok().flatten().is_some() {
        return;
    }
    if let Ok(pid) = libc::pid_t::try_from(child.id()) {
        // SAFETY: signals the group of a child this process spawned and has not reaped.
        if unsafe { libc::kill(-pid, libc::SIGTERM) } != 0 {
            // SAFETY: as above; no group yet: the child itself.
            unsafe { libc::kill(pid, libc::SIGTERM) };
        }
    }
    if !child.exited_within(std::time::Duration::from_secs(2)).unwrap_or(false) {
        let _ = child.kill();
    }
}
