//! The client side of the daemon: connect to the running daemon, or start one (the managed unit,
//! the login session, a detached child) and connect once it serves. `daemon.rs` keeps the
//! detached spawn itself (`spawn_detached`) and the daemon's own `run`.

use super::*;

/// Connect to the daemon, starting one if needed.
pub async fn connect(autostart: bool) -> Result<Arc<Client>> {
    let home = home();
    let path = socket_path();
    connect_with_systemctl("systemctl", &home, &path, autostart, || Client::connect(&path)).await
}

/// Connect a trigger client without forwarding ambient session caller
/// credentials into the daemon connection.
pub async fn connect_without_caller(autostart: bool) -> Result<Arc<Client>> {
    let home = home();
    let path = socket_path();
    connect_with_systemctl("systemctl", &home, &path, autostart, || {
        Client::connect_without_caller(&path)
    })
    .await
}

/// A connected socket to the daemon, starting one if needed, for a client
/// that speaks the wire protocol itself (`acpmux stdio`).
pub async fn connect_stream() -> Result<crate::local_stream::Stream> {
    let home = home();
    let path = socket_path();
    connect_with_systemctl("systemctl", &home, &path, true, || async {
        Ok(crate::local_stream::connect(&path).await?)
    })
    .await
}

/// While the owner record of `home` names a live daemon other than this process (it wrote the
/// record right after taking the lock, before it binds: `supervision::start`), dial it again
/// until it answers, at most [`START_BUDGET`]. `None` at once when no live owner is recorded (a
/// crash left only its record: the caller starts the next one), when the owner dies meanwhile,
/// or at the budget.
pub(super) async fn connect_when_ready<T, F, Fut>(home: &std::path::Path, connect: &F) -> Option<T>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    let starting = || {
        supervision::owner(home).is_some_and(|owner| {
            !owner.is_current() && owner.liveness() == cmux_supervise_core::Liveness::Alive
        })
    };
    if !starting() {
        return None;
    }
    // timeout: a daemon that holds the home and never binds is a hung start; the caller's own
    // start path follows, as before this wait.
    let deadline = tokio::time::Instant::now() + START_BUDGET;
    while tokio::time::Instant::now() < deadline {
        tokio::time::sleep(Duration::from_millis(20)).await;
        if let Ok(value) = connect().await {
            return Some(value);
        }
        if !starting() {
            return None;
        }
    }
    None
}

pub(super) async fn connect_with_systemctl<S, T, F, Fut>(
    systemctl: S,
    current_home: &std::path::Path,
    path: &std::path::Path,
    autostart: bool,
    connect: F,
) -> Result<T>
where
    S: AsRef<std::ffi::OsStr> + Clone,
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    if let Ok(value) = connect().await {
        return Ok(value);
    }
    // A daemon that holds the home and is not serving yet (a restart or an update mid-dial):
    // wait for it to answer instead of failing or starting a second one (F10).
    if let Some(value) = connect_when_ready(current_home, &connect).await {
        return Ok(value);
    }
    if !autostart {
        return Err(anyhow!("no acpmux daemon at {} (run `acpmux daemon`)", path.display()));
    }
    // Starting the managed unit can recreate a removed home, just like a detached start.
    if !EXPLICIT_START.load(std::sync::atomic::Ordering::Relaxed) {
        check_autostart(current_home, path)?;
    }
    if let Some(value) = managed_unit_connect_with(systemctl, current_home, path, &connect).await? {
        return Ok(value);
    }
    start_and_connect(path, connect).await
}

/// How often a command tries again while another daemon holds the lock.
pub(super) const HANDOVER_RETRY: Duration = Duration::from_millis(250);

/// Starts a daemon and connects. When the started daemon found the lock taken (its readiness
/// line says `lockHeld`), another daemon is stopping or starting: the command connects once that
/// one serves, or starts the next daemon once it has exited.
pub(super) async fn start_and_connect<T, F, Fut>(path: &std::path::Path, connect: F) -> Result<T>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    if !EXPLICIT_START.load(std::sync::atomic::Ordering::Relaxed) {
        check_autostart(&home(), path)?;
    }
    exe_path::check_start()?;
    // A config.json the daemon would refuse (a network listen without its opt-in, WireGuard
    // without its settings): a daemon placed as a launchd job has no readiness line to say so.
    // Say it here.
    if let Some(why) = saved_start_refusal().await {
        return Err(anyhow!(why));
    }
    // The lock's holder serves this home at another socket: a start would wait out its own
    // handover for it (`handover::wait`), and no wait makes it serve this one.
    if let Some(other) = holder_elsewhere(path).await {
        return Err(serves_elsewhere(path, &other));
    }
    loop {
        let ready = start_daemon().await?;
        let error = match connect().await {
            Ok(c) => return Ok(c),
            Err(e) => e,
        };
        if !lock_held(&ready) {
            return Err(not_ready(path, &ready, &error));
        }
        // The lock's holder serves this home at another socket: no wait makes it serve this one.
        if let Some(other) = holder_elsewhere(path).await {
            return Err(serves_elsewhere(path, &other));
        }
        tokio::time::sleep(HANDOVER_RETRY).await;
        if let Ok(c) = connect().await {
            return Ok(c);
        }
    }
}

/// Set by `acpmux daemon start`: the person asked for a daemon in this home and at this socket,
/// so [`check_autostart`] (for commands that start one only to be served) does not apply.
pub(super) static EXPLICIT_START: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);

/// This command is `acpmux daemon start` (see [`EXPLICIT_START`]).
pub fn mark_explicit_start() {
    EXPLICIT_START.store(true, std::sync::atomic::Ordering::Relaxed);
}

/// Refuses a start whose home or socket cannot be this command's daemon's
/// ([`crate::config::autostart_refusal`]).
pub(super) fn check_autostart(home: &std::path::Path, path: &std::path::Path) -> Result<()> {
    let configured =
        std::env::var_os("ACPMUX_SOCKET").filter(|v| !v.is_empty()).map(|_| path.to_path_buf());
    #[cfg(unix)]
    let own = crate::config::socket_path_for(home, None);
    // Windows derives its pipe path its own way; only the missing-home rule applies there.
    #[cfg(not(unix))]
    let own = path.to_path_buf();
    match crate::config::autostart_refusal(
        home,
        std::env::var_os("ACPMUX_HOME").is_some(),
        configured.as_deref(),
        &own,
    ) {
        Some(why) => Err(anyhow!(why)),
        None => Ok(()),
    }
}

/// Why a daemon started from this home's config.json would refuse to start, or None: the whole
/// start check (`Config::start_refusal`, `config/start_check.rs`), which `config --set` and
/// `_acpmux/reload_config` run too: the WireGuard transport's settings and a `websocket.listen`
/// on a network address without `websocket.allowInsecureNetwork`. `daemon status` shows it when
/// no daemon runs, and a start refuses with it before it spawns one.
pub async fn saved_start_refusal() -> Option<String> {
    let config = crate::config::Config::load().ok()?;
    tokio::task::spawn_blocking(move || config.start_refusal().err().map(|e| format!("{e:#}")))
        .await
        .ok()
        .flatten()
}

/// The refusal when this home's daemon serves `other`, not `path`.
pub(super) fn serves_elsewhere(path: &std::path::Path, other: &std::path::Path) -> anyhow::Error {
    anyhow!(
        "the acpmux daemon that holds {} serves {}, not {}; unset ACPMUX_SOCKET or set it to {}",
        home().join("daemon.lock").display(),
        other.display(),
        path.display(),
        other.display()
    )
}

/// The socket a daemon of this home serves, when it is not `path`: the socket its lock records
/// (`lock::holder_socket`), else the home's own, once the daemon answering there says in its
/// status that it is this home's (`home`, `socket`).
#[cfg(unix)]
pub(super) async fn holder_elsewhere(path: &std::path::Path) -> Option<std::path::PathBuf> {
    let home = home();
    let mut candidates = Vec::new();
    for socket in lock::holder_socket(&home.join("daemon.lock"))
        .into_iter()
        .chain([crate::config::socket_path_for(&home, None)])
    {
        if socket != path && !candidates.contains(&socket) {
            candidates.push(socket);
        }
    }
    for socket in candidates {
        // The connect too: a stopped (suspended) daemon accepts and never answers `initialize`.
        let Ok(client) = Client::connect(&socket).await else { continue };
        let Ok(status) =
            client.request(crate::rpc::method::MUX_STATUS, serde_json::json!({})).await
        else {
            continue;
        };
        let serves =
            |key: &str| status.get(key).and_then(Value::as_str).map(std::path::PathBuf::from);
        if serves("home").as_deref() == Some(home.as_path())
            && let Some(serving) = serves("socket").filter(|s| s != path)
        {
            return Some(serving);
        }
    }
    None
}

#[cfg(not(unix))]
pub(super) async fn holder_elsewhere(_path: &std::path::Path) -> Option<std::path::PathBuf> {
    None
}

/// Whether a started daemon's readiness line says another daemon holds the lock.
pub(super) fn lock_held(ready: &str) -> bool {
    serde_json::from_str::<Value>(ready.trim())
        .ok()
        .and_then(|v| v.get("lockHeld").and_then(Value::as_bool))
        == Some(true)
}

/// Start a daemon and wait until it reports readiness or exits. Returns its
/// readiness line (empty when it exited first).
#[cfg(unix)]
pub(super) async fn start_daemon() -> Result<String> {
    start_daemon_with(None).await
}

/// `start_daemon`, with a person key for the daemon (`start_keyed`).
#[cfg(unix)]
pub(super) async fn start_daemon_with(key: Option<zeroize::Zeroizing<String>>) -> Result<String> {
    let path = socket_path();
    // Outside the login session (an ssh client): the daemon goes to the user's GUI
    // session so its agents read the login keychain (`daemon/login_session.rs`). A
    // keyed start (the app's restart over ssh) stays here and says so.
    #[cfg(target_os = "macos")]
    {
        let choice = super::start_exe::current(&home())?;
        crate::config::private_state_dir(&home())?;
        let log = home().join("daemon.log");
        drop(open_daemon_log(&log)?);
        let this = choice.this.clone();
        let (daemon_home, keyed) = (home(), key.is_some());
        let placed = tokio::task::spawn_blocking(move || {
            login_session::start_in_login_session(&this, &daemon_home, &log, keyed)
        })
        .await
        .map_err(|e| anyhow!("{e}"))?;
        match placed {
            Ok(login_session::Started::Job(job)) => {
                if let Ok(mut log) = open_daemon_log(&crate::config::home().join("daemon.log")) {
                    super::log_start_choice(&mut log, &choice);
                }
                return wait_for_job(&path, job).await;
            }
            Ok(login_session::Started::Running) => return Ok(LOCK_HELD_LINE.to_owned()),
            Ok(login_session::Started::No) => {}
            Ok(login_session::Started::NoGuiLogin) => {
                eprintln!("{}", login_placement::no_gui_login_warning());
                tracing::warn!("{}", login_placement::no_gui_login_warning());
            }
            Ok(login_session::Started::KeyedInPlace) => {
                eprintln!("{}", login_placement::keyed_in_place_warning());
                tracing::warn!("{}", login_placement::keyed_in_place_warning());
            }
            Err(e) => {
                let line = login_placement::start_failed_warning(&format!("{e:#}"));
                eprintln!("{line}");
                tracing::warn!("{line}");
            }
        }
    }
    // Async pipe I/O keeps the client runtime responsive while the detached
    // process writes readiness or closes the pipe on exit.
    let (ready, child_pid) = spawn_detached(key)?;
    let ready =
        tokio::net::unix::pipe::Receiver::from_file(ready).context("wait for acpmux daemon")?;
    // The daemon writes one line to the pipe once its socket is bound, or
    // the pipe reaches end of file when it exits first (another daemon won
    // the lock, bad config). Either way the caller connects once afterwards.
    let wait = async move {
        use tokio::io::AsyncBufReadExt;
        let mut line = String::new();
        tokio::io::BufReader::new(ready).read_line(&mut line).await.map(|_| line)
    };
    // EOF means the detached child exited; a live child keeps the pipe open
    // until it writes readiness. The pipe itself is the liveness signal, so a
    // busy machine never turns a slow but live daemon into a startup failure.
    let mut wait = std::pin::pin!(wait);
    loop {
        match tokio::time::timeout(START_BUDGET, &mut wait).await {
            Ok(read) => return Ok(read?),
            Err(_)
                if lock_has_live_holder(&home().join("daemon.lock"))
                    && live_holder_pid(&home().join("daemon.lock")) != Some(child_pid) =>
            {
                // A live winner may be slow on a busy machine; keep waiting on
                // its lock/pipe liveness instead of failing the caller.
            }
            Err(_) => {
                return Err(anyhow!(
                    "daemon did not come up at {} within {START_BUDGET:?}; see {}",
                    path.display(),
                    home().join("daemon.log").display()
                ));
            }
        }
    }
}
/// The readiness line of a daemon that found the lock taken (`run`).
#[cfg(target_os = "macos")]
pub(super) const LOCK_HELD_LINE: &str = r#"{"ready":false,"lockHeld":true}"#;

/// A daemon started as launchd job `job` has no readiness pipe: its socket answering is its
/// readiness (an empty line; the caller connects). A job that ended before its socket answered
/// most likely found the lock taken by a daemon still stopping (`daemon shutdown`, `host
/// update`): that is reported as [`LOCK_HELD_LINE`], so `start_and_connect` waits for that
/// daemon while it still owns the lock and starts the next one, as it does for a daemon it
/// spawned. launchd is asked every half second; the lock and job state are the liveness signals.
#[cfg(target_os = "macos")]
pub(super) async fn wait_for_job(path: &std::path::Path, job: String) -> Result<String> {
    let deadline = tokio::time::Instant::now() + START_BUDGET;
    let mut tries = 0u32;
    while tokio::time::Instant::now() < deadline {
        if tokio::net::UnixStream::connect(path).await.is_ok() {
            return Ok(String::new());
        }
        tries += 1;
        if tries.is_multiple_of(5) {
            let job = job.clone();
            // timeout: launchd's status probe must not pin the async runtime;
            // a live job is checked again on the next pass.
            let budget = Duration::from_secs(1);
            let running =
                tokio::task::spawn_blocking(move || login_session::job_running(&job, budget))
                    .await
                    .unwrap_or(true);
            if !running && tokio::net::UnixStream::connect(path).await.is_err() {
                return Ok(LOCK_HELD_LINE.to_owned());
            }
        }
        tokio::time::sleep(Duration::from_millis(100)).await;
    }
    Err(anyhow!(
        "daemon did not come up at {} within {START_BUDGET:?}; see {}",
        path.display(),
        home().join("daemon.log").display()
    ))
}

/// Windows: CreateProcessW with a handle list (`daemon/windows.rs`).
#[cfg(windows)]
pub(super) async fn start_daemon() -> Result<String> {
    windows::start_daemon(&home(), &daemon_prefix()).await
}

pub(super) fn not_ready(
    path: &std::path::Path,
    ready: &str,
    error: &anyhow::Error,
) -> anyhow::Error {
    if let Some(refused) = exe_path::refused_line(ready) {
        return anyhow!("{refused}");
    }
    let why = if ready.trim().is_empty() {
        "exited before it was ready"
    } else {
        "is ready but refused the connection"
    };
    anyhow!(
        "daemon {why} at {}: {error:#}; see {}",
        path.display(),
        home().join("daemon.log").display()
    )
}
