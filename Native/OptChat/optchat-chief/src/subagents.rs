//! Subagents (section 9): `spawn(tasks)` and `tell(id, message)`, served
//! from the host on its tools socket (the MCP server and the `chief`
//! launcher forward to it), so the Chief's harness, whatever it is, uses
//! them like `zoom` and `date`.
//!
//! - `spawn` waits for the view to settle, renders it, and starts one
//!   acpmux session per task (the subagent harness, default the Chief's),
//!   tagged `mux.parent` plus `optchat.spawn` and `optchat.subagent` (never
//!   `cmux.chief`). Its first message is the view, then its task; its system
//!   prompt is section 9's subagent prompt, VIEW_DOC and the user's
//!   instructions (the subagent preset's system prompt on a Claude harness,
//!   else the subagent directory's CLAUDE.md or AGENTS.md). It answers the
//!   ids at once. Each subagent also gets a cmux workspace whose tab is its
//!   chat (workspaces.rs), so the user can watch and join it, when this host
//!   has somewhere to make one. The answer says, per subagent, which
//!   workspace it got and where, or that it got none and why: the Chief
//!   repeats it to the user, so it must never claim more than happened.
//! - `spawn` takes an optional working directory (`~` is this host's home).
//!   A directory that does not exist here is reported and the default
//!   subagent directory is used.
//! - Its tools are zoom and date (its own MCP server says `--role
//!   subagent`), not spawn. Its tool calls stay in its own session.
//! - The brain (brain/spawns.rs) watches the sessions: when a
//!   subagent finishes a turn, its report reaches the chat as its own
//!   `user` message, `[id] report`.
//!
//! Deviation: `tell` reaches a running subagent after its current turn
//! (acpmux queues the prompt), not between its tool calls; it does not
//! steer yet.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use optchat_host::OptChat;
use serde_json::{Value, json};

use crate::acpmux::{AgentPort, SessionSpec, TurnSignal};
use crate::brain::Input;
use crate::tools::Orchestrator;
use crate::trace::Trace;
use crate::workspaces::Workspaces;

/// The acpmux tag naming a subagent's spawn, and the one naming the
/// subagent (`a<N>`).
pub const SPAWN_TAG: &str = "optchat.spawn";
pub const SUBAGENT_TAG: &str = "optchat.subagent";
/// Most tasks one spawn starts.
pub const MAX_TASKS: usize = 8;
/// Most subagents at work at once; a spawn over it queues the rest, which
/// start as others finish.
pub const MAX_LIVE: usize = 16;
/// Longest a Claude spawn waits for its first subagent's response to start
/// (the shared view's cache entry then exists) before it starts the rest.
pub const WARM_WAIT: Duration = Duration::from_secs(20);
/// Longest `spawn` waits for the view to settle (section 6).
pub const SETTLE_LIMIT: Duration = Duration::from_secs(240);
/// Prompt ids of the host's own prompts to a subagent start with this; any
/// other prompt in its session is the user's (typed into its chat).
pub const PROMPT_PREFIX: &str = "optchat-";

/// What one spawn was given: its id and its subagents' ids.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnPlan {
    pub spawn: String,
    pub ids: Vec<String>,
    /// The ids over `MAX_LIVE`: they wait for a free slot.
    pub queued: Vec<String>,
    /// The TTL of the turns' cache marks (`Brain::turn_cache_ttl`), None
    /// once a route refused our marks: a Claude subagent's first message
    /// is marked at the view's end with it.
    pub ttl: Option<crate::prompt::CacheTtl>,
    /// The engine of the turn that called spawn (engine.json); None before
    /// any turn.
    pub engine: Option<SpawnEngine>,
}

/// The engine a spawn's subagents run on: the calling turn's harness and
/// model (2026-10-08: the turns ran on codex, the subagents on claude-sr).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnEngine {
    pub harness: String,
    pub model: Option<String>,
    /// Its family when it is not the default harness's: the subagents then
    /// take that family's preset, `<subagent preset>-<family>`.
    pub other_family: Option<crate::acpmux::Family>,
}

/// The subagent preset of `family` beside the default one `preset`.
pub fn family_preset(preset: &str, family: crate::acpmux::Family) -> Option<String> {
    match family {
        crate::acpmux::Family::Claude => Some(format!("{preset}-claude")),
        crate::acpmux::Family::Codex => Some(format!("{preset}-codex")),
        crate::acpmux::Family::Other => None,
    }
}

/// How subagent sessions start.
#[derive(Clone, Debug)]
pub struct SubagentSettings {
    pub harness: String,
    pub policy: String,
    pub model: Option<String>,
    /// The subagent preset (required: never a fallback to the turn preset).
    pub preset: Option<String>,
    /// Every subagent's working directory (`optchat/subagent`).
    pub cwd: PathBuf,
    /// Session names are `<prefix>-<id>`.
    pub prefix: String,
    /// The `mux.parent` value (the Chief's children).
    pub parent: String,
    /// Claude harness: the system text for CLAUDE.md when acpmux took no
    /// preset system prompt. None on other harnesses (AGENTS.md is written
    /// at host start).
    pub claude_md: Option<String>,
}

/// A subagent session's tags: `mux.parent`, its spawn and its id.
pub fn tags(parent: &str, spawn: &str, id: &str) -> BTreeMap<String, String> {
    BTreeMap::from([
        (cmux_chief::rules::PARENT_TAG.to_owned(), parent.to_owned()),
        (SPAWN_TAG.to_owned(), spawn.to_owned()),
        (SUBAGENT_TAG.to_owned(), id.to_owned()),
    ])
}

/// A queued subagent's launch.
struct Waiting {
    spawn: String,
    task: String,
    floor: Option<String>,
    launch: SubagentSettings,
    ttl: Option<crate::prompt::CacheTtl>,
}

/// Serves `spawn` and `tell` (tools.rs `Orchestrator`).
pub struct Spawner {
    chat: Arc<OptChat>,
    agents: Arc<dyn AgentPort>,
    settings: SubagentSettings,
    tx: Mutex<Sender<Input>>,
    trace: Trace,
    workspaces: Option<Arc<dyn Workspaces>>,
    /// Why there are no workspaces, said in each answer when `workspaces`
    /// is None.
    no_workspace_reason: String,
    /// OPTCHAT_SUBAGENT_HARNESS pins the subagent harness: a spawn never
    /// follows the turn's engine.
    pinned: bool,
    /// Queued subagents' launches, by id, kept until a slot frees (in memory:
    /// a restarted host reports them as not started).
    waiting: Mutex<BTreeMap<String, Waiting>>,
    /// `WARM_WAIT` (shorter in tests).
    warm_wait: Duration,
    log: crate::brain::Log,
}

impl Spawner {
    pub fn new(
        chat: Arc<OptChat>,
        agents: Arc<dyn AgentPort>,
        settings: SubagentSettings,
        tx: Sender<Input>,
        log: crate::brain::Log,
    ) -> Spawner {
        Spawner {
            chat,
            agents,
            settings,
            tx: Mutex::new(tx),
            trace: Trace::off(),
            workspaces: None,
            no_workspace_reason: "this Chief host has nowhere to make cmux workspaces".to_owned(),
            pinned: false,
            waiting: Mutex::new(BTreeMap::new()),
            warm_wait: WARM_WAIT,
            log,
        }
    }

    pub fn with_trace(mut self, trace: Trace) -> Spawner {
        self.trace = trace;
        self
    }

    pub fn with_workspaces(mut self, workspaces: Option<Arc<dyn Workspaces>>) -> Spawner {
        self.workspaces = workspaces;
        self
    }

    /// The subagent harness is pinned (OPTCHAT_SUBAGENT_HARNESS): spawns
    /// never follow the turn's engine.
    pub fn with_pinned_harness(mut self, pinned: bool) -> Spawner {
        self.pinned = pinned;
        self
    }

    /// The settings of one spawn's subagents: the calling turn's harness
    /// and model with its family's preset, unless the harness is pinned.
    /// A family without a subagent preset stays on the default, and says so.
    fn engine_settings(&self, engine: Option<&SpawnEngine>) -> SubagentSettings {
        let mut s = self.settings.clone();
        let Some(e) = engine.filter(|_| !self.pinned) else {
            return s;
        };
        if e.harness == s.harness {
            s.model = s.model.or_else(|| e.model.clone());
            return s;
        }
        let preset = match e.other_family {
            None => s.preset.clone(),
            Some(family) => match s.preset.as_deref().and_then(|p| family_preset(p, family)) {
                Some(preset) => Some(preset),
                None => {
                    (self.log)(&format!(
                        "the turn runs on {}, which has no subagent preset; subagents run on {}",
                        e.harness, s.harness
                    ));
                    return s;
                }
            },
        };
        if e.other_family.is_some() {
            // The family preset carries its own instructions (a Claude
            // preset's system prompt, AGENTS.md for codex).
            s.claude_md = None;
        }
        s.harness = e.harness.clone();
        s.model = e.model.clone();
        s.preset = preset;
        s
    }

    /// How long a Claude spawn waits for its first subagent's response.
    pub fn with_warm_wait(mut self, wait: Duration) -> Spawner {
        self.warm_wait = wait;
        self
    }

    /// Why there are no workspaces (said in each spawn answer without them).
    pub fn with_no_workspace_reason(mut self, reason: impl Into<String>) -> Spawner {
        self.no_workspace_reason = reason.into();
        self
    }

    fn send(&self, input: Input) -> Result<(), String> {
        self.tx
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .send(input)
            .map_err(|_| "the Chief host is stopping".to_owned())
    }

    /// Starts subagent `id`'s session (in `s.cwd`) and first prompt, then its
    /// workspace; answers what the user can see of it: its workspace and
    /// where it lives, or that it has none and why.
    #[allow(clippy::too_many_arguments)]
    fn start_one(
        &self,
        spawn: &str,
        id: &str,
        task: &str,
        view: &str,
        floor: Option<&str>,
        s: &SubagentSettings,
        ttl: Option<crate::prompt::CacheTtl>,
        warm: Option<Sender<()>>,
    ) -> Result<(String, bool), String> {
        let began = Instant::now();
        // Claude only through acpmux's own Claude Code adapter (harness_gate).
        let admitted =
            crate::harness_gate::admit_live(&*self.agents, &s.harness).map_err(|reason| {
                crate::harness_gate::trace_refusal(&self.trace, "subagent", &s.harness, &reason);
                crate::harness_gate::refusal(&reason)
            })?;
        // A Claude session on a preset with a system prompt takes the cached
        // layout: our one mark ends the shared view, with the turns' TTL, and
        // Claude Code is told the same TTL (the API refuses a 1h mark after a
        // 5m one).
        let mark = ttl
            .filter(|_| admitted.family == crate::acpmux::Family::Claude)
            .filter(|_| {
                s.preset
                    .as_deref()
                    .is_some_and(|p| self.agents.system_prompt(p))
            })
            .and_then(|ttl| crate::prompt::Mark::last_whole(view, ttl));
        // The workspace key is chosen first, so the session starts knowing
        // its workspace (CMUX_WORKSPACE_ID; acpmux per-session env).
        let key = self
            .workspaces
            .as_ref()
            .map(|_| crate::workspaces::new_key());
        let spec = SessionSpec {
            name: format!("{}-{id}", s.prefix),
            cwd: s.cwd.clone(),
            harness: admitted.profile.clone(),
            // The spawn floor (`Brain::spawn_policy`) wins over the setting.
            policy: floor.unwrap_or(&s.policy).to_owned(),
            model: s.model.clone(),
            effort: None,
            preset: s.preset.clone(),
            tags: {
                let mut t = tags(&s.parent, spawn, id);
                if floor.is_some() {
                    t.insert(
                        crate::approval::POLICY_TAG.to_owned(),
                        crate::approval::ASK.to_owned(),
                    );
                }
                t
            },
            env: key
                .iter()
                .map(|k| ("CMUX_WORKSPACE_ID".to_owned(), crate::workspaces::env_id(k)))
                .chain(mark.map(|m| ttl_env(m.ttl)))
                .collect(),
        };
        let session = self.agents.new_session(&spec)?;
        let admitted = crate::harness_gate::session_harness(&*self.agents, &session, &admitted)
            .map_err(|reason| {
                let _ = self.agents.end_session(&session);
                crate::harness_gate::trace_refusal(&self.trace, "subagent", &s.harness, &reason);
                crate::harness_gate::refusal(&reason)
            })?;
        // Registered before its prompt: its turn end can only follow.
        self.send(Input::SubagentStarted {
            id: id.to_owned(),
            session_id: session.clone(),
            policy: floor.map(str::to_owned),
        })?;
        let (tx, rx) = channel();
        let prompt_id = format!("{PROMPT_PREFIX}sub:{id}:{}", now_ms());
        self.agents.start_prompt(
            &session,
            match mark {
                Some(mark) => {
                    crate::prompt::cached_layout_marked(
                        "",
                        view,
                        &format!("Your task:\n\n{task}"),
                        Some(mark),
                    )
                    .blocks
                }
                None => crate::prompt::subagent_blocks(view, task),
            },
            &prompt_id,
            tx,
        )?;
        self.forward_answer(id, rx, warm.map(|w| (session.clone(), w)));
        self.trace.emit(
            "subagent.start",
            json!({"id": id, "spawn": spawn, "session": session, "harness": s.harness, "harness_profile": admitted.profile, "harness_kind": admitted.kind, "harness_argv0": admitted.argv0, "ms": began.elapsed().as_millis() as u64}),
        );
        // The chat replays its history when the tab attaches, so the
        // workspace can follow the prompt.
        let Some(workspaces) = &self.workspaces else {
            self.trace.emit(
                "subagent.workspace",
                json!({"id": id, "spawn": spawn, "error": self.trace.text(&self.no_workspace_reason)}),
            );
            return Ok((
                format!("no cmux workspace ({})", self.no_workspace_reason),
                mark.is_some(),
            ));
        };
        let name = crate::workspaces::name(id, task);
        let key = key.unwrap_or_else(crate::workspaces::new_key);
        match workspaces.open(&key, &session, &name, &s.cwd) {
            Ok(key) => {
                let place = workspaces.place();
                self.trace.emit(
                    "subagent.workspace",
                    json!({"id": id, "spawn": spawn, "workspace": key, "name": name, "place": place}),
                );
                let note = format!("workspace \"{name}\" in {place}");
                let _ = self.send(Input::SubagentWorkspace {
                    id: id.to_owned(),
                    key,
                    name,
                });
                Ok((note, mark.is_some()))
            }
            Err(e) => {
                (self.log)(&format!("subagent {id}: opening its workspace: {e}"));
                self.trace.emit(
                    "subagent.workspace",
                    json!({"id": id, "spawn": spawn, "error": self.trace.text(&e)}),
                );
                Ok((
                    format!("no cmux workspace (opening it failed: {e})"),
                    mark.is_some(),
                ))
            }
        }
    }

    /// The directory subagents run in: `asked` when it exists on this host
    /// and the subagent instructions reach it, else the default with the
    /// reason.
    fn run_dir(&self, asked: Option<&str>, s: &SubagentSettings) -> (PathBuf, Option<String>) {
        let default = s.cwd.clone();
        let Some(asked) = asked else {
            return (default, None);
        };
        let home = std::env::var_os("HOME")
            .map(PathBuf::from)
            .unwrap_or_default();
        match resolve_cwd(asked, &home) {
            Err(e) => (
                default.clone(),
                Some(format!("{e}, so they run in {}", default.display())),
            ),
            // Without a preset system prompt the subagent instructions live
            // only in the default directory's CLAUDE.md.
            Ok(dir)
                if s.claude_md.is_some()
                    && !s
                        .preset
                        .as_deref()
                        .is_some_and(|p| self.agents.system_prompt(p)) =>
            {
                (
                    default.clone(),
                    Some(format!(
                        "this harness takes its instructions only from {}, so they run there, not in {}",
                        default.display(),
                        dir.display()
                    )),
                )
            }
            Ok(dir) => (dir, None),
        }
    }

    /// `Some("ask")` under the spawn floor (`Brain::spawn_policy`); `ask`
    /// too when the brain does not answer (fail closed).
    fn spawn_floor(&self) -> Option<String> {
        let (reply, answer) = channel();
        if self.send(Input::SpawnPolicy { reply }).is_err() {
            return Some(crate::approval::ASK.to_owned());
        }
        match answer.recv_timeout(Duration::from_secs(30)) {
            Ok(policy) => policy,
            Err(_) => Some(crate::approval::ASK.to_owned()),
        }
    }

    /// Sends the prompt's answer (token use, cost) to the brain; with
    /// `warm`, also says once when the response started streaming (the
    /// request's cache entry exists), as the compactor's single-flight does.
    fn forward_answer(
        &self,
        id: &str,
        rx: std::sync::mpsc::Receiver<TurnSignal>,
        warm: Option<(String, Sender<()>)>,
    ) {
        let tx = self
            .tx
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let id = id.to_owned();
        let agents = self.agents.clone();
        let mut warm = warm;
        std::thread::spawn(move || {
            while let Ok(signal) = rx.recv() {
                match signal {
                    TurnSignal::Changed => {
                        let spoke = warm.as_ref().is_some_and(|(session, _)| {
                            agents.events(session, 0).is_ok_and(|events| {
                                events.iter().any(|e| crate::acpmux::is_output(&e.kind))
                            })
                        });
                        if spoke && let Some((_, started)) = warm.take() {
                            let _ = started.send(());
                        }
                    }
                    TurnSignal::Done(answer) => {
                        let _ = tx.send(Input::SubagentAnswer { id, answer });
                        return;
                    }
                    TurnSignal::Lost => return,
                }
            }
        });
    }
}

impl Spawner {
    /// The queue starter: the brain sends a queued subagent's id when a slot
    /// frees, and it starts here with the view of that moment and its task.
    pub fn queue_starter(self: &Arc<Self>) -> Sender<String> {
        let (tx, rx) = channel::<String>();
        let me = Arc::downgrade(self);
        std::thread::Builder::new()
            .name("subagent-queue".into())
            .spawn(move || {
                while let Ok(id) = rx.recv() {
                    let Some(me) = me.upgrade() else { return };
                    me.start_waiting(&id);
                }
            })
            .ok();
        tx
    }

    fn start_waiting(&self, id: &str) {
        let waiting = self
            .waiting
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(id);
        let fail = |error: &str| {
            let _ = self.send(Input::SubagentFailed {
                id: id.to_owned(),
                error: error.to_owned(),
            });
        };
        let Some(w) = waiting else {
            return fail("the Chief host restarted while it waited for a free slot");
        };
        if !self.chat.settle(None, Some(SETTLE_LIMIT)) {
            return fail("the memory was still summarizing when its slot freed");
        }
        let view = self.chat.render_view().text;
        match self.start_one(
            &w.spawn,
            id,
            &w.task,
            &view,
            w.floor.as_deref(),
            &w.launch,
            w.ttl,
            None,
        ) {
            Ok((note, _)) => (self.log)(&format!("subagent {id} started from the queue: {note}")),
            Err(e) => fail(&e),
        }
    }

    /// Subagent `id`'s whole chat, one page of `page` characters from `at`.
    pub fn agent_chat_page(&self, id: &str, at: u64, page: u64) -> Result<String, String> {
        let (reply, answer) = channel();
        self.send(Input::SubSession {
            id: id.to_owned(),
            reply,
        })?;
        let session = answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
            .ok_or_else(|| format!("no subagent {id} with a session"))?;
        let events = self.agents.events(&session, 0)?;
        let text = crate::agent_chat::render(&crate::agent_chat::entries(&events));
        Ok(crate::agent_chat::page(id, &text, at, page))
    }
}

/// The session env that gives Claude Code the TTL of our mark.
fn ttl_env(ttl: crate::prompt::CacheTtl) -> (String, String) {
    match ttl {
        crate::prompt::CacheTtl::OneHour => {
            ("CLAUDE_CODE_PROMPT_CACHE_TTL".to_owned(), "1h".to_owned())
        }
        crate::prompt::CacheTtl::FiveMinutes => {
            ("FORCE_PROMPT_CACHING_5M".to_owned(), "1".to_owned())
        }
    }
}

/// `asked` as a directory on this host: `~` and `~/...` are `home`; it must
/// be absolute and exist.
pub fn resolve_cwd(asked: &str, home: &Path) -> Result<PathBuf, String> {
    let asked = asked.trim();
    let dir = if asked == "~" {
        home.to_owned()
    } else if let Some(rest) = asked.strip_prefix("~/") {
        home.join(rest)
    } else {
        PathBuf::from(asked)
    };
    if !dir.is_absolute() {
        return Err(format!("{asked} is not an absolute directory"));
    }
    if !dir.is_dir() {
        return Err(format!("{} does not exist on this host", dir.display()));
    }
    Ok(dir)
}

impl Orchestrator for Spawner {
    fn spawn(&self, tasks: Vec<String>, cwd: Option<String>) -> Result<String, String> {
        if tasks.len() > MAX_TASKS {
            return Err(format!(
                "spawn takes at most {MAX_TASKS} tasks; split the work"
            ));
        }
        let began = Instant::now();
        // Section 9: the view at spawn time, after settle.
        if !self.chat.settle(None, Some(SETTLE_LIMIT)) {
            return Err(
                "the memory is still summarizing, so no subagent started; call spawn again".into(),
            );
        }
        let view = self.chat.render_view().text;
        let (reply, answer) = channel();
        self.send(Input::SpawnRegister {
            tasks: tasks.clone(),
            reply,
        })?;
        let plan = answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())??;
        let run = self.engine_settings(plan.engine.as_ref());
        self.trace.emit(
            "spawn",
            json!({
                "spawn": plan.spawn,
                "ids": plan.ids,
                "tasks": tasks.iter().map(|t| self.trace.text(t)).collect::<Vec<_>>(),
                "settle_ms": began.elapsed().as_millis() as u64,
                "view": {"bytes": view.len(), "hash": crate::trace::hash(&view)},
                "harness": run.harness,
            }),
        );
        if let (Some(text), Some(preset)) = (&run.claude_md, &run.preset) {
            let file = (!self.agents.system_prompt(preset)).then_some(text.as_str());
            if let Err(e) = crate::session_dir::set_claude_md(&run.cwd, file) {
                (self.log)(&format!("the subagent directory's CLAUDE.md: {e}"));
            }
        }
        // The security floor: during a remote-origin (ask) turn, or while an
        // ask child or subagent lives, every subagent runs with policy ask.
        // No answer from the brain fails closed (ask).
        let floor = self.spawn_floor();
        let (dir, dir_note) = self.run_dir(cwd.as_deref(), &run);
        // The run's settings in the directory they start in.
        let launch = SubagentSettings {
            cwd: dir.clone(),
            ..run.clone()
        };
        let mut started = Vec::new();
        let mut lines = Vec::new();
        for (id, task) in plan.ids.iter().zip(&tasks) {
            if plan.queued.contains(id) {
                self.waiting
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .insert(
                        id.clone(),
                        Waiting {
                            spawn: plan.spawn.clone(),
                            task: task.clone(),
                            floor: floor.clone(),
                            launch: launch.clone(),
                            ttl: plan.ttl,
                        },
                    );
                lines.push(format!(
                    "- {id}: queued ({MAX_LIVE} subagents are at work, the most at once; it starts when one finishes)"
                ));
                continue;
            }
            // Single flight on the shared view: the first subagent starts
            // alone; the rest once its response began, so they read the
            // view's cache entry instead of each writing it.
            let first = started.is_empty();
            let rest = plan.ids.iter().filter(|i| !plan.queued.contains(i)).count() > 1;
            let (warm_tx, warm_rx) = channel();
            let warm = (first && rest).then_some(warm_tx);
            match self.start_one(
                &plan.spawn,
                id,
                task,
                &view,
                floor.as_deref(),
                &launch,
                plan.ttl,
                warm,
            ) {
                Ok((note, marked)) => {
                    started.push(id.clone());
                    lines.push(format!("- {id}: {note}"));
                    if first && rest && marked {
                        let wait = Instant::now();
                        let spoke = warm_rx.recv_timeout(self.warm_wait).is_ok();
                        self.trace.emit(
                            "spawn.warm",
                            json!({"spawn": plan.spawn, "first": id, "started": spoke, "ms": wait.elapsed().as_millis() as u64}),
                        );
                    }
                }
                Err(e) => {
                    (self.log)(&format!("subagent {id} did not start: {e}"));
                    let _ = self.send(Input::SubagentFailed {
                        id: id.clone(),
                        error: e.clone(),
                    });
                    lines.push(format!("- {id}: did not start ({e})"));
                }
            }
        }
        let head = if started.is_empty() && plan.queued.is_empty() {
            "No subagent started.".to_owned()
        } else if started.is_empty() {
            format!("Queued {}.", plan.queued.join(", "))
        } else {
            format!("Started {} in {}.", started.join(", "), dir.display())
        };
        let dir_note = dir_note
            .map(|n| format!("\nDirectory: {n}."))
            .unwrap_or_default();
        Ok(format!(
            "{head}{dir_note}\n{}\nTell the user only what these lines say about workspaces. Each one's report reaches you as a message, \"[id] report\", when it finishes; never wait or poll for them. tell(id, message) sends one more instructions.",
            lines.join("\n")
        ))
    }

    fn agent_chat(&self, id: &str, at: u64) -> Result<String, String> {
        self.agent_chat_page(id, at, crate::agent_chat::PAGE)
    }

    fn tell(&self, id: &str, message: &str) -> Result<String, String> {
        let (reply, answer) = channel();
        self.send(Input::Tell {
            id: id.to_owned(),
            message: message.to_owned(),
            reply,
        })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }
}

/// The answer of a prompt to a subagent: its token use and cost.
pub fn answer_fields(answer: &Result<Value, String>) -> Value {
    match answer {
        Ok(v) => json!({
            "usage": crate::fold::answer_usage(v).map(|(u, _)| crate::trace::usage(&u)),
            "cost_usd": crate::turn::answer_cost(v),
            "stop": v.get("stopReason"),
        }),
        Err(e) => json!({"error": crate::trace::prefix(e)}),
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}
