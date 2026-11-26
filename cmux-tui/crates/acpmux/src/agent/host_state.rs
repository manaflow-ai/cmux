//! `ChildAgent`: its host's kind, run class, harness processes and state flags.

use super::*;

impl ChildAgent {
    /// Whether Claude Code's translator runs this agent: here, or in its host
    /// (only that translator answers the host's query with modes). A host that
    /// does not answer within [`HOST_KIND_BUDGET`] gives [`HostKind::Late`]: its
    /// answer still comes, behind the replay the inbound loop drains, which on a
    /// loaded Mac takes longer than any fixed budget.
    pub async fn host_kind(&self) -> HostKind {
        if self.translator.is_some() {
            return HostKind::Known(true);
        }
        let Some(h) = &self.hosted else { return HostKind::Known(false) };
        let Ok(mut answer) = h.link().query_answer().await else { return HostKind::Unknown };
        if !host_kind_waits() {
            return HostKind::Late(LateHostKind(answer));
        }
        match crate::agent_host::within("query", HOST_KIND_BUDGET, &mut answer).await {
            Ok(Ok(reply)) => HostKind::Known(reply.modes.is_some()),
            Ok(Err(_)) => HostKind::Unknown,
            Err(_) => HostKind::Late(LateHostKind(answer)),
        }
    }

    /// Whether Claude Code's translator runs this agent, known without asking its host: a direct
    /// child's own, or one its host's record says it runs (`HostRecord::claude_translator`).
    /// False for a host of an older build, which never says.
    pub fn runs_claude_translator(&self) -> bool {
        self.translator.is_some()
            || self.hosted.as_ref().is_some_and(|h| h.link().record.claude_translator)
    }

    /// The Claude translator's state, wherever the translator runs.
    pub async fn claude_state(&self) -> Option<ClaudeState> {
        if let Some(tr) = &self.translator {
            return Some(ClaudeState {
                session_id: tr.session_id.lock().await.clone(),
                modes: tr.modes_value().await,
                config_options: tr.config_options_value().await,
            });
        }
        let link = self.hosted.as_ref()?.link();
        let reply = link.query().await.ok()?;
        Some(ClaudeState {
            session_id: reply.claude_session_id,
            modes: reply.modes?,
            config_options: reply.config_options.unwrap_or(Value::Null),
        })
    }

    /// The CPU class its harness runs at once its session's start is over (`cpu_class.rs`): the
    /// start that attached a hosted harness sets it (a direct one has it from its spawn). Only
    /// the first value counts.
    pub fn set_run_class(&self, class: crate::cpu_class::CpuClass) {
        let _ = self.run_class.set(class);
    }

    /// Its session's start is over: its harness goes to its run class, once (`cpu_class.rs`).
    /// True when this call lowered it. A harness with no class set (another daemon started it)
    /// takes the agent tier; one that ended is left alone.
    pub async fn enter_run_class(&self) -> bool {
        // A harness adopted from another daemon has no class here: one whose start that daemon
        // did not see end (a restart mid-start) would keep the start's priority for good, so it
        // takes the agent tier ([`CpuClass::Normal`]), which only lowers.
        let class = self.run_class();
        if self.run_class_entered.swap(true, Ordering::SeqCst) {
            return false;
        }
        let lowered = self.with_live_harness(|pid| class.enter(pid)).await.unwrap_or(false);
        if lowered && class == crate::cpu_class::CpuClass::Background {
            self.demotion.mark(true, crate::cpu_class::pressure::mono_ms());
        }
        lowered
    }

    /// The class its harness runs at once its start is over: its start's, else (a harness
    /// another daemon started) `normal`.
    pub fn run_class(&self) -> crate::cpu_class::CpuClass {
        self.run_class.get().copied().unwrap_or(crate::cpu_class::CpuClass::Normal)
    }

    /// Its session's start is over and its harness went to its run class.
    pub fn run_class_entered(&self) -> bool {
        self.run_class_entered.load(Ordering::SeqCst)
    }

    /// Puts its harness's whole tree in background class (`on`) or takes it out
    /// (`cpu_class::set_tree_background`), for the dynamic class (`hub/cpu_pressure.rs`). While
    /// on, every call walks the tree again (a process forked during the last walk); once off,
    /// one more walk follows the change, then none. Some(true) when the class changed, None when
    /// its harness is gone.
    pub async fn apply_background(&self, on: bool, now_ms: u64) -> Option<bool> {
        let changed = self.demotion.is_background() != on;
        let recheck = !changed && !on && self.demotion.take_recheck();
        if !changed && !on && !recheck {
            return Some(false);
        }
        let walked =
            self.with_live_harness(|pid| crate::cpu_class::set_tree_background(pid, on)).await?;
        if changed && (walked > 0 || !on) {
            self.demotion.mark(on, now_ms);
        }
        Some(changed && walked > 0)
    }

    /// `session info`'s `cpuClass` (`cpu_class::pressure::Demotion::view`).
    pub fn cpu_class_view(&self, now_ms: u64) -> Value {
        self.demotion.view(self.run_class(), now_ms)
    }

    /// A person's own turn runs (`on`) or ended: a `background` harness leaves background class
    /// for the turn and goes back after it (`cpu_class.rs`, item 6), so the tools it starts while
    /// a person waits run at the agent tier, still below the app, not at background class. Only a
    /// harness this daemon put in background class moves. True when its class changed.
    pub async fn person_turn(&self, on: bool) -> bool {
        let background =
            self.run_class.get().copied() == Some(crate::cpu_class::CpuClass::Background);
        if !background || !self.run_class_entered.load(Ordering::SeqCst) {
            return false;
        }
        self.with_live_harness(|pid| crate::cpu_class::person_turn(pid, on)).await.unwrap_or(false)
    }

    /// What its harness is doing now (`cpu_class::HarnessSeen`): ended, unread or its state.
    pub async fn harness_seen(&self) -> crate::cpu_class::HarnessSeen {
        use crate::cpu_class::HarnessSeen;
        match self.with_live_harness(crate::cpu_class::harness_state).await {
            None => HarnessSeen::Ended,
            Some(None) => HarnessSeen::Unread,
            Some(Some(state)) => HarnessSeen::Running(state),
        }
    }

    /// `f` of its harness's pid while that pid is still its harness: a direct child not reaped
    /// (its slot locked across `f`, so no reap can free the pid meanwhile), or a hosted one its
    /// host has not reported ended. None otherwise.
    pub(super) async fn with_live_harness<T>(&self, f: impl FnOnce(u32) -> T) -> Option<T> {
        let pid = self.pid?;
        if self.hosted.is_some() {
            return self.is_alive().await.then(|| f(pid));
        }
        let mut guard = self.child.lock().await;
        let child = guard.as_mut()?;
        matches!(child.try_wait(), Ok(None)).then(|| f(pid))
    }

    /// The processes under its harness, for ending some of them (`hub/silent_listing.rs`),
    /// never found from a bare pid, which a reaped process gives up: a direct child's
    /// descendants read while it is not reaped, under its slot's lock; a hosted one's, every
    /// process that carries its host's start nonce (`HOST_MARK`).
    #[cfg(unix)]
    pub(crate) async fn harness_processes(&self) -> Vec<crate::agent_host::tree::Started> {
        if let Some(record) = self.host_record() {
            let mark = self.hosted.as_ref().and_then(|h| h.harness_mark.lock_or_recover().clone());
            let nonce = mark.unwrap_or(record.start_nonce);
            return tokio::task::spawn_blocking(move || {
                crate::agent_host::tree::marked(crate::agent_host::HOST_MARK, &nonce)
            })
            .await
            .unwrap_or_default();
        }
        let guard = self.child.lock().await;
        under_unreaped(guard.as_ref()).await
    }

    /// The host record when this agent runs under a host.
    pub fn host_record(&self) -> Option<crate::agent_host::HostRecord> {
        self.hosted.as_ref().map(|h| h.link().record.clone())
    }

    /// Whether this agent runs under a host whose record says a level below `level`
    /// (`HostRecord::host_level`) on another build than this one's (`hub/host_level.rs`).
    pub fn host_below(&self, level: u32) -> bool {
        self.hosted.as_ref().is_some_and(|h| {
            let link = h.link();
            link.record.host_level < level && link.record.host_build != crate::build_info::build()
        })
    }

    /// The build its host runs (`HostRecord::host_build`), when this agent runs under a host.
    pub fn host_build(&self) -> Option<String> {
        self.hosted.as_ref().map(|h| h.link().record.host_build.clone())
    }

    /// Tests only: its child's slot, which its reaper locks (`Fence::cut_or_end`).
    #[cfg(test)]
    pub(crate) fn child_slot(&self) -> Arc<Mutex<Option<Child>>> {
        self.child.clone()
    }

    /// The hosted harness exited (its host is finishing).
    pub fn has_exited(&self) -> bool {
        self.hosted.as_ref().is_some_and(|h| h.exited.load(Ordering::SeqCst))
    }

    /// Its host is still connected and reported no exit: after a [`Self::terminate`], the host
    /// did not take it (its link stopped reading) or could not end the agent within the grace.
    /// A host whose link closed is not judged here.
    pub fn host_unended(&self) -> bool {
        self.hosted.as_ref().is_some_and(|h| {
            !h.exit_seen.load(Ordering::SeqCst)
                && !h.exited.load(Ordering::SeqCst)
                && !h.link().is_closed()
        })
    }

    /// The reader stopped because an entry could not be logged.
    pub fn is_broken(&self) -> bool {
        self.hosted.as_ref().is_some_and(|h| h.broken.load(Ordering::SeqCst))
    }

    /// Take the one retry of this broken link (`Hub::reach_broken_link`): false while another
    /// runs, or for an agent with no host.
    pub fn claim_broken_retry(&self) -> bool {
        self.hosted.as_ref().is_some_and(|h| {
            h.broken_retry.compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst).is_ok()
        })
    }

    /// End the retry [`Self::claim_broken_retry`] took.
    pub fn release_broken_retry(&self) {
        if let Some(h) = &self.hosted {
            h.broken_retry.store(false, Ordering::SeqCst);
        }
    }

    /// The reader of the current host link stopped otherwise (`Hosted::stopped`): what the host
    /// reports is not heard until a reattach.
    pub fn is_stopped(&self) -> bool {
        self.hosted.as_ref().is_some_and(|h| h.stopped.load(Ordering::SeqCst))
    }
}
