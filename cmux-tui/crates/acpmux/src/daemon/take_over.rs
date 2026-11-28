use super::*;

/// A systemd-owned daemon stays active while a previous daemon hands over this home.
/// This keeps `RestartPreventExitStatus=75` as a guard for detached starts without
/// making the supervised unit inactive during the ordinary handover window.
#[cfg(target_os = "linux")]
pub(super) fn managed_by_acpmux_unit() -> bool {
    std::fs::read_to_string("/proc/self/cgroup")
        .ok()
        .is_some_and(|cgroup| cgroup.lines().any(|line| line.ends_with("/acpmux.service")))
}

#[cfg(not(target_os = "linux"))]
pub(super) fn managed_by_acpmux_unit() -> bool {
    false
}

/// Whether launchd runs this daemon as this user's `com.acpmux.daemon` LaunchAgent: launchd
/// names a job's label in `XPC_SERVICE_NAME`. Such a daemon waits for the home's lock instead of
/// exiting: under `KeepAlive` an exit is a start again every 10 s for as long as another daemon
/// (one the cmux app started) holds the home, and the wait takes the home the moment that one
/// exits (the app quit and its daemon went idle), so launchd keeps it served with no app
/// (cmuxterm-hq docs/design/remote-screen-share-zero-touch.md Z1). It never asks the holder to
/// hand over: the app's own daemon keeps serving while the app runs.
///
/// The per-home job a command starts (`login_placement::job_label`,
/// `com.cmux.acpmux.daemon.<hash>`) waits the same way, in any launchd domain: on a fleet Mac
/// that job runs as a `KeepAlive` LaunchDaemon, and after each hourly update the replaced
/// daemon's swap handed the home to a detached `--take-over` start (`exe_swap.rs` has no restart
/// command for that label), so launchd's start exited 75 every 10 s (2,799 runs) and the job read
/// "loaded but not running" while the home was served outside it (cmuxterm-hq #22842).
fn launchd_job(xpc_service_name: Option<&str>) -> bool {
    cfg!(target_os = "macos")
        && xpc_service_name.is_some_and(|label| {
            label == crate::cli::daemon_service::LAUNCHD_LABEL
                || label
                    .strip_prefix(login_placement::LABEL_PREFIX)
                    .is_some_and(|hash| !hash.is_empty())
        })
}

/// Take this home's lock. The unit's daemon (`--take-over`, or a daemon in the
/// `acpmux.service` cgroup) first asks a holder that serves this same socket to hand over
/// ([`take_over_holder`]), then waits for the lock: a client can start a detached daemon in the
/// seconds between a shutdown and the unit's restart (chief-sub-a524, 2026-11-03), and waiting
/// alone would end in a lock refusal and leave the unit failed while that daemon serves the home
/// outside it. A `--take-over` start whose holder serves another socket is refused at once.
///
/// It asks each holder once, by pid, and looks at the holder again every [`HOLDER_LOOK`] while
/// it waits: when another start took the lock first, that new holder is asked too. Two take-over
/// starts at once are the usual case of an update: the replaced daemon's own swap starts one
/// (`exe_swap.rs`) and the installer starts another. Asking only the first holder left the
/// later start waiting forever on the one that won (`take_over_under_load`, 2026-11-20).
///
/// launchd's own start of the LaunchAgent (`unready`: no `--ready-fd`, so not a child that
/// inherited the job's environment and reports to its starter) waits too, without asking
/// ([`launchd_job`]).
pub(super) async fn acquire_daemon_lock(
    path: &std::path::Path,
    take_over: bool,
    unready: bool,
) -> Result<DaemonLock> {
    let unit = managed_by_acpmux_unit();
    let supervised = take_over || unit;
    let waits =
        supervised || (unready && launchd_job(std::env::var("XPC_SERVICE_NAME").ok().as_deref()));
    // The holder this start has asked, by its pid (`None`: a pid the lock file did not name).
    let mut asked: Option<Option<u32>> = None;
    // When this start began waiting: a holder of its own build whose hub started since is a
    // successor of the same update (`daemon/take_over_yield.rs`). A unit's daemon never yields:
    // it must own the home, or the unit is left failed while a detached daemon serves it.
    let yields_since = (!unit).then(crate::store::now_ms);
    let stands_by = !unit && launchd_standby::this_start_stands_by(take_over);
    loop {
        match acquire_lock(path) {
            Ok(lock) => return Ok(lock),
            Err(error) if stands_by && error.downcast_ref::<LockHeld>().is_some() => {
                // launchd restarts its job whatever the exit status: a refusal here was a
                // respawn loop on a home the app's daemon serves. Stand by until it is free.
                tracing::info!("{error} launchd started this daemon: standing by until it ends");
                while lock_has_live_holder(path) {
                    tokio::time::sleep(launchd_standby::STANDBY_LOOK).await;
                }
                tokio::time::sleep(launchd_standby::STANDBY_GRACE).await;
            }
            Err(error) if waits && error.downcast_ref::<LockHeld>().is_some() => {
                #[cfg(unix)]
                let ours =
                    lock::holder_socket(path).is_some_and(|held| same_path(&held, &socket_path()));
                #[cfg(not(unix))]
                let ours = false;
                if take_over && !ours {
                    return Err(error);
                }
                if !ours || !supervised {
                    // The kernel lock is the liveness signal: a live holder keeps it and a
                    // dead holder releases it. Do not turn a busy but healthy daemon into a
                    // startup failure with an arbitrary wall-clock cutoff. launchd's start
                    // never asks the holder (the app's daemon keeps serving): it waits.
                    wait_for_lock_release(path.to_owned()).await;
                    continue;
                }
                #[cfg(unix)]
                let holder = live_holder_pid(path);
                #[cfg(not(unix))]
                let holder = None;
                if asked != Some(holder)
                    && let Some(answered) = take_over_holder(&socket_path(), yields_since).await?
                    // What answered is the holder (or the lock named none): asked. Another
                    // daemon answering for a holder still starting is not; ask again.
                    && (holder.is_none() || answered == holder)
                {
                    asked = Some(holder);
                }
                // Still no wall-clock cutoff: the wait only looks again at who holds the lock.
                wait_for_lock_release_with_budget(path.to_owned(), Some(HOLDER_LOOK)).await;
            }
            Err(error) => return Err(error),
        }
    }
}

/// How often a supervised start waiting on this home's lock looks at who holds it, to ask a new
/// holder to hand over ([`acquire_daemon_lock`]).
// timeout: not a deadline; the wait goes on, and each look costs one read of the lock file.
const HOLDER_LOOK: Duration = Duration::from_secs(1);

/// Ask the daemon at `socket` to hand this home over: `_acpmux/shutdown` with its agents kept,
/// as `acpmux daemon shutdown` sends it, once its status names this home and socket. Best
/// effort: a holder that does not answer, or one that is already stopping, is waited out by the
/// caller. The pid that answered its status, or `None` when nothing answered (a holder still
/// starting has no socket yet): the caller asks again. With `yields_since` (when a start that may
/// yield began waiting), a holder of this home that runs this build and started since is not asked:
/// the error [`take_over_yield::ServedByThisBuild`] says so.
async fn take_over_holder(
    socket: &std::path::Path,
    yields_since: Option<u64>,
) -> Result<Option<Option<u32>>> {
    // Client::connect and request finish promptly on a closed socket. If the
    // peer is alive but busy, keep the handover request alive until it answers.
    let Ok(client) = crate::client::Client::connect(socket).await else { return Ok(None) };
    let Ok(status) = client.request(crate::rpc::method::MUX_STATUS, serde_json::json!({})).await
    else {
        return Ok(None);
    };
    let same = |key: &str, want: &std::path::Path| {
        status
            .get(key)
            .and_then(serde_json::Value::as_str)
            .is_some_and(|got| same_path(std::path::Path::new(got), want))
    };
    let pid = status.get("pid").and_then(serde_json::Value::as_u64).map(|p| p as u32);
    if !same("home", &home()) || !same("socket", socket) {
        return Ok(Some(pid));
    }
    if yields_since.is_some_and(|since| {
        take_over_yield::serves_this_start(&status, crate::hub::build(), since)
    }) {
        return Err(take_over_yield::ServedByThisBuild {
            ready: take_over_yield::ready_line(&status),
        }
        .into());
    }
    tracing::info!(pid, "another daemon of this home serves its socket; asking it to hand over");
    #[cfg(unix)]
    if let Some(pid) = pid {
        listener_handover::note_took_over_from(pid);
    }
    // Its listeners too, by descriptor, so the listen queue never closes
    // (`daemon/listener_handover.rs`). A daemon from before this ignores the key and stops.
    #[cfg(unix)]
    let side = listener_handover::Side::open(&home());
    #[cfg_attr(not(unix), allow(unused_mut))]
    let mut params = serde_json::json!({"reason": "handover: another daemon of this home starts"});
    #[cfg(unix)]
    if let (Some(side), Some(map)) = (&side, params.as_object_mut()) {
        map.insert(listener_handover::PARAM.to_owned(), serde_json::json!(side.path()));
        map.insert(listener_handover::PARAM_CONNS.to_owned(), serde_json::json!(true));
    }
    let answer = client.request(crate::rpc::method::MUX_SHUTDOWN, params).await;
    #[cfg(unix)]
    if let (Some(side), Ok(answer)) = (side, &answer) {
        let kinds: Vec<String> = answer
            .get(listener_handover::ANSWER)
            .and_then(serde_json::Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|k| k.as_str().map(str::to_owned))
            .collect();
        let _ = tokio::task::spawn_blocking(move || side.receive(&kinds, pid)).await;
    }
    #[cfg(not(unix))]
    let _ = answer;
    Ok(Some(pid))
}

#[cfg(test)]
mod launchd_job_tests {
    /// Only this user's `com.acpmux.daemon` job waits for the lock, and only on macOS.
    #[test]
    fn only_the_acpmux_launch_agent_waits_for_the_home() {
        assert_eq!(super::launchd_job(Some("com.acpmux.daemon")), cfg!(target_os = "macos"));
        assert!(!super::launchd_job(Some("com.cmuxterm.app.nightly.keepalive")));
        assert!(!super::launchd_job(Some("application.com.cmuxterm.app.nightly.1.2")));
        assert!(!super::launchd_job(None));
    }

    /// The per-home job a command starts waits too, so a `KeepAlive` copy of it never loops on
    /// exit 75 while a take-over start serves the home (cmuxterm-hq #22842).
    #[test]
    fn the_per_home_job_waits_for_the_home() {
        let mac = cfg!(target_os = "macos");
        assert_eq!(super::launchd_job(Some("com.cmux.acpmux.daemon.077f602dcb3c3936")), mac);
        assert!(!super::launchd_job(Some("com.cmux.acpmux.daemon.")));
        assert!(!super::launchd_job(Some("com.cmux.acpmux.daemonx")));
    }
}
