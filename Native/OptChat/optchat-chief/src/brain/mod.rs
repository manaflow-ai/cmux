//! The brain: one thread that owns the host state and turns inputs (daemon
//! events, acpmux events, turn workers' reports) into effects. It keeps the
//! queue of new messages and runs the turn loop of section 7:
//!
//! ```text
//! on message: if a call is running: deliver it between tool calls
//!             else: queue.push(text); if idle: turn()
//! turn: settle (worker) -> take the queue -> render the view -> log the
//!       messages as `user` -> fresh call (worker) -> post the reply
//! ```
//!
//! Delivery between tool calls depends on the engine. The native engine
//! (`Engine::Native`, the host's own Messages API loop) asks the brain for
//! queued messages at every tool boundary, so MASTER's "messages the user
//! sends while you work reach you between tool calls" holds. The acpmux
//! engine steers the message into the running session (`steer.rs`; acpmux's
//! Claude Code adapter writes it to claude's stdin, read at the next tool
//! boundary). A session that cannot steer (another harness, an older
//! acpmux) stops the running turn (`session/cancel`; its steps are already
//! in the log) and the next fresh turn takes the message with the view of
//! everything the stopped turn did. A turn that hangs is stopped by
//! `Settings::turn_limit`.

mod approvals;
mod children;
mod drafts;
mod engine_control;
pub mod images;
mod inbox;
mod mux_ack;
mod outbox;
mod prewarm;
mod recover;
mod side;
mod spawns;
mod steer;
mod turns;

use std::collections::{HashMap, HashSet, VecDeque};
use std::path::PathBuf;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender};
use std::time::{Duration, Instant};

use cmux_chief::acp::SessionSummary;
use cmux_conversation::{Op, Part, Summary};
use optchat_host::OptChat;

use crate::acpmux::{AgentEvent, AgentPort};
use crate::daemon::{ConversationPort, DaemonEvent};
use crate::state::{HostState, OutboxEntry, StateFile};
use crate::turn::{TurnOutcome, TurnStart};

/// Everything the brain reacts to.
pub enum Input {
    Daemon(Box<DaemonEvent>),
    Agents(Box<AgentEvent>),
    /// A turn worker settled the view and asks for its turn (None: nothing to do).
    Settled(Sender<Option<TurnStart>>),
    /// A turn worker could not settle (shutdown or a failed write).
    SettleFailed,
    /// A turn worker has waited for the compactor for a while and a node keeps
    /// failing: what to tell the conversation (once per wait).
    Stalled(String),
    /// An acpmux turn's session and how far its events are folded.
    TurnProgress {
        key: String,
        session_id: String,
        after: u64,
    },
    /// A native turn is between tool calls: the brain logs what is queued
    /// and answers with the texts to deliver (section 7).
    Boundary {
        key: String,
        /// The prompt blocks to deliver: the messages' images, then their text.
        reply: Sender<Vec<serde_json::Value>>,
    },
    /// A draft of the running turn's reply (`draft.rs`).
    Draft(Box<crate::draft::Draft>),
    /// A steer's outcome (`steer.rs`): Ok once the harness read it.
    Steered {
        id: u64,
        result: Result<(), String>,
    },
    TurnEnded {
        key: String,
        /// Boxed: the outcome and its stats are the largest input.
        outcome: Box<TurnOutcome>,
    },
    /// Something the user must hear once (the compactor cannot build a
    /// node): posted in the Chief conversation, with `key` as its
    /// idempotency key, as soon as the conversation is known.
    Notice {
        key: String,
        text: String,
    },
    /// The compactor's start-up probe: Err with the text the user must
    /// hear (the compactor cannot build a node), Ok when it built one.
    CompactorStatus(Result<(), String>),
    /// Section 9: a `spawn` asks for its spawn id and subagent ids.
    SpawnRegister {
        tasks: Vec<String>,
        reply: Sender<Result<crate::subagents::SpawnPlan, String>>,
    },
    /// A subagent's session exists (its prompt follows).
    SubagentStarted {
        id: String,
        session_id: String,
        /// `ask` under the spawn floor.
        policy: Option<String>,
    },
    /// A subagent's cmux workspace exists.
    SubagentWorkspace {
        id: String,
        key: String,
        name: String,
    },
    /// A subagent could not start.
    SubagentFailed {
        id: String,
        error: String,
    },
    /// The answer of a prompt the host sent a subagent (token use, cost).
    SubagentAnswer {
        id: String,
        answer: Result<serde_json::Value, String>,
    },
    /// The acpmux session of subagent `id` (`zoom("a<N>")`), None when
    /// there is no such subagent or it has none yet.
    SubSession {
        id: String,
        reply: Sender<Option<String>>,
    },
    /// `tell(id, message)`.
    Tell {
        id: String,
        message: String,
        reply: Sender<Result<String, String>>,
    },
    /// Changes a per-Chief setting (`chief_settings`); refused for
    /// `remote.autoApprove` on during a remote-origin turn.
    Setting {
        key: String,
        value: String,
        reply: Sender<Result<String, String>>,
    },
    /// The per-Chief settings as JSON.
    Settings {
        reply: Sender<serde_json::Value>,
    },
    /// The policy floor for a child spawned now (`Brain::spawn_policy`).
    SpawnPolicy {
        reply: Sender<Option<String>>,
    },
    /// A description of a turn's image arrived (or failed): logged as a note.
    Described {
        image: Box<images::TurnImage>,
        description: Result<String, String>,
    },
    /// chief.engine.get / chief.engine.set: the engine this brain's turns
    /// take (engine.json), answered as one JSON value (`engine_control`).
    Engine {
        request: EngineRequest,
        reply: Sender<serde_json::Value>,
    },
    /// chief.stop: stops the running turn as a newer message does;
    /// answers `{"stopped": bool}`.
    Stop {
        reply: Sender<serde_json::Value>,
    },
}

/// What chief.engine.get / chief.engine.set ask the brain.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum EngineRequest {
    Show,
    /// An absent field stays; `default` clears one.
    Set {
        harness: Option<String>,
        model: Option<String>,
        effort: Option<String>,
    },
}

impl From<DaemonEvent> for Input {
    fn from(event: DaemonEvent) -> Input {
        Input::Daemon(Box::new(event))
    }
}

impl From<AgentEvent> for Input {
    fn from(event: AgentEvent) -> Input {
        Input::Agents(Box::new(event))
    }
}

/// What runs a turn.
#[derive(Clone)]
pub enum Engine {
    /// A fresh acpmux session per turn (claude-sr, codex, ...).
    Acpmux,
    /// The host's own Messages API loop (sections 7 and 8 in full).
    Native(Arc<crate::native::Native>),
}

impl std::fmt::Debug for Engine {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Engine::Acpmux => f.write_str("Acpmux"),
            Engine::Native(_) => f.write_str("Native"),
        }
    }
}

/// How turns run.
#[derive(Clone, Debug)]
pub struct Settings {
    /// The constant working directory of every turn session.
    pub session_dir: PathBuf,
    /// `MUX_HARNESS` (default claude, or a configured claude-cr).
    pub harness: String,
    /// `MUX_POLICY` (default approve-all).
    pub policy: String,
    pub model: Option<String>,
    /// acpmux `effort` of each turn session (`effort::turn_effort`); None:
    /// the harness's default.
    pub effort: Option<String>,
    /// The value of the `mux.parent` tag on the Chief's children.
    pub parent: String,
    /// Turn session names are `<turn_prefix>-<first id>`; `optchat-<home id>`,
    /// so two homes on one acpmux daemon never remove each other's turns.
    pub turn_prefix: String,
    /// The owner's agent gap plus a margin (mux/host: 2.2 s).
    pub agent_gap: Duration,
    /// Longest a turn may run (None: no limit).
    pub turn_limit: Option<Duration>,
    pub engine: Engine,
    /// The turn sessions' acpmux preset on a Claude harness, whose system
    /// prompt each turn sets (the cached layout); None on another harness.
    pub turn_preset: Option<String>,
    /// This Chief's home id: the `cmux.chief` tag on its turn and
    /// compactor sessions.
    pub chief_id: String,
    /// The turn's system text (`prompt::system_text`): the head of the
    /// cached layout's system prompt, and the session directory's CLAUDE.md
    /// in the old layout.
    pub system_text: String,
    /// `$MUX_HOME/optchat/engine.json` (engine.rs), read at each turn start:
    /// harness, model and effort swap between turns. None: the fields above.
    pub engine_file: Option<PathBuf>,
    /// Every acpmux harness's family (`_acpmux/harnesses` at host start).
    /// Empty: the default harness is Claude when `turn_preset` is set.
    pub families: std::collections::BTreeMap<String, crate::acpmux::Family>,
    /// The codex turn preset (`optchat-chief-codex-<home id>`), when a codex
    /// harness exists: a turn on codex starts with it.
    pub codex_preset: Option<String>,
    /// The per-Chief settings file (`chief_settings`), read at start.
    pub settings_file: PathBuf,
    /// The monitoring trace's directory, where approvals are recorded
    /// (None: not recorded).
    pub trace_dir: Option<PathBuf>,
    /// `OPTCHAT_CACHE_TTL` at host start: the turns' cache TTL over the
    /// Chief's `cache.ttl` setting. None: the setting, else 1 hour on the
    /// Claude Code path.
    pub cache_ttl: Option<crate::prompt::CacheTtl>,
    /// The turns' current TTL, shared with the compactor: its nodes take the
    /// same TTL on the same route.
    pub shared_ttl: crate::prompt::SharedTtl,
}

/// How long a turn waits for the compactor before it tells the conversation
/// which node keeps failing (section 6 expects seconds).
const STALL_NOTICE: Duration = Duration::from_secs(60);
/// How often a turn waiting for the compactor updates `settle.json`.
const PROGRESS_TICK: Duration = Duration::from_secs(2);

/// The start of the `mux.parent` value on sessions this Chief started;
/// mux/host uses `mux`, so the two never claim each other's children.
pub const PARENT: &str = "optchat-chief";

/// The `mux.parent` value of the Chief of `home`: two homes sharing one
/// acpmux daemon (tagged builds) never claim each other's children.
pub fn parent_tag(home: &std::path::Path) -> String {
    format!("{PARENT}:{}", crate::paths::home_id(home))
}

/// Longest reply text posted (the owner refuses more than 64 KiB per message).
const REPLY_BYTES: usize = 60_000;

/// One queued new message. The inbox is one queue; each turn takes the
/// items of its head item's conversation and answers there (G9).
#[derive(Clone, Debug, PartialEq, Eq)]
struct Queued {
    text: String,
    source: Source,
    /// The images of a human message, for the turn's prompt (never logged).
    images: Vec<images::TurnImage>,
    /// The side conversation of a human message; None for the main
    /// conversation, which also takes every note, child report and spawn.
    conversation: Option<String>,
}

impl Queued {
    /// It starts a turn (and stops a working one); a stopped subagent's
    /// report does not, and waits for the next turn.
    fn wakes(&self) -> bool {
        !matches!(&self.source, Source::Spawn(r) if r.quiet)
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Source {
    /// A human message of the Chief conversation; `remote` names the paired
    /// install that sent it (the relay's origin), None for a local one.
    Message {
        seq: u64,
        /// The message's id (a side floor's crash dedupe).
        id: String,
        remote: Option<String>,
    },
    /// A child's report; its record turns `Reported` with this floor when logged.
    Child { session_id: String, floor: u64 },
    /// Anything else (a child's permission request).
    Note,
    /// A subagent's report (section 9).
    Spawn(crate::state::SpawnRef),
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Phase {
    Idle,
    /// A worker waits for the view to settle.
    Settling,
    Running,
}

pub type Log = Arc<dyn Fn(&str) + Send + Sync>;

/// Runs after every turn with its key (persist and back up, section 10).
pub type TurnHook = Arc<dyn Fn(&str) + Send + Sync>;

pub struct Brain {
    chat: Arc<OptChat>,
    agents: Arc<dyn AgentPort>,
    settings: Settings,
    file: StateFile,
    state: HostState,
    tx: Sender<Input>,
    log: Log,
    daemon: Option<Box<dyn ConversationPort>>,
    reconnect: Option<Box<dyn Fn() + Send>>,
    summary: Option<Summary>,
    /// Ids of the Chief's own messages (the wake rule's reply-to check).
    mux_messages: HashSet<String>,
    /// Highest conversation seq handled (queued or skipped).
    handled: u64,
    queue: VecDeque<Queued>,
    phase: Phase,
    agents_up: bool,
    sessions: HashMap<String, SessionSummary>,
    /// Turn sessions left by a host that stopped mid-turn before it knew
    /// their id, removed by name once acpmux is up.
    stale_sessions: Vec<String>,
    outbox_timer: Option<Instant>,
    /// When the last agent message was taken by the owner (epoch ms): the next waits out the gap (G11).
    last_agent_send: Option<u64>,
    fatal: Option<String>,
    /// A human message arrived while an acpmux turn ran: that turn is
    /// being stopped, and its end posts nothing.
    stop_wanted: bool,
    /// The owner stopped the running turn (chief.stop): its end says so.
    owner_stopped: bool,
    /// The running turn's interrupt (a new one per turn).
    interrupt: Arc<crate::turn::Interrupt>,
    /// The steer on its way into the running turn (`steer.rs`), and the
    /// last steer's number.
    steering: Option<steer::Steering>,
    steer_seq: u64,
    /// A draft could not be published (logged once).
    draft_failed: bool,
    after_turn: Option<TurnHook>,
    /// Notices waiting for the conversation to be known.
    notices: Vec<(String, String)>,
    /// Notice keys already handled (each is posted once per process).
    noticed: HashSet<String>,
    /// Claude Code refused a turn's cache marker (it placed a fourth
    /// breakpoint of its own): later turns go without it.
    marker_refused: Arc<std::sync::atomic::AtomicBool>,
    /// A route refused a 1-hour cache mark: turns go at 5 minutes until the
    /// host restarts or `cache.ttl` is set again.
    ttl_refused: Arc<std::sync::atomic::AtomicBool>,
    /// The TTL the session settings held when the pool was last hinted: a
    /// pooled session runs Claude Code with it.
    prewarm_ttl: Option<crate::prompt::CacheTtl>,
    /// This turn's TTL differs from `prewarm_ttl` (cache.ttl changed).
    ttl_stale: Arc<std::sync::atomic::AtomicBool>,
    /// The view up to and including the last turn's marked block
    /// (`optchat_core::mark_piece`): the next turn keeps its mark within the
    /// API's lookback of it.
    last_mark: Option<String>,
    /// The monitoring trace (`trace.rs`).
    pub(crate) trace: crate::trace::Trace,
    /// Where subagents' workspaces are renamed when they finish.
    workspaces: Option<Arc<dyn crate::workspaces::Workspaces>>,
    /// Starts a queued subagent by id (`Spawner::queue_starter`).
    sub_starter: Option<Sender<String>>,
    /// A finished subagent's workspace closes instead of taking the done
    /// mark (`OPTCHAT_SUBAGENT_ON_FINISH=close`).
    sub_close_on_finish: bool,
    /// The previous turn's view, to measure how much of it stayed (cache).
    prev_view: Option<String>,
    /// When the current settle wait and turn began.
    settle_clock: Option<Instant>,
    /// Where a turn waiting for the compactor says how far it is.
    settle_status: Option<Arc<crate::settle_status::SettleStatus>>,
    turn_clock: Option<Instant>,
    /// The running turn's engine (engine.rs), for the trace.
    turn_engine: Option<crate::engine::TurnEngine>,
    /// The per-Chief settings (`chief_settings`), owned by the host.
    chief: crate::chief_settings::ChiefSettings,
    /// The running turn has a remote origin (a paired device's message, or
    /// a remote turn it supersedes): the strictest origin wins until it ends.
    turn_remote: bool,
    /// The running turn runs with policy `ask` (remote, no auto-approve).
    turn_ask: bool,
    /// A remote-origin turn was stopped for a newer message: the turn that
    /// answers both keeps its origin.
    remote_taint: bool,
    /// The running turn's permission requests waiting for a person.
    approvals: VecDeque<crate::approval::Pending>,
    /// Writes the log's description of each turn image (None: references only).
    describer: Option<Arc<dyn images::Describe>>,
    /// Images being described now (`conversation/hash`), started once each.
    describing: HashSet<String>,
    /// Highest seq handled (queued or skipped) of each side conversation;
    /// its saved floor follows once nothing of it is queued (`handled` for
    /// the main conversation).
    side_handled: HashMap<String, u64>,
    /// Woken conversations not acked yet: the highest woken seq of each
    /// (`mux_ack.rs`).
    mux_pending: HashMap<String, u64>,
}

impl Brain {
    pub fn new(
        chat: Arc<OptChat>,
        agents: Arc<dyn AgentPort>,
        settings: Settings,
        file: StateFile,
        tx: Sender<Input>,
        log: Log,
    ) -> Brain {
        // The state lives in the memory database from here on (an old
        // host.json is imported once).
        let file = file.attach(chat.clone());
        let mut state = file.load();
        let acpmux = matches!(settings.engine, Engine::Acpmux);
        let mut stale_sessions = recover::recover(&chat, &mut state, acpmux);
        // Only this home's turn sessions: a name without its prefix is a
        // host before audit round 3's or another home's, never removed.
        let own = format!("{}-", settings.turn_prefix);
        stale_sessions.retain(|name| name.starts_with(&own));
        let handled = state.logged_seq;
        let chief = crate::chief_settings::ChiefSettings::load(&settings.settings_file);
        let brain = Brain {
            chat,
            agents,
            settings,
            file,
            state,
            tx,
            log,
            daemon: None,
            reconnect: None,
            summary: None,
            mux_messages: HashSet::new(),
            handled,
            queue: VecDeque::new(),
            phase: Phase::Idle,
            agents_up: false,
            sessions: HashMap::new(),
            stale_sessions,
            outbox_timer: None,
            last_agent_send: None,
            fatal: None,
            stop_wanted: false,
            owner_stopped: false,
            interrupt: Arc::new(crate::turn::Interrupt::new()),
            steering: None,
            steer_seq: 0,
            draft_failed: false,
            marker_refused: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            ttl_refused: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            prewarm_ttl: None,
            ttl_stale: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            last_mark: None,
            chief,
            turn_remote: false,
            turn_ask: false,
            remote_taint: false,
            approvals: VecDeque::new(),
            after_turn: None,
            notices: Vec::new(),
            noticed: HashSet::new(),
            trace: crate::trace::Trace::off(),
            workspaces: None,
            sub_starter: None,
            sub_close_on_finish: false,
            prev_view: None,
            settle_clock: None,
            settle_status: None,
            turn_clock: None,
            turn_engine: None,
            describer: None,
            describing: HashSet::new(),
            side_handled: HashMap::new(),
            mux_pending: HashMap::new(),
        };
        brain.save();
        // The compactor's first nodes take the turns' TTL too.
        brain.turn_cache_ttl();
        brain
    }

    /// Runs `hook` after every turn (the host snapshots the memory there).
    pub fn on_turn_end(mut self, hook: TurnHook) -> Brain {
        self.after_turn = Some(hook);
        self
    }

    /// Writes the monitoring trace (`trace.rs`).
    /// A turn that waits for the compactor writes how far it is here.
    pub fn with_settle_status(mut self, status: crate::settle_status::SettleStatus) -> Brain {
        self.settle_status = Some(Arc::new(status));
        self
    }

    pub fn with_trace(mut self, trace: crate::trace::Trace) -> Brain {
        self.trace = trace;
        self
    }

    /// `with_trace` and `with_workspaces` on a brain already made.
    pub fn set_trace(&mut self, trace: crate::trace::Trace) {
        self.trace = trace;
    }

    pub fn set_workspaces(&mut self, workspaces: Option<Arc<dyn crate::workspaces::Workspaces>>) {
        self.workspaces = workspaces;
    }

    /// Finished subagents' workspaces close (true) or stay with the done
    /// mark (false, the default).
    pub fn set_sub_close_on_finish(&mut self, close: bool) {
        self.sub_close_on_finish = close;
    }

    /// Where queued subagents are started when a slot frees.
    pub fn set_sub_starter(&mut self, starter: Option<Sender<String>>) {
        self.sub_starter = starter;
    }

    /// Renames subagents' workspaces when they finish (workspaces.rs).
    pub fn with_workspaces(
        mut self,
        workspaces: Option<Arc<dyn crate::workspaces::Workspaces>>,
    ) -> Brain {
        self.workspaces = workspaces;
        self
    }

    /// Describes each turn image for the log (the compactor's deny-all model).
    pub fn set_describer(&mut self, describer: Arc<dyn images::Describe>) {
        self.describer = Some(describer);
    }

    /// acpmux sessions the brain keeps a summary of (its children only).
    pub fn known_sessions(&self) -> usize {
        self.sessions.len()
    }

    pub fn state(&self) -> &HostState {
        &self.state
    }

    /// Why the host must stop, once it must.
    pub fn fatal(&self) -> Option<&str> {
        self.fatal.as_deref()
    }

    pub fn is_idle(&self) -> bool {
        self.phase == Phase::Idle
            && !self.queue.iter().any(Queued::wakes)
            && self.steering.is_none()
    }

    /// When the outbox timer fires, if armed.
    pub fn next_timer(&self) -> Option<Instant> {
        self.outbox_timer
    }

    /// Runs until a fatal error; returns it.
    pub fn run(mut self, rx: Receiver<Input>) -> String {
        loop {
            if let Some(fatal) = &self.fatal {
                return fatal.clone();
            }
            let input = match self.outbox_timer {
                Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                    Ok(input) => input,
                    Err(RecvTimeoutError::Timeout) => {
                        self.on_timer();
                        continue;
                    }
                    Err(RecvTimeoutError::Disconnected) => return "input channel closed".into(),
                },
                None => match rx.recv() {
                    Ok(input) => input,
                    Err(_) => return "input channel closed".into(),
                },
            };
            self.step(input);
        }
    }

    pub fn step(&mut self, input: Input) {
        match input {
            Input::Daemon(event) => self.on_daemon(*event),
            Input::Agents(event) => self.on_agents(*event),
            Input::Settled(reply) => {
                let start = self.settled();
                let _ = reply.send(start);
            }
            Input::SettleFailed => {
                self.phase = Phase::Idle;
                let status = self.chat.status();
                if let Some(fatal) = status.fatal {
                    self.fatal = Some(format!("the memory stopped writing: {fatal}"));
                }
            }
            Input::Stalled(text) => self.stalled(&text),
            Input::TurnProgress {
                key,
                session_id,
                after,
            } => self.progress(&key, session_id, after),
            Input::Boundary { key, reply } => {
                let blocks = self.boundary(&key);
                let _ = reply.send(blocks);
            }
            Input::Draft(draft) => self.turn_draft(&draft),
            Input::Steered { id, result } => self.steered(id, result),
            Input::TurnEnded { key, outcome } => self.turn_ended(&key, *outcome),
            Input::Notice { key, text } => self.notice(key, text),
            Input::CompactorStatus(status) => self.compactor_status(status),
            Input::SpawnRegister { tasks, reply } => {
                let plan = self.register_spawn(&tasks);
                let _ = reply.send(plan);
            }
            Input::SubagentStarted {
                id,
                session_id,
                policy,
            } => self.sub_started(&id, session_id, policy),
            Input::SubagentWorkspace { id, key, name } => self.sub_workspace(&id, key, name),
            Input::SubagentFailed { id, error } => self.sub_failed(&id, &error),
            Input::SubagentAnswer { id, answer } => self.sub_answer(&id, &answer),
            Input::SubSession { id, reply } => {
                let session = self.state.sub(&id).and_then(|(_, s)| s.session_id.clone());
                let _ = reply.send(session);
            }
            Input::Tell { id, message, reply } => {
                let answer = self.tell(&id, &message);
                let _ = reply.send(answer);
            }
            Input::Setting { key, value, reply } => {
                let _ = reply.send(self.set_setting(&key, &value));
            }
            Input::Settings { reply } => {
                let _ = reply.send(self.chief.to_json());
            }
            Input::SpawnPolicy { reply } => {
                let _ = reply.send(self.spawn_policy().map(str::to_owned));
            }
            Input::Described { image, description } => self.described(&image, description),
            Input::Engine { request, reply } => {
                let _ = reply.send(self.engine_control(request));
            }
            Input::Stop { reply } => {
                let _ = reply.send(self.owner_stop());
            }
        }
    }

    /// Whether a turn can start now: the memory writes, and the engine's
    /// owner is connected (the native engine needs no acpmux).
    fn ready(&self) -> bool {
        self.fatal.is_none()
            && (self.agents_up || matches!(self.settings.engine, Engine::Native(_)))
    }

    /// Tells the conversation, once per wait, that its message waits on a
    /// failing compactor node (section 6 expects the wait to take seconds).
    fn stalled(&mut self, text: &str) {
        if self.phase != Phase::Settling {
            return;
        }
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        (self.log)(text);
        let key = format!(
            "stall:optchat:{}:{}",
            self.handled,
            self.chat.status().messages
        );
        self.state
            .outbox
            .push(reply_entry(conversation, &key, text));
        self.save();
        self.flush_outbox();
    }

    /// Posts a notice once, now or as soon as the conversation is known.
    fn notice(&mut self, key: String, text: String) {
        if !self.noticed.insert(key.clone()) {
            return;
        }
        (self.log)(&text);
        self.notices.push((key, text));
        self.post_notices();
    }

    /// cx-1hpt: one failure notice in the conversation at a time, across
    /// host starts (the state file keeps it); a good probe retracts it.
    fn compactor_status(&mut self, status: Result<(), String>) {
        match status {
            Err(text) => {
                if self.state.compactor_notice.is_some() {
                    (self.log)(&text);
                    return;
                }
                let key = format!("notice:optchat:compactor:{}", now_ms());
                self.state.compactor_notice = Some(crate::state::PostedNotice {
                    key: key.clone(),
                    message_id: None,
                });
                self.save();
                self.notice(key, text);
            }
            Ok(()) => {
                let Some(posted) = self.state.compactor_notice.take() else {
                    return;
                };
                // Not sent yet: it never shows.
                self.notices.retain(|(k, _)| *k != posted.key);
                self.state
                    .outbox
                    .retain(|e| e.idempotency_key != posted.key || e.attempted);
                match (posted.message_id, self.state.conversation.clone()) {
                    (Some(id), Some(conversation)) => {
                        (self.log)("the memory compactor works again; its notice is retracted");
                        self.state.outbox.push(op_entry(
                            conversation,
                            &format!("{}:retract", posted.key),
                            Op::MessageRetract { message_id: id },
                        ));
                    }
                    _ => (self.log)("the memory compactor works again"),
                }
                self.save();
                self.flush_outbox();
            }
        }
    }

    /// The owner confirmed the message sent under `key`.
    pub(super) fn sent(&mut self, key: &str, message_id: &str) {
        if let Some(posted) = self.state.compactor_notice.as_mut()
            && posted.key == key
        {
            posted.message_id = Some(message_id.to_owned());
        }
    }

    /// Moves waiting notices into the outbox once the conversation is known.
    pub(super) fn post_notices(&mut self) {
        let Some(conversation) = self.state.conversation.clone() else {
            return;
        };
        if self.notices.is_empty() {
            return;
        }
        for (key, text) in std::mem::take(&mut self.notices) {
            self.state
                .outbox
                .push(reply_entry(conversation.clone(), &key, &text));
        }
        self.save();
        self.flush_outbox();
    }

    pub fn on_timer(&mut self) {
        self.outbox_timer = None;
        self.flush_outbox();
    }

    fn save(&self) {
        self.save_with(Vec::new());
    }

    /// Saves the state and `extra` writes in one transaction.
    fn save_with(&self, extra: Vec<optchat_host::StateWrite>) {
        if let Err(e) = self.file.save_with(&self.state, extra) {
            (self.log)(&format!("saving the host state failed: {e}"));
        }
    }

    /// Whether `remote.autoApprove` is on.
    pub fn remote_auto_approve(&self) -> bool {
        self.chief.remote_auto_approve
    }

    /// Changes a per-Chief setting and saves it. `remote.autoApprove` can be
    /// turned on only when no remote-origin work is running, settling or
    /// queued: never by a paired device, nor by a command a remote turn runs
    /// (an approved shell command reaches the host the same way). Turning
    /// it off is always allowed.
    pub fn set_setting(&mut self, key: &str, value: &str) -> Result<String, String> {
        use crate::chief_settings::{CACHE_TTL, REMOTE_AUTO_APPROVE, parse_bool, parse_ttl};
        if key == CACHE_TTL {
            // From the next turn on (the native engine: the next host start).
            let ttl = parse_ttl(value)?;
            let mut next = self.chief;
            next.cache_ttl = Some(ttl);
            next.save(&self.settings.settings_file)
                .map_err(|e| format!("saving {}: {e}", self.settings.settings_file.display()))?;
            self.chief = next;
            self.ttl_refused
                .store(false, std::sync::atomic::Ordering::SeqCst);
            self.turn_cache_ttl();
            (self.log)(&format!("setting {key} = {}", ttl.as_str()));
            return Ok(format!("{key} = {}", ttl.as_str()));
        }
        if key != REMOTE_AUTO_APPROVE {
            return Err(format!(
                "unknown setting {key:?} (known: {REMOTE_AUTO_APPROVE}, {CACHE_TTL})"
            ));
        }
        let on = parse_bool(value)?;
        let remote_queued = self.queue.iter().any(|q| {
            matches!(
                q.source,
                Source::Message {
                    remote: Some(_),
                    ..
                }
            )
        });
        if on && (self.turn_remote || self.remote_taint || remote_queued || self.ask_child_live()) {
            (self.log)("refused: remote.autoApprove on during remote-origin work");
            return Err(
                "refused: remote.autoApprove can be turned on only from the Mac, outside a turn a paired device started"
                    .to_owned(),
            );
        }
        let mut next = self.chief;
        next.remote_auto_approve = on;
        next.save(&self.settings.settings_file)
            .map_err(|e| format!("saving {}: {e}", self.settings.settings_file.display()))?;
        self.chief = next;
        (self.log)(&format!("setting {key} = {on}"));
        Ok(format!("{key} = {on}"))
    }

    fn queue(&mut self, text: String, source: Source) {
        self.queue_with_images(text, Vec::new(), source);
    }

    fn queue_with_images(&mut self, text: String, images: Vec<images::TurnImage>, source: Source) {
        self.queue_in(None, text, images, source);
    }

    /// Queues an item of `conversation` (None: the main one). It interrupts
    /// only a running turn of the same conversation (G9): an item for
    /// another conversation waits and runs when it is the head.
    fn queue_in(
        &mut self,
        conversation: Option<String>,
        text: String,
        images: Vec<images::TurnImage>,
        source: Source,
    ) {
        // Section 9: subagents' reports reach a working Chief between its
        // tool calls; on acpmux that is a stop like a human message's.
        let human = matches!(source, Source::Message { .. } | Source::Spawn(_));
        let same = self.phase == Phase::Running && self.turn_side() == conversation;
        let item = Queued {
            text,
            source,
            images,
            conversation,
        };
        let wakes = item.wakes();
        self.queue.push_back(item);
        if human && same && wakes {
            self.interrupt_for_newer();
        }
        self.maybe_start_turn();
    }

    /// The side conversation of `conversation` (None for the main one).
    fn side_of(&self, conversation: Option<&str>) -> Option<String> {
        conversation
            .filter(|c| self.state.conversation.as_deref() != Some(*c))
            .map(str::to_owned)
    }

    /// The side conversation of the pending turn (None: the main one).
    fn turn_side(&self) -> Option<String> {
        let turn = self.state.turn.as_ref()?;
        self.side_of(turn.conversation.as_deref())
    }

    /// Whether a human message of `conversation` (None: main) is queued.
    fn queued_messages_of(&self, conversation: Option<&str>) -> bool {
        self.queue.iter().any(|q| {
            q.conversation.as_deref() == conversation && matches!(q.source, Source::Message { .. })
        })
    }
}

/// A turn's reply key: `turn:optchat:<first new message id>:<its stamp>`.
/// Ids start again at 0 after a memory reset or a restored backup, while the
/// owner keeps every key it saw, so the id alone would collide (and the
/// owner would refuse or silently replay the reply). The millisecond stamp
/// of message `first` tells the two apart.
fn reply_key(chat: &OptChat, first: u64) -> String {
    reply_key_at(first, &chat.stamp(first).unwrap_or_default())
}

/// `reply_key` from message `first`'s stored date `stamp`.
fn reply_key_at(first: u64, stamp: &str) -> String {
    let stamp: String = stamp.chars().filter(char::is_ascii_digit).collect();
    format!("turn:optchat:{first}:{stamp}")
}

/// A turn reply: `message.send` whose client_msg_id is the turn key, so a
/// retry never posts twice.
/// An outbox entry for `op` under `key`.
fn op_entry(conversation: String, key: &str, op: Op) -> OutboxEntry {
    OutboxEntry {
        conversation,
        idempotency_key: key.to_owned(),
        op,
        rate_retried: false,
        not_before: None,
        attempted: false,
        rate_attempts: 0,
    }
}

fn reply_entry(conversation: String, key: &str, text: &str) -> OutboxEntry {
    let text = if text.len() > REPLY_BYTES {
        let mut cut = REPLY_BYTES;
        while !text.is_char_boundary(cut) {
            cut -= 1;
        }
        format!(
            "{}\n\n[reply cut: {cut} of {} bytes shown]",
            &text[..cut],
            text.len()
        )
    } else {
        text.to_owned()
    };
    OutboxEntry {
        conversation,
        idempotency_key: key.to_owned(),
        op: Op::MessageSend {
            client_msg_id: key.to_owned(),
            parts: vec![Part::Text { text, runs: None }],
            reply_to: None,
        },
        rate_retried: false,
        not_before: None,
        attempted: false,
        rate_attempts: 0,
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
