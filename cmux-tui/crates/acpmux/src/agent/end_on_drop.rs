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

    /// The process exists (a reaped leader is gone; `kill` reaps it).
    fn exists(pid: i32) -> bool {
        // SAFETY: signal 0 only checks that the pid exists.
        unsafe { libc::kill(pid, 0) == 0 }
    }

    /// The helper still writes its heartbeat file.
    async fn beating(file: &std::path::Path) -> bool {
        let stamp = || std::fs::metadata(file).and_then(|m| m.modified()).ok();
        let before = stamp();
        tokio::time::sleep(Duration::from_millis(400)).await;
        before != stamp()
    }

    /// The model probe's shape: the caller's timeout drops its future while the agent (a
    /// leader and a helper in its group, as `cursor-agent acp` runs) is still up and never
    /// reached its explicit kill. Both processes end.
    #[tokio::test]
    async fn a_dropped_owner_ends_its_agents_whole_group() {
        let beat = std::env::temp_dir().join(format!("acpmux-eod-{}", std::process::id()));
        let _ = std::fs::remove_file(&beat);
        let script =
            format!("(while :; do : > '{}'; sleep 0.05; done) & exec sleep 60", beat.display());
        let profile: HarnessProfile =
            serde_json::from_value(serde_json::json!({"argv": ["/bin/sh", "-c", script]})).unwrap();
        let (inbound, _rx) = mpsc::channel(16);
        let tap: super::super::Tap = Arc::new(|_, _, _| true);
        let agent = ChildAgent::spawn("probe", &profile, &std::env::temp_dir(), inbound, tap)
            .await
            .expect("the agent starts");
        let leader = agent.pid.expect("a pid") as i32;
        assert!(beating(&beat).await, "the helper runs");
        let owned = EndOnDrop::new(agent);
        let cut = tokio::time::timeout(Duration::from_millis(50), async move {
            let _owned = owned;
            std::future::pending::<()>().await;
        })
        .await;
        assert!(cut.is_err(), "the owner was cut by its timeout");
        tokio::time::sleep(Duration::from_secs(1)).await;
        let helper_left = beating(&beat).await;
        let leader_left = exists(leader);
        if leader_left {
            // SAFETY: the group this test started.
            unsafe { libc::killpg(leader, libc::SIGKILL) };
        }
        let _ = std::fs::remove_file(&beat);
        assert!(!helper_left && !leader_left, "a dropped owner left its agent's group running");
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
        assert!(!exists(leader), "end left the agent running");
    }
}
