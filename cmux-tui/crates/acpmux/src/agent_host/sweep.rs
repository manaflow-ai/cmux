//! The agent hosts an acpmux home still runs after its daemon stopped, and
//! how `acpmux daemon shutdown` ends them: the backstop for a host that the
//! daemon's own shutdown missed or could not reach.
//!
//! Ownership is the host record and its liveness lock, never a process name:
//! a host belongs to this home when a record in its hosts directory (or the
//! pool below it) names it, and a signal goes to its pid only while the lock
//! that record names is held, which proves that pid is still that host.

use super::*;
use crate::clock::Clock;
use std::time::Duration;

/// A host that a record of this home names, with the lock that proves it
/// alive.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct OwnedHost {
    pub dir: PathBuf,
    pub session_id: String,
    pub start_nonce: String,
    pub host_pid: u32,
    /// The harness process group the host leads (its pgid).
    pub harness_pid: Option<u32>,
    /// The host of a pooled (hidden) session.
    pub pooled: bool,
}

impl OwnedHost {
    fn liveness(&self) -> Liveness {
        liveness(&self.dir, &self.session_id, &self.start_nonce)
    }
}

/// Every host that a record in `hosts` or its pool directory names and that
/// is not proven dead (a held lock, or one that cannot be probed).
pub fn running_hosts(hosts: &Path) -> Vec<OwnedHost> {
    let mut out = Vec::new();
    for (dir, pooled) in [(hosts.to_owned(), false), (pool_dir(hosts), true)] {
        let Ok((good, bad)) = load_records(&dir) else { continue };
        let named = good
            .into_iter()
            .map(|(_, r)| (r.session_id, Some(r.start_nonce), Some(r.host_pid), r.harness_pid))
            .chain(
                bad.into_iter().map(|b| (b.session_id, b.start_nonce, b.host_pid, b.harness_pid)),
            );
        for (session_id, nonce, host_pid, harness_pid) in named {
            // Without a nonce and a pid nothing proves which process it is.
            let (Some(start_nonce), Some(host_pid)) = (nonce, host_pid) else { continue };
            let host = OwnedHost {
                dir: dir.clone(),
                session_id,
                start_nonce,
                host_pid,
                harness_pid,
                pooled,
            };
            if host.liveness() != Liveness::Dead {
                out.push(host);
            }
        }
    }
    out
}

/// End `hosts`: SIGTERM each host whose lock is held (a host ends its
/// harness group on SIGTERM), wait up to `grace` on `clock`, then SIGKILL
/// the harness group and the host of each one whose lock is still held, and
/// wait up to `grace` again. Returns the hosts not proven dead after that.
///
/// A harness process that moved itself into a new session (setsid) is out of
/// reach of the group signal and outlives its host. So every process under a
/// live host is noted before the first signal, and the ones still running
/// (the same pid with the same start time) are killed at the end.
#[cfg(unix)]
pub async fn end_hosts(
    clock: &dyn Clock,
    hosts: Vec<OwnedHost>,
    grace: Duration,
) -> Vec<OwnedHost> {
    let mut under = under_live(&hosts);
    for h in &hosts {
        signal_if_live(h, libc::SIGTERM);
    }
    let left = wait_all(clock, hosts, grace).await;
    for p in under_live(&left) {
        if !under.contains(&p) {
            under.push(p);
        }
    }
    for h in &left {
        signal_if_live(h, libc::SIGKILL);
    }
    let left = wait_all(clock, left, grace).await;
    super::tree::kill_still_running(&under);
    left
}
/// Windows port: hosts are signalled through their job objects there (a
/// later landing); until then they are only waited for.
#[cfg(not(unix))]
pub async fn end_hosts(
    clock: &dyn Clock,
    hosts: Vec<OwnedHost>,
    grace: Duration,
) -> Vec<OwnedHost> {
    wait_all(clock, hosts, grace).await
}

/// Signal the host (and, for SIGKILL, first its harness group, which a
/// killed host can no longer end) only while its lock proves the pid.
#[cfg(unix)]
fn signal_if_live(h: &OwnedHost, signal: i32) {
    if h.liveness() != Liveness::Live {
        return;
    }
    let Ok(pid) = i32::try_from(h.host_pid) else { return };
    if signal == libc::SIGKILL
        && let Some(pg) = h.harness_pid.and_then(|p| i32::try_from(p).ok())
    {
        // SAFETY: the held lock proves the host that leads this group runs.
        unsafe { libc::killpg(pg, libc::SIGKILL) };
    }
    // SAFETY: the held lock proves `pid` is this record's live host.
    unsafe { libc::kill(pid, signal) };
}

/// The processes under each host whose lock is held: the held lock proves
/// the host pid, so its descendants by parent are its own.
#[cfg(unix)]
fn under_live(hosts: &[OwnedHost]) -> Vec<super::tree::Started> {
    let roots: Vec<u32> =
        hosts.iter().filter(|h| h.liveness() == Liveness::Live).map(|h| h.host_pid).collect();
    if roots.is_empty() {
        return Vec::new();
    }
    super::tree::descendants(&roots)
}

/// Wait until every host is dead or `grace` passed on `clock`; the hosts
/// not proven dead.
async fn wait_all(clock: &dyn Clock, hosts: Vec<OwnedHost>, grace: Duration) -> Vec<OwnedHost> {
    if hosts.is_empty() {
        return hosts;
    }
    let deaths = futures::future::join_all(
        hosts.iter().map(|h| super::dead(&h.dir, &h.session_id, &h.start_nonce)),
    );
    let _ = super::within_on(clock, "exit", grace, deaths).await;
    hosts.into_iter().filter(|h| h.liveness() != Liveness::Dead).collect()
}

#[cfg(test)]
mod tests;
