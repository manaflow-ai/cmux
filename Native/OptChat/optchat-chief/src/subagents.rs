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
//!   ids at once. A subagent the Chief shows (`spawn(sidebar)` under the
//!   user's rules, sidebar_choice.rs, a1018) also gets a cmux workspace whose
//!   tab is its chat (workspaces.rs), so the user can watch and join it, when
//!   this host has somewhere to make one; a hidden one (#26386) is reached
//!   from its link and `control show` opens its workspace later. The answer says, per subagent, which workspace it got
//!   and where, that it is hidden, or that it got none and why: the Chief
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
//! - `tell` to a running subagent is steered into its session (read
//!   between its tool calls; brain/spawns.rs), else it is its next prompt.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use cmux_chief::acp::{TurnFolder, TurnOutput};
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
/// Most tasks one spawn starts (Leo, 2026-11-02: eight made a fan-out take
/// a second call).
pub const MAX_TASKS: usize = 24;
/// The environment variable that caps how many subagents work at once
/// (`live_limit`). Unset, empty or `0`: no cap.
pub const MAX_LIVE_ENV: &str = "OPTCHAT_MAX_LIVE_SUBAGENTS";

/// How many subagents may work at once: the value of [`MAX_LIVE_ENV`], or
/// None (no cap, the default; 2026-10-18 the user: a fixed cap of 16 left
/// subagents queued while the Mac had room for them). Over the cap a spawn
/// queues the rest, which start as others finish.
pub fn live_limit(value: Option<&str>) -> Option<usize> {
    value
        .map(str::trim)
        .and_then(|v| v.parse::<usize>().ok())
        .filter(|n| *n > 0)
}
/// A cap on subagents at work at once, with where it came from. There is
/// none by default: a cap is opt-in, from [`MAX_LIVE_ENV`] or `control cap`
/// (2026-10-20 the user: "we need to remove 40 agent limit by default").
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum LiveCap {
    /// Set at run time with `control cap N` (saved as `live_cap`).
    Control(usize),
    /// Set by [`MAX_LIVE_ENV`] when the host started.
    Env(usize),
}

impl LiveCap {
    /// How many subagents may work at once.
    pub fn n(self) -> usize {
        match self {
            LiveCap::Control(n) | LiveCap::Env(n) => n,
        }
    }

    /// Where the cap came from and how to lift it, for a queued line: the
    /// user asked why agents waited, and the old line named the env even
    /// for a `control cap`.
    pub fn source(self) -> String {
        match self {
            LiveCap::Control(n) => format!("set with `control cap {n}`"),
            LiveCap::Env(n) => format!("set by {MAX_LIVE_ENV}={n}"),
        }
    }
}

/// Longest `spawn` waits for the view to settle (section 6), as a turn does
/// (a user turn never waits more than SETTLE_BOUND, 1 s, on compaction):
/// then the subagent gets the view with the lines still building as the
/// placeholder.
pub const SETTLE_LIMIT: Duration = crate::brain::SETTLE_BOUND;
/// Prompt ids of the host's own prompts to a subagent start with this; any
/// other prompt in its session is the user's (typed into its chat).
pub const PROMPT_PREFIX: &str = "optchat-";

/// acpmux errors of a session whose agent host failed to come up, which a
/// second `session/new` usually gets past (acpmux agent_host/link.rs).
const TRANSIENT_START_FAILURES: [&str; 3] = [
    "agent host did not answer hello",
    "agent host closed the connection during hello",
    "agent host exited before it was ready",
];

/// acpmux's error for a harness that exited while it started (`initialize`,
/// `session/new`), with the stderr line that says why when it has one:
/// "agent process closed (claude-sr2): <line>" (acpmux hub/turns.rs
/// `explain_start_failure`).
const PROCESS_CLOSED: &str = "agent process closed";

/// Words of a stderr reason that a moment later is gone: sr2 or Claude Code
/// could not reach its gateway in time (acp-chief-issues.md #3, 2026-10-19:
/// "read rotation: ... context deadline exceeded", "connect: connection
/// refused", "502").
const PASSING_REASONS: [&str; 10] = [
    "deadline exceeded",
    "timeout",
    "timed out",
    "connection refused",
    "connection reset",
    "econnrefused",
    "econnreset",
    "rotation",
    "502",
    "503",
];

/// Whether `error` (a failed `session/new`) is worth another try: an agent
/// host that missed its handshake, or a harness that closed while it started
/// with no reason or a passing one (never one that is not signed in, or
/// refused its arguments).
pub fn is_transient_start_failure(error: &str) -> bool {
    if TRANSIENT_START_FAILURES.iter().any(|t| error.contains(t)) {
        return true;
    }
    let Some(at) = error.find(PROCESS_CLOSED) else {
        return false;
    };
    let reason = error[at + PROCESS_CLOSED.len()..].trim();
    if reason.is_empty() {
        return true;
    }
    let reason = reason.to_ascii_lowercase();
    PASSING_REASONS.iter().any(|w| reason.contains(w))
}

/// The pauses before the second and third `session/new` of a subagent whose
/// start failed for a passing reason (``is_transient_start_failure``): sr2
/// that could not reach its gateway in time usually can a moment later.
pub const START_RETRY_PAUSES: [Duration; 2] = [Duration::from_secs(1), Duration::from_secs(3)];

/// What one spawn was given: its id and its subagents' ids.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnPlan {
    pub spawn: String,
    pub ids: Vec<String>,
    /// The ids over the cap (`live_limit`): they wait for a free slot.
    pub queued: Vec<String>,
    /// The cap in force, when there is one, with where it came from.
    pub limit: Option<LiveCap>,
    /// The engine of the turn that called spawn (engine.json); None before
    /// any turn.
    pub engine: Option<SpawnEngine>,
    /// The acpmux peer its subagents run on (cloud; the first one's when
    /// they differ); None: this host.
    pub peer: Option<String>,
    /// Each subagent's peer, in `ids` order (B4: the least busy one each).
    pub peers: Vec<Option<String>>,
    /// Each subagent's own VM size (one VM per subagent), in `ids` order;
    /// None: a shared peer or this host.
    pub sizes: Vec<Option<String>>,
    /// Why each id was placed here, on a paired machine or in Cloud.
    pub placements: Vec<crate::place_route::Placement>,
}

/// The engine a spawn's subagents run on: the calling turn's harness and
/// model (2026-10-08: the turns ran on codex, the subagents on claude-sr).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SpawnEngine {
    pub harness: String,
    pub model: Option<String>,
    /// The calling turn's effort: subagents think as hard as it by default.
    pub effort: Option<String>,
    /// Its family when it is not the default harness's: the subagents then
    /// take that family's preset, `<subagent preset>-<family>`.
    pub other_family: Option<crate::acpmux::Family>,
}

/// Whether a spawn may route its subagents to another harness (Leo,
/// 2026-11-01: "maybe toggle off-able but if you look into grokbot they auto
/// route stuff all the time"): cmux.json `chief.autoRouteSubagents`, off
/// unless the person set it true (Leo, 2026-11-01: "optional ofc we don't
/// wanna change defaults or whatnot yet").
pub fn auto_route_on(user: Option<&Value>) -> bool {
    user.and_then(|d| crate::agent_memory::settings::value(d, "chief.autoRouteSubagents"))
        .and_then(|v| v.as_bool())
        .unwrap_or(false)
}

/// Whether a spawn may name its subagents' harness or model: this Chief's
/// engine.json `subagent_routing` (`chief engine set --subagent-routing`),
/// else the user's cmux.json (`auto_route_on`), else off.
pub fn routing_on(engine: &crate::engine::EngineChoice, user: Option<&Value>) -> bool {
    match engine.subagent_routing.as_deref().map(str::trim) {
        Some("auto") => true,
        Some("off") => false,
        _ => auto_route_on(user),
    }
}

/// The line a spawn answer names an automatic pick by: `Routed to codex (code
/// task)`, with the model when the pick chose one.
fn route_line(p: &crate::spawn_route::Pick) -> String {
    match &p.model {
        Some(m) => format!("Routed to {} on {m} ({})", p.harness, p.kind.reason()),
        None => format!("Routed to {} ({})", p.harness, p.kind.reason()),
    }
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
    /// How hard the subagents think (`spawn`'s effort, else the turn's, else
    /// this one: `OPTCHAT_SUBAGENT_EFFORT`, else medium on Claude and codex).
    pub effort: Option<String>,
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

/// A subagent session's tags: `mux.parent`, its spawn and its id, and the
/// names acpmux's approval cards give it (`mux.handle` its id, `mux.label`
/// its `title`, the name of its workspace).
pub fn tags(parent: &str, spawn: &str, id: &str, title: &str) -> BTreeMap<String, String> {
    use cmux_chief::rules::{HANDLE_TAG, LABEL_TAG, PARENT_TAG};
    BTreeMap::from([
        (PARENT_TAG.to_owned(), parent.to_owned()),
        (SPAWN_TAG.to_owned(), spawn.to_owned()),
        (SUBAGENT_TAG.to_owned(), id.to_owned()),
        (HANDLE_TAG.to_owned(), id.to_owned()),
        (LABEL_TAG.to_owned(), title.to_owned()),
    ])
}

/// What the brain sends the queue starter: a queued subagent and what its
/// record keeps of its launch, so it starts even after the host restarted
/// (the launch in `Spawner::waiting` lives in memory only).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct QueuedStart {
    pub id: String,
    pub spawn: String,
    /// The saved launch (None: a record from before it was saved).
    pub launch: Option<crate::state::QueuedLaunch>,
    /// The engine of now, for a launch that must be rebuilt.
    pub engine: Option<SpawnEngine>,
    /// Messages the Chief told it while it was queued: they go in after
    /// its task.
    pub extra: Option<String>,
}

/// Where cloud subagents run (plans/cmux-next/cloud-subagents-DESIGN.md):
/// an acpmux peer on a cloud VM. Set from `OPTCHAT_SUBAGENT_PEER`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CloudPlacement {
    /// The acpmux peer name (`acpmux host ls`).
    pub peer: String,
    /// The folder sessions start in on the peer (`OPTCHAT_SUBAGENT_PEER_DIR`).
    pub dir: PathBuf,
    /// The peer's harness profile (`OPTCHAT_SUBAGENT_PEER_HARNESS`).
    pub harness: String,
    /// The subagent system text: local presets do not exist on the peer, so
    /// it goes in front of the first message.
    pub instructions: String,
}

/// The repo a `spawn(cwd)` folder on the Mac names, for its clone on the VM
/// (`~/src/<repo>`): the folder's last part, a `<repo>-worktrees/<x>`
/// folder's repo.
pub fn cloud_repo(cwd: Option<&str>) -> Option<String> {
    let parts: Vec<&str> = cwd?
        .split('/')
        .filter(|p| !p.is_empty() && *p != "~" && *p != ".")
        .collect();
    if let Some(k) = parts.iter().position(|p| p.ends_with("-worktrees")) {
        return Some(parts[k].trim_end_matches("-worktrees").to_owned());
    }
    parts.last().map(|p| (*p).to_owned())
}

/// The `control cloud` value that gives each subagent its own Freestyle VM
/// (one VM per subagent, cloud-subagents-DESIGN.md) instead of naming
/// shared peers.
pub const PER_AGENT: &str = "freestyle";

/// The VM sizes a subagent can get (cmuxterm-hq `tools/cloud-subagents`
/// `SIZES`): small 2 vCPU / 4 GiB, medium 4 / 8, large 8 / 16.
pub const SIZES: [&str; 3] = ["small", "medium", "large"];

/// Subagent `id`'s own VM and acpmux peer.
pub fn agent_peer(id: &str) -> String {
    format!("chief-sub-{id}")
}

/// Whether `peer` is a subagent's own VM (`chief-sub-a<N>`).
pub fn is_agent_peer(peer: &str) -> bool {
    peer.strip_prefix("chief-sub-a")
        .is_some_and(|n| !n.is_empty() && n.bytes().all(|b| b.is_ascii_digit()))
}

fn mentions(task: &str, words: &[&str]) -> bool {
    let t = task.to_lowercase();
    words.iter().any(|w| t.contains(w))
}

/// Whether a task needs this Mac: the app's UI, screenshots, computer use,
/// a tagged build to launch, the simulator or a sign-in. Those subagents
/// stay here; everything else may run in its own VM.
pub fn needs_mac(task: &str) -> bool {
    crate::place_route::Need::of(task) == crate::place_route::Need::MacOnly
}

/// The VM size a task needs: `medium` for tests, type checks and installs
/// (bun, node, go); `small` otherwise (design, docs, review, plain edits).
/// Swift, Rust and app builds go to the Mac-mini fleet, so no task gets
/// `large` unless the Chief asks for it (`place: "cloud:large"`).
pub fn size_for(task: &str) -> &'static str {
    if mentions(
        task,
        &[
            "bun test",
            "bun run",
            "npm ",
            "pnpm",
            "vitest",
            "playwright",
            "typecheck",
            "tsc",
            "go test",
            "pytest",
            "web/",
            "next build",
        ],
    ) {
        "medium"
    } else {
        "small"
    }
}

/// The environment variable naming the acpmux peer cloud subagents run on;
/// unset or empty: they run on this machine.
pub const PEER_ENV: &str = "OPTCHAT_SUBAGENT_PEER";

impl CloudPlacement {
    /// The placement `OPTCHAT_SUBAGENT_PEER` (and `_PEER_DIR`,
    /// `_PEER_HARNESS`) set, if any; `instructions` is the subagent system
    /// text.
    pub fn from_env(
        env: impl Fn(&str) -> Option<String>,
        instructions: String,
    ) -> Option<CloudPlacement> {
        let peer = env(PEER_ENV)
            .map(|p| p.trim().to_owned())
            .filter(|p| !p.is_empty())?;
        Some(CloudPlacement {
            peer,
            dir: env("OPTCHAT_SUBAGENT_PEER_DIR")
                .filter(|d| d.starts_with('/'))
                .map_or_else(PathBuf::new, PathBuf::from),
            harness: env("OPTCHAT_SUBAGENT_PEER_HARNESS")
                .filter(|h| !h.trim().is_empty())
                .unwrap_or_else(|| "claude".to_owned()),
            instructions,
        })
    }

    /// The first message's task on the peer: the subagent system text (no
    /// preset there), where it runs and how it gets its own worktree.
    ///
    /// It opens with the task's own `Title:` line, and its `Group: Chief agents`
    /// line when it has one (`workspaces::spawn_group`; no other group, #27712):
    /// the workspace name and group are read from this text (`workspaces::title`)
    /// and so is the peer session's title (acpmux `prompt_gist`). With the
    /// instructions first, 31 workspaces read "You are a subagent of Chief, an…"
    /// (Oct 22-25; since 82a981959a4, Oct 19).
    pub fn task(&self, id: &str, asked: Option<&str>, task: &str) -> String {
        let repo = cloud_repo(asked).unwrap_or_else(|| "cmux".to_owned());
        // The daemon resolves an empty peer cwd inside its allowed webRoots.
        let dir = if self.dir.as_os_str().is_empty() {
            "\"$PWD\"".to_owned()
        } else {
            self.dir.display().to_string()
        };
        let land = if self.dir.as_os_str().is_empty() {
            "git config cmux.land <branch>".to_owned()
        } else {
            format!("git -C {dir}/{id} config cmux.land <branch>")
        };
        format!(
            "Title: {title}\n{group}\n{}\n\n# Where you run\n\nYou run on the cloud VM `{peer}` (acpmux peer `{peer}`), not on the user's Mac. Paths in the view and the task that start with ~/fun or /Users are the Mac's: here the repo `{repo}` is a clone at ~/src/{repo}. Make your own worktree before you change anything: `git -C ~/src/{repo} fetch -q origin && git -C ~/src/{repo} worktree add {dir}/{id} origin/<branch>` and work in {dir}/{id}. Mac builds and tests go to the fleet (cmux-ci); this VM reaches the fleet controller and sr2 only. Your zoom and date tools are not here. This VM has no GitHub credential, never a token; do not ask for one. To land, commit everything, then run `{land}` (the branch it goes to, e.g. feat-cmux-next): when your final report pauses this VM, the Chief host rebases those commits on the newest origin branch and pushes them plain through the Mac. Say the worktree path, sha and branch in your report.\n\n{fleet}\n\n{task}",
            self.instructions.trim_end(),
            title = crate::workspaces::title(task),
            group = match crate::workspaces::spawn_group(task) {
                "" => String::new(),
                g => format!("Group: {g}\n"),
            },
            fleet = crate::fleet_wait::NOTE,
            peer = self.peer,
        )
    }
}

/// A queued subagent's launch.
struct Waiting {
    spawn: String,
    task: String,
    floor: Option<String>,
    launch: SubagentSettings,
}

/// Serves `spawn` and `tell` (tools.rs `Orchestrator`).
/// What `spawn` answers for its Direct tasks (action_lifetime.rs): not started, and why, so the
/// Chief makes the change itself with its cmux workspace tools.
fn direct_refusal(direct: &[String], why: impl Fn(&str) -> String) -> String {
    let list = direct
        .iter()
        .map(|t| format!("\"{}\" ({})", crate::workspaces::title(t), why(t)))
        .collect::<Vec<_>>()
        .join("; ");
    let organize = direct.iter().any(|t| {
        crate::action_lifetime::is_organize(&crate::sidebar_choice::body(t).to_lowercase())
    });
    let tools = if organize {
        " with the cmux workspace tools (workspace_list, workspace_group_create with reuse, \
         workspace_place, workspace_rename, workspace_move, workspace_group_update)"
    } else {
        " with your own tools"
    };
    format!("not started: {list}. Do it yourself now{tools}; no helper and no workspace.")
}

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
    log: crate::brain::Log,
    /// This Chief's grant (chief_profile.rs): the harnesses the person lets
    /// its subagents use (its record's `harnesses`; empty: every harness),
    /// read at each spawn (a default Chief's record can arrive late).
    grant: Option<std::sync::Arc<crate::chief_profile::ChiefTools>>,
    /// Queued ids of a spawn the grant refused, with the refusal: the queue
    /// starter fails them with it when the brain dequeues them.
    refused: Mutex<BTreeMap<String, String>>,
    /// Cloud placement: new subagents start on this acpmux peer.
    cloud: Option<CloudPlacement>,
    /// The subagent system text for a peer set at run time
    /// (`control cloud`) when the env set none.
    cloud_text: Option<String>,
    /// The VMs behind cloud peers (B4): resumed before a subagent starts.
    cloud_vms: Option<Arc<dyn crate::cloud_vms::CloudVms>>,
    /// Issues each cloud subagent its own sandbox key (agent_keys.rs); None: off.
    agent_keys: Option<Arc<dyn crate::agent_keys::AgentKeys>>,
    /// The person profile `remember` writes (`optchat/person.md`); None: no
    /// profile on this host.
    person: Option<std::path::PathBuf>,
    /// The app's Cloud actions `cloud_workspace` runs (cloud_workspace.rs);
    /// None: no cmux app behind this host.
    cloud_workspaces: Option<Arc<crate::cloud_workspace::CloudWorkspaces>>,
    /// This Chief's engine.json, read at each spawn for `subagent_routing`
    /// and `subagent_harness`; None: neither is set.
    engine_file: Option<std::path::PathBuf>,
    /// Every harness acpmux admitted and its family, what the automatic
    /// picker (spawn_route.rs) chooses from; empty: it picks nothing.
    families: BTreeMap<String, crate::acpmux::Family>,
    /// The user's settings file read at each spawn for the sidebar rules
    /// (sidebar_choice.rs); None: the one `agent_memory::settings` finds.
    user_settings: Option<PathBuf>,
    /// A Claude subagent here works under `/goal` until its task is done
    /// (goal.rs), unless the person turned it off; off in a bare Spawner.
    goal: bool,
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
            log,
            grant: None,
            refused: Mutex::new(BTreeMap::new()),
            cloud: None,
            cloud_text: None,
            cloud_vms: None,
            agent_keys: None,
            person: None,
            cloud_workspaces: None,
            engine_file: None,
            families: BTreeMap::new(),
            user_settings: None,
            goal: false,
        }
    }

    /// Claude subagents here start under `/goal` (goal.rs) and on Opus 5.5
    /// when nothing names their model.
    pub fn with_goal(mut self, goal: bool) -> Spawner {
        self.goal = goal;
        self
    }

    /// Reads the sidebar rules from `path` instead of the user's cmux-next.json.
    pub fn with_user_settings(mut self, path: Option<PathBuf>) -> Spawner {
        self.user_settings = path;
        self
    }

    /// `cloud_workspace` makes Cloud workspaces through `cloud` (None: off).
    pub fn with_cloud_workspaces(
        mut self,
        cloud: Option<Arc<crate::cloud_workspace::CloudWorkspaces>>,
    ) -> Spawner {
        self.cloud_workspaces = cloud;
        self
    }

    /// `remember` keeps preferences in the profile at `path`.
    pub fn with_person(mut self, path: std::path::PathBuf) -> Spawner {
        self.person = Some(path);
        self
    }

    /// Cloud subagents get their own sandbox key from `keys` (None: off).
    pub fn with_agent_keys(
        mut self,
        keys: Option<Arc<dyn crate::agent_keys::AgentKeys>>,
    ) -> Spawner {
        self.agent_keys = keys;
        self
    }

    /// A cloud subagent's own sandbox key: issued, placed on its VM, and the
    /// task note that names its file; None (logged) when keys are off or a
    /// step failed, and then the subagent starts without one. A key placed
    /// nowhere is revoked at once.
    fn agent_key(&self, peer: &str, id: &str) -> Option<(String, String)> {
        let keys = self.agent_keys.as_ref()?;
        let Some(vms) = &self.cloud_vms else {
            (self.log)(&format!("agent key for {id}: no pool tool to place it"));
            return None;
        };
        let key = match keys.issue(id) {
            Ok(key) => key,
            Err(e) => {
                (self.log)(&format!("agent key for {id}: {e}"));
                return None;
            }
        };
        if let Err(e) = vms.put_agent_key(peer, id, &key.file) {
            (self.log)(&format!("agent key for {id} on {peer}: {e}"));
            if let Err(e) = keys.revoke(&key.id) {
                (self.log)(&format!("agent key {} (unplaced): revoke: {e}", key.id));
            }
            return None;
        }
        (self.log)(&format!("agent key {} for {id} on {peer}", key.id));
        Some((key.id, crate::agent_keys::task_note(id)))
    }

    /// New subagents start on this peer (None: on this machine).
    /// The subagent system text a cloud subagent gets in its first message
    /// when the peer comes from `control cloud` (no env placement).
    pub fn with_cloud_text(mut self, text: String) -> Spawner {
        self.cloud_text = Some(text);
        self
    }

    /// The placement on `peer`: the env's folder and harness when it set
    /// one, else the defaults (daemon-selected scratch folder, `claude`).
    fn placement(&self, peer: &str) -> CloudPlacement {
        match &self.cloud {
            Some(c) => CloudPlacement {
                peer: peer.to_owned(),
                ..c.clone()
            },
            None => CloudPlacement {
                peer: peer.to_owned(),
                dir: PathBuf::new(),
                harness: "claude".to_owned(),
                instructions: self.cloud_text.clone().unwrap_or_default(),
            },
        }
    }

    /// The VMs behind cloud peers: resumed before a subagent starts or is
    /// told there.
    pub fn with_cloud_vms(mut self, vms: Option<Arc<dyn crate::cloud_vms::CloudVms>>) -> Spawner {
        self.cloud_vms = vms;
        self
    }

    pub fn with_cloud(mut self, cloud: Option<CloudPlacement>) -> Spawner {
        self.cloud = cloud;
        self
    }

    /// The person's harness grant (empty: every harness).
    pub fn with_harness_grant(
        mut self,
        grant: std::sync::Arc<crate::chief_profile::ChiefTools>,
    ) -> Spawner {
        self.grant = Some(grant);
        self
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

    /// This Chief's engine.json (`subagent_routing`, `subagent_harness`).
    pub fn with_engine_file(mut self, file: Option<std::path::PathBuf>) -> Spawner {
        self.engine_file = file;
        self
    }

    /// The harnesses the automatic picker chooses from, with their families.
    pub fn with_families(mut self, families: BTreeMap<String, crate::acpmux::Family>) -> Spawner {
        self.families = families;
        self
    }

    /// Whether subagent routing is on now (`routing_on`: engine.json, then
    /// cmux.json, else off).
    fn routing_enabled(&self, choice: &crate::engine::EngineChoice) -> bool {
        let user = std::env::var_os("HOME")
            .and_then(|home| crate::agent_memory::settings::document(std::path::Path::new(&home)));
        routing_on(choice, user.as_ref())
    }

    /// The automatic picker's choice for `task` over `default`, among the
    /// harnesses acpmux admitted and the person's grant allows.
    fn pick_for(&self, task: &str, default: &str) -> Option<crate::spawn_route::Pick> {
        let grant = self.grant.as_ref().map(|g| g.grant());
        let allowed = |h: &str| grant.as_ref().is_none_or(|g| g.allows_harness(h));
        let offered = |h: &str| -> Vec<String> {
            self.agents
                .offered_models(h)
                .unwrap_or_default()
                .iter()
                .filter_map(|m| m.get("id").and_then(Value::as_str).map(str::to_owned))
                .collect()
        };
        // Only the families the host made a subagent preset for (host.rs:
        // the subagent harness's own, and the other family's).
        let base = self
            .families
            .get(&self.settings.harness)
            .copied()
            .unwrap_or(crate::acpmux::Family::Claude);
        let prepared = crate::spawn_route::prepared_families(base);
        let families: BTreeMap<String, crate::acpmux::Family> = self
            .families
            .iter()
            .filter(|(_, f)| prepared.contains(f))
            .map(|(h, f)| (h.clone(), *f))
            .collect();
        crate::spawn_route::pick(task, default, &families, &allowed, &offered)
    }

    /// Read acpmux off the brain thread. A peer with unknown login/health
    /// is kept for explicit placement, but never chosen automatically.
    fn machine_table(&self) -> Vec<crate::place_route::Machine> {
        use crate::place_route::{Kind, login_families, machine};
        let status = self.agents.machine_status().unwrap_or_else(|e| {
            (self.log)(&format!("machine placement: {e}"));
            json!({"here": {"os": std::env::consts::OS, "pressure": {"ok": true}}})
        });
        let mut machines = vec![machine("here", Kind::ThisMac, &status["here"], Vec::new())];
        // Read peers together: an old peer's bounded RPC deadline must not
        // multiply by the number of paired machines. Join in listing order.
        machines.extend(std::thread::scope(|scope| {
            let reads: Vec<_> = status["peers"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(|row| Some((row, row["name"].as_str()?)))
                .map(|(row, name)| {
                    scope.spawn(move || {
                        let connected = row["connected"].as_bool() == Some(true);
                        let logins = if connected
                            && row.pointer("/health/pressure/ok").and_then(Value::as_bool)
                                == Some(true)
                        {
                            match (
                                self.agents.harness_catalog_on(Some(name)),
                                self.agents.harness_health_on(Some(name)),
                            ) {
                                (Ok(catalog), Ok(health)) => login_families(&catalog, &health),
                                _ => Vec::new(),
                            }
                        } else {
                            Vec::new()
                        };
                        let mut m = machine(name, Kind::Paired, &row["health"], logins);
                        m.connected = connected;
                        m
                    })
                })
                .collect();
            reads
                .into_iter()
                .filter_map(|read| read.join().ok())
                .collect::<Vec<_>>()
        }));
        machines
    }

    fn machine_login(
        &self,
        mut launch: SubagentSettings,
        default: &str,
        peer: Option<&str>,
    ) -> Result<(SubagentSettings, String), String> {
        // Old peers may not support scoped catalogs at all. An actual
        // catalog, including an empty one, must pass admission before launch.
        let catalog = self
            .agents
            .harness_catalog_on(peer)
            .ok()
            .filter(|answer| answer["harnesses"].is_object());
        let health = self.agents.harness_health_on(peer).unwrap_or_default();
        let admit = |catalog: &Value, harness: &str| {
            if peer.is_some() {
                crate::harness_gate::admit_peer(catalog, harness)
            } else {
                crate::harness_gate::admit(catalog, harness)
            }
        };
        // Peer auth is cached and may be stale. It can suggest another harness,
        // but only session creation can establish a current login failure.
        let unavailable = |harness: &str| -> Result<Option<&str>, String> {
            let profile = match catalog.as_ref() {
                Some(catalog) => admit(catalog, harness)?.profile,
                None => harness.to_owned(),
            };
            Ok(health["harnesses"]
                .as_array()
                .and_then(|rows| rows.iter().find(|row| row["id"] == profile))
                .and_then(|row| row["auth"].as_str())
                .filter(|auth| matches!(*auth, "signedOut" | "expired"))
                .map(|_| "its login is unavailable on this machine"))
        };
        let mut note = String::new();
        if launch.harness != default
            && let Some(why) = unavailable(&launch.harness)?
        {
            note = format!(
                " ({} unavailable: {why}; using default {default})",
                launch.harness
            );
            launch.harness = default.into();
            launch.model = None;
            if peer.is_none() {
                let family = self
                    .families
                    .get(default)
                    .copied()
                    .unwrap_or(crate::acpmux::Family::Claude);
                let base = self
                    .families
                    .get(&self.settings.harness)
                    .copied()
                    .unwrap_or(crate::acpmux::Family::Claude);
                launch.preset = self.settings.preset.as_ref().and_then(|p| {
                    if family == base {
                        Some(p.clone())
                    } else {
                        family_preset(p, family)
                    }
                });
            }
        }
        if self
            .grant
            .as_ref()
            .is_some_and(|g| !g.grant().allows_harness(&launch.harness))
        {
            return Err(format!(
                "the person has not given this Chief's subagents the {} harness",
                launch.harness
            ));
        }
        // Launch the exact remote profile whose login we checked. The grant
        // above covers the requested route; a missing catalog keeps it intact.
        if peer.is_some()
            && let Some(catalog) = catalog.as_ref()
        {
            launch.harness = admit(catalog, &launch.harness)?.profile;
        }
        Ok((launch, note))
    }

    /// A spawn whose tasks the picker sent to more than one harness: one
    /// spawn per harness, in the order of their first task, each answer under
    /// a line naming its pick. A group with no pick spawns as before (its
    /// tasks pick nothing again, so it does not split further).
    fn spawn_groups(
        &self,
        groups: Vec<(Option<crate::spawn_route::Pick>, Vec<usize>)>,
        tasks: &[String],
        cwd: Option<String>,
        effort: Option<String>,
        place: Option<String>,
        default: &str,
    ) -> Result<String, String> {
        let total = tasks.len();
        let mut parts = Vec::new();
        let mut any = false;
        for (p, ks) in groups {
            let which = ks
                .iter()
                .map(|k| (k + 1).to_string())
                .collect::<Vec<_>>()
                .join(", ");
            let head = match &p {
                Some(p) => format!("{} for task {which} of {total}:", route_line(p)),
                None => format!("Stayed on {default} for task {which} of {total}:"),
            };
            let sub: Vec<String> = ks.iter().map(|k| tasks[*k].clone()).collect();
            let (h, m) = match p {
                Some(p) => (Some(p.harness), p.model),
                None => (None, None),
            };
            match self.spawn_with_route(sub, cwd.clone(), effort.clone(), place.clone(), h, m) {
                Ok(answer) => {
                    any = true;
                    parts.push(format!("{head}\n{answer}"));
                }
                Err(e) => parts.push(format!("{head}\nNo subagent started: {e}")),
            }
        }
        let text = parts.join("\n\n");
        if any { Ok(text) } else { Err(text) }
    }

    fn engine_choice(&self) -> crate::engine::EngineChoice {
        self.engine_file
            .as_deref()
            .map(crate::engine::load)
            .unwrap_or_default()
    }

    /// Whether a spawn may name its subagents' `what` (`harness` or
    /// `model`): refused when routing is off (`routing_on`, read now; off by
    /// default), and a harness also when OPTCHAT_SUBAGENT_HARNESS pins it (a
    /// model on the pinned harness is fine, #31163).
    fn check_route(
        &self,
        choice: &crate::engine::EngineChoice,
        what: &str,
        value: &str,
    ) -> Result<(), String> {
        if self.pinned && what == "harness" {
            return Err(format!(
                "spawn: this Chief's subagent harness is pinned (OPTCHAT_SUBAGENT_HARNESS), so it cannot route to {what} {value}; leave out {what}"
            ));
        }
        let user = std::env::var_os("HOME")
            .and_then(|home| crate::agent_memory::settings::document(std::path::Path::new(&home)));
        if !routing_on(choice, user.as_ref()) {
            return Err(format!(
                "spawn: routing subagents is off (the default; the person turns it on with `chief engine set --subagent-routing auto` or cmux.json chief.autoRouteSubagents), so it cannot route to {what} {value}; leave out {what}"
            ));
        }
        Ok(())
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

    /// Why there are no workspaces (said in each spawn answer without them).
    pub fn with_no_workspace_reason(mut self, reason: impl Into<String>) -> Spawner {
        self.no_workspace_reason = reason.into();
        self
    }

    /// The running turn's view (`Input::TurnView`); None outside a turn.
    fn turn_view(&self) -> Option<String> {
        let (reply, answer) = channel();
        self.to_brain(Input::TurnView { reply }).ok()?;
        answer.recv().ok().flatten()
    }

    fn to_brain(&self, input: Input) -> Result<(), String> {
        self.tx
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .send(input)
            .map_err(|_| "the Chief host is stopping".to_owned())
    }

    /// Starts subagent `id`'s session (in `s.cwd`) and first prompt, then its
    /// workspace; answers what the user can see of it: its workspace and
    /// where it lives, that it runs hidden, or that it has none and why.
    #[allow(clippy::too_many_arguments)]
    fn start_one(
        &self,
        spawn: &str,
        id: &str,
        task: &str,
        view: &str,
        floor: Option<&str>,
        s: &SubagentSettings,
        peer: Option<&str>,
    ) -> Result<String, String> {
        let began = Instant::now();
        let peer = peer.map(str::to_owned);
        // Claude only through acpmux's own Claude Code adapter (harness_gate).
        // A peer's harness is its own profile: the gate reads this daemon's
        // catalog, so it does not apply there.
        let admitted = match &peer {
            Some(_) => crate::harness_gate::Admitted::peer(&s.harness),
            None => {
                crate::harness_gate::admit_live(&*self.agents, &s.harness).map_err(|reason| {
                    crate::harness_gate::trace_refusal(
                        &self.trace,
                        "subagent",
                        &s.harness,
                        &reason,
                    );
                    crate::harness_gate::refusal(&reason)
                })?
            }
        };
        // No mark of ours in a subagent's first message: Claude Code marks
        // its two system blocks and the last two messages of every later
        // request in the session (each tool step), and the API takes at
        // most 4 marks, so ours would fail the subagent's second request
        // (Claude Code 2.1.287, measured 2026-10-08). Claude Code's own
        // marks cache the long session step by step.
        // The workspace key is chosen first, so the session starts knowing
        // its workspace (CMUX_WORKSPACE_ID; acpmux per-session env).
        let key = self
            .workspaces
            .as_ref()
            .map(|_| crate::workspaces::new_key());
        // Its workspace's name, also its name on an approval card it is in.
        let name = crate::workspaces::title(task);
        // A Claude subagent under the goal runs on Opus 5.5 unless the spawn
        // or the engine named a model (goal.rs).
        let model = s.model.clone().or_else(|| {
            self.goal_for(admitted.family, peer.is_some())
                .then(|| crate::goal::MODEL.to_owned())
        });
        let spec = SessionSpec {
            name: format!("{}-{id}", s.prefix),
            cwd: s.cwd.clone(),
            harness: admitted.profile.clone(),
            // The spawn floor (`Brain::spawn_policy`) wins over the setting.
            policy: floor.unwrap_or(&s.policy).to_owned(),
            model,
            effort: s.effort.clone(),
            preset: s.preset.clone(),
            tags: {
                let mut t = tags(&s.parent, spawn, id, &name);
                if floor.is_some() {
                    t.insert(
                        crate::approval::POLICY_TAG.to_owned(),
                        crate::approval::ASK.to_owned(),
                    );
                }
                t
            },
            // Per-session env reaches a local session only (acpmux allowlist,
            // unix socket).
            env: key
                .iter()
                .filter(|_| peer.is_none())
                .map(|k| ("CMUX_WORKSPACE_ID".to_owned(), crate::workspaces::env_id(k)))
                .collect(),
            fast: false,
            peer: peer.clone(),
        };
        // The folder the host made for its subagents is trusted up front, so
        // the user's first message in a subagent's pane is never held behind
        // "trust this folder" (Lawrence 2026-10-09). A folder of the user's
        // (a spawn's cwd) is never trusted here: its pane asks as usual.
        if peer.is_none()
            && s.cwd == self.settings.cwd
            && let Err(e) = self.agents.trust_folder(&s.cwd)
        {
            (self.log)(&format!(
                "trusting the subagent folder {}: {e}",
                s.cwd.display()
            ));
        }
        // acpmux's agent host can miss its 5 s startup handshake while the
        // machine is busy (a10, 2026-10-13: "agent host did not answer hello
        // within 5s"), and sr2 exits while it starts when its gateway is
        // slow (a198, 2026-10-19: "agent process closed"); the same spawn
        // a moment later starts. acpmux replaces a slow host once itself
        // (cx-7gs9r), but not a harness that exited. Up to three tries,
        // with a pause, before the subagent counts as failed.
        let mut tries = 0;
        let session = loop {
            match self.agents.new_session(&spec) {
                Err(e) if is_transient_start_failure(&e) && tries < START_RETRY_PAUSES.len() => {
                    let pause = START_RETRY_PAUSES[tries];
                    tries += 1;
                    (self.log)(&format!(
                        "subagent {id}: {e}; starting it again in {} s (try {})",
                        pause.as_secs(),
                        tries + 1
                    ));
                    // A deadline-free pause between two starts of one spawn
                    // worker thread (not a poll): the gateway needs a moment.
                    std::thread::sleep(pause);
                }
                other => break other?,
            }
        };
        let admitted = match &peer {
            Some(_) => admitted,
            None => crate::harness_gate::session_harness(&*self.agents, &session, &admitted)
                .map_err(|reason| {
                    let _ = self.agents.end_session(&session);
                    crate::harness_gate::trace_refusal(
                        &self.trace,
                        "subagent",
                        &s.harness,
                        &reason,
                    );
                    crate::harness_gate::refusal(&reason)
                })?,
        };
        // codex under approve-all: no sandbox for its cmux calls (E6).
        if let Some(mode) = crate::acpmux::chief_session_mode(admitted.family, &spec.policy)
            && let Err(e) = self.agents.set_mode(&session, mode)
        {
            (self.log)(&format!(
                "subagent {id}: {e}; its cmux calls may be sandboxed"
            ));
        }
        // Where its workspace opens, recorded before it counts as started: a
        // `control show` can only come after it, never open a second one.
        // The terminal beside the chat runs on this Mac: a peer session's
        // folder is on the VM (/home/agent/work), and a PTY spawned in a
        // folder missing here fails, so the subagent got no workspace (a511).
        // Its lifetime (action_lifetime.rs): a background Task has no workspace, a tucked
        // Workspace joins the collapsed Chief group and closes when its work ends.
        // One that runs with policy ask always shows: only its tab can allow its prompts, so it
        // is never tucked or reaped.
        let mut route = self.lifetime(task);
        if spec.policy == crate::approval::ASK {
            route = route.shown("it asks before it acts");
        }
        let made = crate::action_lifetime::Made::of(&route);
        let slot_place = (
            if made.tucked() {
                crate::action_lifetime::TUCK_GROUP.to_owned()
            } else {
                crate::workspaces::spawn_group(task).to_owned()
            },
            match &peer {
                Some(_) => self.settings.cwd.clone(),
                None => s.cwd.clone(),
            },
        );
        if let Some(key) = &key {
            let _ = self.to_brain(Input::SubagentWorkspaceSlot {
                id: id.to_owned(),
                name: name.clone(),
                slot: crate::state::WorkspaceSlot {
                    key: key.clone(),
                    group: slot_place.0.clone(),
                    cwd: slot_place.1.clone(),
                },
            });
        }
        // Registered before its prompt: its turn end can only follow.
        self.to_brain(Input::SubagentStarted {
            id: id.to_owned(),
            session_id: session.clone(),
            policy: Some(spec.policy.clone()),
            harness: Some(s.harness.clone()),
            made: Some(made.clone()),
        })?;
        let (tx, rx) = channel();
        let prompt_id = format!("{PROMPT_PREFIX}sub:{id}:{}", now_ms());
        // goal.rs: a Claude subagent here gets its task, then `/goal`, the
        // prompt the Chief follows (its end is the report). `/goal` goes out
        // only when the task turn ended: sent back to back, acpmux ran the
        // short `/goal` before the long task (a1141, 2026-11-12).
        let goal = self.goal_for(admitted.family, peer.is_some());
        self.trace.emit(
            "subagent.start",
            json!({"id": id, "spawn": spawn, "session": session, "peer": peer, "prompt_id": prompt_id, "harness": s.harness, "harness_profile": admitted.profile, "harness_kind": admitted.kind, "harness_argv0": admitted.argv0, "goal": goal, "ms": began.elapsed().as_millis() as u64}),
        );
        let hold_id = goal.then(|| format!("{PROMPT_PREFIX}sub:{id}:task:{}", now_ms()));
        if let Some(hold_id) = &hold_id {
            let mut blocks = crate::prompt::subagent_blocks(view, task);
            blocks.push(crate::goal::hold_block());
            let (hold_tx, hold_rx) = channel();
            self.agents
                .start_prompt(&session, blocks, hold_id, hold_tx)?;
            send_goal_after_task(
                self.agents.clone(),
                session.clone(),
                prompt_id.clone(),
                hold_rx,
                tx,
            );
        } else {
            self.agents.start_prompt(
                &session,
                crate::prompt::subagent_blocks(view, task),
                &prompt_id,
                tx,
            )?;
        }
        let _ = self.to_brain(Input::SubagentPrompted { id: id.to_owned() });
        self.forward_answer(id, &session, &prompt_id, hold_id, rx);
        // The chat replays its history when the tab attaches, so the
        // workspace can follow the prompt.
        let Some(workspaces) = &self.workspaces else {
            self.trace.emit(
                "subagent.workspace",
                json!({"id": id, "spawn": spawn, "error": self.trace.text(&self.no_workspace_reason)}),
            );
            return Ok(format!("no cmux workspace ({})", self.no_workspace_reason));
        };
        let (group, term_cwd) = slot_place;
        let key = key.unwrap_or_else(crate::workspaces::new_key);
        // Its lifetime under the person's words and rules (action_lifetime.rs, sidebar_choice.rs):
        // a background Task is reached from its link in the Chief's reply and its row in the
        // composer hat, and `control show` adds its workspace. One that runs with policy ask
        // (the spawn floor, or MUX_POLICY) always shows: only its tab can allow its prompts.
        let ask = spec.policy == crate::approval::ASK;
        if !ask && route.lifetime != crate::action_lifetime::Lifetime::Workspace {
            self.trace.emit(
                "subagent.hidden",
                json!({"id": id, "spawn": spawn, "workspace": key, "name": name, "group": group, "why": route.why, "lifetime": route.lifetime.as_str()}),
            );
            return Ok(format!(
                "hidden: a background task with no sidebar workspace ({}); its link opens its chat, its row shows over the composer until it ends, and control(action: \"show\", id: \"{id}\") adds its workspace when the user asks",
                route.why
            ));
        }
        match workspaces.open(&key, &session, &name, &group, &term_cwd) {
            Ok(key) => {
                let place = workspaces.place();
                // a313: the real ws_ id, so the CLI can list, move and pin it.
                let located = workspaces.locate(&key);
                self.trace.emit(
                    "subagent.workspace",
                    json!({"id": id, "spawn": spawn, "workspace": key, "name": name, "group": group, "place": place,
                        "ws": located.as_ref().map(|r| r.id.clone()), "session": located.as_ref().map(|r| r.session.clone())}),
                );
                // No link here: the posted reply links every mention (link_subagents), so
                // the memory keeps the plain id, not a 70-character URL per mention.
                let mut note = format!("workspace \"{name}\" in {place}");
                if let Some(r) = &located {
                    note.push_str(&format!(
                        " (id {}; `{}` moves it to the top)",
                        r.id,
                        r.move_to_top()
                    ));
                }
                note.push_str(&match (ask, made.tucked()) {
                    (true, _) => "; shown because it asks before it acts".to_owned(),
                    (false, true) => format!(
                        "; tucked in the collapsed \"{}\" group because {}; it closes when its work ends",
                        crate::action_lifetime::TUCK_GROUP,
                        route.why
                    ),
                    (false, false) => format!("; shown because {}", route.why),
                });
                let _ = self.to_brain(Input::SubagentWorkspace {
                    id: id.to_owned(),
                    key,
                    name,
                    ws: located.map(|r| r.id),
                });
                Ok(note)
            }
            Err(e) => {
                (self.log)(&format!("subagent {id}: opening its workspace: {e}"));
                let _ = self.to_brain(Input::SubagentWorkspaceFailed {
                    id: id.to_owned(),
                    key: key.clone(),
                });
                self.trace.emit(
                    "subagent.workspace",
                    json!({"id": id, "spawn": spawn, "error": self.trace.text(&e)}),
                );
                Ok(format!("no cmux workspace (opening it failed: {e})"))
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
            Err(e) if e.contains("give the exact folder") => (
                default.clone(),
                Some(format!(
                    "{e}, so they run in {} instead; next time pass the exact folder (for example ~/fun/repo), never ~ itself",
                    default.display()
                )),
            ),
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

    /// The lifetime of `task` as it starts (action_lifetime.rs): the person's remembered
    /// preferences (their profile's learned lines), its `Sidebar:` line (the Chief's choice)
    /// and the person's rules, read now.
    pub(crate) fn lifetime(&self, task: &str) -> crate::action_lifetime::Route {
        let user = self.user_document();
        let rules = crate::sidebar_choice::Rules::from_user(user.as_ref(), self.show_workspaces());
        let learned = self
            .person
            .as_deref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|t| crate::action_lifetime::learned_lines(&t))
            .unwrap_or_default();
        crate::action_lifetime::route(
            task,
            crate::sidebar_choice::Requested::of_task(task),
            &learned,
            &rules,
        )
    }

    /// Whether a subagent of `family` starts under `/goal` (goal.rs): the
    /// goal is on for this host and the person did not set
    /// `chief.subagentGoal: false`; only Claude Code here runs the command.
    fn goal_for(&self, family: crate::acpmux::Family, on_peer: bool) -> bool {
        self.goal
            && !on_peer
            && family == crate::acpmux::Family::Claude
            && crate::goal::on(self.user_document().as_ref())
    }

    /// The person's settings document (cmux-next.json), read now.
    fn user_document(&self) -> Option<serde_json::Value> {
        match &self.user_settings {
            Some(path) => std::fs::read_to_string(path).ok().and_then(|t| {
                serde_json::from_str(&crate::agent_memory::settings::strip_jsonc(&t)).ok()
            }),
            None => std::env::var_os("HOME").and_then(|home| {
                crate::agent_memory::settings::document(std::path::Path::new(&home))
            }),
        }
    }

    /// Whether the Chief setting `subagents.showWorkspaces` is on (every
    /// subagent shows); off when the brain does not answer.
    fn show_workspaces(&self) -> bool {
        let (reply, answer) = channel();
        if self.to_brain(Input::Settings { reply }).is_err() {
            return false;
        }
        answer
            .recv_timeout(Duration::from_secs(30))
            .ok()
            .and_then(|v| v["subagents"]["showWorkspaces"].as_bool())
            .unwrap_or(false)
    }

    /// `Some("ask")` under the spawn floor (`Brain::spawn_policy`); `ask`
    /// too when the brain does not answer (fail closed).
    fn spawn_floor(&self) -> Option<String> {
        let (reply, answer) = channel();
        if self.to_brain(Input::SpawnPolicy { reply }).is_err() {
            return Some(crate::approval::ASK.to_owned());
        }
        match answer.recv_timeout(Duration::from_secs(30)) {
            Ok(policy) => policy,
            Err(_) => Some(crate::approval::ASK.to_owned()),
        }
    }

    /// Sends the start of the task prompt's turn (`SubagentTurnStarted`),
    /// then the prompt's answer (token use, cost), to the brain.
    fn forward_answer(
        &self,
        id: &str,
        session: &str,
        prompt_id: &str,
        hold_id: Option<String>,
        rx: std::sync::mpsc::Receiver<TurnSignal>,
    ) {
        let tx = self
            .tx
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let agents = self.agents.clone();
        let (id, session, prompt_id) = (id.to_owned(), session.to_owned(), prompt_id.to_owned());
        std::thread::spawn(move || {
            // Folded until the session's first turn starts, then no more.
            let mut start = Some(TurnFolder::default());
            while let Ok(signal) = rx.recv() {
                match signal {
                    TurnSignal::Changed | TurnSignal::Noted => {
                        let Some(folder) = start.as_mut() else {
                            continue;
                        };
                        match first_turn_start(
                            &*agents,
                            &session,
                            &prompt_id,
                            hold_id.as_deref(),
                            folder,
                        ) {
                            None => {}
                            Some(ours) => {
                                start = None;
                                if ours {
                                    let _ = tx.send(Input::SubagentTurnStarted {
                                        id: id.clone(),
                                        prompt_id: prompt_id.clone(),
                                    });
                                }
                            }
                        }
                    }
                    TurnSignal::Streamed => {}
                    TurnSignal::Done(mut answer) => {
                        if let Ok(value) = &mut answer
                            && let Some(fields) = value.as_object_mut()
                        {
                            fields.insert("chief_prompt_id".into(), json!(prompt_id));
                        }
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
    pub fn queue_starter(self: &Arc<Self>) -> Sender<QueuedStart> {
        let (tx, rx) = channel::<QueuedStart>();
        let me = Arc::downgrade(self);
        std::thread::Builder::new()
            .name("subagent-queue".into())
            .spawn(move || {
                while let Ok(queued) = rx.recv() {
                    let Some(me) = me.upgrade() else { return };
                    me.start_waiting(&queued);
                }
            })
            .ok();
        tx
    }

    /// Waits for the view to settle, at most SETTLE_LIMIT; then the view is
    /// used as it is (the lines still building read as the placeholder).
    /// Err only when the memory stopped (shut down or a failed write).
    fn settle_view(&self) -> Result<(), String> {
        if self.chat.settle(None, Some(SETTLE_LIMIT)) {
            return Ok(());
        }
        let status = self.chat.status();
        if status.closed || status.fatal.is_some() {
            return Err("the memory stopped, so no subagent started".into());
        }
        (self.log)(&format!(
            "spawn goes on without {} view line summaries after {}s (still building)",
            status.unbuilt,
            SETTLE_LIMIT.as_secs()
        ));
        Ok(())
    }

    fn start_waiting(&self, queued: &QueuedStart) {
        let id = queued.id.as_str();
        let waiting = self
            .waiting
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(id);
        let fail = |error: &str| {
            let _ = self.to_brain(Input::SubagentFailed {
                id: id.to_owned(),
                error: error.to_owned(),
            });
        };
        let refused = self
            .refused
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(id);
        if let Some(e) = refused {
            return fail(&e);
        }
        let w = match waiting {
            Some(w) => w,
            // The host restarted while it waited: its launch comes from its
            // record, or from the spawn call in the log (a record saved
            // before launches were).
            None => match self.rebuild_waiting(queued) {
                Ok(w) => {
                    match queued.launch.as_ref().and_then(|l| l.harness.as_deref()) {
                        Some(harness) => (self.log)(&format!(
                            "subagent {id}: continuing it in a new session on {harness}"
                        )),
                        None => (self.log)(&format!(
                            "subagent {id}: the host restarted while it waited; starting it from its saved task"
                        )),
                    }
                    w
                }
                Err(e) => return fail(&e),
            },
        };
        if let Err(e) = self.settle_view() {
            return fail(&e);
        }
        // The compaction view, as at spawn (acp-chief-issues.md #12).
        let view = self.chat.render_compact_view().text;
        let task = match &queued.extra {
            Some(extra) => format!(
                "{}\n\nThe Chief sent this while you were queued:\n\n{extra}",
                w.task
            ),
            None => w.task.clone(),
        };
        // Queued ones are local: a cloud subagent never queues.
        match self.start_one(
            &w.spawn,
            id,
            &task,
            &view,
            w.floor.as_deref(),
            &w.launch,
            None,
        ) {
            Ok(note) => (self.log)(&format!("subagent {id} started from the queue: {note}")),
            Err(e) => fail(&e),
        }
    }

    /// A queued subagent's launch after a restart: its saved launch, else its
    /// spawn call in the log; the harness is the engine of now. A launch
    /// from the log has no trustworthy saved floor, so it fails closed to
    /// `ask` rather than inheriting a possibly lower floor from now.
    fn rebuild_waiting(&self, queued: &QueuedStart) -> Result<Waiting, String> {
        let (saved, from_log) = match queued.launch.clone() {
            Some(saved) => (saved, false),
            None => {
                let count = self.chat.status().messages;
                let saved = recover_launch(
                    &queued.id,
                    (0..count).rev().filter_map(|k| self.chat.message(k)),
                )
                .ok_or_else(|| {
                    "the Chief host restarted while it waited for a free slot, and its task was not saved".to_owned()
                })?;
                (saved, true)
            }
        };
        let run = self.engine_settings(queued.engine.as_ref());
        let (dir, _) = self.run_dir(saved.cwd.as_deref(), &run);
        let floor = if from_log {
            Some(crate::approval::ASK.to_owned())
        } else {
            saved.floor
        };
        Ok(Waiting {
            spawn: queued.spawn.clone(),
            task: saved.task,
            floor,
            launch: SubagentSettings {
                cwd: dir,
                effort: saved
                    .effort
                    .or_else(|| queued.engine.as_ref().and_then(|e| e.effort.clone())),
                // The model its spawn chose (#31164), else the engine's.
                model: saved.model.or(run.model.clone()),
                ..run
            },
        })
    }

    /// Subagent `id`'s whole chat, one page of `page` characters from `at`.
    pub fn agent_chat_page(&self, id: &str, at: u64, page: u64) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::SubSession {
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

/// `asked` as a directory on this host: `~` and `~/...` are `home`; it must
/// be absolute and exist. LAUNCH-NO-TCC-PROMPTS: never the home folder, `/`
/// or a folder macOS guards (`PRIVATE_FOLDERS`): an agent reads its folder
/// at once, and a read there makes macOS ask the user for access in the
/// app's name. A subfolder the Chief names (`~/Downloads/proj`) is kept.
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
    if let Some(what) = private_folder(&dir, home) {
        return Err(format!(
            "{} is {what}, where an agent would read your private folders and macOS would ask you for access; give the exact folder the work is in",
            dir.display()
        ));
    }
    if !dir.is_dir() {
        return Err(format!("{} does not exist on this host", dir.display()));
    }
    Ok(dir)
}

/// The folders macOS guards, relative to the home folder (as acpmux's
/// `protected_folders`).
const PRIVATE_FOLDERS: &[&str] = &[
    "Desktop",
    "Documents",
    "Downloads",
    "Pictures",
    "Music",
    "Movies",
    "Library",
    "Library/Mobile Documents",
    "Library/CloudStorage",
];

/// What `dir` is when no agent may start in it: the home folder, the root
/// folder or one of `PRIVATE_FOLDERS` itself. Compared as spelled, without
/// trailing slashes or `.`, and case-insensitively (APFS).
fn private_folder(dir: &Path, home: &Path) -> Option<&'static str> {
    let clean = |p: &Path| -> String {
        let mut out = PathBuf::new();
        for part in p.components() {
            match part {
                std::path::Component::CurDir => {}
                std::path::Component::ParentDir => {
                    out.pop();
                }
                other => out.push(other),
            }
        }
        out.to_string_lossy().to_lowercase()
    };
    let dir = clean(dir);
    if dir == "/" {
        return Some("the root folder");
    }
    let home = clean(home);
    if dir == home {
        return Some("the home folder");
    }
    PRIVATE_FOLDERS
        .iter()
        .any(|f| dir == format!("{home}/{}", f.to_lowercase()))
        .then_some("a private folder")
}

impl Orchestrator for Spawner {
    fn turn_gate(&self, tool: &str, input: &Value) -> Result<(), String> {
        let (reply, answer) = channel();
        self.to_brain(Input::TurnGate {
            tool: tool.to_owned(),
            input: input.clone(),
            reply,
        })?;
        // No answer fails closed, like the spawn floor.
        answer
            .recv_timeout(Duration::from_secs(30))
            .unwrap_or_else(|_| Err("the Chief host did not answer the turn's tool check".into()))
    }

    fn spawn(&self, tasks: Vec<String>, cwd: Option<String>) -> Result<String, String> {
        self.spawn_with_effort(tasks, cwd, None)
    }

    fn spawn_with_effort(
        &self,
        tasks: Vec<String>,
        cwd: Option<String>,
        effort: Option<String>,
    ) -> Result<String, String> {
        self.spawn_placed(tasks, cwd, effort, None)
    }

    fn spawn_placed(
        &self,
        tasks: Vec<String>,
        cwd: Option<String>,
        effort: Option<String>,
        place: Option<String>,
    ) -> Result<String, String> {
        self.spawn_routed(tasks, cwd, effort, place, None)
    }

    fn spawn_routed(
        &self,
        tasks: Vec<String>,
        cwd: Option<String>,
        effort: Option<String>,
        place: Option<String>,
        harness: Option<String>,
    ) -> Result<String, String> {
        self.spawn_with_route(tasks, cwd, effort, place, harness, None)
    }

    fn spawn_with_route(
        &self,
        tasks: Vec<String>,
        cwd: Option<String>,
        effort: Option<String>,
        place: Option<String>,
        harness: Option<String>,
        model: Option<String>,
    ) -> Result<String, String> {
        // A Direct action (an organize request, or what the person told the Chief to do
        // itself) never becomes a helper or a workspace (action_lifetime.rs): the Chief does it
        // in its own turn, and the other tasks start.
        let (direct, tasks): (Vec<_>, Vec<_>) = tasks
            .into_iter()
            .partition(|t| self.lifetime(t).lifetime == crate::action_lifetime::Lifetime::Direct);
        if !direct.is_empty() {
            let refused = direct_refusal(&direct, |t| self.lifetime(t).why);
            self.trace.emit(
                "subagent.direct",
                json!({"tasks": direct.len(), "started": tasks.len()}),
            );
            if tasks.is_empty() {
                return Err(refused);
            }
            return self
                .spawn_with_route(tasks, cwd, effort, place, harness, model)
                .map(|started| format!("{refused}\n{started}"));
        }
        let given = |v: Option<String>| v.map(|v| v.trim().to_owned()).filter(|v| !v.is_empty());
        let (harness, model) = (given(harness), given(model));
        let choice = self.engine_choice();
        let default_harness = choice
            .subagent_harness
            .clone()
            .filter(|h| !self.pinned && !h.trim().is_empty())
            .unwrap_or_else(|| self.settings.harness.clone());
        if let Some(h) = harness.as_deref() {
            self.check_route(&choice, "harness", h)?;
        }
        if let Some(m) = model.as_deref() {
            self.check_route(&choice, "model", m)?;
        }
        // The cap holds for the whole spawn, before the picker splits it.
        if tasks.len() > MAX_TASKS {
            return Err(format!(
                "spawn takes at most {MAX_TASKS} tasks; split the work"
            ));
        }
        // The automatic picker (spawn_route.rs): routing on, and the spawn
        // names no harness or model. A pinned harness never routes.
        let mut routed_note = None;
        let (harness, model) = if harness.is_none()
            && model.is_none()
            && !self.pinned
            && self.routing_enabled(&choice)
        {
            let default = choice
                .subagent_harness
                .clone()
                .filter(|h| !h.trim().is_empty())
                .unwrap_or_else(|| self.settings.harness.clone());
            let mut groups: Vec<(Option<crate::spawn_route::Pick>, Vec<usize>)> = Vec::new();
            for (k, task) in tasks.iter().enumerate() {
                let p = self.pick_for(task, &default);
                let key = |p: &Option<crate::spawn_route::Pick>| {
                    p.as_ref().map(|p| (p.harness.clone(), p.model.clone()))
                };
                match groups.iter_mut().find(|(g, _)| key(g) == key(&p)) {
                    Some((_, ks)) => ks.push(k),
                    None => groups.push((p, vec![k])),
                }
            }
            if groups.len() > 1 {
                return self.spawn_groups(groups, &tasks, cwd, effort, place, &default);
            }
            match groups.pop().and_then(|(p, _)| p) {
                Some(p) => {
                    routed_note = Some(format!("{}.", route_line(&p)));
                    (Some(p.harness), p.model)
                }
                None => (None, None),
            }
        } else {
            (harness, model)
        };
        // The person's subagent harness (`--subagent-harness`) for a spawn
        // that names none, routing on or off; a pinned harness wins.
        let harness = harness.or_else(|| {
            choice
                .subagent_harness
                .clone()
                .filter(|h| !self.pinned && !h.trim().is_empty())
        });
        if let Some(e) = effort.as_deref()
            && !crate::tools::EFFORTS.contains(&e)
        {
            return Err(format!(
                "no effort {e}; one of {}",
                crate::tools::EFFORTS.join(", ")
            ));
        }
        let began = Instant::now();
        // Section 9: the view at spawn time, as the compaction view: the
        // same tree merged coarser, 16-32 KB instead of the turn's 64-128 KB
        // (acp-chief-issues.md #12: a subagent's first turn read ~108k
        // tokens, ~40k of them the whole view; it zooms for detail). In a
        // turn, at once (parity timing 2026-10-09: the settle waited about
        // 7 s for the compactor to summarize the turn's spawn call); outside
        // a turn, after settle (settle_view).
        if self.turn_view().is_none() {
            self.settle_view()?;
        }
        let view = self.chat.render_compact_view().text;
        let (reply, answer) = channel();
        self.to_brain(Input::SpawnRegister {
            tasks: tasks.clone(),
            peer: self.cloud.as_ref().map(|c| c.peer.clone()),
            place,
            // The pinned subagent may use a different family from the Chief.
            harness: harness
                .clone()
                .or_else(|| self.pinned.then(|| self.settings.harness.clone())),
            machines: self.machine_table(),
            reply,
        })?;
        let plan = answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())??;
        let cloud = plan.peer.as_deref().map(|p| self.placement(p));
        let mut run = self.engine_settings(plan.engine.as_ref());
        // `spawn(model)`: over the engine's (a cloud peer keeps its own).
        if let Some(m) = &model {
            run.model = Some(m.clone());
        }
        // The person's grant: a harness outside it starts nothing.
        let grant = self.grant.as_ref().map(|g| g.grant());
        let refused = grant.filter(|g| !g.allows_harness(&run.harness)).map(|g| {
            format!(
                "the person has not given this Chief's subagents the {} harness; it may use {}",
                run.harness,
                g.harnesses.iter().cloned().collect::<Vec<_>>().join(", ")
            )
        });
        self.trace.emit(
            "spawn",
            json!({
                "spawn": plan.spawn,
                "ids": plan.ids,
                "peers": plan.peers,
                "tasks": tasks.iter().map(|t| self.trace.text(t)).collect::<Vec<_>>(),
                "settle_ms": began.elapsed().as_millis() as u64,
                "view": {"bytes": view.len(), "hash": crate::trace::hash(&view)},
                "harness": run.harness,
                "placements": plan.ids.iter().zip(&plan.placements).map(|(id, p)| json!({"id": id, "place": match &p.target { crate::place_route::Target::Here => "here", crate::place_route::Target::CloudVm => "cloud", crate::place_route::Target::Peer(name) => name.as_str() }, "place_reason": p.reason})).collect::<Vec<_>>(),
            }),
        );
        // Subagents that run here (all of them, or with one VM per subagent
        // the ones that need the Mac or whose VM was not made).
        if let (Some(text), Some(preset)) = (&run.claude_md, &run.preset) {
            let file = (!self.agents.system_prompt(preset)).then_some(text.as_str());
            if let Err(e) = crate::session_dir::set_claude_md(&run.cwd, file) {
                (self.log)(&format!("the subagent directory's CLAUDE.md: {e}"));
            }
        }
        // The security floor: during a turn another person started, or while
        // an ask child or subagent lives, every subagent runs with policy ask.
        // No answer from the brain fails closed (ask).
        let floor = self.spawn_floor();
        let (dir, dir_note) = match &cloud {
            Some(c) => (c.dir.clone(), None),
            None => self.run_dir(cwd.as_deref(), &run),
        };
        // The run's settings in the directory they start in.
        // How hard they think: as asked, else as hard as the calling turn.
        let mut launch = SubagentSettings {
            cwd: dir.clone(),
            effort: effort
                .or_else(|| plan.engine.as_ref().and_then(|e| e.effort.clone()))
                .or_else(|| run.effort.clone()),
            ..run.clone()
        };
        // A subagent that runs here when others of the spawn run on peers.
        let (local_dir, local_dir_note) = match &cloud {
            Some(_) => self.run_dir(cwd.as_deref(), &run),
            None => (dir.clone(), None),
        };
        let local_launch = SubagentSettings {
            cwd: local_dir.clone(),
            ..launch.clone()
        };
        // On a peer: its own harness profile, no local preset or model.
        if let Some(c) = &cloud {
            launch.harness = c.harness.clone();
            launch.preset = None;
            launch.model = None;
            launch.claude_md = None;
        }
        let mut started = Vec::new();
        let mut placed: Vec<(String, Option<String>)> = Vec::new();
        let mut lines = Vec::new();
        if let Some(e) = &refused {
            // Queued ids first, before any failure frees a slot: the brain
            // dequeues them to the queue starter, which fails them with this
            // refusal (they are in no `waiting` entry).
            let mut map = self
                .refused
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            for id in plan.ids.iter().filter(|id| plan.queued.contains(id)) {
                map.insert(id.clone(), e.clone());
            }
        }
        for (k, (id, task)) in plan.ids.iter().zip(&tasks).enumerate() {
            let sub_peer = plan.peers.get(k).cloned().flatten();
            let paired = matches!(
                plan.placements[k].target,
                crate::place_route::Target::Peer(_)
            );
            let sub_cloud = sub_peer
                .as_deref()
                .filter(|_| !paired)
                .map(|p| self.placement(p));
            let place_note = format!(" ({})", plan.placements[k].line());
            if let Some(e) = &refused {
                (self.log)(&format!("subagent {id} did not start: {e}"));
                lines.push(format!("- {id}: did not start ({e}){place_note}"));
                if plan.queued.contains(id) {
                    continue;
                }
                let _ = self.to_brain(Input::SubagentFailed {
                    id: id.clone(),
                    error: e.clone(),
                });
                continue;
            }
            if plan.queued.contains(id) {
                let (queued_launch, login_note) =
                    match self.machine_login(local_launch.clone(), &default_harness, None) {
                        Ok(launch) => launch,
                        Err(error) => {
                            let _ = self.to_brain(Input::SubagentFailed {
                                id: id.clone(),
                                error: error.clone(),
                            });
                            lines.push(format!("- {id}: did not start ({error}){place_note}"));
                            continue;
                        }
                    };
                // Saved in its record too: a restarted host still starts it.
                let _ = self.to_brain(Input::SubagentQueued {
                    id: id.clone(),
                    launch: crate::state::QueuedLaunch {
                        task: task.clone(),
                        cwd: Some(local_dir.display().to_string()),
                        effort: launch.effort.clone(),
                        floor: floor.clone(),
                        harness: Some(queued_launch.harness.clone()),
                        model: queued_launch.model.clone(),
                    },
                });
                self.waiting
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner)
                    .insert(
                        id.clone(),
                        Waiting {
                            spawn: plan.spawn.clone(),
                            task: task.clone(),
                            floor: floor.clone(),
                            launch: queued_launch,
                        },
                    );
                let cap = plan.limit.map_or_else(
                    || "a cap".to_owned(),
                    |cap| {
                        format!(
                            "{} subagents are at work, the cap {}",
                            cap.n(),
                            cap.source()
                        )
                    },
                );
                lines.push(format!(
                    "- {id}: queued ({cap}; it starts when one finishes; there is no cap by default, `control cap 0` removes this one){place_note}{login_note}"
                ));
                continue;
            }
            // A paused VM resumes first (B4); a no-op when it runs. A
            // subagent's own VM is made now (one VM per subagent).
            let resumed = match (sub_peer.as_ref().filter(|_| !paired), &self.cloud_vms) {
                (Some(p), Some(vms)) => {
                    let began = Instant::now();
                    let r = if is_agent_peer(p) {
                        let size = plan
                            .sizes
                            .get(k)
                            .cloned()
                            .flatten()
                            .unwrap_or_else(|| size_for(task).to_owned());
                        vms.provision(p, &size)
                    } else {
                        vms.resume(p)
                    };
                    (self.log)(&format!(
                        "cloud: {p} up for {id} in {} ms",
                        began.elapsed().as_millis()
                    ));
                    r
                }
                _ => Ok(()),
            };
            // Its own VM was not made (over the daily budget, provider
            // down): it runs here rather than not at all.
            let mut here_note = place_note;
            let (sub_peer, sub_cloud, resumed) = match (&resumed, &sub_peer) {
                (Err(e), Some(p)) if is_agent_peer(p) => {
                    let _ = self.to_brain(Input::SubagentPlacedHere {
                        id: id.clone(),
                        why: e.clone(),
                    });
                    here_note = format!(" (on this Mac: its own cloud VM was not made: {e})");
                    (None, None, Ok(()))
                }
                _ => (sub_peer, sub_cloud, resumed),
            };
            let task = match &sub_cloud {
                Some(c) => c.task(id, cwd.as_deref(), task),
                None if paired => {
                    let instructions = self
                        .cloud_text
                        .as_deref()
                        .or_else(|| self.cloud.as_ref().map(|c| c.instructions.as_str()))
                        .or(self.settings.claude_md.as_deref())
                        .unwrap_or(crate::prompt::SUBAGENT);
                    let repo = cloud_repo(cwd.as_deref());
                    let folder = match (cwd.as_deref(), repo) {
                        (Some(asked), Some(repo)) => format!(
                            "\n\n# Where you run\n\nThe requested folder `{asked}` names repo `{repo}` on the Chief's machine. You start in this paired machine's scratch folder; locate its checkout of that repo before working."
                        ),
                        _ => String::new(),
                    };
                    format!("{}{folder}\n\n{task}", instructions.trim_end())
                }
                None => task.clone(),
            };
            // On a VM that is up: its own sandbox key, named in its task.
            let key = match (&resumed, &sub_peer) {
                (Ok(()), Some(p)) if !paired => self.agent_key(p, id),
                _ => None,
            };
            let task = match &key {
                Some((key_id, note)) => {
                    let _ = self.to_brain(Input::SubagentAgentKey {
                        id: id.clone(),
                        key_id: key_id.clone(),
                    });
                    format!("{task}\n\n{note}")
                }
                None => task,
            };
            let mut sub_launch = if sub_peer.is_some() {
                launch.clone()
            } else {
                local_launch.clone()
            };
            if paired && sub_peer.is_some() {
                // Null cwd asks the paired daemon for a native scratch folder.
                sub_launch.cwd = PathBuf::new();
                sub_launch.harness = run.harness.clone();
                sub_launch.preset = None;
                sub_launch.claude_md = None;
                sub_launch.model = run.model.clone();
            } else if sub_peer.is_some() && harness.is_some() {
                sub_launch.harness = run.harness.clone();
                sub_launch.model = run.model.clone();
            }
            // Login status belongs to the chosen machine. A login command
            // is not a sign-in; unknown catalogs cannot justify a switch.
            let fallback = sub_cloud
                .as_ref()
                .filter(|_| !sub_peer.as_deref().is_some_and(is_agent_peer))
                .map_or(default_harness.as_str(), |c| c.harness.as_str());
            let login = self.machine_login(sub_launch, fallback, sub_peer.as_deref());
            let started_one = resumed.and_then(|()| {
                let (sub_launch, login_note) = login?;
                here_note.push_str(&login_note);
                self.start_one(
                    &plan.spawn,
                    id,
                    &task,
                    &view,
                    floor.as_deref(),
                    &sub_launch,
                    sub_peer.as_deref(),
                )
            });
            match started_one {
                Ok(note) => {
                    started.push(id.clone());
                    placed.push((id.clone(), sub_peer.clone()));
                    lines.push(format!("- {id}: {note}{here_note}"));
                }
                Err(e) => {
                    (self.log)(&format!("subagent {id} did not start: {e}"));
                    let _ = self.to_brain(Input::SubagentFailed {
                        id: id.clone(),
                        error: e.clone(),
                    });
                    lines.push(format!("- {id}: did not start ({e}){here_note}"));
                }
            }
        }
        let head = if started.is_empty() && (plan.queued.is_empty() || refused.is_some()) {
            "No subagent started.".to_owned()
        } else if started.is_empty() {
            format!("Queued {}.", plan.queued.join(", "))
        } else if plan
            .placements
            .iter()
            .any(|p| matches!(p.target, crate::place_route::Target::Peer(_)))
        {
            format!(
                "Started {}. Each machine is named below.",
                started.join(", ")
            )
        } else if placed.iter().any(|(_, p)| p.is_some()) {
            let mut on: Vec<&str> = placed.iter().filter_map(|(_, p)| p.as_deref()).collect();
            on.sort_unstable();
            on.dedup();
            let here: Vec<&str> = placed
                .iter()
                .filter(|(_, p)| p.is_none())
                .map(|(id, _)| id.as_str())
                .collect();
            let here = if here.is_empty() {
                String::new()
            } else {
                format!(
                    " {} run on this Mac, in {}.",
                    here.join(", "),
                    local_dir.display()
                )
            };
            if on.len() > 1 {
                let each = placed
                    .iter()
                    .filter_map(|(id, p)| p.as_ref().map(|p| format!("{id} on {p}")))
                    .collect::<Vec<_>>()
                    .join(", ");
                format!(
                    "Started {} on the cloud VMs (acpmux peers; {each}), in {}.{here}",
                    started.join(", "),
                    dir.display()
                )
            } else {
                format!(
                    "Started {} on the cloud VM {} (acpmux peer), in {}.{here}",
                    started.join(", "),
                    on[0],
                    dir.display()
                )
            }
        } else {
            format!("Started {} in {}.", started.join(", "), local_dir.display())
        };
        let dir_note =
            dir_note.or(local_dir_note.filter(|_| placed.iter().any(|(_, p)| p.is_none())));
        let dir_note = dir_note
            .map(|n| format!("\nDirectory: {n}."))
            .unwrap_or_default();
        Ok(format!(
            "{}{head}{dir_note}\n{}\nTell the user only what these lines say about workspaces. Write the user text this turn (your reply or send) that says in a line each what you started: Home shows each one only as a chip beside your words, and a spawn turn with no text gets a [no text] note. Name a subagent by its id (a1): the user's app shows each id as a link to its chat. Each one's report reaches you as a message, \"[id] report\", when it finishes; never wait or poll for them. tell(id, message) sends one more instructions.",
            routed_note.map(|n| format!("{n}\n")).unwrap_or_default(),
            lines.join("\n")
        ))
    }

    fn agent_chat(&self, id: &str, at: u64) -> Result<String, String> {
        self.agent_chat_page(id, at, crate::agent_chat::PAGE)
    }

    fn tell(&self, id: &str, message: &str) -> Result<String, String> {
        self.tell_keyed(id, message, None)
    }

    fn tell_keyed(&self, id: &str, message: &str, key: Option<&str>) -> Result<String, String> {
        self.tell_with(id, message, key, false)
    }

    fn tell_with(
        &self,
        id: &str,
        message: &str,
        key: Option<&str>,
        queue: bool,
    ) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::Tell {
            id: id.to_owned(),
            message: message.to_owned(),
            key: key.map(str::to_owned),
            queue,
            reply,
        })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn cloud_workspace(&self, request: &crate::cloud_workspace::Request) -> Result<String, String> {
        let Some(cloud) = &self.cloud_workspaces else {
            return Err(
                "cloud_workspace: this Chief host has no cmux app to make Cloud workspaces in"
                    .into(),
            );
        };
        let answer = cloud.call(request);
        (self.log)(&format!(
            "cloud_workspace {:?}: {}",
            request.title,
            answer.as_ref().unwrap_or_else(|e| e)
        ));
        self.trace.emit(
            "chief.cloud_workspace",
            serde_json::json!({"title": self.trace.text(&request.title), "ok": answer.is_ok()}),
        );
        answer
    }

    fn control(&self, request: crate::tools::ControlCall) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::Control { request, reply })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn react(&self, id: u64, reaction: &str) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::React {
            id,
            reaction: reaction.to_owned(),
            reply,
        })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn peers(&self, caller: &str) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::PeerList {
            caller: caller.to_owned(),
            reply,
        })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn transcript(&self, n: u32, before: Option<u64>) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::Transcript { n, before, reply })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn reply(&self, id: u64, text: &str) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::Reply {
            id,
            text: text.to_owned(),
            reply,
        })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn send(&self, call: crate::tools::SendCall) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::Send { call, reply })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn stop_turn(&self) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::StopTurn { reply })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn remember(&self, text: &str) -> Result<String, String> {
        let Some(person) = &self.person else {
            return Err("this Chief host has no person profile to remember in".into());
        };
        let answer = crate::remember::remember(person, text, &crate::remember::today())?;
        (self.log)(&format!("remember: {answer}"));
        self.trace.emit(
            "chief.remember",
            serde_json::json!({"text": self.trace.text(text), "noop": answer.starts_with("outcome: noop")}),
        );
        Ok(answer)
    }

    fn sleep(&self, call: crate::tools::SleepCall) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::Sleep { call, reply })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn watch(&self, call: crate::tools::WatchCall) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::Watch { call, reply })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn escalate_auth(
        &self,
        agent: &str,
        request: &crate::tools::AuthEscalation,
    ) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::EscalateAuth {
            agent: agent.to_owned(),
            request: request.clone(),
            reply,
        })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }

    fn peer_tell(
        &self,
        from: &str,
        id: &str,
        message: &str,
        key: Option<&str>,
    ) -> Result<String, String> {
        let (reply, answer) = channel();
        self.to_brain(Input::PeerTell {
            from: from.to_owned(),
            id: id.to_owned(),
            message: message.to_owned(),
            key: key.map(str::to_owned),
            reply,
        })?;
        answer
            .recv()
            .map_err(|_| "the Chief host is stopping".to_owned())?
    }
}

/// Queued subagent `id`'s launch from the log, `messages` newest first: the
/// spawn answer that queued it (`- a<N>: queued`) and the spawn call logged
/// before it (`<tool> {"tasks": [...], "cwd": ..., "effort": ...}`), whose
/// task at `id`'s place among the answer's ids is its own. No floor: the
/// log does not keep it.
pub fn recover_launch(
    id: &str,
    messages: impl Iterator<Item = (optchat_core::Kind, String)>,
) -> Option<crate::state::QueuedLaunch> {
    use optchat_core::Kind;
    let mine = format!("- {id}: queued");
    let mut index = None;
    for (kind, text) in messages {
        match (kind, index) {
            (Kind::Echo, None) if text.lines().any(|l| l.starts_with(&mine)) => {
                let ids: Vec<&str> = text
                    .lines()
                    .filter_map(|l| l.strip_prefix("- ")?.split(':').next())
                    .collect();
                index = ids.iter().position(|i| *i == id);
            }
            (Kind::Tool, Some(k)) => {
                let (name, input) = text.split_once(' ')?;
                if !name.ends_with("spawn") {
                    return None;
                }
                let input: Value = serde_json::from_str(input).ok()?;
                // Trimmed, and dropped when empty, as `Call::parse` does.
                let named = |key: &str| {
                    input
                        .get(key)
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|v| !v.is_empty())
                        .map(str::to_owned)
                };
                return Some(crate::state::QueuedLaunch {
                    task: input.get("tasks")?.get(k)?.as_str()?.to_owned(),
                    cwd: input.get("cwd").and_then(Value::as_str).map(str::to_owned),
                    effort: input
                        .get("effort")
                        .and_then(Value::as_str)
                        .map(str::to_owned),
                    floor: None,
                    harness: named("harness"),
                    model: named("model"),
                });
            }
            _ => {}
        }
    }
    None
}

/// Sends `/goal` (prompt `prompt_id`, its signals to `tx`) once the task
/// turn whose signals come on `task` ended. A task turn that was cancelled,
/// failed or lost its connection gets no `/goal`: its end goes to `tx`, so
/// the subagent ends as that turn did.
fn send_goal_after_task(
    agents: Arc<dyn AgentPort>,
    session: String,
    prompt_id: String,
    task: std::sync::mpsc::Receiver<TurnSignal>,
    tx: Sender<TurnSignal>,
) {
    std::thread::spawn(move || {
        let end = loop {
            match task.recv() {
                Ok(TurnSignal::Done(end)) => break Some(end),
                Ok(TurnSignal::Lost) | Err(_) => break None,
                Ok(_) => {}
            }
        };
        let signal = match end {
            Some(Ok(answer))
                if answer.get("stopReason").and_then(Value::as_str) != Some("cancelled") =>
            {
                let goal = vec![json!({"type": "text", "text": crate::goal::command()})];
                match agents.start_prompt(&session, goal, &prompt_id, tx.clone()) {
                    Ok(()) => return,
                    Err(e) => TurnSignal::Done(Err(e)),
                }
            }
            Some(end) => TurnSignal::Done(end),
            None => TurnSignal::Lost,
        };
        let _ = tx.send(signal);
    });
}

/// Reads `session`'s new events into `folder` and says whether its first
/// turn started: Some(true) when it is the turn of prompt `prompt_id`
/// (acpmux's `turn_started` after that prompt's `user_message`),
/// Some(false) when it is another's, None while none has started (or the
/// events could not be read: the next signal reads them again).
/// The goal's hold prompt (`hold`, goal.rs) runs first: its turn is
/// passed over, so the followed prompt's start still counts.
fn first_turn_start(
    agents: &dyn AgentPort,
    session: &str,
    prompt_id: &str,
    hold: Option<&str>,
    folder: &mut TurnFolder,
) -> Option<bool> {
    let events = agents.events(session, folder.seq()).ok()?;
    events.iter().find_map(|e| {
        folder.apply(e).into_iter().find_map(|out| match out {
            TurnOutput::Started { turn, .. }
                if hold.is_some() && turn.prompt_id.as_deref() == hold =>
            {
                None
            }
            TurnOutput::Started { turn, .. } => Some(turn.prompt_id.as_deref() == Some(prompt_id)),
            _ => None,
        })
    })
}

/// The answer of a prompt to a subagent: its token use and cost.
pub fn answer_fields(answer: &Result<Value, String>) -> Value {
    match answer {
        Ok(v) => json!({
            "usage": crate::fold::answer_usage(v).map(|(u, _)| crate::trace::usage(&u)),
            "cost_usd": crate::turn::answer_cost(v),
            "stop": v.get("stopReason"),
            "prompt_id": v.get("chief_prompt_id"),
        }),
        Err(e) => json!({"error": crate::trace::prefix(e)}),
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;
    use optchat_core::Kind;

    #[test]
    fn peer_directory_defaults_to_daemon_scratch_and_keeps_an_explicit_folder() {
        for asked in [None, Some(""), Some("relative"), Some("/srv/projects")] {
            let placement = CloudPlacement::from_env(
                |key| match key {
                    PEER_ENV => Some("cloud1".into()),
                    "OPTCHAT_SUBAGENT_PEER_DIR" => asked.map(str::to_owned),
                    _ => None,
                },
                "subagent instructions".into(),
            )
            .unwrap();
            assert_eq!(
                placement.dir,
                PathBuf::from(asked.filter(|p| p.starts_with('/')).unwrap_or(""))
            );
            let task = placement.task("a7", Some("~/fun/cmux"), "build the web page");
            if placement.dir.as_os_str().is_empty() {
                assert!(task.contains("worktree add \"$PWD\"/a7"), "{task}");
                assert!(
                    task.contains("then run `git config cmux.land <branch>`"),
                    "{task}"
                );
            } else {
                assert!(task.contains("worktree add /srv/projects/a7"), "{task}");
            }
        }
    }

    #[test]
    fn no_cap_unless_one_is_set() {
        assert_eq!(live_limit(None), None);
        assert_eq!(live_limit(Some("")), None);
        assert_eq!(live_limit(Some("0")), None);
        assert_eq!(live_limit(Some("many")), None);
        assert_eq!(live_limit(Some(" 32 ")), Some(32));
    }

    #[test]
    fn a_queued_launch_comes_back_from_its_spawn_call() {
        // Newest first, as the host reads the log.
        let log = vec![
            (Kind::User, "[a37] report".to_owned()),
            (
                Kind::Echo,
                "Queued a47, a48.\n- a46: started\n- a47: queued (16 subagents are at work)\n- a48: queued (16 subagents are at work)\nTell the user".to_owned(),
            ),
            (
                Kind::Tool,
                r#"mcp__optchat__spawn {"cwd":"~/fun/cmux","effort":"medium","tasks":["one","two","three"]}"#.to_owned(),
            ),
        ];
        let got = recover_launch("a48", log.clone().into_iter()).expect("a48");
        assert_eq!(got.task, "three");
        assert_eq!(got.cwd.as_deref(), Some("~/fun/cmux"));
        assert_eq!(got.effort.as_deref(), Some("medium"));
        assert_eq!(got.floor, None);
        assert_eq!(
            recover_launch("a47", log.clone().into_iter()).unwrap().task,
            "two"
        );
        // a46 started: it was never queued.
        assert_eq!(recover_launch("a46", log.into_iter()), None);
    }

    #[test]
    fn no_launch_when_the_call_before_is_not_a_spawn() {
        let log = vec![
            (Kind::Echo, "Queued a9.\n- a9: queued".to_owned()),
            (Kind::Tool, r#"Bash {"command":"ls"}"#.to_owned()),
        ];
        assert_eq!(recover_launch("a9", log.into_iter()), None);
    }
}
