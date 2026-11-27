//! A daemon that holds its home's lock but whose socket stopped accepting is replaced, never waited
//! on forever. A Mac at load 48-75, 2026-11-27: launchd's daemon held `daemon.lock` for 29 min while
//! its socket refused every connect; four more `daemon run` starts queued behind it, each logging
//! "another daemon holds the lock; waiting for its socket or exit", and `acpmux daemon restart`
//! could not reach it. A manual SIGTERM of the holder brought everything back.
//!
//! Three parts:
//! - Progress: the holder writes `daemon.beat` (its pid, its phase, the wall time) when it takes the
//!   lock, when its socket is bound and at each start step ([`Phase::Starting`], [`step`]), then
//!   every [`BEAT_EVERY`] from its own accept loop ([`Phase::Serving`]) while that loop is polled and accepts without failing. A
//!   wedged runtime, an accept loop that never started, or one stuck on a failing `accept` (EMFILE)
//!   stops the beat; a busy daemon does not.
//! - Replace: the one standing waiter ([`stand`]) replaces the holder only when both its own probes
//!   of the socket have failed and the holder's beat is stale, for longer than the phase's bound
//!   ([`stalled`]): [`SERVING_STALL`] once it served, [`STARTING_STALL`] before. A slow holder that
//!   answers one probe, or keeps beating, is never touched. The replace is SIGTERM, up to
//!   [`TERM_WAIT`] for the lock to go, then SIGKILL; each signal only after [`verify`] proves the
//!   pid is this home's acpmux daemon: the lock is held, the lock's pid is the owner record's,
//!   the owner record's start time and boot match the live process (no reused pid), its executable
//!   is acpmux and its cwd is this home (a daemon `chdir`s into its home, `daemon::run`).
//! - One waiter: a start that loses the lock takes `daemon.wait.lock`; a second start finding it
//!   held answers its launcher (`waiterStands`) and exits 0. The launcher of that start waits for
//!   the standing one instead of starting another (`connect::start_and_connect`). launchd's own
//!   standby and job waits are not waiters here: a launchd job that exits is restarted after its
//!   ThrottleInterval (a respawn loop, hq#22842), so those keep waiting as before.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::Duration;

use serde_json::{Value, json};

/// How long a holder that served may neither answer a probe nor beat before it is replaced: about
/// 15 s, seven missed beats in a row. Progress is the accept loop's beat: the loop's own interval
/// ([`BEAT_EVERY`]) fired, so the runtime polls it, and it accepted or did not fail. A busy daemon
/// still beats (handling runs on other tasks); at load 60 a runnable tokio worker waits tens to
/// hundreds of milliseconds for a core, not seconds, so 15 s with no beat and no answer is a hang.
// timeout: hazard is a holder whose accept loop stopped; fallback is the SIGTERM-then-SIGKILL replace.
pub(crate) const SERVING_STALL: Duration = Duration::from_secs(15);

/// The same for a holder that has not served yet (or an older build that writes no beat): its
/// start beats at each step between the lock and the accept loop ([`step`]), so this bounds one
/// step. The longest is the journal open (`store::open`), seconds on a large home; two minutes
/// leaves a loaded Mac a wide margin and still ends an 8- or 29-minute silent holder.
// timeout: hazard is a start hung between its bind and its accept loop; fallback is the replace.
pub(crate) const STARTING_STALL: Duration = Duration::from_secs(120);

/// How often a serving daemon's accept loop writes its beat (a rename of a few bytes, unsynced).
pub(crate) const BEAT_EVERY: Duration = Duration::from_secs(2);

/// One probe of the holder's socket: connect, hello and `_acpmux/status`. A connect into a queue
/// nobody accepts from waits forever without it (the client's hello has no limit).
// timeout: hazard is a socket whose queue is never accepted; fallback is the next probe.
pub(crate) const PROBE_BOUND: Duration = Duration::from_secs(5);

/// How long a SIGTERM'd holder has to let go of its lock before SIGKILL. Its own stop is bounded
/// at a few seconds (`stop_watchdog.rs`); this leaves room for a loaded machine.
// timeout: hazard is a holder that ignores SIGTERM; fallback is SIGKILL.
pub(crate) const TERM_WAIT: Duration = Duration::from_secs(15);

/// How long the kernel gets to release a SIGKILL'd holder's lock before the waiter looks again.
// timeout: hazard is a killed holder not reaped yet; fallback is the waiter's next look.
const KILL_WAIT: Duration = Duration::from_secs(5);

/// How often the standing waiter says it still waits: the app's launch ends a start whose log saw
/// no write for 20 s (`AcpmuxDaemonLauncher`), which is how the waiters piled up.
pub(crate) const WAITER_SAYS_EVERY: Duration = Duration::from_secs(10);

/// The stall bounds in use.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct Bounds {
    pub serving: Duration,
    pub starting: Duration,
    pub probe: Duration,
}

impl Bounds {
    pub(crate) const DEFAULT: Bounds =
        Bounds { serving: SERVING_STALL, starting: STARTING_STALL, probe: PROBE_BOUND };

    /// [`Bounds::DEFAULT`]; debug builds read `ACPMUX_TEST_STALL_MS` (both stall bounds, the probe a
    /// quarter of it) so a test sees a replace within seconds.
    pub(crate) fn current() -> Bounds {
        #[cfg(debug_assertions)]
        if let Some(ms) =
            std::env::var("ACPMUX_TEST_STALL_MS").ok().and_then(|v| v.trim().parse::<u64>().ok())
        {
            let stall = Duration::from_millis(ms.max(1));
            return Bounds {
                serving: stall,
                starting: stall,
                probe: (stall / 4).max(Duration::from_millis(50)),
            };
        }
        Bounds::DEFAULT
    }
}

/// Where the holder is, as its beat says.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Phase {
    /// Holds the lock; its accept loop has not run yet.
    Starting,
    /// Its accept loop runs and accepts.
    Serving,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Phase::Starting => "starting",
            Phase::Serving => "serving",
        }
    }
}

static BEAT_FILE: OnceLock<PathBuf> = OnceLock::new();

pub(crate) fn beat_path(home: &Path) -> PathBuf {
    home.join("daemon.beat")
}

/// This daemon holds `home`'s lock: its beats go to `home`, starting with this one.
pub(crate) fn arm(home: &Path) {
    let _ = BEAT_FILE.set(beat_path(home));
    beat(Phase::Starting);
}

/// One startup step between the lock and the accept loop is done: a starting beat and a log line,
/// so a holder is never silent while it starts.
pub(crate) fn step(name: &str) {
    beat(Phase::Starting);
    tracing::debug!("daemon start: {name} done");
}

/// Writes this daemon's beat; nothing in a process that holds no home ([`arm`]).
pub(crate) fn beat(phase: Phase) {
    let Some(path) = BEAT_FILE.get() else { return };
    // Debug builds only: a holder as an older build, which writes no beat.
    #[cfg(debug_assertions)]
    if std::env::var_os("ACPMUX_TEST_NO_BEAT").is_some() {
        return;
    }
    let line = json!({"pid": std::process::id(), "phase": phase.name(), "atMs": now_ms()});
    if let Err(e) = crate::config::write_atomic_unsynced(path, line.to_string().as_bytes()) {
        tracing::debug!("daemon beat: {e}");
    }
}

/// The beat in `home` when `pid` wrote it, with its age: a beat of another pid is a previous
/// daemon's, no beat of this one. A beat from the future (a clock set back) is fresh.
pub(crate) fn beat_of(home: &Path, pid: u32) -> Option<(Phase, Duration)> {
    let text = std::fs::read_to_string(beat_path(home)).ok()?;
    let v: Value = serde_json::from_str(text.trim()).ok()?;
    if v.get("pid").and_then(Value::as_u64) != Some(u64::from(pid)) {
        return None;
    }
    let phase = match v.get("phase").and_then(Value::as_str)? {
        "serving" => Phase::Serving,
        _ => Phase::Starting,
    };
    let at = v.get("atMs").and_then(Value::as_u64)?;
    Some((phase, Duration::from_millis(now_ms().saturating_sub(at))))
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
}

/// Whether a holder is hung: every probe this waiter made failed for `unanswered`, and its beat
/// (phase and age; `None`: it wrote none, so it is taken as starting since the waiter began) is
/// as old, both at least the phase's bound. Progress on either side keeps it.
pub(crate) fn stalled(
    unanswered: Duration,
    beat: Option<(Phase, Duration)>,
    bounds: Bounds,
) -> bool {
    let (phase, age) = beat.unwrap_or((Phase::Starting, unanswered));
    let bound = match phase {
        Phase::Serving => bounds.serving,
        Phase::Starting => bounds.starting,
    };
    unanswered >= bound && age >= bound
}

/// Why a pid is not signalled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Refusal {
    /// No live process holds the lock.
    NoHolder,
    /// No owner record to prove the holder's identity with.
    NoOwner,
    /// The lock names one pid, the owner record another.
    OwnerMismatch { lock: u32, owner: u32 },
    /// The owner record is this process's.
    Itself,
    /// The pid's start time or boot is not the owner record's (a reused pid), or unreadable.
    NotTheOwner(u32),
    /// Its executable is not acpmux (or unreadable).
    NotAcpmux(u32, Option<PathBuf>),
    /// It runs in another folder than this home (or one unreadable): another home's daemon.
    OtherHome(u32, Option<PathBuf>),
    /// It answers at a socket of its own (another `ACPMUX_SOCKET`, or an older build that writes
    /// no beat): it is not hung, only not at the socket the waiter dials.
    AnswersAt(u32, PathBuf),
}

impl std::fmt::Display for Refusal {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Refusal::NoHolder => write!(f, "no live process holds the lock"),
            Refusal::NoOwner => write!(f, "no owner record names the holder"),
            Refusal::OwnerMismatch { lock, owner } => {
                write!(f, "the lock names pid {lock}, the owner record pid {owner}")
            }
            Refusal::Itself => write!(f, "the holder is this process"),
            Refusal::NotTheOwner(pid) => {
                write!(f, "pid {pid} is not the process the owner record names (reused pid?)")
            }
            Refusal::NotAcpmux(pid, exe) => write!(f, "pid {pid} runs {exe:?}, not acpmux"),
            Refusal::OtherHome(pid, cwd) => write!(f, "pid {pid} runs in {cwd:?}, not this home"),
            Refusal::AnswersAt(pid, socket) => {
                write!(f, "pid {pid} answers at {}; it is not hung", socket.display())
            }
        }
    }
}

/// The pid of `home`'s live lock holder, once proven to be this home's acpmux daemon.
pub(crate) fn verify(home: &Path) -> Result<u32, Refusal> {
    let pid = super::lock::live_holder_pid(&home.join("daemon.lock")).ok_or(Refusal::NoHolder)?;
    let owner = super::supervision::owner(home).ok_or(Refusal::NoOwner)?;
    if owner.pid != pid {
        return Err(Refusal::OwnerMismatch { lock: pid, owner: owner.pid });
    }
    if owner.is_current() || pid == std::process::id() {
        return Err(Refusal::Itself);
    }
    if owner.liveness() != cmux_supervise_core::Liveness::Alive {
        return Err(Refusal::NotTheOwner(pid));
    }
    check_identity(pid, home)
}

/// Whether `pid` runs acpmux in `home`. Unreadable is a refusal: a pid this cannot read is
/// never signalled.
pub(crate) fn check_identity(pid: u32, home: &Path) -> Result<u32, Refusal> {
    let exe = crate::agent_host::tree::exe(pid);
    if !exe.as_deref().is_some_and(is_acpmux_exe) {
        return Err(Refusal::NotAcpmux(pid, exe));
    }
    let cwd = crate::agent_host::tree::cwd(pid);
    if !cwd.as_deref().is_some_and(|cwd| super::lock::same_path(cwd, home)) {
        return Err(Refusal::OtherHome(pid, cwd));
    }
    Ok(pid)
}

fn is_acpmux_exe(exe: &Path) -> bool {
    let name = |p: &Path| p.file_name().map(|n| n.to_string_lossy().into_owned());
    let Some(file) = name(exe) else { return false };
    file.starts_with("acpmux")
        || std::env::current_exe().ok().as_deref().and_then(name).is_some_and(|me| me == file)
}

fn signal(pid: u32, sig: libc::c_int) -> bool {
    let Ok(pid) = libc::pid_t::try_from(pid) else { return false };
    if pid <= 1 {
        return false;
    }
    // SAFETY: a signal to one verified pid; no memory is shared.
    unsafe { libc::kill(pid, sig) == 0 }
}

/// Replaces `home`'s lock holder: SIGTERM, up to [`TERM_WAIT`] for its lock, then SIGKILL, each
/// only to a pid [`verify`] proves. `Ok(pid)`: the pid it stopped (or that stopped meanwhile);
/// the lock is free or another daemon took it. `Err`: nothing was signalled.
pub(crate) async fn replace(home: &Path, why: &str) -> Result<u32, Refusal> {
    let lock = home.join("daemon.lock");
    let pid = verify(home)?;
    if let Some(socket) = answers_somewhere(home, pid).await {
        return Err(Refusal::AnswersAt(pid, socket));
    }
    tracing::warn!(
        pid,
        "{why}: replacing the lock holder (SIGTERM, SIGKILL after {}s)",
        TERM_WAIT.as_secs()
    );
    if !signal(pid, libc::SIGTERM) {
        tracing::warn!(pid, "SIGTERM failed: {}", std::io::Error::last_os_error());
    }
    if super::lock::wait_for_lock_release_with_budget(lock.clone(), Some(TERM_WAIT)).await {
        tracing::info!(pid, "the lock holder let go after SIGTERM");
        return Ok(pid);
    }
    // Proven again: in the wait it may have exited and its pid been reused, or a successor taken over.
    match verify(home) {
        Ok(again) if again == pid => {}
        Ok(other) => {
            tracing::info!(pid, "daemon {other} took the lock after SIGTERM; not killing it");
            return Ok(pid);
        }
        Err(refusal) => {
            tracing::info!(pid, "after SIGTERM: {refusal}; no SIGKILL");
            return Ok(pid);
        }
    }
    tracing::warn!(pid, "the lock holder ignored SIGTERM for {}s: SIGKILL", TERM_WAIT.as_secs());
    if !signal(pid, libc::SIGKILL) {
        tracing::warn!(pid, "SIGKILL failed: {}", std::io::Error::last_os_error());
    }
    super::lock::wait_for_lock_release_with_budget(lock, Some(KILL_WAIT)).await;
    Ok(pid)
}

/// The socket at which `pid` answers as `home`'s daemon, if any: the socket its lock records,
/// this home's own and this process's `ACPMUX_SOCKET`, each probed within the probe bound. A
/// waiter dials only its own socket, so a holder serving another one (an older build with no
/// beat, or a start with another `ACPMUX_SOCKET`) would look hung to it; this is the check that
/// it is not.
pub(crate) async fn answers_somewhere(home: &Path, pid: u32) -> Option<PathBuf> {
    let mut candidates: Vec<PathBuf> = Vec::new();
    for socket in super::lock::holder_socket(&home.join("daemon.lock"))
        .into_iter()
        .chain([crate::config::socket_path_for(home, None), crate::config::socket_path()])
    {
        if !candidates.contains(&socket) {
            candidates.push(socket);
        }
    }
    let probe = Bounds::current().probe;
    for socket in candidates {
        let status = async {
            let client = crate::client::Client::connect(&socket).await.ok()?;
            client.request(crate::rpc::method::MUX_STATUS, json!({})).await.ok()
        };
        let Ok(Some(status)) = tokio::time::timeout(probe, status).await else { continue };
        let ours = status.get("pid").and_then(Value::as_u64) == Some(u64::from(pid))
            || status
                .get("home")
                .and_then(Value::as_str)
                .is_some_and(|h| super::lock::same_path(Path::new(h), home));
        if ours {
            return Some(socket);
        }
    }
    None
}

fn wait_lock_path(home: &Path) -> PathBuf {
    home.join("daemon.wait.lock")
}

/// The one waiter of a home, while it stands.
pub(crate) struct Standing(#[allow(dead_code)] Option<cmux_file_lock::FileLock>);

/// Takes `home`'s waiter lock; `Err(pid)` when another start holds it (0: its pid unread). A
/// lock file that cannot be opened leaves this start a waiter as before: the gate never stops
/// the only waiter.
pub(crate) fn stand(home: &Path) -> Result<Standing, u32> {
    use std::os::unix::fs::FileExt;
    let Ok(file) = crate::config::private_state_rw(&wait_lock_path(home)) else {
        return Ok(Standing(None));
    };
    match cmux_file_lock::FileLock::try_take(file, cmux_file_lock::Kind::Exclusive) {
        Ok(lock) => {
            let me = format!("{}\n", std::process::id());
            if lock.file().set_len(0).is_ok() {
                let _ = lock.file().write_at(me.as_bytes(), 0);
            }
            Ok(Standing(Some(lock)))
        }
        Err(cmux_file_lock::LockError::Busy(file)) => {
            let mut buf = [0u8; 16];
            let n = file.read_at(&mut buf, 0).unwrap_or(0);
            let read = buf.get(..n).unwrap_or(&[]);
            let pid = std::str::from_utf8(read).ok().and_then(|t| t.trim().parse().ok());
            Err(pid.unwrap_or(0))
        }
        Err(cmux_file_lock::LockError::Io(_)) => Ok(Standing(None)),
    }
}

/// Whether a start stands as `home`'s waiter now.
pub(crate) fn waiter_stands(home: &Path) -> bool {
    std::fs::File::open(wait_lock_path(home)).is_ok_and(|file| {
        cmux_file_lock::FileLock::held_elsewhere(&file, cmux_file_lock::Kind::Exclusive)
            .unwrap_or(false)
    })
}

/// A readiness line saying another start stands as the waiter ([`stand`]).
pub(crate) fn says_waiter_stands(ready: &str) -> bool {
    serde_json::from_str::<Value>(ready.trim())
        .ok()
        .and_then(|v| v.get("waiterStands").and_then(Value::as_bool))
        == Some(true)
}

#[cfg(test)]
#[path = "hung_holder_tests.rs"]
mod tests;
