//! A restart nobody notices (`acpmux.v2` `start`, Unix): `_acpmux/shutdown {restart: true}` execs
//! the installed build in place of this daemon, which keeps its listening sockets and its lock
//! through the exec. A client sees a pause and then `hello`; its dial in the meantime waits in the
//! kept socket's backlog and is never refused. SIGTERM and a store stop keep v1's exit: a
//! supervisor that sent SIGTERM starts the next daemon itself. So does a SIGTERM or SIGINT that
//! comes while a restart's stop runs ([`signalled`]): the stop ends as an exit, not an exec.
//!
//! 1. Before anything is fenced, the request resolves the path this daemon was installed at (the
//!    path, never the open inode: a restart after an update runs the new build) and runs it as
//!    `daemon handoff-check` with a deadline ([`CHECK_WITHIN`]): it prints its build and the
//!    handoff arguments it takes ([`check_line`]). A failed check leaves the daemon serving and
//!    answers the request with why ([`prepare`]). A check with no answer by the deadline (a
//!    build's first launch can take long) is no verdict: the restart is v1's exit.
//! 2. The stop ends the unix accept loop at once and keeps the listeners open, then fences and
//!    runs the whole persistence as any stop does. The socket file, `daemon.pid` and the owner
//!    record stay: the same pid serves on (the next image's `supervision::start` reads its own
//!    record as running and claims a new epoch). The lock goes into this holder, still locked.
//! 3. Once `daemon::run` returned, [`exec_if_armed`] clears close-on-exec on exactly the kept
//!    descriptors (the local listener, the WebSocket listener, the daemon lock; each a
//!    `F_DUPFD_CLOEXEC` copy kept here since its bind) and execs the program with this daemon's
//!    own arguments, each descriptor named by a `daemon run` argument ([`FLAGS`]), never by the
//!    environment, and the handoff count plus one.
//! 4. The new image is the same pid. It makes every handed descriptor close-on-exec first
//!    ([`Handed::take`]), then checks each before it uses it: the lock by its inode and a `flock`
//!    that succeeds, the local listener as a listening socket bound to the configured path, the
//!    WebSocket listener as a listening socket at the address it would bind. One that fails is
//!    closed and that piece starts as usual (take the lock, bind the socket).
//! 5. An exec that returns cannot unfire the fence: the daemon logs it, ends as v1's stop does and
//!    exits [`super::stop_causes::EXIT_HANDOFF_FAILED`], which its supervisor restarts on.
//!
//! After the exec the previous image's children are this process's children with no handle.
//! Those that ended already are reaped before this image starts anything ([`inherited`]). The
//! ones a stop leaves running (the agent hosts, the share sessions, the local router while a kept
//! agent uses it) are named by their own records and reaped as they exit ([`reap_inherited`]), so
//! none stays a zombie that answers `kill(pid, 0)` or keeps its start time.
//!
//! v2 connections get no `bye {restart: true}` frame yet: no such frame exists. Every connection
//! sees what a v1 restart gives it: EOF on the unix socket, the 1012 close on a WebSocket.

use std::ffi::{OsStr, OsString};
use std::net::SocketAddr;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU32, Ordering};
use std::sync::{Mutex, MutexGuard, PoisonError};
use std::time::Duration;

use super::lock::DaemonLock;

mod exec;
use exec::exec_with;

/// The inherited daemon lock.
pub(crate) const LOCK_FD: &str = "--handoff-lock-fd";
/// The inherited unix socket listener.
pub(crate) const UNIX_FD: &str = "--handoff-unix-fd";
/// The inherited WebSocket listener.
pub(crate) const WS_FD: &str = "--handoff-ws-fd";
/// How many restarts this process came through as an exec in place.
pub(crate) const COUNT: &str = "--handoff-count";
/// Every handoff argument of `daemon run`, as `daemon handoff-check` lists them.
pub(crate) const FLAGS: [&str; 4] = [LOCK_FD, UNIX_FD, WS_FD, COUNT];
/// The handoff this build takes, as `daemon handoff-check` names it.
const VERSION: u64 = 1;

/// How long `daemon handoff-check` may take. Past it there is no verdict on the build, and the
/// restart is v1's exit.
// timeout: the restart request waits for this child; a build that is slow to launch must not hold it.
const CHECK_WITHIN: Duration = Duration::from_secs(2);

/// The flags of `daemon run` that name one of this process's own descriptors or a handoff, each
/// with its value: none of them is the next process's.
const PER_PROCESS: [&str; 6] = ["--ready-fd", "--person-key-fd", LOCK_FD, UNIX_FD, WS_FD, COUNT];

/// `start` in `acpmux.v2` as this daemon read it at its start.
static ENABLED: AtomicBool = AtomicBool::new(false);
/// This process's handoff count (`--handoff-count`; 0 on a normal start).
static HANDOFFS: AtomicU32 = AtomicU32::new(0);
/// The descriptors kept for the exec, and the exec once a restart request armed it.
static KEPT: Mutex<Kept> = Mutex::new(Kept::new());
/// SIGTERM or SIGINT came while the stop that hands off ran ([`signalled`]).
static SIGNALLED: AtomicBool = AtomicBool::new(false);

struct Kept {
    /// A close-on-exec copy of the unix socket listener, made when it was bound.
    unix: Option<OwnedFd>,
    /// A close-on-exec copy of the WebSocket listener, made when it was bound.
    ws: Option<OwnedFd>,
    /// The daemon lock, still locked, once the stop's persistence let it go.
    lock: Option<DaemonLock>,
    /// What the exec runs, once a restart request's check passed.
    armed: Option<Exec>,
    /// The request that armed it is beginning the stop ([`commit`]): until then nothing execs.
    committed: bool,
    /// The stop began: whether it hands off is decided, and no request arms it any more.
    frozen: bool,
    /// The socket file was still the one this daemon bound when its stop looked.
    socket_ours: bool,
}

struct Exec {
    /// The installed path, never the open inode.
    program: PathBuf,
    /// This process's own `argv[0]`: a cmux-tui copy named `acpmux` runs as acpmux by that name.
    arg0: OsString,
    /// This daemon's arguments through `run` and its own flags, without [`PER_PROCESS`]; the
    /// handoff's flags are added at the exec.
    args: Vec<String>,
}

impl Kept {
    const fn new() -> Self {
        Self {
            unix: None,
            ws: None,
            lock: None,
            armed: None,
            committed: false,
            frozen: false,
            socket_ours: false,
        }
    }

    /// [`commit`].
    fn commit(&mut self) -> bool {
        self.committed = !self.frozen && self.armed.is_some();
        self.committed
    }

    /// [`confirm`].
    fn confirm(&mut self, by_request: bool) -> bool {
        self.frozen = true;
        if !(by_request && self.committed) {
            self.armed = None;
        }
        self.armed.is_some()
    }
}

fn kept() -> MutexGuard<'static, Kept> {
    KEPT.lock().unwrap_or_else(PoisonError::into_inner)
}

/// At the start: whether `start` is in `acpmux.v2`, and this process's handoff count.
pub(super) fn start(enabled: bool, count: u32) {
    ENABLED.store(enabled, Ordering::SeqCst);
    HANDOFFS.store(count, Ordering::SeqCst);
}

fn enabled() -> bool {
    ENABLED.load(Ordering::SeqCst)
}

/// How many restarts this process came through as an exec in place (`_acpmux/status`
/// `handoffs`).
pub(crate) fn count() -> u32 {
    HANDOFFS.load(Ordering::SeqCst)
}

/// The line `daemon handoff-check` prints: this build, and the handoff it takes.
pub(crate) fn check_line() -> serde_json::Value {
    serde_json::json!({"build": crate::build_info::build(), "handoff": VERSION, "args": FLAGS})
}

/// A close-on-exec copy of `fd` (at 3 or above): no agent or host the daemon starts holds it.
fn dup(fd: RawFd, what: &str) -> Option<OwnedFd> {
    // SAFETY: F_DUPFD_CLOEXEC makes a new descriptor of the open description `fd` names.
    let copy = unsafe { libc::fcntl(fd, libc::F_DUPFD_CLOEXEC, 3) };
    if copy < 0 {
        tracing::warn!(
            "restart handoff: no copy of the {what}: {}",
            std::io::Error::last_os_error()
        );
        return None;
    }
    // SAFETY: `copy` was just made, and nothing else owns it.
    Some(unsafe { OwnedFd::from_raw_fd(copy) })
}

/// The unix socket listener as bound (or bound again, `daemon/socket_rebind.rs`): kept for the
/// exec, in place of the one before. Only with `start`.
pub(super) fn keep_unix(fd: RawFd) {
    if enabled() {
        let copy = dup(fd, "unix socket listener");
        kept().unix = copy;
    }
}

/// The WebSocket listener as bound: kept for the exec. Only with `start`.
pub(super) fn keep_ws(fd: RawFd) {
    if enabled() {
        let copy = dup(fd, "WebSocket listener");
        kept().ws = copy;
    }
}

/// `_acpmux/shutdown {restart: true}` (`server/requests.rs`), before anything changes: `None`
/// keeps v1's exit (no `start`, a take-over successor's handover, which is already the next
/// daemon, a stop under way, or no verdict on the installed build); `Some(Ok)` armed the exec,
/// which the request [`commit`]s as it begins the stop; `Some(Err)` is a failed check, and
/// nothing changed: the daemon serves on.
pub(crate) async fn prepare(reason: &str) -> Option<Result<(), String>> {
    let frozen = kept().frozen;
    if !enabled() || reason.starts_with("handover") || frozen {
        return None;
    }
    match arm().await {
        Ok(true) => Some(Ok(())),
        Ok(false) => None,
        Err(why) => Some(Err(why)),
    }
}

/// Arm the exec. `Ok(false)` when this daemon cannot say what to exec or got no verdict on it
/// (logged): the restart is v1's exit, which needs neither. `Err` only for a build that answered
/// and does not take the handoff.
async fn arm() -> Result<bool, String> {
    let v1 = |why: String| {
        tracing::warn!("restart: {why}; this restart exits and starts again");
        Ok(false)
    };
    let installed = match std::env::current_exe() {
        Ok(path) => crate::self_command::undeleted(path),
        Err(e) => return v1(format!("this daemon's installed path: {e}")),
    };
    let arg0 = std::env::args_os().next().unwrap_or_else(|| installed.clone().into_os_string());
    let Ok(mut args) =
        std::env::args_os().skip(1).map(OsString::into_string).collect::<Result<Vec<String>, _>>()
    else {
        return v1("an argument of this daemon is not UTF-8".into());
    };
    // `acpmux daemon` alone is `daemon run` (`cli/entry.rs`).
    if !args.iter().any(|a| a == "run") && args.last().is_some_and(|a| a == "daemon") {
        args.push("run".into());
    }
    let Some(run) = args.iter().position(|a| a == "run") else {
        return v1("this daemon's arguments name no `run`".into());
    };
    // `<installed> <prefix> handoff-check`: `daemon handoff-check`, or `acp daemon handoff-check`
    // when the daemon runs inside cmux-tui.
    let mut check_args: Vec<String> = args.iter().take(run).cloned().collect();
    check_args.push("handoff-check".into());
    let (program, name) = (installed.clone(), arg0.clone());
    // bare blocking (daemon): one short child the restart request waits for, bounded by its deadline.
    let checked = tokio::task::spawn_blocking(move || {
        tracing::debug!(target: super::HANDOFF_TIMING, "handoff timing: check");
        check(&program, &name, &check_args)
    })
    .await
    .map_err(|e| format!("the check's task: {e}"))?;
    tracing::debug!(target: super::HANDOFF_TIMING, "handoff timing: checked");
    let Some(build) = checked? else {
        return v1(format!(
            "{} daemon handoff-check gave no answer within {CHECK_WITHIN:?}",
            installed.display()
        ));
    };
    let (through_run, rest) = split_run(&args);
    let mut exec_args: Vec<String> = args.iter().take(through_run).cloned().collect();
    exec_args.extend(rest);
    // The same process is still the unit's daemon (`split_run` drops the flag for a successor,
    // which gets its own).
    if args.iter().skip(through_run).any(|a| a == "--take-over") {
        exec_args.push("--take-over".into());
    }
    let mut kept = kept();
    if kept.frozen {
        drop(kept);
        return v1("the daemon began to stop during the check".into());
    }
    kept.armed = Some(Exec { program: installed.clone(), arg0, args: exec_args });
    drop(kept);
    tracing::info!("restart: {} (build {build}) takes the handoff", installed.display());
    Ok(true)
}

/// Run `program` as `arg0` with `args` (`daemon handoff-check`) within [`CHECK_WITHIN`]: its
/// build when it takes this handoff, None when it gave no answer in time.
fn check(program: &Path, arg0: &OsStr, args: &[String]) -> Result<Option<String>, String> {
    use std::io::Read as _;
    let named = |e: std::io::Error| format!("{}: {e}", program.display());
    // Its own group; dropped while it still runs (the deadline), it is ended and reaped.
    let mut child = cmux_process::Command::new(program)
        .arg0(arg0)
        .args(args)
        .stdin(cmux_process::Stdio::null())
        .stdout(cmux_process::Stdio::piped())
        .stderr(cmux_process::Stdio::null())
        .process_group(0)
        .spawn()
        .map_err(named)?;
    let Some(status) = child.wait_timeout(CHECK_WITHIN).map_err(named)? else {
        return Ok(None);
    };
    if !status.success() {
        return Err(format!("{} daemon handoff-check exited {status}", program.display()));
    }
    // One short line, read once the child ended: a pipe's buffer holds it.
    let mut stdout = Vec::new();
    if let Some(mut pipe) = child.stdout.take() {
        pipe.read_to_end(&mut stdout).map_err(named)?;
    }
    accepts(&stdout)
        .map(Some)
        .map_err(|why| format!("{} daemon handoff-check: {why}", program.display()))
}

/// Whether a `daemon handoff-check` output names this handoff and every argument it passes: the
/// build it names.
fn accepts(stdout: &[u8]) -> Result<String, String> {
    let text = String::from_utf8_lossy(stdout);
    let line = text.lines().rev().find(|l| !l.trim().is_empty()).ok_or("no output")?;
    let said: serde_json::Value =
        serde_json::from_str(line.trim()).map_err(|e| format!("not a JSON line: {e}"))?;
    if said.get("handoff").and_then(serde_json::Value::as_u64) != Some(VERSION) {
        return Err(format!("takes no handoff {VERSION}: {line}"));
    }
    let args: Vec<&str> = said
        .get("args")
        .and_then(serde_json::Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(serde_json::Value::as_str)
        .collect();
    if let Some(missing) = FLAGS.iter().find(|flag| !args.contains(*flag)) {
        return Err(format!("does not take {missing}"));
    }
    Ok(said.get("build").and_then(serde_json::Value::as_str).unwrap_or("unknown").to_owned())
}

/// `args` (a daemon's own, after its executable) split at `run`: the index just past it (0
/// without one), and the arguments after it without [`PER_PROCESS`] (with their values) and
/// `--take-over`. A successor's arguments (`exe_swap::handover_args`) and the exec's (which puts
/// `--take-over` back) are built from it.
pub(super) fn split_run(args: &[String]) -> (usize, Vec<String>) {
    let run = args.iter().position(|a| a == "run").map_or(0, |i| i + 1);
    let mut rest = Vec::new();
    let mut it = args.iter().skip(run);
    while let Some(arg) = it.next() {
        let joined = PER_PROCESS
            .iter()
            .any(|flag| arg.strip_prefix(flag).is_some_and(|value| value.starts_with('=')));
        if PER_PROCESS.contains(&arg.as_str()) {
            it.next();
        } else if arg != "--take-over" && !joined {
            rest.push(arg.clone());
        }
    }
    (run, rest)
}

/// The restart request that armed the exec begins the stop now (`server/requests.rs`, with no
/// await before it wakes the stop): whether this stop is its exec in place. False when a stop
/// began meanwhile. A request that failed after its check never commits, so a later plain stop
/// exits as v1 does.
pub(crate) fn commit() -> bool {
    kept().commit()
}

/// The stop begins (`daemon::run`): whether it hands off, decided now for the whole stop. Only a
/// stop a client's request began (`by_request`) and that request committed does: SIGTERM, SIGINT,
/// a store stop and a lost home keep v1's exit even when a restart was armed a moment before. A
/// restart request that comes after this keeps v1's exit.
pub(super) fn confirm(by_request: bool) -> bool {
    kept().confirm(by_request)
}

/// SIGTERM or SIGINT came while the stop that hands off ran (`daemon::run` looks once the stop's
/// work is done): whoever sent it wants this process gone, so [`exec_if_armed`] ends as v1's stop
/// does instead of the exec. One that comes after that look, in the moment before the exec, is
/// lost, as one that comes before a daemon's signal streams are registered ends it at once.
pub(super) fn signalled() {
    SIGNALLED.store(true, Ordering::SeqCst);
}

/// Whether the stop under way hands off ([`confirm`]).
pub(super) fn handing_off() -> bool {
    let kept = kept();
    kept.frozen && kept.armed.is_some()
}

/// The stop left the socket file in place for the next image; whether it was still the one this
/// daemon bound, for an exec that fails.
pub(super) fn keep_socket_ours(ours: bool) {
    kept().socket_ours = ours;
}

/// The stop's persistence let the lock go: kept locked for the next image.
pub(super) fn keep_lock(lock: DaemonLock) {
    kept().lock = Some(lock);
}

/// After `daemon::run` returned (`cli/entry.rs`), when a restart armed it: exec the installed
/// build in place, with the kept descriptors. Returns only when there was nothing to exec (None),
/// a stop signal came meanwhile ([`signalled`]) or the exec failed: then this ends as v1's stop
/// does, and the status to exit with.
pub(crate) fn exec_if_armed() -> Option<i32> {
    let mut kept = kept();
    if !kept.frozen {
        return None;
    }
    let exec = kept.armed.take()?;
    if SIGNALLED.load(Ordering::SeqCst) {
        tracing::warn!("restart: a stop signal came during the stop; exiting, no exec in place");
        let status = super::stop_causes::exit_status();
        drop(kept);
        end_as_v1(status);
        return Some(status);
    }
    let mut args = exec.args;
    let mut fds = Vec::new();
    let handed = [
        (LOCK_FD, kept.lock.as_ref().map(DaemonLock::raw_fd)),
        (UNIX_FD, kept.unix.as_ref().map(|fd| fd.as_raw_fd())),
        (WS_FD, kept.ws.as_ref().map(|fd| fd.as_raw_fd())),
    ];
    for (flag, fd) in handed {
        if let Some(fd) = fd {
            args.push(flag.to_owned());
            args.push(fd.to_string());
            fds.push(fd);
        }
    }
    args.push(COUNT.to_owned());
    args.push(count().saturating_add(1).to_string());
    tracing::info!("restart: exec {} in place", exec.program.display());
    tracing::debug!(target: super::HANDOFF_TIMING, "handoff timing: exec");
    // timeout: a log output that takes no bytes must not hold the exec (`cli/entry.rs`'s flush).
    let _ = crate::log_sink::flush(Duration::from_secs(1));
    let error = exec_with(&exec.program, &exec.arg0, &args, &fds);
    // Here only when the exec failed. The fence cannot be unfired: end as v1's stop does, with a
    // status the supervisor starts the daemon again on.
    let status = super::stop_causes::EXIT_HANDOFF_FAILED;
    tracing::error!(
        "restart: the exec of {} failed: {error}; stopping (exit {status}) for the supervisor or the next client to start the daemon",
        exec.program.display()
    );
    drop(kept);
    end_as_v1(status);
    Some(status)
}

/// What the stop left for the next image, ended as v1's stop ends it: the socket file, the owner
/// record (with `status`), the pid file, the listeners, and last the lock.
fn end_as_v1(status: i32) {
    let mut kept = kept();
    let socket_ours = kept.socket_ours;
    let lock = kept.lock.take();
    kept.unix = None;
    // The stop left this listener listening for the next image (`server/ws_shutdown.rs`,
    // `close_admission`); with none, it stops for good here, whatever copies a child holds.
    #[cfg(target_os = "linux")]
    if let Some(ws) = &kept.ws {
        // SAFETY: shutdown on a descriptor this holder owns, open for the whole call.
        unsafe { libc::shutdown(ws.as_raw_fd(), libc::SHUT_RD) };
    }
    kept.ws = None;
    drop(kept);
    let home = crate::config::home();
    if !crate::config::home_lost() {
        if socket_ours {
            super::home_watch::release_socket();
            let _ = crate::home_fs::remove_file(crate::config::socket_path());
        }
        super::supervision::finish(&home, status);
        let _ = crate::home_fs::remove_file(home.join("daemon.pid"));
    }
    // Last, as the stop's persistence lets it go: its drop unlocks, then closes.
    drop(lock);
}

/// Set or clear `fd`'s close-on-exec flag, then read it back: whether it is as asked.
fn set_cloexec(fd: RawFd, on: bool) -> bool {
    // SAFETY: F_GETFD and F_SETFD change only this descriptor's close-on-exec flag.
    unsafe {
        let flags = libc::fcntl(fd, libc::F_GETFD);
        if flags < 0 {
            return false;
        }
        let flags = if on { flags | libc::FD_CLOEXEC } else { flags & !libc::FD_CLOEXEC };
        if libc::fcntl(fd, libc::F_SETFD, flags) != 0 {
            return false;
        }
        let now = libc::fcntl(fd, libc::F_GETFD);
        now >= 0 && (now & libc::FD_CLOEXEC != 0) == on
    }
}

/// The descriptors a restart's exec handed this image (`daemon run --handoff-*`), each
/// close-on-exec from the start of `daemon::run` and checked where it is used. One never used
/// (the WebSocket listener of a config that has none now) is closed when this drops.
pub(super) struct Handed {
    lock: Option<OwnedFd>,
    unix: Option<OwnedFd>,
    ws: Option<OwnedFd>,
}

impl Handed {
    /// Take the handed descriptors: close-on-exec set and read back on each, before anything is
    /// spawned. One that is no open descriptor, stdio, or another flag's (`reserved`) is left
    /// alone and its piece starts as usual.
    pub(super) fn take(opts: Option<&super::HandoffOptions>, reserved: &[Option<i32>]) -> Self {
        let inherit = |fd: Option<i32>, flag: &str| {
            let fd = fd?;
            if fd <= 2 || reserved.contains(&Some(fd)) {
                tracing::warn!(
                    "restart handoff: {flag} {fd} is not one to take; starting it as usual"
                );
                return None;
            }
            // SAFETY: F_GETFD only asks whether a descriptor is open at `fd`.
            if unsafe { libc::fcntl(fd, libc::F_GETFD) } < 0 {
                tracing::warn!(
                    "restart handoff: {flag} {fd}: {}; starting it as usual",
                    std::io::Error::last_os_error()
                );
                return None;
            }
            // SAFETY: the exec handed this descriptor to this image alone, by its argument;
            // nothing else in this process takes it.
            let owned = unsafe { OwnedFd::from_raw_fd(fd) };
            if !set_cloexec(fd, true) {
                tracing::warn!(
                    "restart handoff: {flag} {fd} stays open across an exec; closed, starting it as usual"
                );
                return None;
            }
            Some(owned)
        };
        let Some(opts) = opts else { return Self { lock: None, unix: None, ws: None } };
        Self {
            lock: inherit(opts.lock_fd, LOCK_FD),
            unix: inherit(opts.unix_fd, UNIX_FD),
            ws: inherit(opts.ws_fd, WS_FD),
        }
    }

    /// The handed lock, when it is `path`'s and its lock holds: this daemon's, its pid
    /// recorded as a start records it.
    pub(super) fn lock(&mut self, path: &Path) -> Option<DaemonLock> {
        let fd = self.lock.take()?;
        match adopt_lock(fd, path) {
            Ok(lock) => {
                tracing::info!("restart handoff: kept the lock {}", path.display());
                Some(lock)
            }
            Err(why) => {
                tracing::warn!(
                    "restart handoff: {LOCK_FD}: {why}; closed, taking the lock as usual"
                );
                None
            }
        }
    }

    /// The handed unix socket listener, when it listens on `socket`.
    pub(super) fn unix(&mut self, socket: &Path) -> Option<tokio::net::UnixListener> {
        let fd = self.unix.take()?;
        let adopted = adopt_unix(fd, socket).and_then(|listener| {
            listener.set_nonblocking(true).map_err(|e| e.to_string())?;
            tokio::net::UnixListener::from_std(listener).map_err(|e| e.to_string())
        });
        match adopted {
            Ok(listener) => {
                tracing::info!("listening on {} (kept through the restart)", socket.display());
                Some(listener)
            }
            Err(why) => {
                tracing::warn!("restart handoff: {UNIX_FD}: {why}; closed, binding it as usual");
                None
            }
        }
    }

    /// The handed WebSocket listener, when it listens at the address `listen` would bind (any
    /// port when `listen` asks for any).
    pub(super) async fn ws(&mut self, listen: &str) -> Option<tokio::net::TcpListener> {
        let fd = self.ws.take()?;
        let wanted: Vec<SocketAddr> = match listen.parse::<SocketAddr>() {
            Ok(one) => vec![one],
            Err(_) => {
                tokio::net::lookup_host(listen).await.map(Iterator::collect).unwrap_or_default()
            }
        };
        let adopted = adopt_tcp(fd, &wanted).and_then(|listener| {
            listener.set_nonblocking(true).map_err(|e| e.to_string())?;
            tokio::net::TcpListener::from_std(listener).map_err(|e| e.to_string())
        });
        match adopted {
            Ok(listener) => {
                tracing::info!("web + websocket listening on {listen} (kept through the restart)");
                Some(listener)
            }
            Err(why) => {
                tracing::warn!(
                    "restart handoff: {WS_FD}: {why}; closed, binding {listen} as usual"
                );
                None
            }
        }
    }
}

/// `fd` as the daemon lock when it is the lock file at `path` (the same device and inode) and
/// locking it succeeds (it holds the lock already, or takes it).
fn adopt_lock(fd: OwnedFd, path: &Path) -> Result<DaemonLock, String> {
    use std::os::unix::fs::MetadataExt;
    let file = std::fs::File::from(fd);
    let held = file.metadata().map_err(|e| format!("fstat: {e}"))?;
    let named = std::fs::symlink_metadata(path).map_err(|e| format!("{}: {e}", path.display()))?;
    if !held.is_file() || held.dev() != named.dev() || held.ino() != named.ino() {
        return Err(format!("not the lock file {}", path.display()));
    }
    super::lock::adopt(file).map_err(|e| format!("its lock: {e}"))
}

/// Whether `fd` is a socket that listens (`SO_ACCEPTCONN`).
fn listening_socket(fd: &OwnedFd) -> Result<(), String> {
    // SAFETY: an all-zero stat is a valid value; fstat only fills it.
    let mut st: libc::stat = unsafe { std::mem::zeroed() };
    // SAFETY: fstat on a descriptor this function borrows.
    if unsafe { libc::fstat(fd.as_raw_fd(), &mut st) } != 0 {
        return Err(format!("fstat: {}", std::io::Error::last_os_error()));
    }
    if (st.st_mode & libc::S_IFMT) != libc::S_IFSOCK {
        return Err("not a socket".into());
    }
    let mut on: libc::c_int = 0;
    let mut len = std::mem::size_of::<libc::c_int>() as libc::socklen_t;
    // SAFETY: getsockopt writes at most `len` bytes into `on`.
    let rc = unsafe {
        libc::getsockopt(
            fd.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_ACCEPTCONN,
            (&mut on as *mut libc::c_int).cast(),
            &mut len,
        )
    };
    // Linux answers 1; the BSDs answer the option's bit.
    if rc != 0 || on == 0 {
        return Err("a socket that does not listen".into());
    }
    Ok(())
}

/// `fd` when it is a listening unix socket bound to `socket`.
fn adopt_unix(fd: OwnedFd, socket: &Path) -> Result<std::os::unix::net::UnixListener, String> {
    listening_socket(&fd)?;
    let listener = std::os::unix::net::UnixListener::from(fd);
    let bound = listener.local_addr().map_err(|e| format!("not a unix socket: {e}"))?;
    match bound.as_pathname() {
        Some(path) if super::same_path(path, socket) => Ok(listener),
        Some(path) => Err(format!("bound to {}, not {}", path.display(), socket.display())),
        None => Err(format!("bound to no path, not {}", socket.display())),
    }
}

/// `fd` when it is a listening TCP socket at one of `wanted` (any port where one asks for 0).
fn adopt_tcp(fd: OwnedFd, wanted: &[SocketAddr]) -> Result<std::net::TcpListener, String> {
    listening_socket(&fd)?;
    let listener = std::net::TcpListener::from(fd);
    let bound = listener.local_addr().map_err(|e| format!("not a TCP socket: {e}"))?;
    if wanted.iter().any(|w| w.ip() == bound.ip() && (w.port() == 0 || w.port() == bound.port())) {
        Ok(listener)
    } else {
        Err(format!("listens on {bound}, not the configured address"))
    }
}

/// On a handoff start, before this image starts any process: every child it has is the previous
/// image's. Those that ended already are reaped here (`waitpid(-1)`, safe only now: later it
/// would take tokio's own children from it). What a stop leaves running is named by its own
/// record: the agent hosts (`agent_host/sweep.rs`) and the share sessions
/// (`share_host/records.rs`). Their pids, for [`reap_inherited`];
/// one that is no child of this process costs one `waitpid` there.
pub(super) fn inherited() -> Vec<libc::pid_t> {
    loop {
        let mut status: libc::c_int = 0;
        // SAFETY: waitpid with WNOHANG never blocks; it reaps one ended child of this process.
        if unsafe { libc::waitpid(-1, &mut status, libc::WNOHANG) } <= 0 {
            break;
        }
    }
    let hosts = crate::agent_host::sweep::running_hosts(&crate::agent_host::hosts_dir());
    hosts
        .into_iter()
        .map(|host| host.host_pid)
        .chain(crate::share_host::session_pids(&crate::config::home()))
        .filter_map(|pid| libc::pid_t::try_from(pid).ok())
        .filter(|pid| *pid > 1)
        .collect()
}

/// Reap `children` ([`inherited`]) as they exit: one task of `scope` on tokio's SIGCHLD stream
/// calls `waitpid(pid, WNOHANG)` for each listed pid only. A pid that is no child of this process
/// (a host an earlier daemon process started) is dropped at the first pass. The next handoff
/// lists them again: those alive are still children.
pub(super) fn reap_inherited(
    mut children: Vec<libc::pid_t>,
    scope: &cmux_scope::Scope,
) -> Option<tokio::task::JoinHandle<Option<()>>> {
    if children.is_empty() {
        return None;
    }
    let mut sigchld = match tokio::signal::unix::signal(tokio::signal::unix::SignalKind::child()) {
        Ok(stream) => stream,
        Err(e) => {
            tracing::warn!(
                "restart handoff: no SIGCHLD stream to reap the previous image's children: {e}"
            );
            return None;
        }
    };
    Some(scope.spawn_until_cancelled("handoff-reap", async move {
        loop {
            // A child that exited before the stream was registered is reaped by this first pass.
            children.retain(|pid| !reaped(*pid));
            if children.is_empty() || sigchld.recv().await.is_none() {
                return;
            }
        }
    }))
}

/// Whether `pid` is reaped now, or no child of this process.
fn reaped(pid: libc::pid_t) -> bool {
    let mut status: libc::c_int = 0;
    // SAFETY: waitpid on one pid a record named; WNOHANG never blocks, and a pid that is no
    // child of this process only fails with ECHILD.
    let got = unsafe { libc::waitpid(pid, &mut status, libc::WNOHANG) };
    got == pid || (got < 0 && std::io::Error::last_os_error().raw_os_error() != Some(libc::EINTR))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn strings(args: &[&str]) -> Vec<String> {
        args.iter().map(|a| (*a).to_owned()).collect()
    }

    #[test]
    fn the_exec_keeps_the_daemons_flags_but_not_its_descriptors_or_an_earlier_handoff() {
        let args = strings(&[
            "acp",
            "daemon",
            "run",
            "--ready-fd",
            "3",
            "--memory",
            "--person-key-fd=4",
            "--take-over",
            "--listen",
            "127.0.0.1:0",
            "--handoff-lock-fd",
            "7",
            "--handoff-unix-fd=8",
            "--handoff-ws-fd",
            "9",
            "--handoff-count",
            "2",
            "--dev",
        ]);
        let (run, rest) = split_run(&args);
        assert_eq!(run, 3);
        assert_eq!(rest, strings(&["--memory", "--listen", "127.0.0.1:0", "--dev"]));
        // No `run`: nothing is taken for the prefix.
        assert_eq!(split_run(&strings(&["daemon"])), (0, strings(&["daemon"])));
    }

    #[test]
    fn a_check_passes_only_with_this_handoff_and_every_argument() {
        let line = check_line().to_string();
        assert_eq!(
            accepts(format!("a log line\n{line}\n").as_bytes()),
            Ok(crate::build_info::build().to_owned())
        );
        assert!(accepts(b"").is_err());
        assert!(accepts(b"usage: acpmux daemon\n").is_err());
        let older =
            serde_json::json!({"build": "x", "handoff": 1, "args": [LOCK_FD, UNIX_FD, COUNT]});
        assert!(accepts(older.to_string().as_bytes()).is_err());
        let other = serde_json::json!({"build": "x", "handoff": 2, "args": FLAGS});
        assert!(accepts(other.to_string().as_bytes()).is_err());
    }

    fn armed() -> Kept {
        let exec = Exec { program: "/x/acpmux".into(), arg0: "acpmux".into(), args: Vec::new() };
        Kept { armed: Some(exec), ..Kept::new() }
    }

    #[test]
    fn only_a_stop_the_committing_request_began_execs_in_place() {
        // The request's check passed, it committed, and its own wake began the stop.
        let mut kept = armed();
        assert!(kept.commit());
        assert!(kept.confirm(true));
        // A signal began the stop a moment after the commit: v1's exit.
        let mut kept = armed();
        assert!(kept.commit());
        assert!(!kept.confirm(false));
        assert!(kept.armed.is_none());
        // The request failed after its check and never committed: a later plain stop exits.
        let mut kept = armed();
        assert!(!kept.confirm(true));
        // A stop under way: a commit after it is no handoff, and nothing was checked.
        let mut kept = armed();
        assert!(!kept.confirm(false));
        assert!(!kept.commit());
        assert!(!Kept::new().commit());
    }

    fn cloexec(fd: RawFd) -> bool {
        // SAFETY: F_GETFD only reads the descriptor's flags.
        let flags = unsafe { libc::fcntl(fd, libc::F_GETFD) };
        flags >= 0 && flags & libc::FD_CLOEXEC != 0
    }

    #[test]
    fn a_failed_exec_returns_its_error_and_leaves_the_descriptors_close_on_exec() {
        let (kept, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
        let fd = kept.as_raw_fd();
        assert!(cloexec(fd));
        let error = exec_with(
            Path::new("/nonexistent/acpmux-handoff-test"),
            OsStr::new("acpmux"),
            &strings(&["daemon", "run"]),
            &[fd],
        );
        assert_eq!(error.kind(), std::io::ErrorKind::NotFound, "{error}");
        assert!(cloexec(fd), "the descriptor stayed open across an exec");
    }

    #[test]
    fn adoption_refuses_what_is_not_the_lock_or_a_listening_socket() {
        let dir = cmux_unix_socket::short_test_dir("amx-hof");
        let lock = dir.path().join("daemon.lock");
        let other = dir.path().join("other");
        std::fs::write(&lock, "").unwrap();
        std::fs::write(&other, "").unwrap();

        // Another file is not the lock; the lock file itself is, and its flock holds.
        let not_lock = OwnedFd::from(std::fs::File::open(&other).unwrap());
        assert!(adopt_lock(not_lock, &lock).is_err());
        let lock_fd = OwnedFd::from(std::fs::File::open(&lock).unwrap());
        assert!(adopt_lock(lock_fd, &lock).is_ok());

        // A file, a connected socket and a listener elsewhere are refused; the listener on the
        // socket path is taken.
        let socket = dir.path().join("s.sock");
        let file = OwnedFd::from(std::fs::File::open(&other).unwrap());
        assert!(adopt_unix(file, &socket).is_err());
        let (stream, _peer) = std::os::unix::net::UnixStream::pair().unwrap();
        assert!(adopt_unix(OwnedFd::from(stream), &socket).is_err());
        let elsewhere = std::os::unix::net::UnixListener::bind(dir.path().join("e.sock")).unwrap();
        assert!(adopt_unix(OwnedFd::from(elsewhere), &socket).is_err());
        let listener = std::os::unix::net::UnixListener::bind(&socket).unwrap();
        assert!(adopt_unix(OwnedFd::from(listener), &socket).is_ok());

        // A TCP listener at another port, and a unix listener, are not the WebSocket listener.
        let tcp = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = tcp.local_addr().unwrap().port();
        let elsewhere: SocketAddr =
            format!("127.0.0.1:{}", port.wrapping_add(1).max(1)).parse().unwrap();
        let tcp_fd = OwnedFd::from(tcp.try_clone().unwrap());
        assert!(adopt_tcp(tcp_fd, &[elsewhere]).is_err());
        let any: SocketAddr = "127.0.0.1:0".parse().unwrap();
        assert!(adopt_tcp(OwnedFd::from(tcp), &[any]).is_ok());
        let unix = std::os::unix::net::UnixListener::bind(dir.path().join("t.sock")).unwrap();
        assert!(adopt_tcp(OwnedFd::from(unix), &[any]).is_err());
    }
}
