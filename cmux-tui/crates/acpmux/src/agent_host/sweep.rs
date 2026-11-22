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
pub async fn end_hosts(
    clock: &dyn Clock,
    hosts: Vec<OwnedHost>,
    grace: Duration,
) -> Vec<OwnedHost> {
    for h in &hosts {
        signal_if_live(h, libc::SIGTERM);
    }
    let left = wait_all(clock, hosts, grace).await;
    for h in &left {
        signal_if_live(h, libc::SIGKILL);
    }
    wait_all(clock, left, grace).await
}

/// Signal the host (and, for SIGKILL, first its harness group, which a
/// killed host can no longer end) only while its lock proves the pid.
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
mod tests {
    use super::*;
    use crate::clock::ManualClock;
    use std::io::{BufRead, BufReader};
    use std::process::{Child, Command, Stdio};

    const GRACE: Duration = Duration::from_secs(3);

    /// A process that holds `lock` as a host holds its liveness lock;
    /// `ignore_term` makes it a host that does not end on SIGTERM.
    fn fake_host(lock: &Path, ignore_term: bool) -> Child {
        let script = format!(
            "import fcntl, signal, sys, time\n{}f = open(sys.argv[1], 'a+')\nfcntl.flock(f, fcntl.LOCK_EX)\nprint('locked', flush=True)\ntime.sleep(600)\n",
            if ignore_term { "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n" } else { "" }
        );
        let mut child = Command::new("python3")
            .args(["-c", &script])
            .arg(lock)
            .stdout(Stdio::piped())
            .spawn()
            .expect("python3");
        let mut line = String::new();
        BufReader::new(child.stdout.take().unwrap()).read_line(&mut line).unwrap();
        assert_eq!(line.trim(), "locked");
        child
    }

    fn owned(dir: &Path, session: &str, child: &Child) -> OwnedHost {
        OwnedHost {
            dir: dir.to_owned(),
            session_id: session.into(),
            start_nonce: "00ff".into(),
            host_pid: child.id(),
            harness_pid: None,
            pooled: false,
        }
    }

    fn temp_dir(tag: &str) -> PathBuf {
        let dir = std::env::temp_dir().join(format!("acpmux-sweep-{tag}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[tokio::test]
    async fn a_host_that_ends_on_sigterm_is_not_waited_for() {
        let dir = temp_dir("term");
        let mut child = fake_host(&live_path(&dir, "s1", "00ff"), false);
        let host = owned(&dir, "s1", &child);
        // The clock never moves: only the host's exit can end the wait.
        let left = tokio::time::timeout(
            Duration::from_secs(20),
            end_hosts(&*ManualClock::new(), vec![host], GRACE),
        )
        .await
        .expect("the wait outlived the host");
        assert!(left.is_empty(), "{left:?}");
        child.wait().unwrap();
    }

    #[tokio::test]
    async fn a_host_that_ignores_sigterm_is_killed_after_the_grace_on_the_clock() {
        let dir = temp_dir("kill");
        let mut child = fake_host(&live_path(&dir, "s1", "00ff"), true);
        let host = owned(&dir, "s1", &child);
        let clock = ManualClock::new();
        let mut ending = std::pin::pin!(end_hosts(&*clock, vec![host], GRACE));
        // Polled once: SIGTERM is sent and the deadline is set.
        assert!(futures::poll!(&mut ending).is_pending());
        assert!(child.try_wait().unwrap().is_none(), "the host ended on SIGTERM");
        clock.advance(GRACE);
        let left = tokio::time::timeout(Duration::from_secs(20), ending)
            .await
            .expect("SIGKILL did not follow the grace on the injected clock");
        assert!(left.is_empty(), "{left:?}");
        assert!(child.wait().unwrap().code().is_none(), "the host was not killed");
    }

    #[tokio::test]
    async fn a_pid_without_its_held_lock_is_never_signalled() {
        let dir = temp_dir("own");
        // A live process the record names, but its lock is not held: the
        // pid may now be any process, so it is not this home's host.
        let mut other = Command::new("sleep").arg("600").spawn().unwrap();
        std::fs::write(live_path(&dir, "s1", "00ff"), "").unwrap();
        let host = owned(&dir, "s1", &other);
        assert!(running_hosts(&dir).is_empty());
        let left = end_hosts(&*ManualClock::new(), vec![host], GRACE).await;
        assert!(left.is_empty(), "{left:?}");
        assert!(other.try_wait().unwrap().is_none(), "an unowned process was signalled");
        other.kill().unwrap();
        other.wait().unwrap();
    }
}
