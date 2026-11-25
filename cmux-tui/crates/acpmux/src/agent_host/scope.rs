//! Agent hosts in their own systemd scopes (cmuxterm-hq#3763).
//!
//! A daemon that runs as a user systemd service kept every agent host in its
//! own unit's cgroup (`setsid` does not change the cgroup). Under a unit with
//! the default `KillMode=control-group` (a hand-written unit, a `systemd-run`
//! one) a daemon restart then sent SIGTERM to every agent host, and a
//! `MemoryHigh` on the unit throttled the daemon for its agents' memory: on
//! huge-blue it stopped answering for 37 minutes. So the daemon moves each
//! host it starts into its own transient scope
//! `acpmux-agent-host-<pid>-<tag>.scope` in [`HOST_SLICE`] of the same user
//! manager ([`place`]), within the start budget and before the host gets its
//! spawn spec, so before it starts its harness. A stop or restart of the
//! daemon's unit then leaves the host and its harness for the next daemon to
//! adopt, whatever the unit's `KillMode`: the same as under
//! `KillMode=process`, which `acpmux.service` has (`cli/hosts.rs`). Logout
//! without linger and machine shutdown still stop the scope with SIGTERM,
//! which a host honors.
//!
//! Pooled hosts move too. They never depended on the unit to end with their
//! daemon: an untaken pooled host ends when its controller goes
//! (`host.rs`, `still_pooled`), and the next daemon ends any left in the
//! pool directory before it adopts hosts (`sweep_pool_hosts`).
//!
//! Only a daemon in a user manager's service unit moves hosts: one in a
//! terminal, a login session scope or under launchd leaves them where they
//! are. `ACPMUX_HOST_SCOPES=0` turns it off. Best effort: a failed move is
//! logged and leaves the host in the daemon's unit, as before, and no move is
//! tried for [`RETRY_AFTER`], so a broken bus does not slow every spawn.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use std::ffi::OsString;
use std::time::Duration;

/// The slice every host scope joins. Dash-free: systemd reads dashes in a
/// slice name as nesting.
pub(crate) const HOST_SLICE: &str = "acpmuxhosts.slice";

/// Where `busctl` is taken from: system directories only, never the
/// daemon's PATH (`acpmux.service` puts `~/.local/bin` first).
pub(crate) const BUSCTL: &[&str] = &["/usr/bin/busctl", "/bin/busctl"];

/// How long no move is tried after one failed.
pub(crate) const RETRY_AFTER: Duration = Duration::from_secs(60);

/// The scope unit name of the host with `pid`. `tag` is random per move: a
/// stale scope of an earlier process with the same pid (a harness that
/// outlived its host keeps it active) never makes the move fail.
pub(crate) fn scope_unit(pid: u32, tag: &str) -> String {
    format!("acpmux-agent-host-{pid}-{tag}.scope")
}

/// Whether `cgroup`, the text of a process's `/proc/<pid>/cgroup`, places it
/// in a service unit of a user manager (`…/user@1000.service/…/x.service`).
pub(crate) fn in_user_service(cgroup: &str) -> bool {
    unified(cgroup).is_some_and(|path| {
        let mut parts = path.split('/').filter(|p| !p.is_empty());
        // The manager's own unit, then a service unit below it as the leaf.
        parts.any(|p| p.starts_with("user@") && p.ends_with(".service"))
            && parts.next_back().is_some_and(|leaf| leaf.ends_with(".service"))
    })
}

/// The cgroup v2 path in `/proc/<pid>/cgroup` text.
pub(crate) fn unified(cgroup: &str) -> Option<&str> {
    cgroup.lines().find_map(|line| line.strip_prefix("0::")).map(str::trim_end)
}

/// Whether `cgroup` text places a process in the host scope `unit`.
pub(crate) fn names_scope(cgroup: &str, unit: &str) -> bool {
    names_scope_in(cgroup, HOST_SLICE, unit)
}

/// Whether `cgroup` text places a process in the scope `unit` of `slice` (a session's slice
/// `acpmuxsessions-<id>.slice` sits under `acpmuxsessions.slice`, so only its last part is named).
pub(crate) fn names_scope_in(cgroup: &str, slice: &str, unit: &str) -> bool {
    unified(cgroup).is_some_and(|path| path.ends_with(&format!("/{slice}/{unit}")))
}

/// The `busctl` arguments that create the scope `unit` holding `pid`, with the scope `limits`
/// (`session_budget::Budget::bus_properties`: `(name, signature, value)`). Before
/// `session_budget.rs` a host or task scope got `TasksMax` alone, so a background `cargo build`
/// ran with no memory ceiling and full CPU weight. The values are the daemon's (its config, else
/// its environment), not a profile's: a host is placed before its session's profile environment
/// reaches it, so a profile override applies to the session scope only. A host's scope holds its
/// session's harness too when that harness got no scope of its own (no `systemd-run`, a remote
/// profile), so a runaway stops there as it would in a session scope.
pub(crate) fn busctl_args(unit: &str, pid: u32, limits: &[[String; 3]]) -> Vec<String> {
    busctl_args_in(unit, pid, HOST_SLICE, limits)
}

/// [`busctl_args`] into `slice`: a background task's scope joins its session's slice
/// (`session_total.rs`), so the session's harness and tasks share one total.
pub(crate) fn busctl_args_in(
    unit: &str,
    pid: u32,
    slice: &str,
    limits: &[[String; 3]],
) -> Vec<String> {
    let mut args: Vec<String> = [
        "--user",
        "--quiet",
        "call",
        "org.freedesktop.systemd1",
        "/org/freedesktop/systemd1",
        "org.freedesktop.systemd1.Manager",
        "StartTransientUnit",
        "ssa(sv)a(sa(sv))",
    ]
    .into_iter()
    .map(str::to_owned)
    .collect();
    args.extend([unit.to_owned(), "fail".into(), (3 + limits.len()).to_string()]);
    args.extend(["PIDs".into(), "au".into(), "1".into(), pid.to_string()]);
    args.extend(["Slice".into(), "s".into(), slice.into()]);
    args.extend(["CollectMode".into(), "s".into(), "inactive-or-failed".into()]);
    for property in limits {
        args.extend(property.iter().cloned());
    }
    args.push("0".into());
    args
}

/// `busctl_args`'s limits with only `TasksMax` (`u64::MAX`: no cap): the fallback when a user
/// manager refuses the budget's properties (an older systemd without `OOMPolicy`).
pub(crate) fn tasks_only(tasks_max: u64) -> Vec<[String; 3]> {
    vec![["TasksMax".into(), "t".into(), tasks_max.to_string()]]
}

/// The whole environment `busctl` gets: the user bus's address and nothing
/// else of the daemon's. Without `XDG_RUNTIME_DIR`, the user's runtime
/// directory is `/run/user/<uid>`.
pub(crate) fn busctl_env(
    runtime_dir: Option<OsString>,
    bus: Option<OsString>,
    uid: u32,
) -> Vec<(&'static str, OsString)> {
    let mut env =
        vec![("XDG_RUNTIME_DIR", runtime_dir.unwrap_or_else(|| format!("/run/user/{uid}").into()))];
    if let Some(bus) = bus {
        env.push(("DBUS_SESSION_BUS_ADDRESS", bus));
    }
    env.push(("PATH", "/usr/bin:/bin".into()));
    env
}

/// Moves are off for [`RETRY_AFTER`] after the failure at `failed`.
pub(crate) fn backing_off(failed: Option<std::time::Instant>, now: std::time::Instant) -> bool {
    failed.is_some_and(|at| now.saturating_duration_since(at) < RETRY_AFTER)
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use crate::no_panic::LockExt;
    use std::process::Stdio;
    use std::sync::{Mutex, OnceLock};
    use std::time::Instant;

    const ENV: &str = "ACPMUX_HOST_SCOPES";
    /// How long the `busctl` call, and then the move showing in the host's
    /// cgroup, may each take. Placement is best effort: expiry logs and the
    /// host spawn continues, so this never turns a live wake into failure.
    // timeout: a stuck user-manager request must not hold the spawn task while
    // the placement operation is optional.
    const PLACEMENT_WAIT: Duration = Duration::from_secs(2);
    static FAILED_AT: Mutex<Option<Instant>> = Mutex::new(None);

    /// This daemon's own cgroup, when it runs in a user manager's service
    /// unit and moves are on.
    fn daemon_cgroup() -> Option<&'static str> {
        static CGROUP: OnceLock<Option<String>> = OnceLock::new();
        CGROUP
            .get_or_init(|| {
                if std::env::var(ENV).is_ok_and(|v| v == "0") {
                    return None;
                }
                let own = std::fs::read_to_string("/proc/self/cgroup").ok()?;
                in_user_service(&own).then(|| unified(&own).map(str::to_owned)).flatten()
            })
            .as_deref()
    }

    pub(super) fn moves() -> bool {
        daemon_cgroup().is_some()
    }

    fn enabled() -> bool {
        daemon_cgroup().is_some() && !backing_off(*FAILED_AT.lock_or_recover(), Instant::now())
    }

    fn tag() -> Result<String, String> {
        let mut bytes = [0u8; 4];
        getrandom::fill(&mut bytes).map_err(|e| format!("the OS random generator: {e}"))?;
        Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
    }

    /// Move the host `pid` this process just started, and has not reaped
    /// (its pid cannot be reused), into its own scope. Never fails the spawn.
    pub(crate) async fn place(pid: u32) {
        place_in(pid, None).await;
    }

    /// [`place`] into `slice` (a session's, `session_total.rs`); None: [`HOST_SLICE`].
    pub(crate) async fn place_in(pid: u32, slice: Option<String>) {
        if enabled() {
            let slice = slice.as_deref().unwrap_or(HOST_SLICE);
            let placed = match tag() {
                Ok(tag) => try_place(&scope_unit(pid, &tag), pid, slice).await,
                Err(e) => Err(e),
            };
            report(pid, placed);
        }
    }

    fn report(pid: u32, result: Result<(), String>) {
        let Err(failure) = result else { return };
        *FAILED_AT.lock_or_recover() = Some(Instant::now());
        tracing::warn!(
            "could not move agent host {pid} into its own scope: {failure}; it stays in the \
             daemon's unit, where a stop of that unit ends it unless the unit has \
             KillMode=process; no host moves for {RETRY_AFTER:?}"
        );
    }

    async fn try_place(unit: &str, host: u32, slice: &str) -> Result<(), String> {
        let busctl = BUSCTL
            .iter()
            .find(|p| std::path::Path::new(p).is_file())
            .ok_or_else(|| format!("no busctl in {BUSCTL:?}"))?;
        // SAFETY: getuid has no preconditions.
        let uid = unsafe { libc::getuid() };
        let env = busctl_env(
            std::env::var_os("XDG_RUNTIME_DIR"),
            std::env::var_os("DBUS_SESSION_BUS_ADDRESS"),
            uid,
        );
        let call = |limits: Vec<[String; 3]>| {
            tokio::process::Command::new(busctl)
                .args(busctl_args_in(unit, host, slice, &limits))
                .env_clear()
                .envs(env.clone())
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::piped())
                .kill_on_drop(true)
                .output()
        };
        let budget = crate::session_budget::task_budget().0.bus_properties();
        let output = tokio::time::timeout(PLACEMENT_WAIT, call(budget))
            .await
            .map_err(|_| format!("busctl did not answer within {PLACEMENT_WAIT:?}"))?
            .map_err(|e| format!("busctl: {e}"))?;
        // A user manager that refuses a budget property still gets the task cap it took before.
        let output = if output.status.success() {
            output
        } else {
            let tasks = tasks_only(crate::session_scope::host_tasks_max().unwrap_or(u64::MAX));
            tracing::warn!(
                "the budget's scope properties were refused ({}); placing agent host {host} \
                 with its task cap only",
                String::from_utf8_lossy(&output.stderr).trim()
            );
            tokio::time::timeout(PLACEMENT_WAIT, call(tasks))
                .await
                .map_err(|_| format!("busctl did not answer within {PLACEMENT_WAIT:?}"))?
                .map_err(|e| format!("busctl: {e}"))?
        };
        if !output.status.success() {
            return Err(format!(
                "busctl {}: {}",
                output.status,
                String::from_utf8_lossy(&output.stderr).trim()
            ));
        }
        // StartTransientUnit only queues the job; the host must not start its
        // harness before the move is done, or the harness stays in the unit.
        let deadline = Instant::now() + PLACEMENT_WAIT;
        loop {
            let cgroup =
                tokio::fs::read_to_string(format!("/proc/{host}/cgroup")).await.unwrap_or_default();
            if names_scope_in(&cgroup, slice, unit) {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(format!("{unit} did not take the host within {PLACEMENT_WAIT:?}"));
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

#[cfg(target_os = "linux")]
pub(crate) use linux::{place, place_in};

/// Hosts move into scopes only under a Linux user manager.
#[cfg(not(target_os = "linux"))]
pub(crate) async fn place(_pid: u32) {}

/// Hosts move into scopes only under a Linux user manager.
#[cfg(not(target_os = "linux"))]
pub(crate) async fn place_in(_pid: u32, _slice: Option<String>) {}

/// Whether hosts and tasks move into scopes here (a user manager's service unit, moves on).
#[cfg(target_os = "linux")]
pub(crate) fn moves() -> bool {
    linux::moves()
}

/// Hosts move into scopes only under a Linux user manager.
#[cfg(not(target_os = "linux"))]
pub(crate) fn moves() -> bool {
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    #[test]
    fn only_a_user_managers_service_unit_moves_hosts() {
        let hand_written = "0::/user.slice/user-1001.slice/user@1001.service/acpmux.slice/\
                            acpmux-agent.slice/acpmux-agent-huge.slice/\
                            acpmux-agent-huge-blue.slice/acpmux-agent-huge-blue.service\n";
        assert!(in_user_service(hand_written));
        assert!(in_user_service(
            "0::/user.slice/user-1000.slice/user@1000.service/app.slice/acpmux.service\n"
        ));
        // A terminal, an ssh login, the manager itself, a system service, cgroup v1.
        for other in [
            "0::/user.slice/user-1000.slice/user@1000.service/app.slice/vte-spawn-1.scope\n",
            "0::/user.slice/user-1000.slice/session-4.scope\n",
            "0::/user.slice/user-1000.slice/user@1000.service\n",
            "0::/user.slice/user-1000.slice/user@1000.service/init.scope\n",
            "0::/system.slice/acpmux.service\n",
            "1:name=systemd:/user.slice/user-1000.slice/user@1000.service/acpmux.service\n",
            "",
        ] {
            assert!(!in_user_service(other), "{other}");
        }
    }

    #[test]
    fn a_host_counts_as_placed_only_when_its_cgroup_names_its_own_scope() {
        let unit = scope_unit(4242, "0a1b2c3d");
        assert_eq!(unit, "acpmux-agent-host-4242-0a1b2c3d.scope");
        let placed =
            format!("0::/user.slice/user-1000.slice/user@1000.service/{HOST_SLICE}/{unit}\n");
        assert!(names_scope(&placed, &unit));
        // A stale scope of an earlier process with the same pid is not this move's.
        assert!(!names_scope(&placed, &scope_unit(4242, "ffffffff")));
        assert!(!names_scope(
            "0::/user.slice/user-1000.slice/user@1000.service/app.slice/acpmux.service\n",
            &unit
        ));
        assert!(!HOST_SLICE.trim_end_matches(".slice").contains('-'), "a dash nests slices");
    }

    #[test]
    fn the_scope_request_names_the_host_pid_and_the_host_slice_on_the_user_bus() {
        let unit = scope_unit(4242, "0a1b2c3d");
        let joined = busctl_args(&unit, 4242, &tasks_only(4096)).join(" ");
        assert!(joined.starts_with("--user --quiet call org.freedesktop.systemd1 "), "{joined}");
        assert!(
            joined.contains(
                "StartTransientUnit ssa(sv)a(sa(sv)) acpmux-agent-host-4242-0a1b2c3d.scope fail 4"
            ),
            "{joined}"
        );
        assert!(joined.contains("PIDs au 1 4242 Slice"), "{joined}");
        assert!(joined.contains("Slice s acpmuxhosts.slice"), "{joined}");
        assert!(joined.ends_with("CollectMode s inactive-or-failed TasksMax t 4096 0"), "{joined}");
        // No cap: `infinity` (uint64 max), never systemd's DefaultTasksMax.
        let joined = busctl_args(&unit, 4242, &tasks_only(u64::MAX)).join(" ");
        assert!(joined.ends_with("TasksMax t 18446744073709551615 0"), "{joined}");
        // The budget: memory, CPU and IO limits, the property count follows them.
        let budget = crate::session_budget::Budget {
            memory_max: 1 << 30,
            memory_high: 900 << 20,
            tasks_max: Some(4096),
            cpu_weight: 50,
            cpu_quota: 1200,
            io_weight: 50,
            ..Default::default()
        };
        let joined = busctl_args(&unit, 4242, &budget.bus_properties()).join(" ");
        assert!(joined.contains("acpmux-agent-host-4242-0a1b2c3d.scope fail 10 PIDs"), "{joined}");
        assert!(
            joined.ends_with(
                "CollectMode s inactive-or-failed MemoryMax t 1073741824 MemoryHigh t 943718400 \
                 TasksMax t 4096 CPUWeight t 50 CPUQuotaPerSecUSec t 12000000 IOWeight t 50 \
                 OOMPolicy s continue 0"
            ),
            "{joined}"
        );
    }

    #[test]
    fn busctl_comes_from_system_directories_with_only_the_bus_address() {
        assert!(BUSCTL.iter().all(|p| p.starts_with("/usr/bin/") || p.starts_with("/bin/")));
        let env = busctl_env(None, None, 1001);
        assert_eq!(
            env,
            vec![("XDG_RUNTIME_DIR", "/run/user/1001".into()), ("PATH", "/usr/bin:/bin".into())]
        );
        let env = busctl_env(Some("/run/user/7".into()), Some("unix:path=/b".into()), 7);
        let keys: Vec<_> = env.iter().map(|(k, _)| *k).collect();
        assert_eq!(keys, ["XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "PATH"]);
    }

    #[test]
    fn a_failure_pauses_moves_for_a_while_not_for_good() {
        let now = Instant::now();
        assert!(!backing_off(None, now));
        assert!(backing_off(Some(now), now + Duration::from_secs(1)));
        assert!(!backing_off(Some(now), now + RETRY_AFTER));
    }
}
