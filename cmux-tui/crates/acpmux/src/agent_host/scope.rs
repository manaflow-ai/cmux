//! Agent hosts in their own systemd scopes (cmuxterm-hq#3763).
//!
//! A daemon that runs as a user systemd service kept every agent host in its
//! own unit's cgroup (`setsid` does not change the cgroup). Under a unit with
//! the default `KillMode=control-group` (a hand-written unit, a `systemd-run`
//! one) a daemon restart then sent SIGTERM to every agent host, and a
//! `MemoryHigh` on the unit throttled the daemon for its agents' memory: on
//! huge-blue it stopped answering for 37 minutes. So before a new host gets
//! its spawn spec, and so before it starts its harness, the daemon moves it
//! into its own transient scope `acpmux-agent-host-<pid>.scope` in
//! [`HOST_SLICE`] of the same user manager. A stop or restart of the daemon's
//! unit then leaves the host and its harness for the next daemon to adopt,
//! whatever the unit's `KillMode` (`acpmux.service` also has
//! `KillMode=process`, `cli/hosts.rs`). Logout without linger and machine
//! shutdown still stop the scope with SIGTERM, which a host honors.
//!
//! Only a daemon in a user manager's service unit moves its hosts: one in a
//! terminal, a login session scope or under launchd leaves them where they
//! are. `ACPMUX_HOST_SCOPES=0` turns it off. Best effort: the first failed
//! move is logged, turns moves off until the daemon restarts (so a broken bus
//! does not slow every spawn) and leaves the host in the daemon's unit, as
//! before.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

/// The slice every host scope joins. Dash-free: systemd reads dashes in a
/// slice name as nesting.
pub(crate) const HOST_SLICE: &str = "acpmuxhosts.slice";

/// The scope unit name of the host with `pid`.
pub(crate) fn scope_unit(pid: u32) -> String {
    format!("acpmux-agent-host-{pid}.scope")
}

/// Whether `cgroup`, the text of a process's `/proc/<pid>/cgroup`, places it
/// in a service unit of a user manager (`…/user@1000.service/…/x.service`).
pub(crate) fn in_user_service(cgroup: &str) -> bool {
    cgroup.lines().filter_map(|line| line.strip_prefix("0::")).any(|path| {
        let mut parts = path.trim_end().split('/').filter(|p| !p.is_empty());
        // The manager's own unit, then a service unit below it as the leaf.
        parts.any(|p| p.starts_with("user@") && p.ends_with(".service"))
            && parts.next_back().is_some_and(|leaf| leaf.ends_with(".service"))
    })
}

/// Whether `cgroup` text places `pid` in its own host scope.
pub(crate) fn names_scope(cgroup: &str, pid: u32) -> bool {
    let scope = format!("/{HOST_SLICE}/{}", scope_unit(pid));
    cgroup.lines().any(|line| line.trim_end().ends_with(&scope))
}

/// The `busctl` arguments that create the scope for `pid`.
pub(crate) fn busctl_args(pid: u32) -> Vec<String> {
    [
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
    .chain([scope_unit(pid), "fail".into(), "3".into()])
    .chain(["PIDs".into(), "au".into(), "1".into(), pid.to_string()])
    .chain(["Slice".into(), "s".into(), HOST_SLICE.into()])
    .chain(["CollectMode".into(), "s".into(), "inactive-or-failed".into()])
    .chain(["0".into()])
    .collect()
}

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::process::Stdio;
    use std::sync::OnceLock;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::{Duration, Instant};

    const ENV: &str = "ACPMUX_HOST_SCOPES";
    /// How long the `busctl` call, and then the move showing in the host's
    /// cgroup, may each take.
    const PLACEMENT_WAIT: Duration = Duration::from_secs(2);
    static FAILED: AtomicBool = AtomicBool::new(false);

    fn enabled() -> bool {
        static ENABLED: OnceLock<bool> = OnceLock::new();
        *ENABLED.get_or_init(|| {
            std::env::var(ENV).map_or(true, |v| v != "0")
                && std::fs::read_to_string("/proc/self/cgroup")
                    .is_ok_and(|cgroup| in_user_service(&cgroup))
        }) && !FAILED.load(Ordering::Acquire)
    }

    /// Move the host `pid` this process just started, and has not reaped
    /// (its pid cannot be reused), into its own scope. The argv is fixed (no
    /// shell). Never fails the spawn.
    pub(crate) async fn place(pid: u32) {
        if !enabled() {
            return;
        }
        if let Err(failure) = try_place(pid).await
            && !FAILED.swap(true, Ordering::AcqRel)
        {
            tracing::warn!(
                "could not move agent host {pid} into {}: {failure}; agent hosts stay in the \
                 daemon's unit until it restarts, and a stop of that unit ends them unless it \
                 has KillMode=process",
                scope_unit(pid)
            );
        }
    }

    async fn try_place(pid: u32) -> Result<(), String> {
        let call = tokio::process::Command::new("busctl")
            .args(busctl_args(pid))
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .output();
        let output = tokio::time::timeout(PLACEMENT_WAIT, call)
            .await
            .map_err(|_| format!("busctl did not answer within {PLACEMENT_WAIT:?}"))?
            .map_err(|e| format!("busctl: {e}"))?;
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
                tokio::fs::read_to_string(format!("/proc/{pid}/cgroup")).await.unwrap_or_default();
            if names_scope(&cgroup, pid) {
                return Ok(());
            }
            if Instant::now() >= deadline {
                return Err(format!("the scope did not take the host within {PLACEMENT_WAIT:?}"));
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    }
}

#[cfg(target_os = "linux")]
pub(crate) use linux::place;

/// Hosts move into scopes only under a Linux user manager.
#[cfg(not(target_os = "linux"))]
pub(crate) async fn place(_pid: u32) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_user_managers_service_unit_moves_hosts() {
        let hand_written = "0::/user.slice/user-1001.slice/user@1001.service/acpmux.slice/\
                            acpmux-agent.slice/acpmux-agent-huge-blue.slice/\
                            acpmux-agent-huge-blue.service\n";
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
    fn a_host_counts_as_placed_only_when_its_cgroup_names_its_scope() {
        let placed = "0::/user.slice/user-1000.slice/user@1000.service/acpmuxhosts.slice/\
                      acpmux-agent-host-4242.scope\n";
        assert!(names_scope(placed, 4242));
        assert!(!names_scope(placed, 424));
        assert!(!names_scope(
            "0::/user.slice/user-1000.slice/user@1000.service/app.slice/acpmux.service\n",
            4242
        ));
        assert!(!HOST_SLICE.trim_end_matches(".slice").contains('-'), "a dash nests slices");
    }

    #[test]
    fn the_scope_request_names_the_host_pid_and_the_host_slice_on_the_user_bus() {
        let joined = busctl_args(4242).join(" ");
        assert!(joined.starts_with("--user --quiet call org.freedesktop.systemd1 "), "{joined}");
        assert!(
            joined.contains("StartTransientUnit ssa(sv)a(sa(sv)) acpmux-agent-host-4242.scope fail 3"),
            "{joined}"
        );
        assert!(joined.contains("PIDs au 1 4242"), "{joined}");
        assert!(joined.contains("Slice s acpmuxhosts.slice"), "{joined}");
        assert!(joined.ends_with("CollectMode s inactive-or-failed 0"), "{joined}");
    }
}
