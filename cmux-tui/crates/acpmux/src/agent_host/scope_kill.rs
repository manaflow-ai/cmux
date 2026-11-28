//! A host's last act: end everything still in its own scope (RFD 0177 piece 7).
//!
//! A host ends what its harness started in two passes: the group signal, then
//! the tree it last saw (`tree.rs`, `kill_still_running`). A process that
//! double-forked or used `setsid` after the last look has the system as its parent,
//! so neither pass finds it, and it outlives the session: 9 such trees on
//! fs-agent-lane-11. Everything the host started stays in its own scope
//! (`scope.rs`, `acpmux-agent-host-<pid>-<tag>.scope`) wherever it was reparented,
//! so writing `1` to that cgroup's `cgroup.kill` ends all of it at once, the host
//! included. That is why the write comes last, after the host has removed its
//! records.
//!
//! The kill applies only to a scope named for this host's own pid. A host that
//! was never moved (no user manager, `ACPMUX_HOST_SCOPES=0`, a failed move)
//! shares a cgroup with the daemon, so nothing is written. The kill is off
//! unless `ACPMUX_HOST_CGROUP_KILL=1`.

/// The opt-in switch.
pub(crate) const ENV: &str = "ACPMUX_HOST_CGROUP_KILL";

/// The cgroup directory under `/sys/fs/cgroup` of the scope named for `pid`,
/// read from `cgroup` (the text of `/proc/self/cgroup`). Returns None when the
/// leaf is any other unit: the daemon's own, or another host's scope.
pub(crate) fn own_scope_dir(cgroup: &str, pid: u32) -> Option<String> {
    let path = super::scope::unified(cgroup)?;
    let leaf = path.rsplit('/').next()?;
    let rest = leaf.strip_prefix("acpmux-agent-host-")?.strip_suffix(".scope")?;
    let (leaf_pid, tag) = rest.split_once('-')?;
    (leaf_pid == pid.to_string() && !tag.is_empty()).then(|| format!("/sys/fs/cgroup{path}"))
}

/// Whether the switch is on in `value`, the variable's value.
pub(crate) fn switched_on(value: Option<&str>) -> bool {
    value == Some("1")
}

/// End every process still in this host's own scope, this host included.
/// Does nothing when the switch is off or the host is not in its own scope.
/// When the write fails (a kernel before 5.14 has no `cgroup.kill`), it logs
/// and returns, so the host exits as it would without the kill.
#[cfg(target_os = "linux")]
pub(crate) fn end_own_scope() {
    if !switched_on(std::env::var(ENV).ok().as_deref()) {
        return;
    }
    let Ok(cgroup) = std::fs::read_to_string("/proc/self/cgroup") else { return };
    let Some(dir) = own_scope_dir(&cgroup, std::process::id()) else { return };
    if let Err(e) = std::fs::write(format!("{dir}/cgroup.kill"), "1") {
        tracing::warn!("could not end the agent host scope {dir}: {e}");
    }
}

/// Scopes are a Linux user manager's.
#[cfg(not(target_os = "linux"))]
pub(crate) fn end_own_scope() {}

#[cfg(test)]
mod tests {
    use super::*;

    const SLICE: &str = "/user.slice/user-1001.slice/user@1001.service/acpmuxsessions.slice/\
                         acpmuxsessions-01a2.slice";

    #[test]
    fn only_the_scope_named_for_this_host_is_ended() {
        let own = format!("0::{SLICE}/acpmux-agent-host-4242-f91d17ad.scope\n");
        assert_eq!(
            own_scope_dir(&own, 4242).as_deref(),
            Some(format!("/sys/fs/cgroup{SLICE}/acpmux-agent-host-4242-f91d17ad.scope").as_str())
        );
        // Another host's scope, a pid that only shares a prefix, the daemon's unit.
        assert_eq!(own_scope_dir(&own, 424), None);
        assert_eq!(own_scope_dir(&own, 42421), None);
        let daemon = "0::/user.slice/user-1001.slice/user@1001.service/app.slice/acpmux.service\n";
        assert_eq!(own_scope_dir(daemon, 4242), None);
        let untagged = format!("0::{SLICE}/acpmux-agent-host-4242-.scope\n");
        assert_eq!(own_scope_dir(&untagged, 4242), None);
        assert_eq!(own_scope_dir("", 4242), None);
    }

    #[test]
    fn the_kill_is_off_unless_switched_on() {
        assert!(!switched_on(None));
        assert!(!switched_on(Some("0")));
        assert!(!switched_on(Some("")));
        assert!(switched_on(Some("1")));
    }
}
