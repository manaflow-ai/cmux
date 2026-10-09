//! The compactor's model through acpmux (as mux/host/src/compactor.ts does):
//! the team subrouter serves Claude Code clients and answers raw Messages
//! API calls with 429, so on the subrouter each node is built by the normal
//! harness (claude-sr) in its own acpmux session, never by a request that
//! pretends to be Claude Code.
//!
//! One node, one session: `deny-all`, every tool denied, and the
//! compactor's own acpmux preset, which the session REQUIRES (acpmux refuses
//! to start it without the preset). The session signs in with the user's
//! Claude login (no `CLAUDE_CONFIG_DIR` of its own: an empty one has no
//! login); the preset turns off auto-memory, CLAUDE.md files, bundled
//! skills and Claude Code's own refusal fallback, and the slot's project
//! settings deny every tool and every hook. The session's cwd is a slot
//! directory under the system temporary directory, outside any directory
//! with instruction files. The request maps onto the session's prompts.
//! On a Claude harness whose acpmux takes a preset `systemPrompt`, the
//! cached layout: each slot has its own preset, whose system prompt the
//! node sets to the system text plus the context up to the first cache mark
//! (acpmux writes it into its own preset directory and checks its sha256
//! when the session starts), and the first prompt is the rest of the
//! context with one `cache_control` marker at the last mark, then the step
//! (`cached_prompt`). Otherwise the old layout: the system text, the
//! context pieces and the step as one prompt, which a harness with
//! automatic prefix caching (codex) reads back from its cache as long as
//! the prefix is byte-identical; its nodes share one working directory. Each size loop retry is the next prompt in the same session, the
//! reply text the line. `end` (after the node is built or failed) kills the session with
//! purge, deletes its Claude Code transcript and logs its seconds and token
//! use. At most COMPACTOR_SESSIONS sessions live at once across the main and fallback
//! compactors (one `Slots` gate).

use std::collections::{BTreeMap, HashMap};
use std::io;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::mpsc::{RecvTimeoutError, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant};

use cmux_chief::acp::AcpmuxEvent;
use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, ModelError, NodeId, PROBE_NODE, Reply,
};
use serde_json::{Value, json};

use crate::acpmux::{AgentPort, Family, Preset, SessionSpec, TurnSignal};
use crate::fold::{TurnFold, Usage, answer_usage};
use crate::paths::{Paths, home_id};

/// The permission policy of every compactor session: a node needs no tool.
pub const POLICY: &str = "deny-all";

/// Longest one compactor prompt may take, the session's start included.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(300);

/// Days Claude Code keeps a compactor transcript that `end` could not
/// delete (a crash); its minimum.
pub const TRANSCRIPT_DAYS: u64 = 1;

/// Claude Code's built-in tools, denied in each compactor slot's project
/// settings so the harness does not offer them (section 4.2: no tools;
/// checked live: a tool denied in project settings leaves the model's list).
/// The interactive ones matter most: acpmux keeps questions and plan
/// approval for a human under every policy, so one call would hang the
/// node (and, under rule 3, every turn) until `CALL_TIMEOUT`. The
/// `deny-all` policy refuses any call that still happens, and the start-up
/// probe reports any tool or MCP server the session still offers.
pub const DENIED_TOOLS: [&str; 48] = [
    "Agent",
    "AskUserQuestion",
    "Bash",
    "BashOutput",
    "CronCreate",
    "CronDelete",
    "CronList",
    "DesignSync",
    "Edit",
    "EnterPlanMode",
    "EnterWorktree",
    "ExitPlanMode",
    "ExitWorktree",
    "Glob",
    "Grep",
    "KillShell",
    "LS",
    "LSP",
    "ListAgents",
    "ListMcpResourcesTool",
    "Monitor",
    "MultiEdit",
    "NotebookEdit",
    "NotebookRead",
    "PushNotification",
    "Read",
    "ReadMcpResourceTool",
    "RemoteTrigger",
    "ReportFindings",
    "ScheduleWakeup",
    "SendMessage",
    "Skill",
    "SlashCommand",
    "Task",
    "TaskCreate",
    "TaskGet",
    "TaskList",
    "TaskOutput",
    "TaskStop",
    "TaskUpdate",
    "TeamCreate",
    "TeamDelete",
    "TodoWrite",
    "ToolSearch",
    "WebFetch",
    "WebSearch",
    "Workflow",
    "Write",
];

/// How compactor sessions start.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CompactorSpec {
    /// Session names are `<name>-<node>` (`<name>-probe` for the probe).
    pub name: String,
    /// Where the slot working directories live (`<work>/slot-<k>`): outside
    /// the home, so no CLAUDE.md of a parent directory loads.
    pub work: PathBuf,
    /// Claude Code configuration directories a node's transcript may land
    /// in (under `projects/`), each cleaned when the node ends: the
    /// compactor's own `CLAUDE_CONFIG_DIR`, and the user's Claude home,
    /// because `sr claude proxy` (claude-sr) resets `CLAUDE_CONFIG_DIR` to it.
    pub transcript_dirs: Vec<PathBuf>,
    /// The base name of the acpmux presets compactor sessions require: slot
    /// `k` uses `<preset>-slot-<k>` (`slot_preset`).
    pub preset: String,
    pub harness: String,
    /// The harness's family as acpmux reports it (`acpmux::harness_family`).
    pub family: Family,
    /// Codex: the slots' own `CODEX_HOME`s live under it (`<dir>/slot-<k>`,
    /// `codex_slot_home`), emptied but for their configuration around
    /// every node.
    pub codex_home: PathBuf,
    pub model: Option<String>,
    /// acpmux's `effort` (`COMPACTOR_EFFORT` by default on a Claude or
    /// codex harness, `OPTCHAT_COMPACTOR_EFFORT` overrides); None leaves the
    /// harness's own default.
    pub effort: Option<String>,
    /// Longest one prompt may take.
    pub timeout: Duration,
    /// This Chief's home id: the `cmux.chief` tag on every compactor session.
    pub chief: String,
}

/// Compactor sessions that live at once across the main and fallback
/// compactors (one `Slots` gate): fewer than the core's `JOBS` (64), which
/// the other calls wait behind. Each session is a Claude Code process
/// (about 200-400 MB), and every node of one Chief goes to one sticky
/// subrouter account, whose subscription limits concurrent requests; 16
/// keeps both bounded while a burst still runs 2x the old width.
pub const COMPACTOR_SESSIONS: usize = 16;

/// Warm sessions the main compactor keeps (`with_warm`): a node takes a
/// Claude Code process that already started instead of waiting for one.
/// Each idle one costs a process (200-400 MB) and holds a slot; most turns
/// end with 1-4 nodes to build, so 4 cover them, and a burst starts the
/// rest cold. A session is never reused across nodes: each node needs a
/// fresh conversation (its system prompt, its view, its task), and neither
/// acpmux nor Claude Code clears one.
pub const WARM_SESSIONS: usize = 4;

/// The session slots of the compactor (`COMPACTOR_SESSIONS`), shared by the main
/// and the fallback compactor. Each slot has its own working directory, so a
/// node's Claude Code project directory holds only that node's transcript.
pub struct Slots {
    state: Mutex<SlotState>,
    freed: Condvar,
}

#[derive(Default)]
struct SlotState {
    free: Vec<bool>,
    /// Warm sessions, each holding its slot, waiting for a node.
    warm: Vec<Warm>,
    /// Warm sessions being started (their slots held).
    warming: usize,
    /// Nodes blocked in `acquire`.
    waiting: usize,
}

/// A started session no node has prompted yet: a Claude Code process
/// that is ready when a node needs one (`with_warm`).
struct Warm {
    id: String,
    slot: usize,
    cwd: PathBuf,
    preset: String,
    /// What a node must need to take it: its system prompt and model.
    key: u64,
    system: Option<String>,
}

/// What `acquire` hands a node.
enum Acquired {
    Warm(Warm),
    Slot(usize),
    /// A free slot held by a warm session no node of this kind can use (another
    /// model or system prompt): end it, then use the slot.
    Stale(Warm),
}

impl Slots {
    pub fn new(jobs: usize) -> Arc<Slots> {
        Arc::new(Slots {
            state: Mutex::new(SlotState {
                free: vec![true; jobs.max(1)],
                ..SlotState::default()
            }),
            freed: Condvar::new(),
        })
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, SlotState> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// A warm session with `key`, else a free slot, else a stale warm
    /// session's slot; waits while none is there.
    fn acquire(&self, key: Option<u64>) -> Acquired {
        let mut st = self.lock();
        loop {
            if let Some(key) = key
                && let Some(k) = st.warm.iter().position(|w| w.key == key)
            {
                return Acquired::Warm(st.warm.remove(k));
            }
            if let Some(k) = st.free.iter().position(|f| *f) {
                st.free[k] = false;
                return Acquired::Slot(k);
            }
            if let Some(k) = st.warm.iter().position(|w| Some(w.key) != key) {
                return Acquired::Stale(st.warm.remove(k));
            }
            st.waiting += 1;
            st = self
                .freed
                .wait(st)
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            st.waiting -= 1;
        }
    }

    /// Whether the caller, which holds a slot it is done with, should start
    /// a warm session in it: no node waits for a slot, and fewer than `max`
    /// are warm or warming. True counts it as warming until `put_warm` or
    /// `give`.
    fn rewarm(&self, max: usize) -> bool {
        let mut st = self.lock();
        if st.waiting > 0 || st.warm.len() + st.warming >= max {
            return false;
        }
        st.warming += 1;
        true
    }

    fn put_warm(&self, warm: Warm) {
        let mut st = self.lock();
        st.warming = st.warming.saturating_sub(1);
        st.warm.push(warm);
        drop(st);
        self.freed.notify_all();
    }

    /// Gives `k` back; `warming`: the slot was counted as warming.
    fn give_slot(&self, k: usize, warming: bool) {
        let mut st = self.lock();
        if warming {
            st.warming = st.warming.saturating_sub(1);
        }
        if let Some(slot) = st.free.get_mut(k) {
            *slot = true;
        }
        drop(st);
        self.freed.notify_all();
    }

    fn give(&self, k: usize) {
        self.give_slot(k, false);
    }

    /// Every warm session, for ending them.
    fn drain_warm(&self) -> Vec<Warm> {
        let mut st = self.lock();
        let warm = std::mem::take(&mut st.warm);
        for w in &warm {
            if let Some(slot) = st.free.get_mut(w.slot) {
                *slot = true;
            }
        }
        drop(st);
        self.freed.notify_all();
        warm
    }
}

/// A node's open session.
struct Live {
    id: String,
    /// The last event seq already read.
    seq: u64,
    slot: usize,
    cwd: PathBuf,
    /// The slot's preset, and the system prompt this node set in it.
    preset: String,
    system: Option<String>,
    opened: Instant,
    prompts: u32,
    /// Token use the harness reported, summed over the node's prompts.
    usage: Option<Usage>,
    cost: Option<f64>,
    /// The last prompt's failure (None: it built the line), for the trace.
    error: Option<String>,
    /// The node's context as the trace records it (size, hash, pieces).
    context: Value,
}

pub type Log = Arc<dyn Fn(&str) + Send + Sync>;

pub struct AcpmuxCompactor {
    port: Arc<dyn AgentPort>,
    spec: CompactorSpec,
    slots: Arc<Slots>,
    live: Mutex<HashMap<NodeId, Live>>,
    prompts: AtomicU64,
    /// Image descriptions started (each gets its own node id).
    describes: AtomicU64,
    /// Makes prompt ids unique across host starts (acpmux runs an id once).
    stamp: u64,
    /// Claude Code refused the node's cache marker (it placed a fourth
    /// breakpoint of its own): later nodes go without it.
    marker_refused: AtomicBool,
    /// The model sessions start with: `spec.model`, until the account
    /// turns it down and `model_fallback` (Some) takes over.
    model: Mutex<Option<String>>,
    model_fallback: Option<Option<String>>,
    /// Warm sessions kept for the next nodes (`with_warm`; 0: none).
    warm: usize,
    reaped: AtomicBool,
    log: Option<Log>,
    trace: crate::trace::Trace,
}

impl AcpmuxCompactor {
    pub fn new(
        port: Arc<dyn AgentPort>,
        spec: CompactorSpec,
        slots: Arc<Slots>,
    ) -> AcpmuxCompactor {
        let model = Mutex::new(spec.model.clone());
        AcpmuxCompactor {
            port,
            spec,
            slots,
            live: Mutex::new(HashMap::new()),
            prompts: AtomicU64::new(0),
            describes: AtomicU64::new(0),
            stamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map_or(0, |d| d.as_millis() as u64),
            marker_refused: AtomicBool::new(false),
            model,
            model_fallback: None,
            warm: 0,
            reaped: AtomicBool::new(false),
            log: None,
            trace: crate::trace::Trace::off(),
        }
    }

    /// Traces every node: seconds, prompts, token use, cost, outcome.
    pub fn with_trace(mut self, trace: crate::trace::Trace) -> AcpmuxCompactor {
        self.trace = trace;
        self
    }

    /// The model to build with when the account cannot use `spec.model`
    /// (None: the harness's default model).
    pub fn with_model_fallback(mut self, model: Option<String>) -> AcpmuxCompactor {
        self.model_fallback = Some(model);
        self
    }

    /// The model sessions start with now.
    fn model(&self) -> Option<String> {
        self.model
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
    }

    /// `error` says the account cannot use the current model: switch to the
    /// fallback for good and say so once. False: no switch (none set, or
    /// done already, or another error).
    fn switch_model(&self, error: &ModelError) -> bool {
        let Some(fallback) = &self.model_fallback else {
            return false;
        };
        if !is_model_unavailable(&error.message) {
            return false;
        }
        let mut model = self
            .model
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        if *model == *fallback {
            return false;
        }
        let old = model.clone().unwrap_or_else(|| "(default)".to_owned());
        *model = fallback.clone();
        drop(model);
        self.say(&format!(
            "compactor model {old} is not available on {} ({}); building with {} from now on",
            self.spec.harness,
            error.message,
            fallback.as_deref().unwrap_or("the harness's default model")
        ));
        true
    }

    /// Keeps up to `n` warm sessions (`WARM_SESSIONS` in the host).
    pub fn with_warm(mut self, n: usize) -> AcpmuxCompactor {
        self.warm = n;
        self
    }

    /// Logs one line per node: its seconds, prompts and token use.
    pub fn with_log(mut self, log: Log) -> AcpmuxCompactor {
        self.log = Some(log);
        self
    }

    fn say(&self, line: &str) {
        if let Some(log) = &self.log {
            log(line);
        }
    }

    fn session_name(&self, node: NodeId) -> String {
        if node == PROBE_NODE {
            format!("{}-probe", self.spec.name)
        } else {
            format!("{}-{}", self.spec.name, node.name())
        }
    }

    /// A Claude Code harness: the cached layout's flags and system prompt
    /// apply, and each slot needs its own directory (Claude Code keeps a
    /// transcript per project directory, deleted per node).
    fn claude(&self) -> bool {
        self.spec.family == Family::Claude
    }

    /// Codex: empties the slot's `CODEX_HOME` but for its configuration
    /// (the node's transcript, thread database and logs go).
    fn wipe_codex(&self, slot: usize) {
        if self.spec.family != Family::Codex {
            return;
        }
        let dir = codex_slot_home(&self.spec.codex_home, slot);
        if let Err(e) = wipe_codex_home(&dir) {
            self.say(&format!(
                "emptying the compactor's CODEX_HOME {}: {e}",
                dir.display()
            ));
        }
    }

    /// The slot's working directory, created, by its real path (Claude
    /// Code names the project directory after the real path). Another
    /// harness shares one directory across slots: codex names the cwd in
    /// its environment context, ahead of the prompt, so one cwd keeps the
    /// request prefix identical from node to node.
    fn slot_dir(&self, slot: usize) -> io::Result<PathBuf> {
        private_dir(&self.spec.work)?;
        let dir = if self.claude() {
            self.spec.work.join(format!("slot-{slot}"))
        } else {
            self.spec.work.join("shared")
        };
        private_dir(&dir)?;
        // Project settings: the only settings claude-sr is sure to read
        // (sr resets CLAUDE_CONFIG_DIR, so the preset's user settings are
        // not), and the ones that take denied tools off the model's list.
        std::fs::create_dir_all(dir.join(".claude"))?;
        write_settings(&dir.join(".claude").join("settings.json"))?;
        std::fs::canonicalize(&dir)
    }

    /// What a warm session must match for a node: its system prompt and the
    /// model sessions start with now.
    fn warm_key(&self, system: Option<&str>) -> u64 {
        let mut h = std::collections::hash_map::DefaultHasher::new();
        std::hash::Hash::hash(&system, &mut h);
        std::hash::Hash::hash(&self.model(), &mut h);
        std::hash::Hasher::finish(&h)
    }

    /// Opens the node's session: a warm one with its system prompt when
    /// there is one (`with_warm`), else a new one in a slot (so at most
    /// COMPACTOR_SESSIONS live), with `system` as its slot preset's system
    /// prompt in the cached layout.
    fn open(&self, node: NodeId, system: Option<&str>) -> Result<String, ModelError> {
        // Claude only through acpmux's own Claude Code adapter
        // (harness_gate), checked before a slot is taken.
        let admitted = self.admit(node)?;
        self.reap_warm();
        let key = self.warm_key(system);
        let (id, slot, cwd, preset) = match self.slots.acquire((self.warm > 0).then_some(key)) {
            Acquired::Warm(w) => (w.id, w.slot, w.cwd, w.preset),
            other => {
                let slot = match other {
                    Acquired::Stale(w) => {
                        self.end_warm(&w);
                        w.slot
                    }
                    Acquired::Slot(k) => k,
                    Acquired::Warm(_) => unreachable!(),
                };
                let name = self.session_name(node);
                match self.start(slot, &name, system, &admitted) {
                    Ok((id, cwd, preset)) => (id, slot, cwd, preset),
                    Err(e) => {
                        self.slots.give(slot);
                        return Err(e);
                    }
                }
            }
        };
        self.live
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(
                node,
                Live {
                    id: id.clone(),
                    seq: 0,
                    slot,
                    cwd,
                    preset,
                    system: system.map(str::to_owned),
                    opened: Instant::now(),
                    prompts: 0,
                    usage: None,
                    cost: None,
                    error: None,
                    context: Value::Null,
                },
            );
        Ok(id)
    }

    fn admit(&self, node: NodeId) -> Result<crate::harness_gate::Admitted, ModelError> {
        crate::harness_gate::admit_live(&*self.port, &self.spec.harness).map_err(|reason| {
            self.say(&format!("compactor node {}: {reason}", node.name()));
            crate::harness_gate::trace_refusal(
                &self.trace,
                "compactor",
                &self.spec.harness,
                &reason,
            );
            ModelError::new(crate::harness_gate::refusal(&reason))
        })
    }

    /// Starts a session named `name` in `slot` (held by the caller), with
    /// `system` as the slot preset's system prompt: its id, cwd and preset.
    fn start(
        &self,
        slot: usize,
        name: &str,
        system: Option<&str>,
        admitted: &crate::harness_gate::Admitted,
    ) -> Result<(String, PathBuf, String), ModelError> {
        let cwd = self.slot_dir(slot).map_err(|e| {
            ModelError::new(format!("creating the compactor's working directory: {e}"))
        })?;
        let preset = slot_preset(&self.spec.preset, slot);
        // The slot is this caller's alone, so is its preset: no other node
        // changes the prompt before this session starts with it.
        if let Some(text) = system {
            self.port.set_system_prompt(&preset, text).map_err(|e| {
                ModelError::new(format!("setting the compactor's system prompt: {e}"))
            })?;
        }
        // A transcript left by a crash in this slot.
        self.delete_transcript(&cwd);
        self.wipe_codex(slot);
        // Left by a host that stopped while the node was being built.
        if let Ok(Some(old)) = self.port.find(name) {
            let _ = self.port.end_session(&old);
        }
        let spec = SessionSpec {
            name: name.to_owned(),
            cwd: cwd.clone(),
            harness: admitted.profile.clone(),
            policy: POLICY.to_owned(),
            model: self.model(),
            effort: self.spec.effort.clone(),
            preset: Some(preset.clone()),
            tags: crate::acpmux::chief_tags(&self.spec.chief, "compactor"),
            env: Default::default(),
        };
        let id = self
            .port
            .new_session(&spec)
            .and_then(|id| {
                // The session's own harness is what answers (a name that is
                // also a family resolves through acpmux's preference list).
                match crate::harness_gate::session_harness(&*self.port, &id, admitted) {
                    Ok(_) => Ok(id),
                    Err(reason) => {
                        let _ = self.port.end_session(&id);
                        crate::harness_gate::trace_refusal(
                            &self.trace,
                            "compactor",
                            &self.spec.harness,
                            &reason,
                        );
                        Err(crate::harness_gate::refusal(&reason))
                    }
                }
            })
            .map_err(|e| ModelError::new(format!("starting a compactor session: {e}")))?;
        Ok((id, cwd, preset))
    }

    /// The warm session name of `slot`; a restarted host ends the one a
    /// stopped host left when it starts its own there.
    fn warm_name(&self, slot: usize) -> String {
        format!("{}-warm-{slot}", self.spec.name)
    }

    /// Starts a warm session in `slot` (counted as warming by
    /// `Slots::rewarm`) with `system`; gives the slot back when it cannot.
    fn warm_up(&self, slot: usize, system: Option<String>) {
        let started = self.admit(PROBE_NODE).and_then(|admitted| {
            self.start(slot, &self.warm_name(slot), system.as_deref(), &admitted)
        });
        match started {
            Ok((id, cwd, preset)) => self.slots.put_warm(Warm {
                id,
                slot,
                cwd,
                preset,
                key: self.warm_key(system.as_deref()),
                system,
            }),
            Err(e) => {
                self.say(&format!("starting a warm compactor session: {e}"));
                self.slots.give_slot(slot, true);
            }
        }
    }

    /// Once per host: ends the warm sessions a stopped host left (by name).
    fn reap_warm(&self) {
        if self.warm == 0 || self.reaped.swap(true, Ordering::SeqCst) {
            return;
        }
        let slots = self.slots.lock().free.len();
        for k in 0..slots {
            if let Ok(Some(old)) = self.port.find(&self.warm_name(k)) {
                let _ = self.port.end_session(&old);
            }
        }
    }

    /// Ends a warm session no node will prompt; its slot stays the caller's.
    fn end_warm(&self, w: &Warm) {
        let _ = self.port.end_session(&w.id);
        self.delete_transcript(&w.cwd);
        self.wipe_codex(w.slot);
        if w.system.is_some() {
            let _ = self.port.set_system_prompt(&w.preset, "");
        }
    }

    fn delete_transcript(&self, cwd: &Path) {
        for root in &self.spec.transcript_dirs {
            let dir = root.join("projects").join(project_dir_name(cwd));
            if dir.exists()
                && let Err(e) = std::fs::remove_dir_all(&dir)
            {
                self.say(&format!(
                    "deleting the compactor transcript {}: {e}",
                    dir.display()
                ));
            }
        }
    }

    /// One prompt in the node's session; its reply text.
    fn prompt(
        &self,
        node: NodeId,
        session: &str,
        blocks: Vec<Value>,
        started: &dyn Fn(),
    ) -> Result<Reply, ModelError> {
        let n = self.prompts.fetch_add(1, Ordering::SeqCst);
        let before = self
            .live
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&node)
            .map_or(0, |l| l.seq);
        let mut begun = false;
        let prompt_id = format!("optchat-compact:{}:{}:{n}", self.stamp, node.name());
        let (tx, rx) = channel();
        self.port
            .start_prompt(session, blocks, &prompt_id, tx)
            .map_err(|e| ModelError::new(format!("prompting the compactor session: {e}")))?;
        let deadline = Instant::now() + self.spec.timeout;
        let answer = loop {
            match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(TurnSignal::Changed) => {
                    // The first streamed output: the response started.
                    if !begun
                        && self.port.events(session, before).is_ok_and(|events| {
                            events.iter().any(|e| crate::acpmux::is_output(&e.kind))
                        })
                    {
                        begun = true;
                        started();
                    }
                }
                Ok(TurnSignal::Done(answer)) => break answer,
                Ok(TurnSignal::Lost) | Err(RecvTimeoutError::Disconnected) => {
                    return Err(ModelError::new(
                        "the acpmux connection was lost during a compactor call",
                    ));
                }
                Err(RecvTimeoutError::Timeout) => {
                    let _ = self.port.cancel(session);
                    return Err(ModelError::new(format!(
                        "the compactor session did not answer within {} s",
                        self.spec.timeout.as_secs()
                    )));
                }
            }
        };
        // acpmux answers a refused Claude turn with a JSON-RPC error that
        // carries Claude Code's text (claude_stdio/inbound.rs), never with
        // `stopReason: "refusal"`; both are refusals.
        let answer = answer.map_err(|e| {
            if is_refusal_error(&e) {
                ModelError::refusal(format!("refused: {e}"))
            } else {
                ModelError::new(format!("compactor session: {e}"))
            }
        })?;
        self.count(node, &answer);
        match answer.get("stopReason").and_then(Value::as_str) {
            Some("refusal") => {
                return Err(ModelError::refusal(format!("refused: {answer}")));
            }
            Some("max_tokens") => return Err(ModelError::new("reply hit max_tokens")),
            Some("end_turn") | None => {}
            Some(other) => {
                return Err(ModelError::new(format!(
                    "the compactor turn stopped early ({other})"
                )));
            }
        }
        let after = self
            .live
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get(&node)
            .map_or(0, |l| l.seq);
        let events = self
            .port
            .events(session, after)
            .map_err(|e| ModelError::new(format!("reading the compactor reply: {e}")))?;
        if node == PROBE_NODE {
            check_isolation(&events).map_err(ModelError::new)?;
        }
        let mut fold = TurnFold::after(after);
        for event in &events {
            fold.apply(event);
        }
        fold.finish(None);
        if let Some(l) = self
            .live
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get_mut(&node)
        {
            l.seq = fold.seq();
        }
        if let Some(error) = fold.ended().and_then(|e| e.error.clone()) {
            return Err(ModelError::new(format!("compactor turn: {error}")));
        }
        if !begun {
            // A reply whose first chunk this call did not see: written too.
            started();
        }
        Ok(Reply::text(strip_preamble(
            fold.final_text().unwrap_or_default(),
        )))
    }

    /// Adds a prompt's reported token use and cost to its node.
    fn count(&self, node: NodeId, answer: &Value) {
        let mut live = self
            .live
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let Some(l) = live.get_mut(&node) else { return };
        l.prompts += 1;
        if let Some((u, _)) = answer_usage(answer) {
            let sum = l.usage.get_or_insert_with(Usage::default);
            sum.input += u.input;
            sum.cache_read += u.cache_read;
            sum.cache_write += u.cache_write;
            sum.output += u.output;
        }
        if let Some(cost) = answer
            .pointer("/_meta/claude/cost_usd")
            .and_then(Value::as_f64)
        {
            *l.cost.get_or_insert(0.0) += cost;
        }
    }
}

impl AcpmuxCompactor {
    /// A node's first prompt in the cached layout (when the preset carries
    /// its args): the system prompt file, one marker, and one retry without
    /// the marker when Claude Code's own breakpoints leave no room for it.
    fn first_cached(
        &self,
        request: &CompactRequest,
        started: &dyn Fn(),
    ) -> Result<Reply, ModelError> {
        let node = request.node;
        let marker = !self.marker_refused.load(Ordering::SeqCst);
        let layout = cached_prompt(request, marker);
        let session = self.open(node, Some(&layout.system))?;
        let has_marker = layout
            .blocks
            .iter()
            .any(|b| b.get("cache_control").is_some());
        match self.prompt(node, &session, layout.blocks, started) {
            Err(e) if has_marker && is_marker_limit_error(&e.message) => {
                self.marker_refused.store(true, Ordering::SeqCst);
                self.say(&format!(
                    "compactor node {}: Claude Code refused the cache_control marker ({}); retrying without it, and later nodes go without it",
                    node.name(),
                    e.message
                ));
                // A fresh session: the refused prompt may sit in the old one's history.
                self.end(request);
                let layout = cached_prompt(request, false);
                let session = self.open(node, Some(&layout.system))?;
                self.prompt(node, &session, layout.blocks, started)
            }
            other => other,
        }
    }
}

impl AcpmuxCompactor {
    fn call_inner(
        &self,
        request: &CompactRequest,
        followups: &[Followup],
        started: &dyn Fn(),
    ) -> Result<Reply, ModelError> {
        let node = request.node;
        let (session, blocks) = match followups.last() {
            None => {
                // A fresh conversation: whatever an earlier try left is gone.
                self.end(request);
                if self.claude() && self.port.system_prompt(&slot_preset(&self.spec.preset, 0)) {
                    return self.first_cached(request, started);
                }
                (self.open(node, None)?, request_blocks(request))
            }
            Some(last) => {
                let session = self
                    .live
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .get(&node)
                    .map(|l| l.id.clone())
                    .ok_or_else(|| ModelError::new("the node's compactor session is gone"))?;
                (session, vec![text_block(&last.retry)])
            }
        };
        self.prompt(node, &session, blocks, started)
    }
}

impl CompactModel for AcpmuxCompactor {
    fn call(&self, request: &CompactRequest, followups: &[Followup]) -> Result<Reply, ModelError> {
        self.call_started(request, followups, &|| {})
    }

    fn call_started(
        &self,
        request: &CompactRequest,
        followups: &[Followup],
        started: &dyn Fn(),
    ) -> Result<Reply, ModelError> {
        let result = match self.call_inner(request, followups, started) {
            // The account cannot use the model: the node again, fresh, on the fallback.
            Err(e) if followups.is_empty() && self.switch_model(&e) => {
                self.end(request);
                self.call_inner(request, followups, started)
            }
            other => other,
        };
        if let Some(l) = self
            .live
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .get_mut(&request.node)
        {
            l.error = result.as_ref().err().map(|e| e.message.clone());
            if l.context.is_null() {
                l.context = json!({
                    "bytes": request.context.len(),
                    "hash": crate::trace::hash(&request.context),
                    "pieces": crate::trace::pieces(&request.context),
                    "system_hash": crate::trace::hash(&request.system),
                });
            }
        }
        result
    }

    fn end(&self, request: &CompactRequest) {
        self.end_node(request.node);
    }
}

impl AcpmuxCompactor {
    /// Ends `node`'s session: purges its transcript, gives its slot back
    /// and logs its use.
    fn end_node(&self, node: NodeId) {
        let Some(live) = self
            .live
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(&node)
        else {
            return;
        };
        self.trace.emit(
            "node",
            json!({
                "node": node.name(),
                "harness": self.spec.harness,
                "model": self.model(),
                "ms": live.opened.elapsed().as_millis() as u64,
                "prompts": live.prompts,
                "usage": live.usage.as_ref().map(crate::trace::usage),
                "cost_usd": live.cost,
                "ok": live.error.is_none(),
                "error": live.error.as_deref().map(|e| self.trace.text(e)),
                "context": live.context,
            }),
        );
        // Purged: a node's session holds the chat's text, and nothing reads it again.
        let _ = self.port.end_session(&live.id);
        // So is Claude Code's own transcript of it (the whole view, each time),
        // and the slot preset's system prompt (the view's first piece).
        self.delete_transcript(&live.cwd);
        self.wipe_codex(live.slot);
        // The next node's session starts now, in this slot, so it does not
        // wait for one; else the slot goes back.
        if self.warm > 0 && !is_describe(node) && self.slots.rewarm(self.warm) {
            self.warm_up(live.slot, live.system.clone());
        } else {
            if live.system.is_some() {
                let _ = self.port.set_system_prompt(&live.preset, "");
            }
            self.slots.give(live.slot);
        }
        let tokens = match live.usage {
            Some(u) => format!(
                "uncached {} cache write {} cache read {} output {}",
                u.input, u.cache_write, u.cache_read, u.output
            ),
            None => "tokens not reported".to_owned(),
        };
        let cost = live.cost.map_or(String::new(), |c| format!(", ${c:.3}"));
        self.say(&format!(
            "compactor node {} ({}, {}): {:.1} s, {} prompt(s), {tokens}{cost}",
            node.name(),
            self.spec.harness,
            self.model().as_deref().unwrap_or("default model"),
            live.opened.elapsed().as_secs_f64(),
            live.prompts
        ));
    }
}

/// Image descriptions count down from the top of level 0's id space.
fn is_describe(node: NodeId) -> bool {
    node.l == 0 && node.i > u64::MAX / 2
}

impl Drop for AcpmuxCompactor {
    /// The warm sessions end with the compactor: no Claude Code process
    /// outlives the host idle.
    fn drop(&mut self) {
        for w in self.slots.drain_warm() {
            self.end_warm(&w);
        }
    }
}

/// Image descriptions for the OptChat log (chief-done.md item 12): one
/// deny-all session per image, under a node id no chat node uses (level 0,
/// counting down from the top of the id space), ended at once.
impl crate::brain::images::Describe for AcpmuxCompactor {
    fn describe(&self, blocks: Vec<Value>) -> Result<String, String> {
        let n = self.describes.fetch_add(1, Ordering::SeqCst);
        let node = NodeId::new(0, u64::MAX - n);
        let session = self.open(node, None).map_err(|e| e.message)?;
        let reply = self.prompt(node, &session, blocks, &|| {});
        self.end_node(node);
        reply.map(|r| r.text).map_err(|e| e.message)
    }
}

pub(crate) fn private_dir(dir: &Path) -> io::Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new()
        .recursive(true)
        .mode(0o700)
        .create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
}

fn text_block(text: &str) -> Value {
    json!({"type": "text", "text": text})
}

/// The node's first prompt: the system text, the context cut at the view's
/// cache marks (section 8), then the step, one text block each. acpmux
/// forwards text blocks without `cache_control`, so the pieces keep the
/// spec's order and boundaries but carry no breakpoints (README).
pub fn request_blocks(request: &CompactRequest) -> Vec<Value> {
    let mut blocks = vec![text_block(&request.system)];
    blocks.extend(
        optchat_core::cache_pieces(&request.context)
            .into_iter()
            .map(text_block),
    );
    blocks.push(text_block(&request.step));
    blocks
}

/// The compactor presets' harness arguments on a Claude harness: acpmux's
/// allowlist of preset args, every one of which takes a capability away: no
/// tools, no MCP servers, no transcript. The system prompt is the preset's
/// `systemPrompt` text (acpmux writes and checks the file), never a path.
pub const COMPACTOR_ARGS: [&str; 4] = [
    "--tools",
    "",
    "--strict-mcp-config",
    "--no-session-persistence",
];

/// The slot presets' system prompt at install, before any node sets its
/// own (acpmux needs some text to take the key, which detects support).
pub const COMPACTOR_PROMPT_SEED: &str = "optchat compactor (each node sets its own system prompt)";

pub use crate::prompt::CachedPrompt;

/// A node's first prompt in the cached layout (`prompt::cached_layout`): the
/// compactor's system text plus the context up to its first cache mark is
/// the session's system prompt, then the rest of the context with one
/// marker at the last mark, then the step.
pub fn cached_prompt(request: &CompactRequest, marker: bool) -> CachedPrompt {
    crate::prompt::cached_layout_at_marks(&request.system, &request.context, &request.step, marker)
}

/// Whether a failed turn's error is the API's limit of four cache
/// breakpoints ("A maximum of 4 blocks with cache_control may be provided.
/// Found 5."): a Claude Code that places a fourth one of its own.
pub fn is_marker_limit_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("cache_control") && (lower.contains("maximum") || lower.contains("too many"))
}

/// Whether a failed Claude turn's error text is a refusal: Claude Code's
/// refusal messages all link the usage policy (2.1.289: "... safeguards
/// flagged this message (https://www.anthropic.com/legal/aup) ...";
/// older: "... appears to violate our Usage Policy ..."). A usage limit,
/// an overload or a dead process is not one: those are retried.
pub fn is_refusal_error(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("anthropic.com/legal/aup")
        || lower.contains("usage policy")
        || lower.contains("safeguards flagged")
}

/// Drops a lead-in line ("Here is the line:") before the summary line,
/// which the model or Claude Code sometimes writes. A lead-in ends with a
/// colon and has no other `: ` in it, so a real line ("user: asked:") stays.
pub fn strip_preamble(text: &str) -> String {
    let text = text.trim();
    let lines: Vec<&str> = text.lines().collect();
    let mut start = 0;
    while start + 1 < lines.len() {
        let line = lines[start].trim();
        if line.is_empty() || (line.ends_with(':') && line.len() < 100 && !line.contains(": ")) {
            start += 1;
        } else {
            break;
        }
    }
    if start == 0 {
        return text.to_owned();
    }
    lines[start..].join("\n").trim().to_owned()
}

/// The name Claude Code gives the project directory of `cwd` under its
/// configuration's `projects/`: every character but ASCII letters and
/// digits becomes `-`.
pub fn project_dir_name(cwd: &Path) -> String {
    cwd.to_string_lossy()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
        .collect()
}

/// Section 4.2 says a compactor call has no tools: the probe fails when the
/// session's Claude Code reports a tool or an MCP server (its `system/init`,
/// which acpmux records as a `session_info_update`), or when the session
/// offers a skill (codex-acp's `available_commands_update`).
pub fn check_isolation(events: &[AcpmuxEvent]) -> Result<(), String> {
    for event in events {
        // Codex lists every skill it loaded as a `$name` command (a user
        // skill, a plugin's, a bundled one); a chat line that names one
        // would pull its text into the node.
        if event.kind == "available_commands_update" {
            let skills: Vec<&str> = event
                .msg
                .get("params")
                .and_then(|p| p.pointer("/update/availableCommands"))
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(|c| c.get("name").and_then(Value::as_str))
                .filter(|name| name.starts_with('$'))
                .collect();
            if !skills.is_empty() {
                return Err(format!(
                    "the compactor session is not isolated: it offers skills [{}]",
                    skills.join(", ")
                ));
            }
            continue;
        }
        if event.kind != "session_info_update" {
            continue;
        }
        let Some(claude) = event
            .msg
            .get("params")
            .and_then(|p| p.pointer("/update/_meta/claude"))
        else {
            continue;
        };
        let names = |key: &str| -> Vec<String> {
            claude
                .get(key)
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .map(|v| match v {
                    Value::String(s) => s.clone(),
                    other => other
                        .get("name")
                        .and_then(Value::as_str)
                        .map_or_else(|| other.to_string(), str::to_owned),
                })
                .collect()
        };
        let (tools, servers) = (names("tools"), names("mcp_servers"));
        if !tools.is_empty() || !servers.is_empty() {
            return Err(format!(
                "the compactor session is not isolated: it offers tools [{}] and MCP servers [{}]",
                tools.join(", "),
                servers.join(", ")
            ));
        }
    }
    Ok(())
}

/// The start-up probe of both compactor models: the main one, then the
/// refusal fallback (which nothing else checks until a node is refused).
pub fn probe_models(
    main: &dyn CompactModel,
    fallback: Option<&dyn CompactModel>,
    system: &str,
) -> Result<String, String> {
    let line =
        optchat_host::probe(main, system).map_err(|e| format!("the compactor model: {e}"))?;
    if let Some(fallback) = fallback {
        optchat_host::probe(fallback, system)
            .map_err(|e| format!("the fallback model (for refused nodes): {e}"))?;
    }
    Ok(line)
}

/// The compactor's Claude Code settings (each slot's project settings, and
/// its own configuration's user settings): every tool denied, no
/// auto-memory, no hooks (the user's included), no bundled skills, and a
/// one-day transcript retention for whatever `end` could not delete.
pub fn compactor_settings() -> Value {
    json!({
        "permissions": {"deny": DENIED_TOOLS.as_slice()},
        "autoMemoryEnabled": false,
        "hooks": {},
        "disableAllHooks": true,
        "disableBundledSkills": true,
        // The same TTL as the node's own 5-minute mark: the API refuses a
        // 5m mark before a 1h one, and Claude Code may pick 1h on a
        // subscription.
        "promptCacheTtl": "5m",
        "enableAllProjectMcpServers": false,
        "cleanupPeriodDays": TRANSCRIPT_DAYS,
    })
}

/// Creates the compactor's configuration directory (0700) and its settings.
pub fn prepare_config(dir: &Path) -> io::Result<()> {
    private_dir(dir)?;
    write_settings(&dir.join("settings.json"))
}

fn write_settings(path: &Path) -> io::Result<()> {
    crate::session_dir::write_if_changed(
        path,
        format!(
            "{}\n",
            serde_json::to_string_pretty(&compactor_settings()).map_err(io::Error::other)?
        )
        .as_bytes(),
    )
}

/// The user's Claude Code home: `CLAUDE_CONFIG_DIR` of the host, else
/// `~/.claude` (where claude-sr puts every session's transcript).
pub fn user_claude_home() -> PathBuf {
    if let Some(dir) = crate::cli::env("CLAUDE_CONFIG_DIR") {
        return PathBuf::from(dir);
    }
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| "/".into())
        .join(".claude")
}

/// The acpmux preset of compactor slot `k` (`<base>-slot-<k>`). One preset
/// per slot: a node sets its slot preset's system prompt just before its
/// session starts, and no other node uses that slot meanwhile.
pub fn slot_preset(base: &str, k: usize) -> String {
    format!("{base}-slot-{k}")
}

/// The compactor's acpmux presets (`optchat-compact-<home id>-slot-<k>`, one
/// per slot), which every compactor session requires.
/// OPTCHAT_CHIEF_ISOLATE=0 does not touch them.
pub fn compactor_presets(paths: &Paths, home: &Path, harness: &str, family: Family) -> Vec<Preset> {
    let base = format!("optchat-compact-{}", home_id(home));
    if family == Family::Codex {
        // Codex: the slot's own CODEX_HOME and the Chief's compactor cache key.
        return (0..COMPACTOR_SESSIONS)
            .map(|k| Preset {
                name: slot_preset(&base, k),
                harness: harness.to_owned(),
                env: BTreeMap::from([
                    // No cmux agent tools (acpmux `agent_tools.rs`): a
                    // compactor session stays isolated.
                    ("ACPMUX_AGENT_TOOLS".to_owned(), "0".to_owned()),
                    (
                        "CODEX_HOME".to_owned(),
                        codex_slot_home(&paths.compactor_codex, k)
                            .display()
                            .to_string(),
                    ),
                    (
                        CODEX_CACHE_KEY_ENV.to_owned(),
                        codex_cache_key(home, "compact"),
                    ),
                ]),
                args: Vec::new(),
                system_prompt: None,
            })
            .collect();
    }
    let mut env = BTreeMap::new();
    // No cmux agent tools (acpmux `agent_tools.rs`); `--strict-mcp-config`
    // already keeps them out, this says so for every harness.
    env.insert("ACPMUX_AGENT_TOOLS".to_owned(), "0".to_owned());
    // No CLAUDE_CONFIG_DIR of its own (cx-1hpt): the user's Claude login
    // lives with the user's Claude home, and a plain `claude` compactor in
    // an empty one cannot sign in. The slot's project settings (every tool
    // denied, no hooks, no auto-memory, no bundled skills), the env below
    // and the preset's flags keep the session isolated; `end` deletes its
    // transcript there.
    // One sticky subrouter account for every node of this Chief, so nodes
    // read each other's cached context (claude-sr; harmless elsewhere).
    env.insert(
        SUBROUTER_SESSION_KEY_ENV.to_owned(),
        codex_cache_key(home, "compact"),
    );
    for key in [
        "CLAUDE_CODE_DISABLE_AUTO_MEMORY",
        "CLAUDE_CODE_DISABLE_CLAUDE_MDS",
        "CLAUDE_CODE_DISABLE_BUNDLED_SKILLS",
        // A refusal must reach the host, whose fallback model is probed.
        "CLAUDE_CODE_DISABLE_REFUSAL_FALLBACK",
        // Claude Code's own marks at 5 minutes, the TTL of the node's mark:
        // on a subscription login it marks 1 hour, and the API refuses a
        // 1h mark after a 5m one.
        "FORCE_PROMPT_CACHING_5M",
    ] {
        env.insert(key.to_owned(), "1".to_owned());
    }
    // Claude Code flags and system prompts: a Claude harness only (claude,
    // claude-sr, ...); another harness keeps the old layout.
    let claude = family == Family::Claude;
    (0..COMPACTOR_SESSIONS)
        .map(|k| Preset {
            name: slot_preset(&base, k),
            harness: harness.to_owned(),
            env: env.clone(),
            args: if claude {
                COMPACTOR_ARGS.iter().map(|a| (*a).to_owned()).collect()
            } else {
                Vec::new()
            },
            system_prompt: claude.then(|| COMPACTOR_PROMPT_SEED.to_owned()),
        })
        .collect()
}

/// The effort of a Claude compactor session: high, with Claude Haiku 5.5
/// (`optchat_host::DEFAULT_EFFORT`, as the reference client runs it; at low
/// effort the compactor overshot the size limit much more). acpmux maps
/// `effort` onto Claude Code's `--effort`.
pub const COMPACTOR_EFFORT: &str = optchat_host::DEFAULT_EFFORT;

/// The effort of a codex compactor session (codex's `reasoning_effort`):
/// medium, as section 4.2 runs its compactor; codex is not Haiku.
pub const CODEX_COMPACTOR_EFFORT: &str = "medium";

/// The default effort of `family`'s compactor sessions; another harness
/// keeps its own default (its effort names are not known here).
pub fn compactor_effort(family: Family) -> Option<String> {
    match family {
        Family::Claude => Some(COMPACTOR_EFFORT.to_owned()),
        Family::Codex => Some(CODEX_COMPACTOR_EFFORT.to_owned()),
        Family::Other => None,
    }
}

/// Whether a failed compactor turn says the account cannot use the model:
/// Claude Code's "There's an issue with the selected model (...). It may
/// not exist or you may not have access to it", or the API's
/// `not_found_error` for the model. A usage limit or an overload is not.
pub fn is_model_unavailable(message: &str) -> bool {
    let lower = message.to_ascii_lowercase();
    lower.contains("issue with the selected model")
        || lower.contains("may not exist or you may not have access")
        || (lower.contains("not_found_error") && lower.contains("model"))
}

/// How the compactor's sessions start for `home`.
pub fn compactor_spec(
    paths: &Paths,
    home: &Path,
    harness: &str,
    family: Family,
    model: Option<&str>,
) -> CompactorSpec {
    let name = format!("optchat-compact-{}", home_id(home));
    CompactorSpec {
        work: std::env::temp_dir().join(&name),
        transcript_dirs: vec![paths.compactor_config.clone(), user_claude_home()],
        preset: name.clone(),
        name,
        harness: harness.to_owned(),
        family,
        codex_home: paths.compactor_codex.clone(),
        model: model.map(str::to_owned),
        effort: compactor_effort(family),
        timeout: CALL_TIMEOUT,
        chief: home_id(home),
    }
}

pub use crate::codex_home::*;

/// `sr claude proxy` sends this as `X-Subrouter-Session` (subrouter PR 511):
/// the subrouter keeps every process with one key on one sticky account, so
/// fresh per-turn Claude Code processes of one Chief share its prompt cache.
/// Earlier `sr` builds ignore it.
pub const SUBROUTER_SESSION_KEY_ENV: &str = "SUBROUTER_SESSION_KEY";

/// Which model builds the compactor's nodes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum CompactRoute {
    /// A deny-all acpmux session per node (the harness's own sign-in).
    Acpmux,
    /// The Messages API at `OPTCHAT_ANTHROPIC_BASE_URL` with a real key.
    Api,
}

impl CompactRoute {
    pub fn name(self) -> &'static str {
        match self {
            CompactRoute::Acpmux => "acpmux",
            CompactRoute::Api => "api",
        }
    }
}

/// `OPTCHAT_COMPACTOR` when set (`acpmux` or `api`); else acpmux on the
/// team subrouter or without a real key, the Messages API on a configured
/// endpoint with a key.
pub fn compact_route(choice: Option<&str>, config: &Config) -> Result<CompactRoute, String> {
    match choice {
        Some("acpmux") => Ok(CompactRoute::Acpmux),
        Some("api") => Ok(CompactRoute::Api),
        Some(other) => Err(format!("OPTCHAT_COMPACTOR={other}: use acpmux or api")),
        // Purely local ACP: the Messages API only when asked for.
        None => {
            let _ = config;
            Ok(CompactRoute::Acpmux)
        }
    }
}
