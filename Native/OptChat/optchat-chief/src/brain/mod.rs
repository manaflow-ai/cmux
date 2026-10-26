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
mod control;
mod drafts;
mod engine_control;
pub mod files;
mod harness_offer;
mod image_fit;
pub mod images;
mod inbox;
pub mod media;
mod mux_ack;
mod outbox;
mod previews;
mod prewarm;
pub mod reaction_wake;
mod recover;
mod replies;
mod reply_ledger;
pub use reply_ledger::{MAX_REPLY_TRIES, NO_REPLY_TAG, REPLY_RETRY_WAITS};
mod send;
mod side;
mod spawns;
mod steer;
mod transcript;
mod turns;
mod wakes;
pub use reaction_wake::{JudgeAsk, ReactionJudge};
pub use replies::{REACTIONS, reaction, tapback};
pub use steer::STEER_DEADLINE;
pub use transcript::{TRANSCRIPT_DEFAULT, TRANSCRIPT_MAX};
pub use turns::stuck_notice;

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
/// The start of [`Brain::run`]'s answer when a signal asked the host to stop.
pub const STOP_REQUESTED: &str = "stop requested";

/// The brain's stop when an update asked the host to hand off when idle
/// (SIGUSR1): it stopped between turns, so the next host cuts nothing.
pub const HANDOFF_WHEN_IDLE: &str = "handed off between turns for an update";

/// How long a handoff request waits for the running turn: past it the host
/// stops anyway and the next host adopts the turn session.
pub(crate) const HANDOFF_DEADLINE: std::time::Duration = std::time::Duration::from_secs(10 * 60);

pub enum Input {
    Daemon(Box<DaemonEvent>),
    Agents(Box<AgentEvent>),
    /// A turn worker settled the view and asks for its turn (None: nothing to
    /// do). `deferred`: it waited SETTLE_BOUND and lines are still building.
    Settled {
        reply: Sender<Option<TurnStart>>,
        deferred: bool,
    },
    /// A turn worker could not settle (shutdown or a failed write).
    SettleFailed,
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
    /// A change of the running turn's run record (`run.rs`).
    Run(Box<crate::run::RunUpdate>),
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
        /// The env's acpmux peer (`OPTCHAT_SUBAGENT_PEER`); None: none.
        peer: Option<String>,
        /// `spawn(place)`: `cloud`, `local` or None (the saved default).
        place: Option<String>,
        reply: Sender<Result<crate::subagents::SpawnPlan, String>>,
    },
    /// A queued subagent's launch, saved in its record.
    SubagentQueued {
        id: String,
        launch: crate::state::QueuedLaunch,
    },
    /// A subagent's session exists (its prompt follows).
    SubagentStarted {
        id: String,
        session_id: String,
        /// The effective session policy (configured policy or spawn floor).
        policy: Option<String>,
    },
    /// A subagent's first prompt (view and task) is sent: its inbox follows.
    SubagentPrompted {
        id: String,
    },
    /// A subagent's task turn started at acpmux: `turn_started` after the
    /// echo of its task prompt `prompt_id` (`Spawner::forward_answer`).
    SubagentTurnStarted {
        id: String,
        prompt_id: String,
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
    /// A cloud subagent holds this sandbox key (agent_keys.rs): revoked once
    /// it has been done for `agent_keys::REVOKE_AFTER_DONE`.
    SubagentAgentKey {
        id: String,
        key_id: String,
    },
    /// The sandbox key of subagent `id` is revoked (its VMs go with it).
    AgentKeyRevoked {
        id: String,
    },
    /// Revoking subagent `id`'s sandbox key failed; the next tick retries.
    AgentKeyRevokeFailed {
        id: String,
    },
    /// The answer of a prompt the host sent a subagent (token use, cost).
    SubagentAnswer {
        id: String,
        answer: Result<serde_json::Value, String>,
    },
    /// An auto-resume of subagent `id` is due (auto_resume.rs): its backoff
    /// passed, or (`after_network`) the network came back (`online`) or
    /// the wait for it ended (`!online`).
    AutoResume {
        id: String,
        attempt: u32,
        reason: String,
        after_network: bool,
        online: bool,
    },
    /// Subagent `id`, whose account hit a usage limit, continues in a new
    /// session on `harness` (auto_resume.rs `Decision::Move`).
    AutoMove {
        id: String,
        harness: String,
    },
    /// The acpmux session of subagent `id` (`zoom("a<N>")`), None when
    /// there is no such subagent or it has none yet.
    SubSession {
        id: String,
        reply: Sender<Option<String>>,
    },
    /// The running turn's view as its subagents get it (`spawn`): None
    /// outside a turn.
    TurnView {
        reply: Sender<Option<String>>,
    },
    /// `tell(id, message, key, queue)`.
    Tell {
        id: String,
        message: String,
        key: Option<String>,
        /// Wait for the running turn instead of interrupting it.
        queue: bool,
        reply: Sender<Result<String, String>>,
    },
    /// `react(id, reaction)` (replies.rs).
    React {
        id: u64,
        reaction: String,
        reply: Sender<Result<String, String>>,
    },
    /// `transcript(n, before)` (transcript.rs): the conversation as the
    /// daemon stores it; the answer goes to `reply`.
    Transcript {
        n: u32,
        before: Option<u64>,
        reply: Sender<Result<String, String>>,
    },
    /// `reply(id, text)` (replies.rs): the answer goes to `reply`.
    Reply {
        id: u64,
        text: String,
        reply: Sender<Result<String, String>>,
    },
    /// A tell's steer into subagent `id`'s running turn in `session` was
    /// refused (its agent cannot steer now): the brain interrupts the turn
    /// and sends `message` as its next prompt (spawns.rs `tell_unsteered`).
    TellUnsteered {
        id: String,
        session: String,
        message: String,
    },
    /// `send(text, attachments, reply_to)` (send.rs).
    Send {
        call: crate::tools::SendCall,
        reply: Sender<Result<String, String>>,
    },
    /// `stop()` (wakes.rs): ends the running turn.
    StopTurn {
        reply: Sender<Result<String, String>>,
    },
    /// `sleep(seconds, note, until)` (wakes.rs).
    Sleep {
        call: crate::tools::SleepCall,
        reply: Sender<Result<String, String>>,
    },
    /// A message from a Chief on another machine (peer_chiefs.rs), already
    /// framed as `[chief:<name>] ...`: queued as a note that wakes the Chief.
    PeerChiefNote {
        text: String,
    },
    /// `escalate_auth` from subagent `agent` (control.rs): an urgent note.
    EscalateAuth {
        agent: String,
        request: crate::tools::AuthEscalation,
        reply: Sender<Result<String, String>>,
    },
    /// `peers` from subagent `caller` (acp-chief-issues.md #11).
    PeerList {
        caller: String,
        reply: Sender<Result<String, String>>,
    },
    /// `tell` from subagent `from` to subagent `id`.
    PeerTell {
        from: String,
        id: String,
        message: String,
        key: Option<String>,
        reply: Sender<Result<String, String>>,
    },
    /// A tell to a running subagent that neither its steer nor the prompt
    /// after it delivered (acp-chief-issues.md #10): it goes back into the
    /// subagent's inbox, first, for its next prompt.
    TellUndelivered {
        id: String,
        message: String,
        error: String,
    },
    /// `control(action, ...)` (control.rs).
    Control {
        request: crate::tools::ControlCall,
        reply: Sender<Result<String, String>>,
    },
    /// Once a minute while subagents work: stuck detection (control.rs).
    SubTick,
    /// Changes a per-Chief setting (`chief_settings`).
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
    /// Whether the turn may run a Chief tool with these arguments
    /// (`Brain::turn_gate`).
    TurnGate {
        tool: String,
        input: serde_json::Value,
        reply: Sender<Result<(), String>>,
    },
    /// The reaction classifier's answer for decision `id` on Chief message
    /// `seq` (reaction_wake.rs).
    ReactionJudged {
        seq: u64,
        id: u64,
        answer: Result<String, String>,
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
    /// SIGTERM, SIGINT or SIGHUP to the host: the brain stops taking input
    /// and returns [`STOP_REQUESTED`] (E20).
    Shutdown {
        signal: i32,
    },
    /// Every few seconds while cloud VMs are set: pauses idle ones
    /// (`cloud.autoPauseIdleSeconds`).
    CloudTick,
    /// Fleet job `job`, which cloud subagent `id` waits on, ended in `state`.
    FleetJobFinished {
        id: String,
        job: String,
        state: String,
    },
    /// The fleet poll of subagent `id`'s jobs ended.
    FleetPolled {
        id: String,
    },
    /// The pool tool refused to pause `peer` (busy there): it is tried again.
    CloudPauseFailed {
        peer: String,
    },
    /// A finished subagent's own VM `peer` is deleted (its work was pushed).
    CloudVmDeleted {
        peer: String,
    },
    /// Deleting `peer` was refused (unpushed work) or failed: tried again
    /// after another reap wait.
    CloudVmDeleteFailed {
        peer: String,
    },
    /// Subagent `id`'s own VM could not be made (`why`): it runs on this host.
    SubagentPlacedHere {
        id: String,
        why: String,
    },
    /// SIGUSR1 to the host: an update replaced the app, so the brain stops
    /// once no turn runs ([`HANDOFF_WHEN_IDLE`]); the app then hands acpmux
    /// off and starts the next host.
    HandoffWhenIdle,
    /// chief.stop: stops the running turn as a newer message does;
    /// answers `{"stopped": bool}`.
    Stop {
        reply: Sender<serde_json::Value>,
    },
    /// chief.stop {name}: stops ONE subagent at work (or queued), the turn
    /// and the other subagents going on; answers `{"stopped": bool, ...}`.
    StopSubagent {
        name: String,
        reply: Sender<serde_json::Value>,
    },
    /// chief.stop {all: true} ("Stop all agents"): the running turn and
    /// every subagent at work or queued; answers `{"stopped": bool,
    /// "subagents": [ids]}`.
    StopAll {
        reply: Sender<serde_json::Value>,
    },
    /// chief.stop {restart: [ids]} (Restart on the stop-all toast): those
    /// subagents go on; answers `{"restarted": [ids], "errors": [...]}`.
    RestartSubagents {
        names: Vec<String>,
        reply: Sender<serde_json::Value>,
    },
    /// The link preview thread's answer for reply `key`: its parts with the
    /// cards filled (pictures uploaded), or None when no line qualifies (the
    /// reply stays its text).
    Previews {
        key: String,
        parts: Option<Vec<cmux_conversation::Part>>,
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
        speed: Option<String>,
        compactor_speed: Option<String>,
        compactor_harness: Option<String>,
        compactor_model: Option<String>,
        /// The reaction classifier's fields (reaction_wake.rs).
        reactions: Box<ReactionFields>,
    },
}

/// The reaction-wake fields of an engine set (engine.json
/// `classifier_harness`, `classifier_model`, `classifier_prompt`,
/// `reactions_can_wake`): an absent field stays; `default` clears one.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ReactionFields {
    pub classifier_harness: Option<String>,
    pub classifier_model: Option<String>,
    pub classifier_prompt: Option<String>,
    /// `true`, `false` or `default`.
    pub reactions_can_wake: Option<String>,
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
    /// A turn with no harness event for this long ends with a typed error
    /// and runs once again (`OPTCHAT_CHIEF_TURN_IDLE_MIN`, default 10).
    pub turn_idle_limit: Option<Duration>,
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
    /// Reads the person's Home workspace for each turn (`home_view`); None: no block.
    pub home_view: Option<crate::home_view::HomeView>,
    /// Who this Chief is in the conversations and which messages wake it.
    pub membership: crate::membership::Membership,
    /// Keep a Claude turn's Claude Code session after the turn and prompt it
    /// again with only the next turn's new messages while the frozen view
    /// holds (the Unii baseline's one process: no spawn, a fully cached
    /// prefix). The session runs with Claude Code's own cache marks.
    /// `CHIEF_KEEP_TURN_SESSION=0` turns it off.
    pub keep_turn_session: bool,
}

/// The longest a turn waits for view lines that are still building
/// (chief 2026-10-10: 10 s; hq-6d 2026-10-14, Lawrence "the chief responds
/// too slow": 1 s, the turn starts and the compactor catches up after);
/// then it reads them unsummarized and the next turn gets their summaries.
pub const SETTLE_BOUND: Duration = Duration::from_secs(1);
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
    /// Already logged as `user` (a steer on a harness that answers at the
    /// turn's end, which then failed): the next turn takes it without
    /// logging it again.
    logged: bool,
}

impl Queued {
    /// It starts a turn (and stops a working one); a stopped subagent's
    /// report does not, and waits for the next turn.
    fn wakes(&self) -> bool {
        !matches!(&self.source, Source::Spawn(r) if r.quiet)
    }

    fn requires_approval(&self) -> bool {
        matches!(
            self.source,
            Source::Message {
                requires_approval: true,
                ..
            } | Source::Resume {
                requires_approval: true,
                ..
            } | Source::Spawn(crate::state::SpawnRef {
                requires_approval: true,
                ..
            })
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Source {
    /// A human message of the Chief conversation; `remote` names the paired
    /// install that sent it (the relay's origin), None for a local one.
    /// `requires_approval` is true for every author other than the Chief's
    /// owner, even when the message is otherwise allowed to wake the Chief.
    Message {
        seq: u64,
        /// The message's id (a side floor's crash dedupe).
        id: String,
        remote: Option<String>,
        requires_approval: bool,
    },
    /// A child's report; its record turns `Reported` with this floor when logged.
    Child { session_id: String, floor: u64 },
    /// Anything else (a child's permission request).
    Note,
    /// A subagent's report (section 9).
    Spawn(crate::state::SpawnRef),
    /// The note that resumes a turn a host stop cut (`HostState::resumes`),
    /// with the cut messages' full text for the turn's prompt.
    Resume {
        remote: bool,
        requires_approval: bool,
        cut: Vec<String>,
    },
}

#[derive(Clone, Debug, PartialEq, Eq)]
enum Phase {
    Idle,
    /// A worker waits for the view to settle.
    Settling,
    Running,
}

pub type Log = Arc<dyn Fn(&str) + Send + Sync>;

/// The longest the Chief waits for a turn session the next acpmux adopted
/// (an update relaunch) to end before it folds and ends it.
pub(crate) const ORPHAN_WAIT: std::time::Duration = std::time::Duration::from_secs(30 * 60);

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
    /// The owner stopped the running turn (chief.stop): its end posts nothing.
    owner_stopped: bool,
    /// The running turn's interrupt (a new one per turn).
    interrupt: Arc<crate::turn::Interrupt>,
    /// The steer on its way into the running turn (`steer.rs`), and the
    /// last steer's number.
    steering: Vec<steer::Steering>,
    steer_seq: u64,
    /// A draft could not be published (logged once).
    draft_failed: bool,
    /// A run append failed once: later failures are not logged.
    run_failed: bool,
    /// A live frame (`chief-live-v1`) failed once: later failures are not logged.
    live_failed: bool,
    /// What the owner took of each streamed step (renumbers, restarts after a failure).
    live_streams: crate::run::LiveStreams,
    /// The attachments uploaded for the running turn's steps (turn key, step id):
    /// every later append of the step names them again (a step is replaced whole).
    run_attachments: HashMap<(String, String), Vec<serde_json::Value>>,
    /// The owner said once that it takes no typing indicator (cloud).
    typing_unsupported: bool,
    after_turn: Option<TurnHook>,
    /// Notices waiting for the conversation to be known.
    notices: Vec<(String, String)>,
    /// Notice keys already handled (each is posted once per process).
    noticed: HashSet<String>,
    /// Claude Code refused a turn's cache marker (it placed a fourth
    /// breakpoint of its own): later turns go without it.
    marker_refused: crate::prompt::MarkLatch,
    /// A route refused a 1-hour cache mark: turns go at 5 minutes until the
    /// host restarts or `cache.ttl` is set again.
    ttl_refused: Arc<std::sync::atomic::AtomicBool>,
    /// The TTL the session settings held when the pool was last hinted: a
    /// pooled session runs Claude Code with it.
    prewarm_ttl: Option<crate::prompt::CacheTtl>,
    /// Whether the pool was last hinted for a turn with our mark (Claude
    /// Code's own marks off, `session_dir::set_session_cache`).
    prewarm_ours: Option<bool>,
    /// The turn session the last turn kept (`Settings::keep_turn_session`).
    kept: Option<turns::KeptTurn>,
    /// The running turn's keep check: its key and the session shape.
    keep_pending: Option<(String, u64)>,
    /// This turn's TTL differs from `prewarm_ttl` (cache.ttl changed).
    ttl_stale: Arc<std::sync::atomic::AtomicBool>,

    /// The monitoring trace (`trace.rs`).
    pub(crate) trace: crate::trace::Trace,
    /// Where subagents' workspaces are renamed when they finish.
    workspaces: Option<Arc<dyn crate::workspaces::Workspaces>>,
    /// Starts a queued subagent by id (`Spawner::queue_starter`).
    sub_starter: Option<Sender<crate::subagents::QueuedStart>>,
    /// B4: the VMs behind cloud peers, how long a peer idles before its VM
    /// pauses, the peers paused by this host and since when each idles.
    cloud_vms: Option<std::sync::Arc<dyn crate::cloud_vms::CloudVms>>,
    cloud_idle: std::time::Duration,
    cloud_paused: std::collections::BTreeSet<String>,
    cloud_idle_since: std::collections::BTreeMap<String, u64>,
    /// One VM per subagent: how long a finished subagent's own VM stays
    /// (paused) before it is deleted, since when each is done, and the
    /// deletes in flight.
    cloud_reap: std::time::Duration,
    cloud_reaping: std::collections::BTreeSet<String>,
    /// The fleet controller cloud subagents' `fleet-wait` jobs are read
    /// from (fleet_wait.rs), how often, when last, and the subagents whose
    /// poll is running.
    fleet: Option<std::sync::Arc<dyn crate::fleet_wait::FleetJobs>>,
    fleet_every: std::time::Duration,
    fleet_polled_ms: u64,
    fleet_polling: std::collections::BTreeSet<String>,
    /// Revokes cloud subagents' sandbox keys (agent_keys.rs); since when each
    /// keyed subagent is done, and the revokes in flight.
    agent_keys: Option<std::sync::Arc<dyn crate::agent_keys::AgentKeys>>,
    agent_key_done_since: std::collections::BTreeMap<String, u64>,
    agent_key_revoking: std::collections::BTreeSet<String>,
    /// How long a keyed subagent stays done before its key is revoked.
    agent_key_grace: std::time::Duration,
    /// Most subagents at work at once (`subagents::live_limit`); None: no cap.
    max_live: Option<usize>,
    /// The wall clock (ms since the epoch) the subagent watch reads; tests
    /// set their own (`set_clock`).
    clock: Arc<dyn Fn() -> u64 + Send + Sync>,
    /// Each running subagent's folded events (sub_watch.rs), by id: kept
    /// between ticks so each tick reads only the new events.
    watches: HashMap<String, crate::sub_watch::Watch>,
    /// A finished subagent's workspace closes instead of taking the done
    /// mark (`OPTCHAT_SUBAGENT_ON_FINISH=close`).
    sub_close_on_finish: bool,
    /// Auto-resume of subagents that stopped on an error (auto_resume.rs);
    /// None: off (`OPTCHAT_AUTO_RESUME=off`).
    resume_policy: Option<crate::auto_resume::ResumePolicy>,
    /// Whether the model endpoint answers (a network stop waits for it).
    reach: Arc<dyn crate::auto_resume::Reachability>,
    /// The previous turn's view, to measure how much of it stayed (cache).
    prev_view: Option<String>,
    /// When the current settle wait and turn began.
    settle_clock: Option<Instant>,
    /// Where a turn waiting for the compactor says how far it is.
    settle_status: Option<Arc<crate::settle_status::SettleStatus>>,
    /// A Chief that is not the default: a compactor fault is also its message.
    compactor_messages: bool,
    turn_clock: Option<Instant>,
    /// The running turn's view with its new messages, what a `spawn` in it
    /// gives its subagents (no wait for the compactor to summarize the
    /// turn's own messages and tool calls).
    turn_view: Option<String>,
    /// The running turn's engine (engine.rs), for the trace.
    turn_engine: Option<crate::engine::TurnEngine>,
    /// The per-Chief settings (`chief_settings`), owned by the host.
    chief: crate::chief_settings::ChiefSettings,
    /// The running turn carries another person's text: it runs with policy
    /// `ask`, and every local effect it asks for is refused at once.
    turn_ask: bool,
    /// The last turn was an ask turn: a tool call of it that reaches the
    /// host after it ended is still held to its rules (`turn_gate`) until
    /// the next turn starts.
    last_turn_ask: bool,
    /// Requests refused in the running turn (`approval::signature`): a
    /// repeat counts toward stopping the turn.
    turn_denied: Vec<String>,
    /// Requests of the running turn denied again because they repeat one
    /// already denied (`approvals::REPEATS_BEFORE_STOP` stops the turn).
    repeat_denials: u32,
    /// Writes the log's description of each turn image (None: references only).
    describer: Option<Arc<dyn images::Describe>>,
    /// A user's reaction that may wake the Chief (reaction_wake.rs).
    reaction_wake: reaction_wake::State,
    /// Images being described now (`conversation/hash`), started once each.
    describing: HashSet<String>,
    /// Highest seq handled (queued or skipped) of each side conversation;
    /// its saved floor follows once nothing of it is queued (`handled` for
    /// the main conversation).
    side_handled: HashMap<String, u64>,
    /// Woken conversations not acked yet: the highest woken seq of each
    /// (`mux_ack.rs`).
    mux_pending: HashMap<String, u64>,
    /// Local side conversations (`membership`), from the last summary seen:
    /// None when the Chief is not in it (its messages are not read), else
    /// each participant and whether it is a person.
    side_member: HashMap<String, Option<HashMap<String, bool>>>,
    /// The thread a reply to a waking group message goes into, by message
    /// id: `(thread_root, parent)` (`membership::thread_target`). In memory
    /// only: after a restart such a reply goes to the top level.
    reply_threads: HashMap<String, (String, String)>,
    /// The seq of each user message of the Chief conversation, by id, and
    /// the newest seq it has (any author): whether a reply would sit right
    /// under the message it answers (`replies.rs`). In memory only: after a
    /// restart an unknown message counts as not the newest.
    message_seqs: HashMap<String, u64>,
    newest_seq: u64,
    /// The keys of the reactions this host posted (`react` dedupe, besides
    /// the message's own reactions).
    reacted: std::collections::HashSet<String>,
    /// The idempotency keys of this run's `send` calls (send.rs): a repeat
    /// of one in the same turn is a noop even after the owner took it.
    sent_keys: std::collections::HashSet<String>,
    /// The running turn was ended by the Chief's own `stop` or `sleep`
    /// (wakes.rs): its final text is not posted, and it is no failure.
    tool_stopped: bool,
    /// The running turn was stopped for asking again and again for a tool
    /// call it was denied (approvals.rs): later requests are denied, and the
    /// turn posts one line saying so (what it asked for) instead of its text.
    denial_stopped: Option<(String, approvals::DenyWhy)>,
    /// Permission requests the host left open, denied once overdue
    /// (`approvals::deny_overdue_permissions_at`).
    unanswered: Vec<approvals::Unanswered>,
    /// Subagent prompts whose refused allow the person was told about
    /// (`control answer`): the line is posted once per prompt.
    approval_told: HashSet<String>,
    /// Fetches link previews for replies' URL lines (None: replies stay text).
    previewer: Option<Arc<dyn crate::link_preview::Fetcher>>,
    /// Turns cut in a row by a lost acpmux link (`Brain::turn_cut`): past
    /// `turns::MAX_CUTS` the next one fails as before, never a loop.
    cuts: u32,
    /// While set, an adopted turn session still runs and no turn starts; at
    /// this time it is folded and ended anyway (`children::adopt_orphans`).
    orphan_wait: Option<Instant>,
    /// When a turn an upstream error cut may run again (None: now).
    resume_at: Option<Instant>,
    /// The waits before such a turn runs again (`turns::UPSTREAM_RESUME_BACKOFF`).
    upstream_backoff: Vec<std::time::Duration>,
    /// An update asked for a handoff: the brain stops between turns, at
    /// the latest at this deadline.
    handoff_at: Option<Instant>,
    handoff_wait: std::time::Duration,
    /// How long a person's message steered into the running turn may stay
    /// unread before the turn is interrupted (`steer.rs`); None: it waits
    /// for the turn's next tool boundary.
    steer_deadline: Option<Duration>,
    /// When that deadline passes, and for which turn.
    steer_due: Option<(Instant, String)>,
    /// The waits between reply checks (`reply_ledger::REPLY_RETRY_WAITS`).
    reply_waits: Vec<Duration>,
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
        let mut brain = Brain {
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
            steering: Vec::new(),
            steer_seq: 0,
            draft_failed: false,
            run_failed: false,
            live_failed: false,
            live_streams: Default::default(),
            run_attachments: HashMap::new(),
            typing_unsupported: false,
            marker_refused: crate::prompt::MarkLatch::default(),
            ttl_refused: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            prewarm_ttl: None,
            prewarm_ours: None,
            kept: None,
            keep_pending: None,
            ttl_stale: Arc::new(std::sync::atomic::AtomicBool::new(false)),
            chief,
            turn_ask: false,
            last_turn_ask: false,
            turn_denied: Vec::new(),
            repeat_denials: 0,
            after_turn: None,
            notices: Vec::new(),
            noticed: HashSet::new(),
            trace: crate::trace::Trace::off(),
            workspaces: None,
            sub_starter: None,
            cloud_vms: None,
            cloud_idle: std::time::Duration::from_secs(chief.cloud_auto_pause_idle_secs),
            cloud_paused: Default::default(),
            cloud_idle_since: Default::default(),
            cloud_reap: std::time::Duration::from_secs(
                chief.cloud_delete_after_paused_days * 86_400,
            ),
            cloud_reaping: Default::default(),
            fleet: None,
            fleet_every: std::time::Duration::from_secs(30),
            fleet_polled_ms: 0,
            fleet_polling: Default::default(),
            agent_keys: None,
            agent_key_done_since: Default::default(),
            agent_key_revoking: Default::default(),
            agent_key_grace: crate::agent_keys::REVOKE_AFTER_DONE,
            max_live: None,
            clock: Arc::new(now_ms),
            watches: HashMap::new(),
            sub_close_on_finish: false,
            resume_policy: Some(crate::auto_resume::ResumePolicy::default()),
            reach: Arc::new(crate::auto_resume::TcpProbe::from_env(
                |k| std::env::var(k).ok(),
                std::env::var_os("HOME")
                    .map(std::path::PathBuf::from)
                    .as_deref(),
            )),
            prev_view: None,
            settle_clock: None,
            settle_status: None,
            compactor_messages: false,
            turn_clock: None,
            turn_view: None,
            turn_engine: None,
            describer: None,
            reaction_wake: reaction_wake::State::default(),
            describing: HashSet::new(),
            side_handled: HashMap::new(),
            mux_pending: HashMap::new(),
            side_member: HashMap::new(),
            reply_threads: HashMap::new(),
            message_seqs: HashMap::new(),
            newest_seq: 0,
            reacted: std::collections::HashSet::new(),
            sent_keys: std::collections::HashSet::new(),
            tool_stopped: false,
            denial_stopped: None,
            unanswered: Vec::new(),
            approval_told: HashSet::new(),
            previewer: None,
            cuts: 0,
            resume_at: None,
            orphan_wait: None,
            upstream_backoff: turns::UPSTREAM_RESUME_BACKOFF.to_vec(),
            handoff_at: None,
            handoff_wait: HANDOFF_DEADLINE,
            steer_deadline: None,
            steer_due: None,
            reply_waits: reply_ledger::REPLY_RETRY_WAITS.to_vec(),
        };
        // Each cut turn runs again first, on the reference client's note;
        // its messages are in the log already and are not logged again.
        let resumes = brain.state.resumes.clone();
        for resume in resumes {
            brain.queue.push_back(Queued {
                text: recover::RESUMED.to_owned(),
                source: Source::Resume {
                    remote: resume.remote,
                    requires_approval: resume.requires_approval,
                    cut: resume.messages,
                },
                images: Vec::new(),
                conversation: resume.conversation,
                logged: false,
            });
        }
        brain.rearm_reply_checks();
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

    /// A compactor fault is also posted as this Chief's message (a Chief whose
    /// home the app does not watch for `state/compactor.json`).
    pub fn with_compactor_messages(mut self, on: bool) -> Brain {
        self.compactor_messages = on;
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

    /// Auto-resume of subagents that stop on an error (None: off), and the
    /// probe a network stop waits on.
    pub fn set_auto_resume(
        &mut self,
        policy: Option<crate::auto_resume::ResumePolicy>,
        reach: Option<Arc<dyn crate::auto_resume::Reachability>>,
    ) {
        self.resume_policy = policy;
        if let Some(reach) = reach {
            self.reach = reach;
        }
    }

    /// Where queued subagents are started when a slot frees.
    pub fn set_sub_starter(&mut self, starter: Option<Sender<crate::subagents::QueuedStart>>) {
        // A host that runs subagents checks them for stuck runs.
        if starter.is_some() && self.sub_starter.is_none() {
            control::start_ticker(self.tx.clone());
        }
        self.sub_starter = starter;
    }

    /// The VMs behind cloud peers: resumed before a cloud subagent starts,
    /// paused after `idle` with no cloud subagent on them (B4).
    pub fn set_cloud_vms(
        &mut self,
        vms: Option<std::sync::Arc<dyn crate::cloud_vms::CloudVms>>,
        idle: std::time::Duration,
    ) {
        // A host that runs cloud subagents checks its VMs every few seconds.
        if vms.is_some() && self.cloud_vms.is_none() {
            control::start_cloud_ticker(self.tx.clone());
        }
        self.cloud_vms = vms;
        self.cloud_idle = idle;
    }

    /// How long a finished subagent's own VM is kept (paused) before it is
    /// deleted (`cloud.deleteAfterPausedDays`, default 7 days).
    pub fn set_fleet_jobs(
        &mut self,
        fleet: Option<std::sync::Arc<dyn crate::fleet_wait::FleetJobs>>,
        every: std::time::Duration,
    ) {
        self.fleet = fleet;
        self.fleet_every = every;
    }

    pub fn set_cloud_reap(&mut self, after: std::time::Duration) {
        self.cloud_reap = after;
    }

    /// Revokes cloud subagents' sandbox keys once they are done for a while.
    /// `grace`: how long a subagent stays done before its key is revoked
    /// (`agent_keys::REVOKE_AFTER_DONE` on a host).
    pub fn set_agent_keys(
        &mut self,
        keys: Option<std::sync::Arc<dyn crate::agent_keys::AgentKeys>>,
        grace: std::time::Duration,
    ) {
        if keys.is_some() && self.agent_keys.is_none() && self.cloud_vms.is_none() {
            control::start_cloud_ticker(self.tx.clone());
        }
        self.agent_keys = keys;
        self.agent_key_grace = grace;
    }

    /// How long a finished subagent's own VM stays paused before it is
    /// deleted (`cloud.deleteAfterPausedDays`).
    pub fn cloud_delete_after_paused(&self) -> std::time::Duration {
        self.cloud_reap
    }

    /// `cloud.autoPauseIdleSeconds`: how long a cloud VM idles before it
    /// pauses.
    pub fn cloud_auto_pause_idle(&self) -> std::time::Duration {
        std::time::Duration::from_secs(self.chief.cloud_auto_pause_idle_secs)
    }

    /// The clock the subagent watch reads (ms since the epoch).
    pub fn set_clock(&mut self, clock: Arc<dyn Fn() -> u64 + Send + Sync>) {
        self.clock = clock;
    }

    /// Caps the subagents at work at once (None: no cap, the default).
    pub fn set_max_live(&mut self, limit: Option<usize>) {
        self.max_live = limit;
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
            && self.steering.is_empty()
            && !self.reaction_wake.busy()
    }

    /// When the outbox timer fires, if armed.
    pub fn next_timer(&self) -> Option<Instant> {
        [
            self.outbox_timer,
            self.resume_at,
            self.orphan_wait,
            self.handoff_at,
            self.steer_due.as_ref().map(|(at, _)| *at),
            self.reaction_wake.due(),
        ]
        .into_iter()
        .flatten()
        .min()
    }

    /// Runs until a fatal error; returns it.
    pub fn run(mut self, rx: Receiver<Input>) -> String {
        self.rearm_auto_resumes();
        loop {
            if let Some(fatal) = &self.fatal {
                return fatal.clone();
            }
            // The `sleep` wakes run on the same loop (wakes.rs); they stay
            // out of `next_timer`, which waits only for the outbox and resume.
            // So does the watch on permission requests nobody answers
            // (approvals.rs).
            let timer = [
                self.next_timer(),
                self.next_wake(),
                self.next_unanswered_due(),
                self.next_reply_due(),
            ]
            .into_iter()
            .flatten()
            .min();
            let input = match timer {
                Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                    Ok(input) => input,
                    Err(RecvTimeoutError::Timeout) => {
                        self.on_timer();
                        self.fire_wakes_at(now_ms());
                        self.fire_reply_checks_at(now_ms());
                        let now = (self.clock)();
                        self.deny_overdue_permissions_at(now);
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
            Input::Settled { reply, deferred } => {
                let start = self.settled(deferred);
                let _ = reply.send(start);
            }
            Input::SettleFailed => {
                self.phase = Phase::Idle;
                let status = self.chat.status();
                if let Some(fatal) = status.fatal {
                    self.fatal = Some(format!("the memory stopped writing: {fatal}"));
                }
            }
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
            Input::Run(update) => self.turn_run(*update),
            Input::Steered { id, result } => self.steered(id, result),
            Input::TurnEnded { key, outcome } => self.turn_ended(&key, *outcome),
            Input::Notice { key, text } => self.notice(key, text),
            Input::CompactorStatus(status) => self.compactor_status(status),
            Input::SpawnRegister {
                tasks,
                peer,
                place,
                reply,
            } => {
                // `cloud:SIZE`: on the cloud, at that VM size.
                let (place, size) = match place.as_deref().and_then(|p| p.split_once(':')) {
                    Some((p, s)) => (Some(p.to_owned()), Some(s.to_owned())),
                    None => (place, None),
                };
                let plan = self
                    .spawn_peer(peer.as_deref(), place.as_deref())
                    .and_then(|peers| {
                        self.register_spawn_sized(&tasks, &peers, place.as_deref(), size.as_deref())
                    });
                let _ = reply.send(plan);
            }
            Input::SubagentQueued { id, launch } => self.sub_queued(&id, launch),
            Input::SubagentStarted {
                id,
                session_id,
                policy,
            } => self.sub_started(&id, session_id, policy),
            Input::SubagentPrompted { id } => {
                self.sub_prompted(&id);
                self.stop_if_cancelled(&id);
            }
            Input::SubagentTurnStarted { id, prompt_id } => self.sub_turn_started(&id, &prompt_id),
            Input::SubagentWorkspace { id, key, name } => self.sub_workspace(&id, key, name),
            Input::SubagentFailed { id, error } => self.sub_failed(&id, &error),
            Input::SubagentAgentKey { id, key_id } => self.sub_agent_key(&id, key_id),
            Input::AgentKeyRevoked { id } => self.agent_key_revoked(&id),
            Input::AgentKeyRevokeFailed { id } => self.agent_key_revoke_failed(&id),
            Input::SubagentAnswer { id, answer } => self.sub_answer(&id, &answer),
            Input::AutoResume {
                id,
                attempt,
                reason,
                after_network,
                online,
            } => self.auto_resume_due(&id, attempt, &reason, after_network, online),
            Input::AutoMove { id, harness } => self.auto_move_due(&id, &harness),
            Input::TurnView { reply } => {
                let _ = reply.send(self.turn_view.clone());
            }
            Input::SubSession { id, reply } => {
                let session = self.state.sub(&id).and_then(|(_, s)| s.session_id.clone());
                let _ = reply.send(session);
            }
            Input::Tell {
                id,
                message,
                key,
                queue,
                reply,
            } => {
                let answer = self.tell_with(&id, &message, key.as_deref(), queue);
                let _ = reply.send(answer);
            }
            Input::React {
                id,
                reaction,
                reply,
            } => {
                let _ = reply.send(self.react(id, &reaction));
            }
            Input::Reply { id, text, reply } => {
                let _ = reply.send(self.reply_now(id, &text));
            }
            Input::Transcript { n, before, reply } => {
                let _ = reply.send(self.transcript(n, before));
            }
            Input::TellUnsteered {
                id,
                session,
                message,
            } => self.tell_unsteered(&id, &session, &message),
            Input::Send { call, reply } => {
                let _ = reply.send(self.send(call));
            }
            Input::StopTurn { reply } => {
                let _ = reply.send(self.stop_turn());
            }
            Input::Sleep { call, reply } => {
                let _ = reply.send(self.sleep(call));
            }
            Input::PeerChiefNote { text } => self.queue(text, Source::Note),
            Input::EscalateAuth {
                agent,
                request,
                reply,
            } => {
                let _ = reply.send(self.escalate_auth(&agent, &request));
            }
            Input::PeerList { caller, reply } => {
                let _ = reply.send(Ok(self.agents_list(&caller)));
            }
            Input::PeerTell {
                from,
                id,
                message,
                key,
                reply,
            } => {
                let _ = reply.send(self.peer_tell(&from, &id, &message, key.as_deref()));
            }
            Input::TellUndelivered { id, message, error } => {
                self.tell_undelivered(&id, message, &error);
            }
            Input::Control { request, reply } => {
                let answer = self.control(&request);
                let _ = reply.send(answer);
            }
            Input::CloudTick => {
                self.cloud_tick();
                self.agent_key_tick();
                self.cloud_reap_tick();
                self.fleet_tick();
            }
            Input::FleetJobFinished { id, job, state } => {
                self.fleet_job_finished(&id, &job, &state)
            }
            Input::FleetPolled { id } => {
                self.fleet_polling.remove(&id);
            }
            Input::CloudPauseFailed { peer } => self.cloud_pause_failed(&peer),
            Input::CloudVmDeleted { peer } => self.cloud_vm_deleted(&peer),
            Input::CloudVmDeleteFailed { peer } => self.cloud_vm_delete_failed(&peer),
            Input::SubagentPlacedHere { id, why } => self.sub_placed_here(&id, &why),
            Input::SubTick => {
                self.sub_tick();
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
            Input::TurnGate { tool, input, reply } => {
                let _ = reply.send(self.turn_gate(&tool, &input));
            }
            Input::Described { image, description } => self.described(&image, description),
            Input::ReactionJudged { seq, id, answer } => self.reaction_judged(seq, id, answer),
            Input::Engine { request, reply } => {
                let _ = reply.send(self.engine_control(request));
            }
            Input::Stop { reply } => {
                let _ = reply.send(self.owner_stop());
            }
            Input::Shutdown { signal } => {
                (self.log)(&format!("signal {signal}: stopping"));
                // The Chief goes away: its idle cloud VMs pause now.
                self.cloud_shutdown();
                self.fatal = Some(format!("{STOP_REQUESTED} (signal {signal})"));
            }
            Input::HandoffWhenIdle => {
                if self.handoff_at.is_none() {
                    (self.log)("an update asks for a handoff: stopping once no turn runs");
                    self.handoff_at = Some(Instant::now() + self.handoff_wait);
                }
                self.handoff_if_idle();
            }
            Input::StopSubagent { name, reply } => {
                let _ = reply.send(self.stop_subagent(&name));
            }
            Input::StopAll { reply } => {
                let _ = reply.send(self.stop_all());
            }
            Input::RestartSubagents { names, reply } => {
                let _ = reply.send(self.restart_subagents(&names));
            }
            Input::Previews { key, parts } => self.previews_fetched(&key, parts),
        }
    }

    /// Whether a turn can start now: the memory writes, and the engine's
    /// owner is connected (the native engine needs no acpmux).
    fn ready(&self) -> bool {
        self.fatal.is_none()
            && (self.agents_up || matches!(self.settings.engine, Engine::Native(_)))
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

    /// cx-oqnw3: a compactor fault is a system notice (the app reads
    /// `state/compactor.json`), never a Chief message; a good probe removes
    /// it, and retracts a notice an older build posted as a message (cx-1hpt).
    fn compactor_status(&mut self, status: Result<(), String>) {
        if let Some(settle) = &self.settle_status {
            settle.compactor_fault(status.as_ref().err().map(String::as_str));
        }
        match status {
            Err(text) if self.compactor_messages && self.state.compactor_notice.is_none() => {
                let key = format!("notice:optchat:compactor:{}", now_ms());
                self.state.compactor_notice = Some(crate::state::PostedNotice {
                    key: key.clone(),
                    message_id: None,
                });
                self.save();
                self.notice(key, text);
            }
            Err(text) => (self.log)(&text),
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
        let now = Instant::now();
        if self.handoff_at.is_some_and(|at| at <= now) && self.fatal.is_none() {
            (self.log)("the turn ran past the handoff deadline; stopping, the next host adopts it");
            self.fatal = Some(format!("{HANDOFF_WHEN_IDLE} (deadline)"));
            return;
        }
        if self.outbox_timer.is_some_and(|at| at <= now) {
            self.outbox_timer = None;
            self.flush_outbox();
        }
        self.on_resume_timer();
        self.on_steer_deadline(now);
        self.reaction_timer(now);
        if self.orphan_wait.is_some_and(|at| at <= now) {
            (self.log)("an adopted turn session ran past its wait; folding and ending it");
            self.adopt_orphans(true);
            self.maybe_start_turn();
        }
    }

    /// Sets how long a handoff request waits for the running turn (tests
    /// shorten it).
    pub fn set_handoff_deadline(&mut self, wait: std::time::Duration) {
        self.handoff_wait = wait;
    }

    /// A handoff was asked and no turn runs (none in flight, no adopted turn
    /// session it waits for): the brain stops. True when it stopped.
    pub(super) fn handoff_if_idle(&mut self) -> bool {
        if self.handoff_at.is_none() || self.phase != Phase::Idle || self.orphan_wait.is_some() {
            return false;
        }
        if self.fatal.is_none() {
            (self.log)("no turn runs: handing off for the update");
            // Replies the agent gap holds back post now, not with the next host.
            if self.outbox_timer.take().is_some() {
                self.flush_outbox();
            }
            self.save();
            self.fatal = Some(HANDOFF_WHEN_IDLE.into());
        }
        true
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

    /// Changes a per-Chief setting and saves it.
    pub fn set_setting(&mut self, key: &str, value: &str) -> Result<String, String> {
        use crate::chief_settings::{
            CACHE_TTL, CLOUD_AUTO_PAUSE_IDLE_SECONDS, REPLY_THREADS, SHOW_AFTER_REPORT, parse_bool,
            parse_reply_threads, parse_ttl,
        };
        if key == crate::chief_settings::CLOUD_DELETE_AFTER_PAUSED_DAYS {
            let days = crate::chief_settings::parse_paused_days(value)?;
            let mut next = self.chief;
            next.cloud_delete_after_paused_days = days;
            next.save(&self.settings.settings_file)
                .map_err(|e| format!("saving {}: {e}", self.settings.settings_file.display()))?;
            self.chief = next;
            self.cloud_reap = std::time::Duration::from_secs(days * 86_400);
            (self.log)(&format!("setting {key} = {days}"));
            return Ok(format!("{key} = {days}"));
        }
        if key == CLOUD_AUTO_PAUSE_IDLE_SECONDS {
            let secs = crate::chief_settings::parse_idle_secs(value)?;
            let mut next = self.chief;
            next.cloud_auto_pause_idle_secs = secs;
            next.save(&self.settings.settings_file)
                .map_err(|e| format!("saving {}: {e}", self.settings.settings_file.display()))?;
            self.chief = next;
            self.cloud_idle = std::time::Duration::from_secs(secs);
            (self.log)(&format!("setting {key} = {secs}"));
            return Ok(format!("{key} = {secs}"));
        }
        if key == SHOW_AFTER_REPORT {
            let on = parse_bool(value)?;
            let mut next = self.chief;
            next.show_after_report = on;
            next.save(&self.settings.settings_file)
                .map_err(|e| format!("saving {}: {e}", self.settings.settings_file.display()))?;
            self.chief = next;
            (self.log)(&format!("setting {key} = {on}"));
            return Ok(format!("{key} = {on}"));
        }
        if key == REPLY_THREADS {
            let threads = parse_reply_threads(value)?;
            let mut next = self.chief;
            next.reply_threads = threads;
            next.save(&self.settings.settings_file)
                .map_err(|e| format!("saving {}: {e}", self.settings.settings_file.display()))?;
            self.chief = next;
            (self.log)(&format!("setting {key} = {}", threads.as_str()));
            return Ok(format!("{key} = {}", threads.as_str()));
        }
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
        Err(format!(
            "unknown setting {key:?} (known: {CACHE_TTL}, {REPLY_THREADS}, {SHOW_AFTER_REPORT}, {CLOUD_AUTO_PAUSE_IDLE_SECONDS})"
        ))
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
        // tool calls (steered on acpmux); one that cannot reach it waits for
        // the next turn and never stops it (decision 2026-10-09).
        let human = matches!(source, Source::Message { .. } | Source::Spawn(_));
        let same = self.phase == Phase::Running && self.turn_side() == conversation;
        let item = Queued {
            logged: false,
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

    /// Queues `text` as a note at the head of the main conversation's queue
    /// and steers it into a running main turn at once (a subagent's
    /// sign-in escalation: the user is waiting on it, so it never waits
    /// behind other reports).
    fn queue_urgent(&mut self, text: String) {
        let item = Queued {
            logged: false,
            text,
            source: Source::Note,
            images: Vec::new(),
            conversation: None,
        };
        self.queue.push_front(item);
        if self.phase == Phase::Running && self.turn_side().is_none() {
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

/// A turn's reply key: `turn:optchat:<first new message id>:<its stamp>`,
/// from message `first`'s stored date `stamp`. Ids start again at 0 after a
/// memory reset or a restored backup, while the owner keeps every key it
/// saw, so the id alone would collide (and the owner would refuse or
/// silently replay the reply). The millisecond stamp tells the two apart.
fn reply_key_at(first: u64, stamp: &str) -> String {
    let stamp: String = stamp.chars().filter(char::is_ascii_digit).collect();
    format!("turn:optchat:{first}:{stamp}")
}

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
        previews_until: None,
        plain_text: None,
    }
}

/// A turn reply: `message.send` whose client_msg_id is the turn key, so a
/// retry never posts twice.
fn reply_entry(conversation: String, key: &str, text: &str) -> OutboxEntry {
    answer_entry(conversation, key, text, Vec::new(), Vec::new())
}

/// A turn reply that names the messages it answers (E22).
fn answer_entry(
    conversation: String,
    key: &str,
    text: &str,
    answers: Vec<String>,
    answers_pending: Vec<String>,
) -> OutboxEntry {
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
            answers,
            answers_pending,
            thread_root: None,
        },
        rate_retried: false,
        not_before: None,
        attempted: false,
        rate_attempts: 0,
        previews_until: None,
        plain_text: None,
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}
