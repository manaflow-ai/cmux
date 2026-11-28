//! Connecting through the user systemd unit (`acpmux.service`) that owns this home's daemon,
//! instead of starting a detached daemon beside it.
use super::*;

#[cfg(target_os = "linux")]
// timeout: cleanup for a wedged systemctl health probe; the daemon request waits on liveness.
const PROBE_BUDGET: Duration = Duration::from_secs(1);

/// How long a command keeps asking a user systemd that does not answer about an installed
/// `acpmux.service` (each probe bounded by [`PROBE_BUDGET`]) before it fails with an error. A
/// probe that timed out says nothing about the unit, so it never sends the command to a detached
/// daemon: on fleet lane VMs under load (2026-11-28) a 1 s probe timing out while the unit
/// restarted started a detached `--ready-fd` daemon that took the home's lock, then hung, and
/// left the unit's own daemon waiting on it for hours.
// timeout: hazard is a wedged user systemd; fallback is an error naming it, never a second daemon.
#[cfg(target_os = "linux")]
const UNIT_SILENT_PATIENCE: Duration = Duration::from_secs(60);

/// A CLI may be launched without the service's `ACPMUX_HOME` (for example,
/// from a session shell) while its daemon is owned by the user systemd unit.
/// In that case never call [`spawn_detached`]: the unit may use a supervised
/// state directory while the default home is a symlink, and the private-state
/// guard must continue to reject that symlink. Ask systemd to start its unit
/// and wait for the socket instead.
///
/// Only a definite answer takes the detached path: no systemctl, a unit that is not loaded or
/// serves another home or socket, or one systemd marked inactive or failed. A probe that timed out
/// is asked again for [`UNIT_SILENT_PATIENCE`] when the unit file is installed, then is an error.
#[cfg(target_os = "linux")]
pub(super) async fn managed_unit_connect_with<S, T, F, Fut>(
    systemctl: S,
    current_home: &std::path::Path,
    path: &std::path::Path,
    connect: &F,
) -> Result<Option<T>>
where
    S: AsRef<std::ffi::OsStr> + Clone,
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    let installed =
        dirs::home_dir().is_some_and(|home| crate::cli::daemon_service::unit_path(&home).exists());
    managed_unit_connect_in(systemctl, installed, UNIT_SILENT_PATIENCE, current_home, path, connect)
        .await
}

/// [`managed_unit_connect_with`] with whether the unit file is `installed` and the `patience`
/// for a systemd that does not answer.
#[cfg(target_os = "linux")]
pub(super) async fn managed_unit_connect_in<S, T, F, Fut>(
    systemctl: S,
    installed: bool,
    patience: Duration,
    current_home: &std::path::Path,
    path: &std::path::Path,
    connect: &F,
) -> Result<Option<T>>
where
    S: AsRef<std::ffi::OsStr> + Clone,
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    let silent = |what: &str| {
        anyhow!(
            "systemd did not answer about acpmux.service ({what}) for {}s; not starting a daemon \
             beside the unit (check `systemctl --user status acpmux.service`)",
            patience.as_secs()
        )
    };
    let asked = tokio::time::Instant::now();
    let loaded = loop {
        match show_property(systemctl.clone(), "LoadState").await {
            Ok(Some(output)) if output.status.success() => {
                break output.stdout.trim_ascii() == b"loaded";
            }
            Ok(Some(_)) => break false,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(error) => return Err(error.into()),
            // No unit file: nothing to wait on, the detached launch serves the request.
            Ok(None) if !installed => return Ok(None),
            Ok(None) if asked.elapsed() >= patience => return Err(silent("LoadState")),
            Ok(None) => tokio::time::sleep(HANDOVER_RETRY).await,
        }
    };
    if !loaded {
        return Ok(None);
    }

    let asked = tokio::time::Instant::now();
    let env = loop {
        match show_property(systemctl.clone(), "Environment").await {
            Ok(Some(output)) if output.status.success() => {
                break String::from_utf8_lossy(&output.stdout).into_owned();
            }
            Ok(Some(output)) => {
                return Err(anyhow!(
                    "systemd could not read acpmux.service environment: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                ));
            }
            Err(error) => return Err(error.into()),
            // Loaded: the unit exists whatever its file says, so its daemon is waited on.
            Ok(None) if asked.elapsed() >= patience => return Err(silent("Environment")),
            Ok(None) => tokio::time::sleep(HANDOVER_RETRY).await,
        }
    };
    let unit_home =
        unit_environment_path(&env, "ACPMUX_HOME").unwrap_or_else(crate::config::default_home);
    if !equivalent_path(current_home, &unit_home) {
        return Ok(None);
    }
    let unit_socket = unit_environment_path(&env, "ACPMUX_SOCKET");
    let expected_socket = crate::config::socket_path_for(
        &unit_home,
        unit_socket.as_deref().and_then(|path| path.to_str()),
    );
    if !equivalent_path(path, &expected_socket) {
        return Ok(None);
    }

    // A unit start can overlap the old daemon's graceful handover. The socket
    // is the authoritative liveness signal; a slow start command is retried.
    let mut next_start = tokio::time::Instant::now();
    let mut silent_since: Option<tokio::time::Instant> = None;
    loop {
        if tokio::time::Instant::now() >= next_start {
            let _ = run_systemctl(systemctl.clone(), &["--user", "start", "acpmux.service"]).await;
            next_start = tokio::time::Instant::now() + HANDOVER_RETRY;
        }
        if let Ok(value) = connect().await {
            return Ok(Some(value));
        }
        // If systemd has already marked the unit inactive or failed, its socket
        // peer is gone; let the ordinary detached launch path recover it. A unit
        // that is starting, stopping or reloading keeps this wait open, however
        // long its request takes: during a restart the unit is `deactivating`
        // for as long as the old daemon takes to stop, and a detached daemon
        // started then runs in this command's cgroup, under its limits, and
        // takes the lock from the unit's next daemon (on a fleet lane host a
        // review box's 256-task, 4-CPU scope ran the daemon for 53 minutes and
        // every harness start in it failed with EAGAIN).
        // A probe that timed out says nothing: the unit is waited on until systemd answers, for
        // up to the patience in a row.
        match unit_active_state(systemctl.clone()).await {
            Some(state) if unit_still_live(&state) => silent_since = None,
            Some(_) => return Ok(None),
            None => {
                let since = *silent_since.get_or_insert_with(tokio::time::Instant::now);
                if since.elapsed() >= patience {
                    return Err(silent("ActiveState"));
                }
            }
        }
        tokio::time::sleep(HANDOVER_RETRY).await;
    }
}

/// Whether a unit in systemd's `ActiveState` `state` still has, or is about to
/// have, a daemon of its own: active, or on its way in or out of it.
#[cfg(target_os = "linux")]
fn unit_still_live(state: &str) -> bool {
    matches!(state, "active" | "activating" | "deactivating" | "reloading" | "refreshing")
}

/// `acpmux.service`'s `ActiveState`, or `None` when systemd did not answer in
/// [`PROBE_BUDGET`] or could not say.
// timeout: cleanup for a wedged systemctl probe; the caller asks again, up to its patience.
#[cfg(target_os = "linux")]
async fn unit_active_state<S>(systemctl: S) -> Option<String>
where
    S: AsRef<std::ffi::OsStr>,
{
    let show = tokio::process::Command::new(systemctl)
        .args(["--user", "show", "acpmux.service", "-p", "ActiveState", "--value"])
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(PROBE_BUDGET, show).await {
        Ok(Ok(output)) if output.status.success() => {
            Some(String::from_utf8_lossy(output.stdout.trim_ascii()).into_owned())
        }
        _ => None,
    }
}

/// One `systemctl --user show acpmux.service -p PROPERTY --value`; `Ok(None)` when it did not
/// finish in [`PROBE_BUDGET`] (the child is killed).
// timeout: cleanup for a wedged systemctl probe; the caller asks again, up to its patience.
#[cfg(target_os = "linux")]
async fn show_property<S>(
    systemctl: S,
    property: &str,
) -> std::io::Result<Option<std::process::Output>>
where
    S: AsRef<std::ffi::OsStr>,
{
    let show = tokio::process::Command::new(systemctl)
        .args(["--user", "show", "acpmux.service", "-p", property, "--value"])
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    match tokio::time::timeout(PROBE_BUDGET, show).await {
        Ok(output) => output.map(Some),
        Err(_) => Ok(None),
    }
}

/// Run a systemd probe without leaving a timed-out child behind. The timeout is
/// only for this advisory health probe; the daemon request itself waits on its
/// socket and lock liveness.
// timeout: cleanup for a wedged systemctl probe before retrying it.
#[cfg(target_os = "linux")]
async fn run_systemctl<S>(
    systemctl: S,
    args: &[&str],
) -> std::io::Result<Option<std::process::ExitStatus>>
where
    S: AsRef<std::ffi::OsStr>,
{
    let mut child = tokio::process::Command::new(systemctl).args(args).spawn()?;
    match tokio::time::timeout(PROBE_BUDGET, child.wait()).await {
        Ok(status) => status.map(Some),
        Err(_) => {
            let _ = child.kill().await;
            let _ = child.wait().await;
            Ok(None)
        }
    }
}

#[cfg(not(target_os = "linux"))]
pub(super) async fn managed_unit_connect_with<S, T, F, Fut>(
    _systemctl: S,
    _current_home: &std::path::Path,
    _path: &std::path::Path,
    _connect: &F,
) -> Result<Option<T>>
where
    F: Fn() -> Fut,
    Fut: std::future::Future<Output = Result<T>>,
{
    Ok(None)
}

#[cfg(target_os = "linux")]
fn unit_environment_path(environment: &str, key: &str) -> Option<std::path::PathBuf> {
    unit_environment_words(environment).into_iter().find_map(|entry| {
        entry
            .strip_prefix(key)
            .and_then(|value| value.strip_prefix('='))
            .map(std::path::PathBuf::from)
    })
}

#[cfg(target_os = "linux")]
fn unit_environment_words(environment: &str) -> Vec<String> {
    let mut words = Vec::new();
    let mut word = String::new();
    let mut quote = None;
    let mut escaped = false;
    let mut has_word = false;
    for ch in environment.chars() {
        if escaped {
            word.push(ch);
            escaped = false;
            has_word = true;
            continue;
        }
        match quote {
            Some('"') if ch == '\\' => escaped = true,
            Some(q) if ch == q => quote = None,
            Some(_) => {
                word.push(ch);
                has_word = true;
            }
            None if ch == '\\' => escaped = true,
            None if ch == '\'' || ch == '"' => {
                quote = Some(ch);
                has_word = true;
            }
            None if ch.is_ascii_whitespace() => {
                if has_word {
                    words.push(std::mem::take(&mut word));
                    has_word = false;
                }
            }
            None => {
                word.push(ch);
                has_word = true;
            }
        }
    }
    if escaped {
        word.push('\\');
        has_word = true;
    }
    if has_word {
        words.push(word);
    }
    words
}

#[cfg(target_os = "linux")]
fn equivalent_path(left: &std::path::Path, right: &std::path::Path) -> bool {
    fn normalized(path: &std::path::Path) -> Option<std::path::PathBuf> {
        std::fs::canonicalize(path).ok().or_else(|| {
            let parent = path.parent()?;
            Some(std::fs::canonicalize(parent).ok()?.join(path.file_name()?))
        })
    }
    left == right || normalized(left).zip(normalized(right)).is_some_and(|(l, r)| l == r)
}
