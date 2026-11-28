//! The daemon's TCP listeners outlive a service-manager restart (2026-11-25: a self-update's
//! `systemctl --user restart acpmux.service` refused the vault egress proxy's port for about 3 s,
//! and four Claude Code subagents whose requests went through it died mid-turn).
//!
//! `daemon/listener_handover.rs` keeps the listen queues open across a `--take-over` start, which
//! overlaps the two daemons. A restart through systemd or launchd does not: the manager stops the
//! old daemon, then starts the new one, and nothing holds the ports in between. So a daemon that
//! stops for a restart without having handed its listeners on ([`hold_for_next`]):
//!
//! 1. starts a keeper, `acpmux __hold-listeners`, with copies of the web listener and the egress
//!    proxy's listener as inherited descriptors. On Linux in a user service it starts under
//!    `systemd-run --user --scope`, so the unit's stop does not end it with the daemon (as agent
//!    hosts leave it, `agent_host/scope.rs`); elsewhere it is in its own session;
//! 2. waits for the keeper to say it holds them (at most [`READY_WITHIN`]), then stops as before;
//! 3. a connect from then on waits in the kernel's queue, which the keeper's copy keeps open;
//! 4. the next daemon, holding the lock, takes them from the keeper's socket in the home
//!    ([`take_held`]) before it binds, and accepts what queued. The keeper then ends, or after
//!    [`HOLD_FOR`] with no daemon to take them: its copies close, and a connect is refused, as
//!    before.
//!
//! The keeper only holds: `accept()` keeps no state, so nothing the daemon serves moves out of it.
//! A daemon that cannot start the keeper stops as before.

use std::ffi::OsString;
use std::io::{self, BufRead as _};
use std::os::fd::{AsRawFd, FromRawFd as _, OwnedFd, RawFd};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use super::listener_handover::{self, Received};

/// The keeper's argument: `acpmux __hold-listeners HOME KIND=FD...`.
pub(crate) const HOLD_ARG: &str = "__hold-listeners";
/// The keeper's socket, in the home.
const HELD: &str = "listeners-held.sock";
/// How long a keeper holds the listeners for the next daemon.
// timeout: no daemon comes back (a `systemctl stop`, a failed start); its copies then close.
const HOLD_FOR: Duration = Duration::from_secs(30);
/// How long the stopping daemon waits for its keeper to hold.
// timeout: a keeper that never starts; the daemon then stops as before.
const READY_WITHIN: Duration = Duration::from_secs(2);
/// How long the next daemon waits on the keeper's socket.
// timeout: a keeper that stops mid-handover; the daemon then binds as before.
const TAKE_WITHIN: Duration = Duration::from_secs(3);
/// What the keeper prints once it holds.
const READY: &str = "held";

fn held_path(home: &Path) -> PathBuf {
    home.join(HELD)
}

/// The stopping daemon's side: start a keeper with copies of its TCP listeners. The kinds held.
pub(crate) fn hold_for_next(home: &Path) -> Vec<&'static str> {
    let held = listener_handover::offered_tcp();
    if held.is_empty() || !cmux_unix_socket::fits(&held_path(home)) {
        return Vec::new();
    }
    match start_keeper(home, &held) {
        Ok(()) => {
            listener_handover::mark_kept();
            let kinds: Vec<&'static str> = held.iter().map(|(kind, _)| kind_name(kind)).collect();
            tracing::info!(?kinds, "a listener keeper holds this daemon's ports for the next one");
            kinds
        }
        Err(e) => {
            tracing::warn!("no listener keeper, the ports close with this daemon: {e}");
            Vec::new()
        }
    }
}

fn kind_name(kind: &[u8; 4]) -> &'static str {
    match kind {
        b"egrs" => "egress",
        b"ws\0\0" => "ws",
        _ => "unix",
    }
}

fn start_keeper(home: &Path, held: &[(&'static [u8; 4], OwnedFd)]) -> io::Result<()> {
    use std::os::unix::process::CommandExt as _;
    let exe = keeper_exe()?;
    let mut args: Vec<OsString> = vec![HOLD_ARG.into(), home.as_os_str().to_owned()];
    for (kind, fd) in held {
        args.push(format!("{}={}", kind_name(kind), fd.as_raw_fd()).into());
    }
    let prefix = scope_prefix();
    let mut cmd = match prefix.as_deref().and_then(<[_]>::split_first) {
        Some((program, rest)) => {
            let mut cmd = std::process::Command::new(program);
            cmd.args(rest).arg(&exe);
            cmd
        }
        None => std::process::Command::new(&exe),
    };
    cmd.args(&args)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null());
    let fds: Vec<RawFd> = held.iter().map(|(_, fd)| fd.as_raw_fd()).collect();
    // SAFETY: between fork and exec only async-signal-safe calls (setsid, fcntl) on descriptors
    // this process owns. The copies stay close-on-exec here, so no other child inherits them.
    unsafe {
        cmd.pre_exec(move || {
            libc::setsid();
            for &fd in &fds {
                if libc::fcntl(fd, libc::F_SETFD, 0) != 0 {
                    return Err(io::Error::last_os_error());
                }
            }
            Ok(())
        });
    }
    let mut child = cmd.spawn()?;
    let stdout = child.stdout.take().ok_or_else(|| io::Error::other("no keeper stdout"))?;
    let (tx, rx) = std::sync::mpsc::channel();
    std::thread::spawn(move || {
        let mut line = String::new();
        let _ = io::BufReader::new(stdout).read_line(&mut line);
        let _ = tx.send(line);
    });
    // The keeper (or `systemd-run`, which execs it) is reaped by whoever outlives this daemon.
    drop(child);
    match rx.recv_timeout(READY_WITHIN) {
        Ok(line) if line.trim() == READY => Ok(()),
        Ok(line) => Err(io::Error::other(format!("the keeper said {:?}", line.trim()))),
        Err(_) => Err(io::Error::other("the keeper did not hold in time")),
    }
}

/// The binary the keeper runs: this daemon's own, even when an update replaced the file.
fn keeper_exe() -> io::Result<PathBuf> {
    #[cfg(target_os = "linux")]
    return Ok(PathBuf::from(format!("/proc/{}/exe", std::process::id())));
    #[cfg(not(target_os = "linux"))]
    std::env::current_exe()
}

/// `systemd-run --user --scope …` when this daemon runs in a user service unit, whose stop would
/// otherwise end the keeper with it.
fn scope_prefix() -> Option<Vec<OsString>> {
    #[cfg(target_os = "linux")]
    {
        let cgroup = std::fs::read_to_string("/proc/self/cgroup").ok()?;
        if !crate::agent_host::scope::in_user_service(&cgroup) {
            return None;
        }
        let runner = crate::session_scope::scope_runner()?;
        Some(vec![
            runner.into(),
            "--user".into(),
            "--scope".into(),
            "--quiet".into(),
            "--collect".into(),
            format!("--slice={}", crate::agent_host::scope::HOST_SLICE).into(),
            format!("--unit=acpmux-listener-keeper-{}.scope", std::process::id()).into(),
            "--".into(),
        ])
    }
    #[cfg(not(target_os = "linux"))]
    None
}

/// The next daemon's side: the listeners a keeper holds for this home, if one does.
pub(crate) fn take_held(home: &Path) -> Received {
    let path = held_path(home);
    let mut received = Received::default();
    if !path.exists() {
        return received;
    }
    let stream = match UnixStream::connect(&path) {
        Ok(stream) => stream,
        Err(_) => return received,
    };
    let _ = stream.set_read_timeout(Some(TAKE_WITHIN));
    while let Ok((kind, fd)) = cmux_unix_socket::descriptor::receive(&stream, 4) {
        if let Some(fd) = fd {
            listener_handover::add_received(&mut received, &kind, fd);
        }
    }
    tracing::info!(
        ws = received.ws.is_some(),
        egress = received.egress.is_some(),
        "took the listeners a keeper held across the restart"
    );
    received
}

/// The keeper process: `acpmux __hold-listeners HOME KIND=FD...`.
pub fn main(args: &[OsString]) -> anyhow::Result<()> {
    let home = PathBuf::from(args.first().ok_or_else(|| anyhow::anyhow!("no home"))?);
    let mut held = Vec::new();
    for arg in args.get(1..).unwrap_or_default() {
        let arg = arg.to_string_lossy();
        let Some((kind, fd)) = arg.split_once('=') else { continue };
        let kind: &'static [u8; 4] = match kind {
            "egress" => b"egrs",
            "ws" => b"ws\0\0",
            _ => continue,
        };
        let fd: RawFd = fd.parse()?;
        anyhow::ensure!(is_socket(fd), "descriptor {fd} is not a socket");
        // SAFETY: the daemon passed this descriptor to this process for it alone.
        let fd = unsafe { OwnedFd::from_raw_fd(fd) };
        // SAFETY: a valid descriptor this process owns.
        unsafe { libc::fcntl(fd.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) };
        widen_backlog(&fd);
        held.push((kind, fd));
    }
    let path = held_path(&home);
    let listener = bind_held(&path)?;
    {
        use std::io::Write as _;
        let mut out = io::stdout().lock();
        writeln!(out, "{READY}")?;
        out.flush()?;
    }
    // Nothing reads stdout any more: the daemon that read it has stopped.
    // SAFETY: closing this process's own stdout once, with nothing writing to it later.
    unsafe { libc::close(1) };
    let _ = serve(&listener, &held, HOLD_FOR);
    let _ = std::fs::remove_file(&path);
    Ok(())
}

/// Nothing accepts while the listener is held, so every connect of the handover waits in its
/// backlog; std binds with 128, which a busy few seconds can fill (a full backlog drops SYNs, and
/// the client retries for a second or more). Listening again on a listening socket only resizes
/// its queue, up to the kernel's somaxconn.
fn widen_backlog(fd: &OwnedFd) {
    // SAFETY: listen on a valid socket this process holds.
    unsafe { libc::listen(fd.as_raw_fd(), libc::SOMAXCONN.max(4096)) };
}

fn is_socket(fd: RawFd) -> bool {
    // SAFETY: fstat into a zeroed buffer of the right type.
    let mut stat: libc::stat = unsafe { std::mem::zeroed() };
    (unsafe { libc::fstat(fd, &raw mut stat) }) == 0
        && stat.st_mode & libc::S_IFMT == libc::S_IFSOCK
}

fn bind_held(path: &Path) -> io::Result<UnixListener> {
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    use std::os::unix::fs::PermissionsExt as _;
    std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o600))?;
    Ok(listener)
}

/// Hand the held listeners to the first process that connects within `within`. Whether one did.
fn serve(listener: &UnixListener, held: &[(&'static [u8; 4], OwnedFd)], within: Duration) -> bool {
    let deadline = Instant::now() + within;
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return false;
        }
        let mut poll = libc::pollfd { fd: listener.as_raw_fd(), events: libc::POLLIN, revents: 0 };
        let ms = i32::try_from(left.as_millis()).unwrap_or(i32::MAX).max(1);
        // SAFETY: one valid pollfd.
        if unsafe { libc::poll(&raw mut poll, 1, ms) } <= 0 {
            continue;
        }
        let Ok((stream, _)) = listener.accept() else { continue };
        let _ = stream.set_write_timeout(Some(TAKE_WITHIN));
        for (kind, fd) in held {
            if cmux_unix_socket::descriptor::send(&stream, *kind, fd.as_raw_fd()).is_err() {
                break;
            }
        }
        return true;
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::fd::AsFd as _;

    /// Connects to `port` every few ms while `gap` runs: how many were refused, of how many.
    fn connect_through(port: u16, gap: impl FnOnce()) -> (usize, usize, Vec<std::net::TcpStream>) {
        let stop = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
        let dialer = {
            let stop = stop.clone();
            std::thread::spawn(move || {
                let (mut refused, mut total, mut open) = (0, 0, Vec::new());
                while !stop.load(std::sync::atomic::Ordering::SeqCst) {
                    total += 1;
                    match std::net::TcpStream::connect(("127.0.0.1", port)) {
                        Ok(s) => open.push(s),
                        Err(_) => refused += 1,
                    }
                    std::thread::sleep(Duration::from_millis(2));
                }
                (refused, total, open)
            })
        };
        std::thread::sleep(Duration::from_millis(30));
        gap();
        std::thread::sleep(Duration::from_millis(30));
        stop.store(true, std::sync::atomic::Ordering::SeqCst);
        dialer.join().unwrap()
    }

    /// The restart as a service manager runs it: the old daemon's listener closes, 300 ms pass,
    /// the next daemon serves the port. Before this every connect in between was refused (the
    /// control below); with a keeper holding a copy none is, and the next daemon accepts each one
    /// that queued.
    #[test]
    fn connects_across_a_restart_are_never_refused() {
        // Control: the old code's restart, close then bind again.
        let old = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = old.local_addr().unwrap().port();
        let mut slot = Some(old);
        let mut next = None;
        let (refused, total, _) = connect_through(port, || {
            drop(slot.take());
            std::thread::sleep(Duration::from_millis(300));
            next = Some(std::net::TcpListener::bind(("127.0.0.1", port)).unwrap());
        });
        assert!(
            refused > 0,
            "the control restart refused none of {total}: the gap is not measured"
        );
        drop(next);

        // With a keeper.
        let dir = cmux_unix_socket::short_test_dir("lkp");
        let home = dir.path().to_path_buf();
        let daemon = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = daemon.local_addr().unwrap().port();
        let copy = daemon.as_fd().try_clone_to_owned().unwrap();
        widen_backlog(&copy);
        let socket = bind_held(&held_path(&home)).unwrap();
        let keeper = std::thread::spawn(move || {
            let held: [(&'static [u8; 4], OwnedFd); 1] = [(b"egrs", copy)];
            serve(&socket, &held, Duration::from_secs(10))
        });
        let mut taken = None;
        let (refused, total, open) = connect_through(port, || {
            drop(daemon);
            std::thread::sleep(Duration::from_millis(300));
            taken = take_held(&home).egress;
        });
        assert!(keeper.join().unwrap(), "the keeper handed its listener on");
        assert_eq!(refused, 0, "{refused} of {total} connects refused across the restart");
        let taken = taken.expect("the next daemon took the egress listener");
        assert_eq!(taken.local_addr().unwrap().port(), port);
        taken.set_nonblocking(true).unwrap();
        let mut accepted = 0;
        while taken.accept().is_ok() {
            accepted += 1;
        }
        assert_eq!(accepted, open.len(), "every connect is served by the next daemon");
    }

    /// A home with no keeper gives nothing, at once.
    #[test]
    fn no_keeper_takes_nothing() {
        let dir = cmux_unix_socket::short_test_dir("lkn");
        let got = take_held(dir.path());
        assert!(got.ws.is_none() && got.egress.is_none());
    }
}
