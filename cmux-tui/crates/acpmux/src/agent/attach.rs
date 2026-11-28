//! `ChildAgent`: attaching to a host and building one from its link.

use super::*;

impl ChildAgent {
    /// Become the owner of a running host and resume after `resume_after`,
    /// the last entry of it already in the session log.
    pub async fn attach_hosted(
        name: &str,
        record: crate::agent_host::HostRecord,
        resume_after: u64,
        awaiting: Vec<Id>,
        inbound: mpsc::Sender<Inbound>,
        tap: Tap,
    ) -> Result<Attached> {
        use crate::agent_host::link::{Connect, connect};
        let (link, adopted): (Arc<crate::agent_host::link::Link>, _) =
            match connect(record, resume_after).await? {
                Connect::Ready(link, adopted) => (Arc::from(link), adopted),
                Connect::Incompatible { min, max, host_build } => {
                    return Ok(Attached::Incompatible { min, max, host_build });
                }
            };
        let (agent, responses) =
            Self::from_link(name, link, &adopted, resume_after, awaiting, inbound, tap);
        Ok(Attached::Ready(agent, adopted, responses))
    }

    /// The agent over an owner connection that is already open; starts its
    /// reader.
    pub(crate) fn from_link(
        name: &str,
        link: Arc<crate::agent_host::link::Link>,
        adopted: &crate::agent_host::link::Adopted,
        resume_after: u64,
        awaiting: Vec<Id>,
        inbound: mpsc::Sender<Inbound>,
        tap: Tap,
    ) -> (Arc<Self>, Vec<Response>) {
        // Never reuse an id the harness may still answer.
        let (stdin_tx, _unused) = mpsc::channel(1);
        // Answers to requests a previous controller sent may be among the
        // replayed entries: register them before the reader starts.
        let mut map = HashMap::new();
        let mut responses = Vec::new();
        for id in awaiting {
            let (tx, rx) = oneshot::channel();
            map.insert(key(&id), tx);
            responses.push(rx);
        }
        let pending = Arc::new(Mutex::new(Pending {
            map,
            orphans: Default::default(),
            cancelled: Default::default(),
        }));
        let agent = Arc::new(Self {
            name: name.to_owned(),
            child: Arc::new(Mutex::new(None)),
            stdin_tx,
            next_id: AtomicI64::new(adopted.max_out_id.max(0) + 1),
            pending,
            tap,
            inbound: inbound.clone(),
            pid: adopted.harness_pid,
            translator: None,
            codex: None,
            codex_repo_gated: false,
            hosted: Some(Hosted {
                link: std::sync::RwLock::new(link.clone()),
                inbound,
                detached: Arc::new(std::sync::atomic::AtomicBool::new(false)),
                // Through the host's `acked_h` too: an owner acknowledged those entries once it
                // handled them, and the host dropped them, so none replays. Not every entry leaves
                // a `hostSeq` in the log (a stderr line, an Exit, a tap the live path keeps), so
                // the log's last one can trail it, and an adoption waiting for the hello's
                // `last_h` waited out `REPLAY_STALL` (10 s of every carrier restart fault,
                // 2026-11-24: "adopt agent hosts 10012ms", "replay incomplete").
                logged: tokio::sync::watch::channel(resume_after.max(adopted.acked_h)).0,
                log_turn: tokio::sync::Mutex::new(()),
                broken: std::sync::atomic::AtomicBool::new(false),
                broken_retry: std::sync::atomic::AtomicBool::new(false),
                replay_to: std::sync::atomic::AtomicU64::new(0),
                recovery_replay_complete: std::sync::atomic::AtomicBool::new(true),
                recovery_replay_retryable: std::sync::atomic::AtomicBool::new(false),
                stopped: std::sync::atomic::AtomicBool::new(false),
                unlogged_answers: std::sync::Mutex::new(Vec::new()),
                reattach_turn: tokio::sync::Mutex::new(()),
                #[cfg(unix)]
                custody: std::sync::Mutex::new(None),
                logged_o: std::sync::atomic::AtomicU64::new(0),
                harness_mark: std::sync::Mutex::new(None),
                exited: std::sync::atomic::AtomicBool::new(false),
                exit_seen: std::sync::atomic::AtomicBool::new(false),
                exit: tokio::sync::Notify::new(),
            }),
            all_tools: std::sync::atomic::AtomicBool::new(false),
            given_servers: std::sync::Mutex::new(None),
            launch: std::sync::Mutex::new(None),
            retired: std::sync::Mutex::new(false),
            ended_on_purpose: std::sync::atomic::AtomicBool::new(false),
            generation: NEXT_GENERATION.fetch_add(1, Ordering::Relaxed),
            preview_format: None,
            run_class: std::sync::OnceLock::new(),
            run_class_entered: std::sync::atomic::AtomicBool::new(false),
            demotion: Default::default(),
            writer_stop: std::sync::OnceLock::new(),
            #[cfg(test)]
            input_seam: InputSeam::default(),
            #[cfg(windows)]
            job: None,
            #[cfg(unix)]
            _tether: None,
            #[cfg(feature = "sim")]
            sim_alive: None,
        });
        agent.start_reader(link);
        (agent, responses)
    }

    /// Sets `flag` (`Hosted::broken` or `stopped`) while `link` is still this agent's link, under
    /// the requests' lock a reattach replaces the link and clears those flags under (`reattach`):
    /// a reader of a replaced link marks nothing on the one that replaced it (review 3 of #26059).
    /// False once the link was replaced or the agent detached.
    pub(super) async fn mark_link_unheard(
        &self,
        hosted: &Hosted,
        link: &Arc<crate::agent_host::link::Link>,
        flag: &std::sync::atomic::AtomicBool,
    ) -> bool {
        let _pending = self.pending.lock().await;
        if hosted.detached.load(Ordering::SeqCst) || !Arc::ptr_eq(&hosted.link(), link) {
            return false;
        }
        flag.store(true, Ordering::SeqCst);
        true
    }
}
