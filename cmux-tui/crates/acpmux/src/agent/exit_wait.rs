//! `ChildAgent`: retiring it, failing its pending requests and killing it.

use super::*;

impl ChildAgent {
    /// Mark the agent replaced (a failover) or stopping: a /context breakdown or usage limits it
    /// still sends, answering a turn that ended before, are dropped (`tap_live`). Waits for a breakdown being
    /// logged right now, so what the caller logs next comes after it.
    pub fn retire(&self) {
        *self.retired.lock().unwrap_or_else(|e| e.into_inner()) = true;
    }

    /// Mark the agent ended on purpose ([`Self::ended_on_purpose`]).
    pub fn end_on_purpose(&self) {
        self.ended_on_purpose.store(true, Ordering::SeqCst);
    }

    /// Whether [`Self::end_on_purpose`] ran.
    pub fn ended_on_purpose(&self) -> bool {
        self.ended_on_purpose.load(Ordering::SeqCst)
    }

    /// How many requests wait on this agent's answer now (as `Peer::pending_requests`).
    pub async fn pending_requests(&self) -> usize {
        self.pending.lock().await.map.len()
    }

    /// Fails every request still waiting on this agent: it was ended, and no exit may be read for
    /// it (a host whose reader stopped, #23322 review 65). A request already answered is not here.
    pub async fn fail_pending(&self) {
        let mut p = self.pending.lock().await;
        for (_, tx) in p.map.drain() {
            let _ = tx.send(Err(RpcError::internal(AGENT_CLOSED)));
        }
    }

    /// `fail_pending` while this agent's link is still broken or stopped: a reattach clears those
    /// under the same lock, so a late notice of an old link never fails the open requests of the
    /// link that replaced it (review 2 of #26059).
    pub async fn fail_pending_if_unheard(&self) {
        self.fail_pending_if_unheard_with(AGENT_CLOSED).await;
    }

    /// [`Self::fail_pending_if_unheard`] with `why` as each request's error: a link that broke
    /// because an entry could not be stored answers its open requests with the store's refusal
    /// (`disk.full` on a full disk) at once, rather than leaving them to the client's limit.
    pub async fn fail_pending_if_unheard_with(&self, why: &str) {
        let mut p = self.pending.lock().await;
        if !self.is_broken() && !self.is_stopped() {
            return;
        }
        for (_, tx) in p.map.drain() {
            let _ = tx.send(Err(RpcError::internal(why.to_owned())));
        }
    }

    /// Whether [`Self::retire`] ran.
    pub fn is_retired(&self) -> bool {
        *self.retired.lock().unwrap_or_else(|e| e.into_inner())
    }

    /// Runs `log` for `m`, unless `m` is a /context breakdown or usage limits update
    /// (`process_state`) from a retired agent (None).
    /// For such an update the retire lock is held across the check and `log`.
    pub(super) fn tap_live<R>(&self, m: &Message, log: impl FnOnce() -> R) -> Option<R> {
        let context = matches!(m, Message::Notification { method, params }
            if method == crate::rpc::method::SESSION_UPDATE
                && params.as_ref().is_some_and(process_state));
        if !context {
            return Some(log());
        }
        let retired = self.retired.lock().unwrap_or_else(|e| e.into_inner());
        (!*retired).then(log)
    }

    pub async fn kill(&self) {
        self.retire();
        #[cfg(feature = "sim")]
        self.end_sim();
        if self.hosted.is_some() {
            self.terminate(KILL_GRACE).await;
            return;
        }
        let mut guard = self.child.lock().await;
        #[cfg(unix)]
        let under = under_unreaped(guard.as_ref()).await;
        // The saved group id, not `child.id()`: once the leader is reaped
        // that is None, and its background processes would survive.
        if let Some(pid) = self.pid {
            // TERM the whole group first so children get a chance to exit,
            // then KILL whatever is left. The wait ends as soon as the
            // agent exits; 300 ms is only the most it gets.
            #[cfg(unix)]
            unsafe {
                libc::killpg(pid as i32, libc::SIGTERM);
            }
            // Windows: Ctrl+Break to the agent's process group first.
            #[cfg(windows)]
            crate::job::ctrl_break(pid);
            if let Some(child) = guard.as_mut() {
                let _ = tokio::time::timeout(KILL_GRACE, child.wait()).await;
            }
            // Then the job ends, stragglers included (SIGKILL on Unix).
            #[cfg(windows)]
            self.kill_job();
            #[cfg(unix)]
            unsafe {
                libc::killpg(pid as i32, libc::SIGKILL);
            }
        }
        if let Some(child) = guard.as_mut() {
            let _ = child.kill().await;
        }
        *guard = None;
        #[cfg(unix)]
        end_still_running(under).await;
    }
}
