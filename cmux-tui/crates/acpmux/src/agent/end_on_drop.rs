//! Ends an agent when the future that owns it is dropped.
//!
//! A `ChildAgent` does not end itself when its last owner lets go: its stdout reader holds
//! the agent (`agent_for_exit`) for as long as the process runs, so nothing drops the
//! `Child`, and `kill_on_drop` never fires. A caller that is cancelled before its own
//! `kill().await` therefore leaves the whole process group running. The model probe is one:
//! the hub's 60 s bound (`probe_models_with`) drops `probe_one` before it reaches its
//! kill, and two `cursor-agent … acp` probes were still running past 120 s in the Cloud
//! image bake (cmux runs 45732114266, 45762865802, step acpmux-probes-quiet).

use std::sync::Arc;

use super::ChildAgent;

/// Holds an agent and ends it (`ChildAgent::kill`) when dropped, unless `end` already did.
pub(crate) struct EndOnDrop(Option<Arc<ChildAgent>>);

impl EndOnDrop {
    pub(crate) fn new(agent: Arc<ChildAgent>) -> Self {
        Self(Some(agent))
    }

    /// Ends the agent now. If this future is dropped part way, the drop ends it again: the
    /// group could otherwise have its SIGTERM and never its SIGKILL.
    pub(crate) async fn end(mut self) {
        if let Some(agent) = &self.0 {
            agent.kill().await;
        }
        self.0 = None;
    }
}

impl Drop for EndOnDrop {
    fn drop(&mut self) {
        let Some(agent) = self.0.take() else { return };
        if let Ok(rt) = tokio::runtime::Handle::try_current() {
            rt.spawn(async move { agent.kill().await });
            return;
        }
        // No runtime to run the kill on (shutdown): the group still ends.
        #[cfg(unix)]
        if let Some(pg) = agent.pid {
            // SAFETY: the agent's own group id, saved at spawn; a signal, no memory touched.
            unsafe { libc::killpg(pg as i32, libc::SIGKILL) };
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use crate::config::HarnessProfile;
    use std::time::Duration;
    use tokio::sync::mpsc;

    fn running(pid: i32) -> bool {
        // A zombie has exited; only a live process still writes.
        std::fs::read_to_string(format!("/proc/{pid}/stat"))
            .ok()
            .and_then(|s| s.rsplit_once(") ").map(|(_, rest)| !rest.starts_with('Z')))
            .unwrap_or(false)
    }

    /// The model probe's shape: the caller's timeout drops its future while the agent (a
    /// leader and a helper in its group, as `cursor-agent acp` runs) is still up and never
    /// reached its explicit kill. Both processes end.
    #[tokio::test]
    async fn a_dropped_owner_ends_its_agents_whole_group() {
        let pid_file = std::env::temp_dir().join(format!("acpmux-eod-{}", std::process::id()));
        let _ = std::fs::remove_file(&pid_file);
        let script = format!("sleep 60 & echo $! > '{}'; exec sleep 60", pid_file.display());
        let profile: HarnessProfile =
            serde_json::from_value(serde_json::json!({"argv": ["/bin/sh", "-c", script]})).unwrap();
        let (inbound, _rx) = mpsc::channel(16);
        let tap: super::super::Tap = Arc::new(|_, _, _| true);
        let agent = ChildAgent::spawn("probe", &profile, &std::env::temp_dir(), inbound, tap)
            .await
            .expect("the agent starts");
        let leader = agent.pid.expect("a pid") as i32;
        let helper = async {
            loop {
                if let Some(p) = std::fs::read_to_string(&pid_file)
                    .ok()
                    .and_then(|p| p.trim().parse::<i32>().ok())
                {
                    return p;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
        };
        let helper = tokio::time::timeout(Duration::from_secs(5), helper).await.expect("helper");
        let _ = std::fs::remove_file(&pid_file);
        let owned = EndOnDrop::new(agent);
        let cut = tokio::time::timeout(Duration::from_millis(50), async move {
            let _owned = owned;
            std::future::pending::<()>().await;
        })
        .await;
        assert!(cut.is_err(), "the owner was cut by its timeout");
        let mut left = true;
        for _ in 0..100 {
            left = running(leader) || running(helper);
            if !left {
                break;
            }
            tokio::time::sleep(Duration::from_millis(50)).await;
        }
        if left {
            // SAFETY: the processes this test started.
            unsafe {
                libc::kill(helper, libc::SIGKILL);
                libc::kill(leader, libc::SIGKILL);
            }
        }
        assert!(!left, "a dropped owner left its agent's group running");
    }

    /// `end` ends it once; the drop after it sends nothing more.
    #[tokio::test]
    async fn end_disarms_the_drop() {
        let profile: HarnessProfile =
            serde_json::from_value(serde_json::json!({"argv": ["/bin/sh", "-c", "exec sleep 60"]}))
                .unwrap();
        let (inbound, _rx) = mpsc::channel(16);
        let tap: super::super::Tap = Arc::new(|_, _, _| true);
        let agent = ChildAgent::spawn("probe", &profile, &std::env::temp_dir(), inbound, tap)
            .await
            .expect("the agent starts");
        let leader = agent.pid.expect("a pid") as i32;
        let owned = EndOnDrop::new(agent);
        owned.end().await;
        assert!(!running(leader), "end left the agent running");
    }
}
