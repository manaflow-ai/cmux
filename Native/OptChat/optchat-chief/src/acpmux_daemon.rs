//! Finding and starting the acpmux daemon, the app's launch contract
//! (`ACPMUX_BIN`, `ACPMUX_HOME`, `ACPMUX_SOCKET`; mux/host/src/acpmux-daemon.ts):
//! when the socket does not answer, `$ACPMUX_BIN daemon run` starts detached
//! in its own process group with its log in `$ACPMUX_HOME/daemon.log`.
//!
//! Who starts acpmux (one rule for every host, coordinator 2026-10-06; see
//! [`decide`]): with `OPTCHAT_ACPMUX_SUPERVISED=1` a supervisor owns the daemon
//! (the always-on brain's LaunchAgent), so the host never spawns one and waits
//! for its socket with a bounded backoff. Without it (the app's local Chief)
//! the host starts acpmux when none answers, but never again after it saw a
//! daemon it had reached go away: a quit or End Sessions shut it down on
//! purpose, and a respawn would leave an orphan.

use std::os::unix::net::UnixStream;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

use crate::cli::env;

/// `ACPMUX_SOCKET`, else `$ACPMUX_HOME/acpmux.sock`, else `~/.acpmux/acpmux.sock`
/// (a long path maps to a short alias: [`socket_path_for`]).
pub fn socket_path() -> PathBuf {
    let user = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/".into());
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    socket_path_for(
        env("ACPMUX_SOCKET").as_deref(),
        env("ACPMUX_HOME").as_deref(),
        &user,
        uid,
    )
}

/// [`socket_path`] for a configured socket, acpmux home, user home and uid, by
/// the rule acpmux and every host share (cmux-agent-pane-policy
/// `environment::socket_path`, whose tests/cases/environment.json this crate's
/// tests run): an absolute `ACPMUX_SOCKET` past the Unix socket limit (a long
/// TMPDIR), and a long home, map to `/tmp/acpmux-<uid>/<fnv1a64>.sock`.
pub fn socket_path_for(
    configured: Option<&str>,
    home: Option<&str>,
    user_home: &Path,
    uid: u32,
) -> PathBuf {
    let alias = |key: &str| PathBuf::from(format!("/tmp/acpmux-{uid}/{:016x}.sock", fnv1a64(key)));
    if let Some(socket) = configured {
        if socket.starts_with('/') && socket.len() > MAX_SOCKET_PATH_BYTES {
            return alias(socket);
        }
        return socket.into();
    }
    let home = home
        .map(PathBuf::from)
        .unwrap_or_else(|| user_home.join(".acpmux"));
    let preferred = home.join("acpmux.sock");
    if preferred.as_os_str().len() < 96 {
        return preferred;
    }
    alias(&home.to_string_lossy())
}

/// The longest Unix socket path every host binds (cmux-agent-pane-policy
/// `MAX_SOCKET_PATH_BYTES`): macOS's `sun_path` less its NUL.
const MAX_SOCKET_PATH_BYTES: usize = 103;

fn fnv1a64(text: &str) -> u64 {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in text.bytes() {
        hash ^= u64::from(byte);
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    hash
}

/// Whether something accepts connections on the socket.
pub fn reachable(path: &Path) -> bool {
    UnixStream::connect(path).is_ok()
}

/// Env the daemon this process starts gets over its own (the host's pinned
/// cmux env, so the children it runs reach the app's daemon; cmux_env).
static CHILD_ENV: std::sync::OnceLock<std::collections::BTreeMap<String, String>> =
    std::sync::OnceLock::new();

/// Sets the started daemon's extra env (once per process; later calls keep the first).
pub fn set_child_env(env: std::collections::BTreeMap<String, String>) {
    let _ = CHILD_ENV.set(env);
}

/// Who owns the acpmux daemon.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mode {
    /// A supervisor (LaunchAgent) starts and restarts it: never spawn.
    Supervised,
    /// The host starts it when none answers (the app's local Chief).
    Local,
}

/// What to do about the daemon now.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Action {
    /// The socket answers.
    Ready,
    /// Start `$ACPMUX_BIN daemon run`.
    Spawn,
    /// Wait for the supervisor's daemon.
    Wait,
    /// A daemon this host reached went away: it was shut down on purpose.
    Refuse,
}

/// `OPTCHAT_ACPMUX_SUPERVISED=1` (set by deploy/brain/install.sh): supervised.
pub fn mode() -> Mode {
    if env("OPTCHAT_ACPMUX_SUPERVISED").as_deref() == Some("1") {
        Mode::Supervised
    } else {
        Mode::Local
    }
}

/// `OPTCHAT_ACPMUX_SHARED=1`: this host's acpmux is its Chief home's, which
/// every Chief of that home uses (hq-6d 2026-10-14; the daemon's Chief brain
/// supervisor, cmux-tui-core chief_brains.rs, sets it). Such a host starts
/// the daemon like a local host when none answers, with the Chief home
/// (`CMUX_CHIEF_HOME`) as the daemon's `ACPMUX_CHIEF_MUX_HOME`, but never
/// shuts it down: when it stops it ends only its own sessions
/// (`agents::end_own_sessions`). Without it (the app's default Chief, a
/// host with its own `ACPMUX_HOME`) nothing changes.
pub const SHARED_ENV: &str = "OPTCHAT_ACPMUX_SHARED";

/// The Chief-specific variables a shared host keeps out of the daemon it
/// starts.
const CHIEF_IDENTITY_ENV: [&str; 7] = [
    "MUX_HOME",
    "MUX_AGENT_TOKEN_FILE",
    "MUX_HOST_LOG",
    "MUX_CHIEF_TITLE",
    "OPTCHAT_CHIEF_PARTICIPANT",
    "OPTCHAT_GROUP_WAKE",
    SHARED_ENV,
];

/// This host's credential and participant: the token file binds as this
/// Chief (`agent_mux` for the default Chief). No daemon this host starts
/// gets them, shared or not: the default Chief's host starts the Chief
/// home's acpmux, which every Chief of the home and the person use, so its
/// sessions would act as the default Chief (hq-6d 2026-10-14). The host
/// binds with its own copy; acpmux drops them from every child too
/// (acpmux `config::CHIEF_CREDENTIAL_ENV`).
const CHIEF_CREDENTIAL_ENV: [&str; 2] = ["MUX_AGENT_TOKEN_FILE", "OPTCHAT_CHIEF_PARTICIPANT"];

/// Whether this host's acpmux is shared ([`SHARED_ENV`]).
pub fn shared() -> bool {
    env(SHARED_ENV).as_deref() == Some("1")
}

/// The rule: `reachable` is the socket now, `seen_up` whether this host ever reached a daemon.
pub fn decide(mode: Mode, reachable: bool, seen_up: bool) -> Action {
    match (reachable, mode, seen_up) {
        (true, _, _) => Action::Ready,
        (false, Mode::Supervised, _) => Action::Wait,
        (false, Mode::Local, false) => Action::Spawn,
        (false, Mode::Local, true) => Action::Refuse,
    }
}

/// Whether this process ever reached an acpmux daemon (the local-mode respawn rule).
static SEEN_UP: AtomicBool = AtomicBool::new(false);

/// How long a supervised host waits for the supervisor's daemon in one call;
/// the callers' own link loops retry after that.
const SUPERVISED_WAIT: Duration = Duration::from_secs(30);

/// How long a host waits for the next daemon after its daemon went away. A
/// handoff stops a daemon without ending its sessions (`_acpmux/shutdown`
/// without `endAgents`): its hosted agents detach, and the client that handed
/// it off starts the next daemon, which adopts them. An app build from before
/// cx-ebm.54 still does so from a subagent tab (its version and person-key
/// handoffs wait up to 15 s for the old daemon's exit, then start their own);
/// a supervisor restarts its daemon the same way. A daemon that is not back
/// by then was ended.
pub const HANDOFF_WAIT: Duration = Duration::from_secs(20);

/// Whether a daemon answers on `socket` within `wait`; never starts one
/// (the next daemon of a handoff is its starter's, cx-ebm.54).
pub fn await_next(socket: &Path, wait: Duration) -> bool {
    await_socket(socket, wait).is_ok()
}

/// [`ensure_with`] in this process's mode (`OPTCHAT_ACPMUX_SUPERVISED`).
pub fn ensure(socket: &Path, log: &dyn Fn(&str)) -> Result<Option<u32>, String> {
    let bin = env("ACPMUX_BIN");
    ensure_with(
        socket,
        mode(),
        &SEEN_UP,
        bin.as_deref(),
        SUPERVISED_WAIT,
        log,
    )
}

/// Makes the daemon answer by the rule ([`decide`]): ready, wait (supervised,
/// bounded by `wait`), spawn (local, first time) or refuse. Returns the pid it
/// started, if any.
pub fn ensure_with(
    socket: &Path,
    mode: Mode,
    seen_up: &AtomicBool,
    bin: Option<&str>,
    wait: Duration,
    log: &dyn Fn(&str),
) -> Result<Option<u32>, String> {
    match decide(mode, reachable(socket), seen_up.load(Ordering::SeqCst)) {
        Action::Ready => {
            seen_up.store(true, Ordering::SeqCst);
            Ok(None)
        }
        Action::Wait => {
            await_socket(socket, wait)?;
            seen_up.store(true, Ordering::SeqCst);
            Ok(None)
        }
        Action::Refuse => Err(format!(
            "acpmux at {} was shut down; this host does not start it again",
            socket.display()
        )),
        Action::Spawn => {
            // Recorded before the child exists (cx-33c6): a stop from here on
            // waits for this start and stops what it started; after a stop no
            // start begins.
            if bin.is_some() && !begin_start() {
                return Err("the host is stopping; it starts no acpmux".into());
            }
            let child = match spawn(socket, bin, log) {
                Ok(Some(child)) => child,
                // Another starter's daemon answered while this one waited.
                Ok(None) => {
                    if bin.is_some() {
                        finish_start(None);
                    }
                    seen_up.store(true, Ordering::SeqCst);
                    return Ok(None);
                }
                Err(e) => {
                    if bin.is_some() {
                        finish_start(None);
                    }
                    return Err(e);
                }
            };
            let pid = child.id();
            // `spawn` starts nothing without a binary, so `bin` is set here.
            if let Some(bin) = bin {
                finish_start(Some(Started {
                    bin: bin.into(),
                    socket: socket.to_path_buf(),
                    home: daemon_home(socket),
                    child,
                }));
            }
            seen_up.store(true, Ordering::SeqCst);
            Ok(Some(pid))
        }
    }
}

/// Waits for a supervisor's daemon: a short, growing interval, bounded by `wait`.
fn await_socket(socket: &Path, wait: Duration) -> Result<(), String> {
    let deadline = Instant::now() + wait;
    let mut step = Duration::from_millis(25);
    loop {
        if reachable(socket) {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!(
                "acpmux (supervised) is not up at {} after {} s",
                socket.display(),
                wait.as_secs_f32()
            ));
        }
        std::thread::sleep(
            step.min(deadline.saturating_duration_since(Instant::now()))
                .max(Duration::from_millis(1)),
        );
        step = (step * 2).min(Duration::from_millis(500));
    }
}

fn daemon_home(socket: &Path) -> PathBuf {
    let user = std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/".into());
    // SAFETY: getuid has no preconditions.
    let uid = unsafe { libc::getuid() };
    daemon_home_for(
        env("ACPMUX_HOME").as_deref(),
        env("ACPMUX_SOCKET").as_deref(),
        socket,
        &user,
        uid,
    )
}

/// The home a started daemon gets: `ACPMUX_HOME`, else the configured
/// socket's directory, else the socket's own, except the shared short alias
/// folder a long path resolves to ([`socket_path_for`]): acpmux creates that
/// one private, so a home there would be `~/.acpmux`.
pub fn daemon_home_for(
    home: Option<&str>,
    configured: Option<&str>,
    socket: &Path,
    user_home: &Path,
    uid: u32,
) -> PathBuf {
    if let Some(home) = home {
        return home.into();
    }
    let named = configured.map_or(socket, Path::new);
    match named.parent() {
        Some(dir) if dir != Path::new(&format!("/tmp/acpmux-{uid}")) => dir.into(),
        Some(_) => user_home.join(".acpmux"),
        None => PathBuf::from("."),
    }
}

/// The daemon this process started (local mode): only that one is this
/// host's to stop. One per process: the host never starts a second
/// ([`decide`] refuses once it saw a daemon).
pub struct Started {
    bin: PathBuf,
    socket: PathBuf,
    home: PathBuf,
    /// The daemon's process (never waited before the stop): whether it
    /// still runs tells a daemon this host may stop from one already gone.
    child: std::process::Child,
}

impl Started {
    /// Whether the daemon this host started already exited (a handoff or
    /// the app stopped it; the next daemon on its socket is not this host's).
    pub fn gone(&mut self) -> bool {
        !matches!(self.child.try_wait(), Ok(None))
    }

    /// Stops it with `acpmux daemon shutdown` (its agents end first).
    pub fn shutdown(self, log: &dyn Fn(&str)) -> bool {
        let stopped = shutdown_at(&self.bin, &self.home, &self.socket, log);
        let mut child = self.child;
        // Reaped when it exited (no zombie while the host still runs).
        let _ = child.try_wait();
        stopped
    }
}

/// The starts of this process: in flight, done, and whether it stops.
struct Starts {
    starting: u32,
    started: Option<Started>,
    stopped: bool,
}

static STARTS: std::sync::Mutex<Starts> = std::sync::Mutex::new(Starts {
    starting: 0,
    started: None,
    stopped: false,
});
static START_DONE: std::sync::Condvar = std::sync::Condvar::new();

fn starts() -> std::sync::MutexGuard<'static, Starts> {
    STARTS
        .lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
}

/// A start begins, unless a stop came first.
fn begin_start() -> bool {
    let mut starts = starts();
    if starts.stopped {
        return false;
    }
    starts.starting += 1;
    true
}

/// A start ended, with the daemon it started (None: it started none).
fn finish_start(started: Option<Started>) {
    let mut starts = starts();
    starts.starting -= 1;
    if starts.started.is_none() {
        starts.started = started;
    }
    START_DONE.notify_all();
}

/// How long a stop waits for a start in flight: [`spawn`] ends within
/// [`SPAWN_LIMIT`].
const START_WAIT: Duration = Duration::from_secs(65);

/// A stop began ([`take_started`]): a start waiting in [`spawn`] for an
/// older daemon's lock starts no daemon.
static STOP_ASKED: AtomicBool = AtomicBool::new(false);

/// How long `acpmux daemon shutdown` may take (it ends every agent host,
/// with its own SIGTERM-to-SIGKILL grace).
const SHUTDOWN_LIMIT: Duration = Duration::from_secs(20);

/// The daemon this process started (local mode), once: a start in flight
/// (the child exists, its socket not yet) finishes first, and no start
/// begins after this. None: it started none (a daemon it found running
/// belongs to the app, a supervisor or another Chief, and is left alone).
pub fn take_started() -> Option<Started> {
    // A start that waits for an older daemon's lock gives up now.
    STOP_ASKED.store(true, Ordering::SeqCst);
    let (mut starts, _) = START_DONE
        .wait_timeout_while(starts(), START_WAIT, |s| s.starting > 0)
        .unwrap_or_else(std::sync::PoisonError::into_inner);
    starts.stopped = true;
    starts.started.take()
}

/// Stops the acpmux daemon this process started, if it still runs, with
/// every agent host of its home (`acpmux daemon shutdown`). Whether it
/// stopped one.
pub fn shutdown_started(log: &dyn Fn(&str)) -> bool {
    let Some(mut started) = take_started() else {
        return false;
    };
    !started.gone() && started.shutdown(log)
}

/// Stops the daemon this host's `ACPMUX_HOME`/`ACPMUX_SOCKET` name with
/// `$ACPMUX_BIN daemon shutdown`, whoever started it: the last Chief to
/// leave a Chief home's shared acpmux (hq-6d 2026-10-14).
pub fn shutdown_shared(log: &dyn Fn(&str)) {
    let Some(bin) = env("ACPMUX_BIN") else {
        log("stopping acpmux: ACPMUX_BIN is not set");
        return;
    };
    let socket = socket_path();
    let home = daemon_home(&socket);
    // Not waited for, in its own process group: a brain's host stops within
    // the supervisor's grace (5 s before SIGKILL), the shutdown may take 20.
    let started = Command::new(&bin)
        .args(["daemon", "shutdown", "--end-agents"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", &socket)
        .current_dir(&home)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn();
    match started {
        Ok(child) => log(&format!(
            "stopping acpmux: `daemon shutdown --end-agents` runs (pid {})",
            child.id()
        )),
        Err(e) => log(&format!("stopping acpmux: starting {bin}: {e}")),
    }
}

/// `bin daemon shutdown --end-agents` for the daemon of `home` on `socket`, bounded.
fn shutdown_at(bin: &Path, home: &Path, socket: &Path, log: &dyn Fn(&str)) -> bool {
    let mut command = Command::new(bin);
    command
        .args(["daemon", "shutdown", "--end-agents"])
        .env("ACPMUX_HOME", home)
        .env("ACPMUX_SOCKET", socket)
        .current_dir(home)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    let mut child = match command.spawn() {
        Ok(child) => child,
        Err(e) => {
            log(&format!("stopping acpmux: starting {}: {e}", bin.display()));
            return false;
        }
    };
    let deadline = Instant::now() + SHUTDOWN_LIMIT;
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                log(&format!("stopped the acpmux daemon ({status})"));
                return true;
            }
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(50));
            }
            Ok(None) => {
                let _ = child.kill();
                let _ = child.wait();
                log("stopping acpmux: `daemon shutdown` did not finish in 20 s");
                return false;
            }
            Err(e) => {
                log(&format!("stopping acpmux: {e}"));
                return false;
            }
        }
    }
}

/// How long one `daemon run` may take to answer on its socket.
const READY_LIMIT: Duration = Duration::from_secs(30);

/// How long [`spawn`] takes at most, a wait for the daemon before it to let
/// `daemon.lock` go and the second start included. That daemon still stops
/// after an update's handoff: the new host started 15 s after the old one
/// ended, and the old daemon took 15 to 23 s to stop (2026-10-20).
const SPAWN_LIMIT: Duration = Duration::from_secs(60);

/// Whether another process holds the daemon lock at `path` now. The probe
/// takes the lock for an instant, as the app's `AcpmuxQuitProof.lockState`.
fn lock_held(path: &Path) -> bool {
    use std::os::unix::io::AsRawFd;
    let Ok(file) = std::fs::OpenOptions::new().read(true).write(true).open(path) else {
        return false;
    };
    // SAFETY: flock on a descriptor this function owns.
    if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) } == 0 {
        // SAFETY: as above.
        unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_UN) };
        return false;
    }
    std::io::Error::last_os_error().kind() == std::io::ErrorKind::WouldBlock
}

/// Waits until no process holds the daemon lock at `path`, at most `wait`.
/// Deviation, as in acpmux's own `wait_for_lock_release`: flock gives no
/// release event, so this checks with a short, growing interval.
fn await_lock_release(path: &Path, wait: Duration) -> bool {
    let deadline = Instant::now() + wait;
    let mut step = Duration::from_millis(10);
    while lock_held(path) {
        if Instant::now() >= deadline || STOP_ASKED.load(Ordering::SeqCst) {
            return false;
        }
        std::thread::sleep(step);
        step = (step * 2).min(Duration::from_millis(250));
    }
    true
}

/// Starts `$ACPMUX_BIN daemon run` and waits for its socket (local mode).
/// When the daemon exits before its socket answers, most often because the
/// one before it still holds `daemon.lock` (it stops after a handoff), this
/// waits for that lock and starts it once more, all within [`SPAWN_LIMIT`].
/// `None`: a daemon this host did not start answered meanwhile.
fn spawn(
    socket: &Path,
    bin: Option<&str>,
    log: &dyn Fn(&str),
) -> Result<Option<std::process::Child>, String> {
    let limit = Instant::now() + SPAWN_LIMIT;
    let lock = daemon_home(socket).join("daemon.lock");
    let status = match spawn_once(socket, bin, log, limit)? {
        Spawned::Ready(child) => return Ok(Some(child)),
        Spawned::Exited(status) => status,
    };
    // The lock may already be free here: the old daemon can stop between
    // this start's exit and the probe, so a free lock starts once more too.
    if lock_held(&lock) {
        log(&format!(
            "acpmux daemon exited ({status}): the daemon before it still holds {}; waiting for it to stop",
            lock.display()
        ));
        if !await_lock_release(&lock, limit.saturating_duration_since(Instant::now())) {
            return Err(format!(
                "acpmux daemon exited before its socket was ready: {status}; another daemon still holds {}",
                lock.display()
            ));
        }
    }
    if reachable(socket) {
        return Ok(None);
    }
    if STOP_ASKED.load(Ordering::SeqCst) {
        return Err("the host is stopping; it starts no acpmux".into());
    }
    if Instant::now() >= limit {
        return Err(format!(
            "acpmux daemon exited before its socket was ready: {status}; no time is left to start it again"
        ));
    }
    match spawn_once(socket, bin, log, limit)? {
        Spawned::Ready(child) => Ok(Some(child)),
        // Another starter's daemon took the lock first: use it once it answers.
        Spawned::Exited(_) if lock_held(&lock) => {
            await_socket(socket, limit.saturating_duration_since(Instant::now()))?;
            Ok(None)
        }
        Spawned::Exited(status) => Err(format!(
            "acpmux daemon exited before its socket was ready: {status}"
        )),
    }
}

/// What one `daemon run` start did.
enum Spawned {
    /// Its socket answers.
    Ready(std::process::Child),
    /// It exited before its socket answered.
    Exited(std::process::ExitStatus),
}

/// One `$ACPMUX_BIN daemon run`, waited for until its socket answers, for
/// [`READY_LIMIT`] and never past `limit`.
fn spawn_once(
    socket: &Path,
    bin: Option<&str>,
    log: &dyn Fn(&str),
    limit: Instant,
) -> Result<Spawned, String> {
    let Some(bin) = bin else {
        return Err(format!(
            "acpmux is not reachable at {} and ACPMUX_BIN is not set",
            socket.display()
        ));
    };
    let home = daemon_home(socket);
    std::fs::create_dir_all(&home).map_err(|e| format!("creating {}: {e}", home.display()))?;
    let out = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(home.join("daemon.log"))
        .map_err(|e| format!("opening the daemon log: {e}"))?;
    let err = out.try_clone().map_err(|e| e.to_string())?;
    let mut command = Command::new(bin);
    for key in CHIEF_CREDENTIAL_ENV {
        command.env_remove(key);
    }
    if shared() {
        // The Chief home's daemon serves every Chief and the person's tabs:
        // none of this Chief's identity reaches it (its sessions would act
        // as this Chief), and its MUX_HOME is the Chief home, as when the
        // default Chief's host starts it. Each Chief's own sessions get
        // their MUX_HOME from their preset (acpmux chief_builtins).
        for key in CHIEF_IDENTITY_ENV {
            command.env_remove(key);
        }
        if let Some(home) = env("CMUX_CHIEF_HOME") {
            command.env("MUX_HOME", home);
        }
    }
    if let Some(extra) = CHILD_ENV.get() {
        command.envs(extra);
    }
    let mut child = command
        .args(["daemon", "run"])
        .env("ACPMUX_HOME", &home)
        .env("ACPMUX_SOCKET", socket)
        // LAUNCH-NO-TCC-PROMPTS: in its own home, never the host's folder
        // (the app's `/`, or the home folder); what it starts without a
        // folder of its own inherits this one.
        .current_dir(&home)
        .stdin(Stdio::null())
        .stdout(out)
        .stderr(err)
        // Its own process group, so it outlives the host like the app's start.
        .process_group(0)
        .spawn()
        .map_err(|e| format!("starting {bin}: {e}"))?;
    let pid = child.id();
    log(&format!(
        "started acpmux daemon {bin} (pid {pid}, ACPMUX_HOME {})",
        home.display()
    ));
    // Deviation: acpmux-daemon.ts waits on file-system events of the socket's
    // directory; without a watcher dependency this checks with a short,
    // growing interval, bounded by READY_LIMIT, and stops early when the child exits.
    let started = Instant::now();
    let deadline = (started + READY_LIMIT).min(limit);
    let mut step = Duration::from_millis(10);
    loop {
        if reachable(socket) {
            // Never waited for while it runs: it outlives the host (its own
            // process group); the stop asks whether it still runs.
            return Ok(Spawned::Ready(child));
        }
        if let Ok(Some(status)) = child.try_wait() {
            return Ok(Spawned::Exited(status));
        }
        if Instant::now() >= deadline {
            // Started and never ready: it is this host's, so it ends here.
            let _ = child.kill();
            let _ = child.wait();
            return Err(format!(
                "acpmux socket {} not ready after {} s",
                socket.display(),
                started.elapsed().as_secs()
            ));
        }
        std::thread::sleep(step);
        step = (step * 2).min(Duration::from_millis(250));
    }
}
