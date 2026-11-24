//! Open-source brains for the Chief (chief-cohesion OSS-LOCAL-BRAINS.md, "Build"): Hermes Agent
//! (NousResearch/hermes-agent) and OpenClaw (openclaw/openclaw) run a Chief turn as acpmux ACP
//! harnesses, each from a home the Chief owns, `$MUX_HOME/optchat/brains/<family>`. acpmux points
//! the brain there (`HERMES_HOME`, `OPENCLAW_HOME`: acpmux `config/chief_builtins.rs`, and the
//! brain turn preset here, `brain_turn_preset`), so the person's own `~/.hermes` or `~/.openclaw`
//! never runs a Chief turn and a turn never changes them.
//!
//! The Chief keeps what is its own (coordinator decision 2026-11-19):
//!
//! - the UI, the conversation and the memory of record: the brain reads the Chief's view and
//!   instructions (the session folder's AGENTS.md) and writes memory only through the Chief's
//!   `remember`; its own memory files and memory tool are off;
//! - the scheduler of record: the brain's own cron never runs (Hermes runs cron only in its
//!   gateway, which the Chief never starts; OpenClaw's `cron.enabled` is false), and `brains
//!   migrate` imports the jobs a brain already has into cmux automations, each one confirmed;
//! - the approvals: the brain's permission requests reach acpmux, which answers under the
//!   Chief's policy;
//! - the models: every model call goes to the gateway the person set (`brain_base_url` in
//!   engine.json or `OPTCHAT_BRAIN_BASE_URL`; there is no built-in one) with a placeholder key
//!   the gateway ignores, never a personal key. Hermes does not borrow the person's Codex or Claude Code login
//!   (`auth.adopt_external_logins: false`).
//!
//! The host writes each installed brain's home at its start (`prepare`) and records what it
//! found in `brains/state.json` (`BrainState`); a turn on a brain that cannot start falls back
//! to the default harness and records that too (brain/turns.rs), so `chief brains` and the
//! Chief settings picker say which brain answers and why.

use std::collections::BTreeMap;
use std::io;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::paths::Paths;
use crate::session_dir::write_if_changed;

/// One open-source brain: its acpmux family (the harness id discovery gives it), its name, and
/// the env key that points it at its home (the same pairs as acpmux `chief_builtins::BRAINS`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Brain {
    pub family: &'static str,
    pub name: &'static str,
    pub home_env: &'static str,
}

/// The brains the Chief supports, in the order the picker lists them.
pub const BRAINS: [Brain; 2] = [
    Brain {
        family: "hermes",
        name: "Hermes Agent",
        home_env: "HERMES_HOME",
    },
    Brain {
        family: "openclaw",
        name: "OpenClaw",
        home_env: "OPENCLAW_HOME",
    },
];

/// The brain of acpmux family `family`, if it is one.
pub fn brain(family: &str) -> Option<&'static Brain> {
    BRAINS.iter().find(|b| b.family == family)
}

/// The brain's home: `$MUX_HOME/optchat/brains/<family>`.
pub fn dir(paths: &Paths, brain: &Brain) -> PathBuf {
    paths.root.join("brains").join(brain.family)
}

/// Where the host records the brains' state: `<optchat root>/brains/state.json`.
pub fn state_path(root: &Path) -> PathBuf {
    root.join("brains").join("state.json")
}

/// The brains a host's turns can run on, for the brain (brain/turns.rs).
#[derive(Clone, Debug, Default)]
pub struct BrainTurns {
    /// The optchat folder (`$MUX_HOME/optchat`) whose `brains/state.json` records fallbacks;
    /// None: nothing is recorded (tests).
    pub root: Option<PathBuf>,
    /// By acpmux harness name.
    pub by_harness: BTreeMap<String, BrainTurn>,
    /// The model the brains' homes name (their turns' model when engine.json names none):
    /// what prices a brain turn (turn_price.rs).
    pub model: Option<String>,
}

/// One brain harness: its turn preset, and whether it can run a turn (Err: why not).
#[derive(Clone, Debug)]
pub struct BrainTurn {
    pub brain: &'static Brain,
    pub preset: Option<String>,
    pub ready: Result<(), String>,
    /// A turn that failed on it at run time: when the brain is tried again. None with an Err:
    /// its state at the host start (not installed, unavailable), until the next start.
    pub retry_at: Option<std::time::Instant>,
    /// Turns it answered while this host runs.
    pub ran: u64,
}

/// How long a brain that failed a turn waits before a turn is tried on it again.
pub const RETRY_AFTER: std::time::Duration = std::time::Duration::from_secs(10 * 60);

impl BrainTurns {
    /// The brain harness `harness` runs, if it is one.
    pub fn get(&self, harness: &str) -> Option<&BrainTurn> {
        self.by_harness.get(harness)
    }

    /// Records that `harness` answered a turn: a later fallback posts its note again.
    pub fn mark_ran(&mut self, harness: &str) {
        if let Some(turn) = self.by_harness.get_mut(harness) {
            turn.ran += 1;
        }
    }

    /// How many turns `harness` answered (the fallback note's key).
    pub fn ran_ok(&self, harness: &str) -> u64 {
        self.get(harness).map_or(0, |t| t.ran)
    }

    /// Marks `harness` as unable to run turns until the host starts again.
    pub fn disable(&mut self, harness: &str, reason: &str) {
        if let Some(turn) = self.by_harness.get_mut(harness) {
            turn.ready = Err(reason.to_owned());
            turn.retry_at = None;
        }
    }

    /// Marks `harness` as unable to run turns for [`RETRY_AFTER`].
    pub fn fail(&mut self, harness: &str, reason: &str, now: std::time::Instant) {
        if let Some(turn) = self.by_harness.get_mut(harness) {
            turn.ready = Err(reason.to_owned());
            turn.retry_at = Some(now + RETRY_AFTER);
        }
    }

    /// Why a turn on brain harness `harness` cannot run now (None: it can, or it is no brain).
    /// A run-time failure past its retry time clears here, so the next turn tries it again.
    pub fn refusal(&mut self, harness: &str, now: std::time::Instant) -> Option<String> {
        let turn = self.by_harness.get_mut(harness)?;
        if turn.retry_at.is_some_and(|at| now >= at) {
            turn.ready = Ok(());
            turn.retry_at = None;
        }
        // A brain with no turn preset of its own would start with the person's own home: never.
        match (&turn.ready, &turn.preset) {
            (Err(reason), _) => Some(reason.clone()),
            (Ok(()), None) => Some("it has no turn preset on this acpmux".to_owned()),
            (Ok(()), Some(_)) => None,
        }
    }

    /// The harness a turn takes when a brain cannot run it: `default` unless that is a brain
    /// itself, else the first harness of `families` that is no brain (Claude first).
    pub fn fallback_harness(
        &self,
        default: &str,
        families: &BTreeMap<String, crate::acpmux::Family>,
    ) -> String {
        if self.get(default).is_none() {
            return default.to_owned();
        }
        let not_brain = |name: &&String| self.get(name).is_none();
        families
            .iter()
            .filter(|(_, f)| **f == crate::acpmux::Family::Claude)
            .map(|(name, _)| name)
            .find(not_brain)
            .or_else(|| families.keys().find(not_brain))
            .cloned()
            .unwrap_or_else(|| default.to_owned())
    }
}

/// The host env that names the brains' gateway when engine.json names none. There is no
/// built-in gateway: a person's brain calls only the gateway they set (`chief engine set
/// --brain-base-url URL`, engine.json `brain_base_url`, or this env). Without one the brain is
/// unavailable ([`NO_GATEWAY`]) and the default harness answers with a note.
pub const BASE_URL_ENV: &str = "OPTCHAT_BRAIN_BASE_URL";

/// Why a brain is unavailable when no gateway is set.
pub const NO_GATEWAY: &str = "no model gateway is set for open-source brains (`chief engine set --brain-base-url URL`, or OPTCHAT_BRAIN_BASE_URL)";

/// The model a brain runs when engine.json names none: one an OpenAI-compatible gateway serves on its
/// Responses route.
pub const DEFAULT_MODEL: &str = "gpt-6.1-terra";

/// The API key a brain sends: the gateway signs requests itself and ignores it. Never a
/// personal key.
pub const GATEWAY_KEY: &str = "cmux-gateway-signs-requests";

/// What a brain home is written from.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct BrainSetup {
    /// The gateway base URL, without `/v1`; empty when none is set ([`NO_GATEWAY`]).
    pub base_url: String,
    /// The brain's start model (a turn's engine model replaces it per session).
    pub model: String,
    /// The Chief's turn session folder (its AGENTS.md holds the Chief's instructions).
    pub session_dir: PathBuf,
    /// cmux's MCP servers for a brain that takes none per session (OpenClaw): `{name, command,
    /// args, env}`.
    pub mcp_servers: Vec<Value>,
}

impl BrainSetup {
    /// From engine.json's `brain_base_url` and `model`, else the defaults.
    pub fn from_choice(choice: &crate::engine::EngineChoice, paths: &Paths) -> BrainSetup {
        let base_url = choice
            .brain_base_url
            .clone()
            .or_else(|| crate::cli::env(BASE_URL_ENV))
            .as_deref()
            .map(str::trim)
            .filter(|u| !u.is_empty())
            .unwrap_or("")
            .trim_end_matches('/')
            .trim_end_matches("/v1")
            .to_owned();
        BrainSetup {
            base_url,
            model: choice
                .model
                .clone()
                .filter(|m| !m.trim().is_empty())
                .unwrap_or_else(|| DEFAULT_MODEL.to_owned()),
            session_dir: paths.session.clone(),
            mcp_servers: Vec::new(),
        }
    }
}

/// A YAML scalar: a JSON string is a valid YAML double-quoted scalar.
fn yaml(text: &str) -> String {
    Value::String(text.to_owned()).to_string()
}

/// Hermes' `config.yaml` for a Chief turn. Every key is one Hermes documents
/// (`cli-config.yaml.example`, v0.23).
pub fn hermes_config(setup: &BrainSetup) -> String {
    format!(
        "# Written by the cmux Chief (optchat-chief brain_home.rs) at each Chief start; edits here are
# replaced. The Chief owns the schedules, the memory, the approvals and the chat apps: this
# Hermes runs one Chief turn at a time over ACP (`hermes acp`) and never starts its gateway,
# which is where Hermes runs cron.
model:
  provider: cmux-gateway
  default: {model}
providers:
  cmux-gateway:
    base_url: {base}
    api_mode: codex_responses
    api_key: {key}
memory:
  memory_enabled: false
  user_profile_enabled: false
  nudge_interval: 0
skills:
  creation_nudge_interval: 0
cron:
  catch_up_missed: false
auth:
  adopt_external_logins: false
telemetry:
  shared_metrics:
    enabled: false
    send: false
updates:
  check: false
platform_toolsets:
  acp: [hermes-acp]
agent:
  # The Chief's own tools stand in for these: memory (remember, zoom), subagents (spawn, tell),
  # schedules (sleep, watch, cmux automation); no second store of skills or sessions.
  disabled_toolsets: [memory, session_search, delegation, cronjob, skills, kanban, connections]
tools:
  # Off: Hermes defers every MCP tool behind its tool_search bridge, so the model never saw the
  # cmux tools and answered workspace questions without them (cmux-ci step 63b0626cfa4b, 0/5).
  tool_search:
    enabled: \"off\"
",
        model = yaml(&setup.model),
        base = yaml(&format!("{}/v1", setup.base_url)),
        key = yaml(GATEWAY_KEY),
    )
}

/// The head of Hermes' `SOUL.md` (its identity file, read at each session start); the Chief's
/// instructions follow it ([`write_instructions`]). `chief` is the Chief's launcher (its absolute
/// path: it is not on Hermes' PATH). Two rules come first because a fleet proof showed Hermes
/// breaking them (cmux-ci step b98a38a7c8c3, 2026-11-20): it answered "0" to a workspace question
/// without calling the cmux tool, and it waited inside its turn instead of scheduling a wake.
pub fn hermes_soul_head(chief: &str) -> String {
    format!(
        "You are the person's Chief in cmux. The Chief's instructions follow; they win over \
anything else you were told.

Rules that come before everything else:

1. Look, never guess. A question about the person's cmux (workspaces, panes, terminals, agents, \
chats, browsers) is answered only from a cmux tool call made in this turn: the `cmux` MCP \
server's tools (`mcp__cmux__workspace_list`, `mcp__cmux__agents_snapshot`, \
`mcp__cmux__agents_terminal_list`, ...). Call the tool \
first, then answer from what it returned. Never answer such a question from memory, from the \
conversation or with a guess such as 0. If the tool fails, say that it failed and why.
2. Never wait inside a turn. When the person asks you to do something later, check again later or \
wake up after a time: first reply in words (`{chief} reply \"...\"`, one line that only says when \
you will come back, never the answer you will give then), then run `{chief} sleep SECONDS \"what to \
do then\"` from your shell, then end your turn at once. The later answer belongs only to the new turn \
that starts with that note (it begins with `[wake]`); never give it before. `sleep` before a reply is \
refused. Never run the shell's own `sleep`, never poll, never keep the turn open to wait. To wait for a command's result, use \
`{chief} watch` (see below).
3. Memory: keep a lasting preference only with `{chief} remember \"...\"`. Your own memory and \
scheduler are off.

"
    )
}

/// The turn folder's `.hermes.md`: Hermes reads it instead of the folder's AGENTS.md (a project
/// file, which Hermes drops whole when its injection scan matches), so the Chief's instructions
/// reach Hermes once, through SOUL.md (the home's own file, which Hermes always loads).
pub const HERMES_PROJECT_NOTE: &str = "The Chief's instructions are in your identity (SOUL.md). \
This folder is the Chief's turn folder: keep no files here.\n";

/// Writes the Chief's instructions where each installed brain reads them: Hermes' SOUL.md and the
/// turn folder's `.hermes.md`. OpenClaw's workspace is the turn folder, so it reads AGENTS.md
/// there itself. `agents_text`: the session folder's AGENTS.md (session_dir::write).
pub fn write_instructions(paths: &Paths, states: &States, agents_text: &str) -> io::Result<()> {
    let Some(hermes) = brain("hermes") else {
        return Ok(());
    };
    if states.get("hermes").is_none_or(|s| s.home.is_none()) {
        return Ok(());
    }
    let home = dir(paths, hermes);
    write_if_changed(
        &home.join("SOUL.md"),
        format!(
            "{}{agents_text}",
            hermes_soul_head(&paths.bin.join("chief").display().to_string())
        )
        .as_bytes(),
    )?;
    write_if_changed(
        &paths.session.join(".hermes.md"),
        HERMES_PROJECT_NOTE.as_bytes(),
    )
}

/// Writes the brain's home for `setup` (a file is rewritten only when it changed).
pub fn write(paths: &Paths, brain: &Brain, setup: &BrainSetup) -> io::Result<PathBuf> {
    let home = dir(paths, brain);
    std::fs::create_dir_all(&home)?;
    match brain.family {
        "hermes" => {
            write_if_changed(&home.join("config.yaml"), hermes_config(setup).as_bytes())?;
        }
        "openclaw" => crate::brain_home_openclaw::write(&home, setup)?,
        _ => {}
    }
    Ok(home)
}

/// A brain's state as the host found it at its start, and its last fallback.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct BrainState {
    /// `ready`, `not-installed`, `unavailable` (acpmux lists it but cannot run it) or `error`
    /// (its home could not be written).
    pub state: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
    /// The acpmux harness that runs it, when installed.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub home: Option<String>,
    /// The brain's program (the harness command's first word).
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub program: Option<String>,
    /// The model gateway its home names.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base_url: Option<String>,
    /// The last turn that asked for this brain and ran on the default harness instead.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub fallback: Option<Fallback>,
}

/// A turn that fell back from a brain to the default harness.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Fallback {
    /// Unix ms.
    pub at: u64,
    /// The harness that ran the turn instead.
    pub to: String,
    pub reason: String,
}

/// Every brain's state, by family.
pub type States = BTreeMap<String, BrainState>;

pub fn load_states(root: &Path) -> States {
    std::fs::read(state_path(root))
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
        .unwrap_or_default()
}

pub fn save_states(root: &Path, states: &States) -> io::Result<()> {
    let path = state_path(root);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let mut bytes = serde_json::to_vec_pretty(states).map_err(io::Error::other)?;
    bytes.push(b'\n');
    write_if_changed(&path, &bytes)
}

/// Records that a turn asked for the brain of harness `from` and ran on `to`.
pub fn record_fallback(root: &Path, family: &str, to: &str, reason: &str, at: u64) {
    let mut states = load_states(root);
    let entry = states.entry(family.to_owned()).or_default();
    entry.fallback = Some(Fallback {
        at,
        to: to.to_owned(),
        reason: reason.to_owned(),
    });
    let _ = save_states(root, &states);
}

/// The one-line note a reply carries after a fallback: what failed and who answered instead.
pub fn fallback_note(brain: &Brain, to: &str, reason: &str) -> String {
    let reason: String = reason
        .lines()
        .next()
        .unwrap_or("")
        .chars()
        .take(200)
        .collect();
    format!(
        "Note: {} could not run this turn ({reason}). {to} answered instead; `chief brains` shows why.",
        brain.name
    )
}

/// The host start: each brain's state from acpmux's `_acpmux/harnesses` answer, and its home
/// written for an installed one. `harnesses`: the admitted harnesses (name, acpmux family).
pub fn prepare(paths: &Paths, answer: &Value, setup: &BrainSetup, log: &dyn Fn(String)) -> States {
    let old = load_states(&paths.root);
    let mut states = States::new();
    // A daemon that defines the Chief's presets itself fills a brain preset's env from its own
    // definition; one from before the brain presets would start the brain with the person's own
    // home and keys, so no brain runs on it.
    let features = answer.get(crate::acpmux::DAEMON_FEATURES);
    let old_daemon = features
        .is_some_and(|f| f["builtinPresets"] == json!(true) && f["brainPresets"] != json!(true));
    let profiles = answer.get("harnesses").and_then(Value::as_object);
    for brain in &BRAINS {
        let found = profiles.and_then(|m| {
            m.iter().find(|(name, p)| {
                p.get("family").and_then(Value::as_str) == Some(brain.family)
                    || name.as_str() == brain.family
            })
        });
        let mut state = BrainState {
            fallback: old.get(brain.family).and_then(|s| s.fallback.clone()),
            ..BrainState::default()
        };
        match found {
            None => {
                state.state = "not-installed".into();
                state.reason = Some(install_hint(brain).into());
            }
            Some((name, profile)) => {
                state.harness = Some(name.clone());
                state.program = profile
                    .get("argv")
                    .or_else(|| profile.get("command"))
                    .and_then(|a| a.as_array().and_then(|a| a.first()).or(Some(a)))
                    .and_then(Value::as_str)
                    .map(str::to_owned);
                let blocked = match brain.family {
                    "openclaw" => {
                        crate::brain_home_openclaw::blocker(std::env::var_os("PATH").as_deref())
                    }
                    _ => None,
                };
                let unavailable = profile
                    .get("unavailable")
                    .and_then(Value::as_str)
                    .filter(|r| !r.is_empty())
                    .map(str::to_owned)
                    .or(blocked)
                    .or_else(|| setup.base_url.is_empty().then(|| NO_GATEWAY.to_owned()))
                    .or_else(|| {
                        old_daemon.then(|| {
                            "this acpmux is older than the Chief's brain presets; update cmux"
                                .to_owned()
                        })
                    });
                // No gateway: nothing to write (a home would name no model route).
                if setup.base_url.is_empty() {
                    state.state = "unavailable".into();
                    state.reason = unavailable;
                    states.insert(brain.family.to_owned(), state);
                    log(format!(
                        "brain {}: unavailable ({NO_GATEWAY})",
                        brain.family
                    ));
                    continue;
                }
                match write(paths, brain, setup) {
                    Ok(home) => {
                        state.home = Some(home.display().to_string());
                        state.base_url = Some(setup.base_url.clone());
                        match unavailable {
                            Some(reason) => {
                                state.state = "unavailable".into();
                                state.reason = Some(reason);
                            }
                            None => state.state = "ready".into(),
                        }
                    }
                    Err(e) => {
                        state.state = "error".into();
                        state.reason = Some(format!("writing its home: {e}"));
                    }
                }
            }
        }
        log(format!(
            "brain {}: {}{}",
            brain.family,
            state.state,
            state
                .reason
                .as_deref()
                .map(|r| format!(" ({r})"))
                .unwrap_or_default()
        ));
        states.insert(brain.family.to_owned(), state);
    }
    if let Err(e) = save_states(&paths.root, &states) {
        log(format!(
            "brains: writing {}: {e}",
            state_path(&paths.root).display()
        ));
    }
    states
}

/// How to install a brain.
pub fn install_hint(brain: &Brain) -> &'static str {
    match brain.family {
        "hermes" => {
            "install it with its installer (hermes-agent.nousresearch.com/docs/getting-started/installation; it builds no wheel), then restart the Chief"
        }
        "openclaw" => "install it with `npm install -g openclaw`, then restart the Chief",
        _ => "not installed",
    }
}

/// The `chief brains` listing: each brain, its state, its harness and gateway, and its last
/// fallback.
pub fn listing(paths: &Paths, current: Option<&str>) -> String {
    let states = load_states(&paths.root);
    let mut out = String::new();
    if states.is_empty() {
        out.push_str(
            "brains: unknown (the Chief host has not started since it began recording them)\n",
        );
    }
    for brain in &BRAINS {
        let Some(s) = states.get(brain.family) else {
            continue;
        };
        let on = s.harness.as_deref().is_some_and(|h| current == Some(h));
        out.push_str(&format!(
            "{}{} ({}): {}{}\n",
            if on { "* " } else { "  " },
            brain.family,
            brain.name,
            s.state,
            s.reason
                .as_deref()
                .map(|r| format!(": {r}"))
                .unwrap_or_default()
        ));
        if let Some(url) = &s.base_url {
            out.push_str(&format!("    models through {url}\n"));
        }
        if let Some(f) = &s.fallback {
            let when = chrono::DateTime::from_timestamp_millis(f.at as i64)
                .map(|t| {
                    t.with_timezone(&chrono::Local)
                        .format("%Y-%m-%d %H:%M")
                        .to_string()
                })
                .unwrap_or_default();
            out.push_str(&format!(
                "    last fallback {when}: {} answered ({})\n",
                f.to, f.reason
            ));
        }
    }
    out.push_str(
        "Pick one: `chief engine set --harness hermes` (or openclaw); back: `chief engine set --harness default`.\n",
    );
    out
}

/// One brain job that `brains migrate` turns into a cmux automation.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MigratedJob {
    pub name: String,
    /// The `cmux automation create` arguments after the name.
    pub args: Vec<String>,
    /// Why a job cannot move (a script-only job, a schedule cmux does not take).
    pub skipped: Option<String>,
}

/// Hermes' jobs (`<hermes home>/cron/jobs.json`: `{"jobs": [...]}` or a bare list) as cmux
/// automations. A job keeps its prompt, schedule, model and paused state; it runs on Hermes
/// (`--model hermes[/MODEL]`), so moving it changes where it is scheduled, not what runs it.
pub fn hermes_jobs(text: &str) -> Result<Vec<MigratedJob>, String> {
    let doc: Value = serde_json::from_str(text).map_err(|e| format!("jobs.json: {e}"))?;
    let jobs = match &doc {
        Value::Array(list) => list.clone(),
        Value::Object(map) => match map.get("jobs") {
            Some(Value::Array(list)) => list.clone(),
            Some(Value::Object(by_id)) => by_id.values().cloned().collect(),
            _ => Vec::new(),
        },
        _ => return Err("jobs.json: neither a list nor {\"jobs\": ...}".into()),
    };
    Ok(jobs.iter().filter_map(hermes_job).collect())
}

fn hermes_job(job: &Value) -> Option<MigratedJob> {
    let text = |k: &str| {
        job.get(k)
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|v| !v.is_empty())
    };
    let id = text("id").unwrap_or("job");
    let name = slug(text("name").unwrap_or(id));
    let mut skipped = None;
    let mut args = Vec::new();
    match text("prompt") {
        Some(prompt) if job.get("no_agent").and_then(Value::as_bool) != Some(true) => {
            args.extend(["--prompt".to_owned(), prompt.to_owned()]);
        }
        _ => skipped = Some(
            "a script-only job (no prompt): recreate it with `cmux automation create --command`"
                .to_owned(),
        ),
    }
    let schedule = job.get("schedule");
    let kind = schedule.and_then(|s| s.get("kind")).and_then(Value::as_str);
    match kind {
        Some("cron") => match schedule.and_then(|s| s.get("expr")).and_then(Value::as_str) {
            Some(expr) => args.extend(["--cron".to_owned(), expr.to_owned()]),
            None => skipped = skipped.or(Some("a cron schedule with no expression".into())),
        },
        Some("interval") => match schedule
            .and_then(|s| s.get("minutes"))
            .and_then(Value::as_u64)
        {
            Some(m) if m > 0 => args.extend(["--every".to_owned(), format!("{m}m")]),
            _ => skipped = skipped.or(Some("an interval with no minutes".into())),
        },
        Some("once") => match schedule
            .and_then(|s| s.get("run_at"))
            .and_then(Value::as_str)
        {
            Some(at) => match chrono::DateTime::parse_from_rfc3339(at) {
                Ok(t) => args.extend([
                    "--at".to_owned(),
                    t.with_timezone(&chrono::Local)
                        .format("%Y-%m-%d %H:%M")
                        .to_string(),
                ]),
                Err(_) => {
                    skipped = skipped.or(Some(format!("a run time cmux does not read: {at}")))
                }
            },
            None => skipped = skipped.or(Some("a one-time job with no run time".into())),
        },
        other => {
            skipped = skipped.or(Some(format!(
                "schedule kind {}",
                other.unwrap_or("missing")
            )))
        }
    }
    let model = text("model");
    args.extend([
        "--model".to_owned(),
        match model {
            Some(m) => format!("hermes/{m}"),
            None => "hermes".to_owned(),
        },
    ]);
    let enabled = job.get("enabled").and_then(Value::as_bool).unwrap_or(true)
        && text("state") != Some("paused");
    if !enabled {
        args.push("--paused".to_owned());
    }
    Some(MigratedJob {
        name,
        args,
        skipped,
    })
}

/// A cmux automation name from a job name: lowercase words and dashes.
fn slug(name: &str) -> String {
    let mut out = String::new();
    for c in name.chars() {
        if c.is_ascii_alphanumeric() {
            out.push(c.to_ascii_lowercase());
        } else if !out.ends_with('-') && !out.is_empty() {
            out.push('-');
        }
    }
    let out = out.trim_end_matches('-').to_owned();
    if out.is_empty() {
        "hermes-job".into()
    } else {
        format!("hermes-{out}")
    }
}

/// A shell-quoted word for the printed commands.
fn quote(word: &str) -> String {
    if !word.is_empty()
        && word
            .chars()
            .all(|c| c.is_ascii_alphanumeric() || "-_./:=,".contains(c))
    {
        word.to_owned()
    } else {
        format!("'{}'", word.replace('\'', "'\\''"))
    }
}

/// `optchat-chief brains [list] | migrate hermes [--from DIR] [--apply NAME|all]`.
pub fn run(flags: &crate::cli::Flags) -> Result<String, String> {
    let home = flags
        .value("mux-home")
        .map(PathBuf::from)
        .unwrap_or_else(crate::paths::mux_home);
    let paths = Paths::new(&home);
    match flags.words.get(1).map(String::as_str) {
        None | Some("list") => {
            let current = crate::engine::load(&crate::engine::path(&home)).harness;
            Ok(listing(&paths, current.as_deref()))
        }
        Some("migrate") => match flags.words.get(2).map(String::as_str) {
            Some("hermes") => migrate_hermes(flags),
            Some("openclaw") => Err("migrate openclaw: list its jobs with `openclaw cron list --json` and recreate each with `cmux automation create`; an automatic import is not built yet".into()),
            _ => Err("usage: chief brains migrate hermes [--from DIR] [--apply NAME|all]".into()),
        },
        Some(other) => Err(format!(
            "unknown brains command {other:?}: use list, or migrate hermes [--from DIR] [--apply NAME|all]"
        )),
    }
}

fn migrate_hermes(flags: &crate::cli::Flags) -> Result<String, String> {
    let from = flags
        .value("from")
        .map(PathBuf::from)
        .or_else(|| crate::cli::env("HERMES_HOME").map(PathBuf::from))
        .or_else(|| dirs_home().map(|h| h.join(".hermes")))
        .ok_or("no home folder: pass --from DIR")?;
    let file = from.join("cron").join("jobs.json");
    let text = match std::fs::read_to_string(&file) {
        Ok(text) => text,
        Err(e) if e.kind() == io::ErrorKind::NotFound => {
            return Ok(format!("{}: no Hermes jobs to move\n", file.display()));
        }
        Err(e) => return Err(format!("{}: {e}", file.display())),
    };
    let jobs = hermes_jobs(&text)?;
    let apply = flags.value("apply");
    let cmux = crate::cli::env("CMUX_BUNDLED_CLI_PATH").unwrap_or_else(|| "cmux".to_owned());
    let mut out = format!("{} Hermes job(s) in {}\n", jobs.len(), file.display());
    for job in &jobs {
        let line = format!(
            "cmux automation create {} {}",
            quote(&job.name),
            job.args
                .iter()
                .map(|a| quote(a))
                .collect::<Vec<_>>()
                .join(" ")
        );
        if let Some(why) = &job.skipped {
            out.push_str(&format!("skip {}: {why}\n", job.name));
            continue;
        }
        let wanted = apply.is_some_and(|a| a == "all" || a == job.name);
        if !wanted {
            out.push_str(&format!("{line}\n"));
            continue;
        }
        let status = std::process::Command::new(&cmux)
            .args(["automation", "create", &job.name])
            .args(&job.args)
            .stdin(std::process::Stdio::null())
            .status()
            .map_err(|e| format!("{cmux}: {e}"))?;
        out.push_str(&format!(
            "{} {}\n",
            if status.success() {
                "created"
            } else {
                "FAILED"
            },
            job.name
        ));
    }
    if apply.is_none() {
        out.push_str(
            "Nothing changed. Check each line, then run it, or `chief brains migrate hermes --apply NAME|all`.\nTurn the job off in Hermes after it moves (`hermes cron pause ID`), so it does not run twice.\n",
        );
    }
    Ok(out)
}

fn dirs_home() -> Option<PathBuf> {
    std::env::var_os("HOME").map(PathBuf::from)
}

/// The provider keys a brain's env blanks, so its models go only through the gateway its home
/// names (the same names as acpmux `login_env::PROVIDER_KEYS`, which a built-in preset blanks).
pub const PROVIDER_KEYS: [&str; 26] = [
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_BASE_URL",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "AZURE_OPENAI_API_KEY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "GOOGLE_GENERATIVE_AI_API_KEY",
    "OPENROUTER_API_KEY",
    "GROQ_API_KEY",
    "TOGETHER_API_KEY",
    "TOGETHER_AI_API_KEY",
    "FIREWORKS_API_KEY",
    "DEEPSEEK_API_KEY",
    "MISTRAL_API_KEY",
    "XAI_API_KEY",
    "CEREBRAS_API_KEY",
    "DEEPINFRA_API_KEY",
    "HF_TOKEN",
    "AI_GATEWAY_API_KEY",
    "ZAI_API_KEY",
    "MINIMAX_API_KEY",
    "KIMI_API_KEY",
    "MOONSHOT_API_KEY",
    "PERPLEXITY_API_KEY",
    "NOUS_API_KEY",
];

/// The brain turn preset's name: `optchat-chief-<family>-<home id>` (acpmux
/// `chief_builtins::parse` knows it, so a Chief started outside the app gets the same env).
pub fn turn_preset_name(home: &Path, brain: &Brain) -> String {
    format!(
        "optchat-chief-{}-{}",
        brain.family,
        crate::paths::home_id(home)
    )
}

/// The cmux servers a brain that takes none per session gets in its own config: the `cmux`
/// server with the Chief's tools only, and the Chief's own `optchat` server (zoom, date,
/// remember, sleep, spawn, tell).
pub fn chief_mcp_servers(paths: &Paths, exe: &str, cmux_cli: Option<&Path>) -> Vec<Value> {
    let mut servers = vec![json!({
        "name": "optchat",
        "command": exe,
        "args": ["mcp", "--socket", paths.tools_socket.display().to_string()],
        "env": {},
    })];
    if let Some(cli) = cmux_cli {
        servers.push(json!({
            "name": "cmux",
            "command": cli.display().to_string(),
            "args": ["mcp", "serve"],
            "env": {
                crate::session_dir::TURN_TOOLS_ENV: crate::session_dir::CHIEF_CMUX_TOOLS.join(","),
            },
        }));
    }
    servers
}
