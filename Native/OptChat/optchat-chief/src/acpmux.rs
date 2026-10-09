//! The acpmux side: the port the turn runner and the brain use, and its real
//! implementation over the acpmux socket, which reconnects on its own and
//! routes notifications to the turn that owns a session or to the brain.

use std::collections::{BTreeMap, HashMap, HashSet};
use std::path::PathBuf;
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_chief::acp::{AcpmuxEvent, SessionSummary};
use serde_json::{Value, json};

use crate::rpc::{Notification, RpcClient, RpcError};

/// A new acpmux session.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SessionSpec {
    pub name: String,
    pub cwd: PathBuf,
    pub harness: String,
    pub policy: String,
    pub model: Option<String>,
    /// acpmux's `effort` (a harness config option); None: the harness default.
    pub effort: Option<String>,
    /// A preset the session requires: it never starts without it (the
    /// compactor). None: the port's turn preset when installed.
    pub preset: Option<String>,
    /// acpmux tags set on the session right after it is created.
    pub tags: BTreeMap<String, String>,
    /// Per-session env (acpmux `_meta.acpmux.env`, unix socket only, an
    /// allowlist: CMUX_WORKSPACE_ID); empty for none.
    pub env: BTreeMap<String, String>,
}

/// The tag on every session the Chief itself runs (its turns and its
/// compactor nodes), valued with its home id; its children never carry it
/// (they keep `mux.parent`). Quit counts and endAgents exclude these.
pub const CHIEF_TAG: &str = "cmux.chief";
/// `turn` or `compactor`, next to `cmux.chief`.
pub const CHIEF_ROLE_TAG: &str = "cmux.chief.role";

/// The tags of a Chief session of `role` for home `home_id`.
pub fn chief_tags(home_id: &str, role: &str) -> BTreeMap<String, String> {
    BTreeMap::from([
        (CHIEF_TAG.to_owned(), home_id.to_owned()),
        (CHIEF_ROLE_TAG.to_owned(), role.to_owned()),
    ])
}

/// A harness's family, as acpmux reports it: it decides the layout and the
/// isolation each Chief session gets.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Family {
    /// Claude Code (claude, claude-sr, ...): preset system prompts, cache
    /// markers, `CLAUDE_CONFIG_DIR`.
    Claude,
    /// Codex (codex-acp): automatic prefix caching routed by
    /// `prompt_cache_key`, `CODEX_HOME`.
    Codex,
    /// Any other harness: the codex layout without codex's settings.
    Other,
}

impl Family {
    pub fn from_name(family: &str) -> Family {
        match family {
            "claude" => Family::Claude,
            "codex" => Family::Codex,
            _ => Family::Other,
        }
    }
}

/// The family of `harness` in an `_acpmux/harnesses` answer: the `family`
/// acpmux reports (a declared one, else derived from the harness kind and
/// command). A daemon from before that field: derived here the same way,
/// from `kind` and the command's words, never from the harness's name.
pub fn harness_family(answer: &Value, harness: &str) -> Result<Family, String> {
    cmux_chief::policy::harness::family(answer, harness).map(|f| Family::from_name(&f))
}

/// `_acpmux/harnesses` from the daemon at `socket` (started when it does not
/// answer, as the link starts it), on a connection of its own.
pub fn query_harnesses(socket: &std::path::Path, log: &dyn Fn(&str)) -> Result<Value, String> {
    crate::acpmux_daemon::ensure(socket, log)?;
    let client = RpcClient::connect(socket, |_| {})
        .map_err(|e| format!("connect {}: {e}", socket.display()))?;
    let result = client
        .request(
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "optchat-chief", "version": env!("CARGO_PKG_VERSION")}}),
        )
        .map_err(|e| format!("initialize: {e}"))
        .and_then(|_| {
            client
                .request("_acpmux/harnesses", json!({}))
                .map_err(|e| format!("harnesses: {e}"))
        });
    client.close();
    result
}

/// What a running turn hears about its session.
#[derive(Clone, Debug, PartialEq)]
pub enum TurnSignal {
    /// Reply text streamed (drafts, `draft.rs`): read soon, at most every
    /// `draft::STREAM_GAP`.
    Streamed,
    /// New events that matter for the log (not text chunks, but for a
    /// prompt's first, which says its response started): fetch them.
    Changed,
    /// The prompt's answer: the turn ended (or never started, on an error).
    Done(Result<Value, String>),
    /// The acpmux connection ended during the turn.
    Lost,
}

/// What the brain hears from acpmux.
#[derive(Clone, Debug, PartialEq)]
pub enum AgentEvent {
    /// Connected (again): every session, for reconciling children.
    Up(Vec<SessionSummary>),
    Down,
    /// The acpmux daemon this host started or joined shut down (its socket
    /// is gone): the host never starts another and stops.
    Ended,
    SessionChanged(SessionSummary),
    Permission {
        session_id: String,
        permission_id: String,
        request: Value,
    },
}

/// The acpmux operations the Chief needs. Implemented over the socket here
/// and by in-process fakes in tests.
pub trait AgentPort: Send + Sync {
    /// Creates a session; returns its id.
    fn new_session(&self, spec: &SessionSpec) -> Result<String, String>;
    /// Sends a prompt as a new turn; the session's signals and the answer go to `signals`.
    fn start_prompt(
        &self,
        session: &str,
        blocks: Vec<Value>,
        prompt_id: &str,
        signals: Sender<TurnSignal>,
    ) -> Result<(), String>;
    /// The session's recorded events after `after`, oldest first.
    fn events(&self, session: &str, after: u64) -> Result<Vec<AcpmuxEvent>, String>;
    /// Stops routing the session's signals and removes the session.
    fn end_session(&self, session: &str) -> Result<(), String>;
    /// A session's id by name.
    fn find(&self, name: &str) -> Result<Option<String>, String>;
    /// A session's summary by id (None: no such session).
    fn session(&self, _id: &str) -> Result<Option<SessionSummary>, String> {
        Ok(None)
    }
    /// Stops the session's running turn (`session/cancel`; Claude Code gets an
    /// interrupt). The turn then ends with stop reason `cancelled`.
    fn cancel(&self, _session: &str) -> Result<(), String> {
        Err("cancel is not supported".into())
    }
    /// The daemon's `_acpmux/harnesses` answer: every profile with its kind,
    /// command and family (`harness_gate::admit` reads it before each Chief
    /// session). A port without one refuses every Chief session.
    fn harness_catalog(&self) -> Result<Value, String> {
        Err("this acpmux port reports no harness catalog".into())
    }

    /// Answers a pending permission request of `session`
    /// (`_acpmux/permission_respond`) with `option` (None: cancelled).
    fn respond_permission(
        &self,
        _session: &str,
        _permission: &str,
        _option: Option<&str>,
    ) -> Result<(), String> {
        Err("answering permissions is not supported".into())
    }
    /// Delivers `blocks` into `session`'s running turn between its tool
    /// calls (a steered `session/prompt`, `steerOnly`): Ok once the harness
    /// read them. Err: the session could not take them now (no running turn,
    /// a harness that does not steer); nothing was delivered.
    fn steer(&self, _session: &str, _blocks: Vec<Value>, _prompt_id: &str) -> Result<(), String> {
        Err("steering is not supported".into())
    }
    /// Hints acpmux's session pool (`_acpmux/prewarm`) to start a hidden
    /// session of `harness` and `preset` in `cwd`, so the next `session/new`
    /// of exactly that shape takes a harness that is already up.
    fn prewarm(
        &self,
        _harness: &str,
        _preset: Option<&str>,
        _cwd: &std::path::Path,
    ) -> Result<(), String> {
        Ok(())
    }
    /// Whether the connected daemon installed `preset` with its `args`.
    fn preset_args(&self, _preset: &str) -> bool {
        false
    }
    /// Whether the connected daemon installed `preset` with a system prompt
    /// (it knows `systemPrompt`): the cached layout.
    fn system_prompt(&self, _preset: &str) -> bool {
        false
    }
    /// Replaces preset `preset`'s system prompt text (acpmux writes the file
    /// and records its new sha256); sessions that start after it use it.
    fn set_system_prompt(&self, _preset: &str, _text: &str) -> Result<(), String> {
        Err("this acpmux takes no preset system prompt".into())
    }
}

/// Event kinds that never change the log by themselves; a turn fetches
/// events only on the others, so streaming text costs no requests.
fn is_noise(kind: &str) -> bool {
    matches!(
        kind,
        "agent_message_chunk" | "agent_thought_chunk" | "usage_update" | "user_message_chunk"
    )
}

type Sink = Arc<dyn Fn(AgentEvent) + Send + Sync>;

/// An acpmux preset every turn session starts with: its env reaches the
/// harness process (acpmux puts a preset's env over the profile's).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Preset {
    pub name: String,
    /// The harness the preset names (acpmux requires one); turn sessions
    /// still pass their own explicitly.
    pub harness: String,
    pub env: BTreeMap<String, String>,
    /// Words appended to the harness command (acpmux preset `args`, one argv
    /// word each, no shell). A daemon from before `args` refuses the key; the
    /// preset is then installed without them and `preset_args` says so.
    pub args: Vec<String>,
    /// The preset's system prompt text at install (acpmux `systemPrompt`,
    /// Claude harnesses only): acpmux writes it into its own preset directory
    /// and records its sha256; `set_system_prompt` replaces it later. A
    /// daemon from before `systemPrompt` refuses the key; the preset is then
    /// installed without it and `system_prompt` says so.
    pub system_prompt: Option<String>,
}

/// The real port: one connection at a time to the acpmux daemon.
pub struct Acpmux {
    socket: PathBuf,
    client: Mutex<Option<Arc<RpcClient>>>,
    turns: Arc<Mutex<HashMap<String, TurnRoute>>>,
    /// The turn sessions' preset, used when installed (else a turn runs with
    /// the harness's own configuration, and host.log says so).
    preset: Option<Preset>,
    /// Presets that sessions name in `SessionSpec::preset` and require.
    required: Vec<Preset>,
    /// Presets installed in the connected daemon.
    ready: Mutex<HashSet<String>>,
    /// Presets installed with their `args` (the daemon knows the key).
    with_args: Mutex<HashSet<String>>,
    /// Presets installed with a system prompt (the daemon knows `systemPrompt`).
    with_prompt: Mutex<HashSet<String>>,
}

impl Acpmux {
    pub fn new(socket: PathBuf, preset: Option<Preset>, required: Vec<Preset>) -> Arc<Acpmux> {
        Arc::new(Acpmux {
            socket,
            client: Mutex::new(None),
            turns: Arc::new(Mutex::new(HashMap::new())),
            preset,
            required,
            ready: Mutex::new(HashSet::new()),
            with_args: Mutex::new(HashSet::new()),
            with_prompt: Mutex::new(HashSet::new()),
        })
    }

    /// Installs (or refreshes) every preset; acpmux saves them in its config.
    /// A daemon that does not know a key refuses it ("unknown preset key"):
    /// the preset is installed again without it, and its users keep the
    /// layout without (args before #17283, systemPrompt before the preset
    /// system prompt).
    fn install_presets(&self, client: &RpcClient, log: &dyn Fn(&str)) {
        let mut ready = HashSet::new();
        let mut with_args = HashSet::new();
        let mut with_prompt = HashSet::new();
        let all = self.preset.iter().map(|p| (p, false));
        for (preset, required) in all.chain(self.required.iter().map(|p| (p, true))) {
            let mut set = json!({
                "harness": preset.harness,
                "env": preset.env,
                "description": "optchat-chief: an isolated Claude Code configuration",
            });
            // Always say both: acpmux merges a set into the preset it saved,
            // and the last host's Claude args or system prompt (an engine
            // switch on the same daemon) would stay and refuse a codex set.
            set["args"] = if preset.args.is_empty() {
                Value::Null
            } else {
                json!(preset.args)
            };
            set["systemPrompt"] = preset
                .system_prompt
                .as_ref()
                .map_or(Value::Null, |text| json!(text));
            let result = loop {
                let result =
                    client.request("_acpmux/presets", json!({"name": preset.name, "set": set}));
                let Err(e) = &result else { break result };
                let text = e.to_string();
                // An unknown key ("unknown preset key \"systemPrompt\"; use
                // ..., args, ...") or a refused value ("systemPrompt: ...",
                // "args: ...").
                let key = if text.contains("key \"systemPrompt\"") || text.contains("systemPrompt:")
                {
                    "systemPrompt"
                } else if text.contains("args") {
                    "args"
                } else {
                    break result;
                };
                let Some(map) = set.as_object_mut() else {
                    break result;
                };
                // A daemon older than the isolation args: keep the args it
                // knows (`--tools ""` and the rest), drop only those.
                if key == "args"
                    && let Some(args) = map.get_mut("args").and_then(Value::as_array_mut)
                    && let Some(kept) = without_isolation_args(args)
                {
                    *args = kept;
                    log(&format!(
                        "acpmux refused the isolation args of preset {} ({text}); installed without --setting-sources, --disable-slash-commands and a --tools list (the project settings' denied tools still apply)",
                        preset.name
                    ));
                    continue;
                }
                if map.remove(key).is_none() {
                    break result;
                }
                log(&format!(
                    "acpmux refused the {key} of preset {} ({text}); installed without it",
                    preset.name
                ));
            };
            match result {
                Ok(_) => {
                    ready.insert(preset.name.clone());
                    if set.get("args").is_some_and(|args| !args.is_null()) {
                        with_args.insert(preset.name.clone());
                    }
                    if set.get("systemPrompt").is_some_and(|text| !text.is_null()) {
                        with_prompt.insert(preset.name.clone());
                    }
                }
                Err(e) if required => log(&format!(
                    "acpmux preset {} not installed ({e}); sessions that require it do not start",
                    preset.name
                )),
                Err(e) => log(&format!(
                    "acpmux preset {} not installed ({e}); turns run with the user's Claude configuration",
                    preset.name
                )),
            }
        }
        *self
            .ready
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = ready;
        *self
            .with_args
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = with_args;
        *self
            .with_prompt
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = with_prompt;
    }

    fn client(&self) -> Result<Arc<RpcClient>, String> {
        self.client
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone()
            .filter(|c| !c.is_closed())
            .ok_or_else(|| "acpmux is not connected".to_owned())
    }

    /// Runs the connection loop on its own thread: start the daemon if needed,
    /// connect, report sessions, wait for the end, back off, again.
    pub fn spawn_link(self: &Arc<Self>, sink: Sink, log: Arc<dyn Fn(&str) + Send + Sync>) {
        let this = self.clone();
        let report = log.clone();
        let spawned = std::thread::Builder::new()
            .name("acpmux-link".into())
            .spawn(move || {
                let mut delay = Duration::from_millis(500);
                // The host starts the daemon only before its first link: once
                // that daemon (or the one it joined) shuts down, the host's
                // sessions ended with it, and it never starts another.
                let mut linked = false;
                loop {
                    let started = std::time::Instant::now();
                    match this.connect_once(&sink, &*log, !linked) {
                        Ok(closed) => {
                            linked = true;
                            let _ = closed.recv();
                            log("acpmux connection closed");
                        }
                        Err(e) => log(&format!("acpmux: {e}")),
                    }
                    *this
                        .client
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner) = None;
                    for (_, turn) in this
                        .turns
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner)
                        .drain()
                    {
                        let _ = turn.tx.send(TurnSignal::Lost);
                    }
                    sink(AgentEvent::Down);
                    if linked && !crate::acpmux_daemon::reachable(&this.socket) {
                        log("acpmux daemon ended; the host does not start another");
                        sink(AgentEvent::Ended);
                        return;
                    }
                    if started.elapsed() > Duration::from_secs(30) {
                        delay = Duration::from_millis(500);
                    }
                    std::thread::sleep(delay);
                    delay = (delay * 2).min(Duration::from_secs(30));
                }
            });
        if let Err(e) = spawned {
            report(&format!("acpmux: cannot start the link thread: {e}"));
        }
    }

    fn connect_once(
        &self,
        sink: &Sink,
        log: &dyn Fn(&str),
        may_start: bool,
    ) -> Result<std::sync::mpsc::Receiver<()>, String> {
        if may_start {
            crate::acpmux_daemon::ensure(&self.socket, log)?;
        }
        let (closed_tx, closed_rx) = channel();
        let turns = self.turns.clone();
        let route_sink = sink.clone();
        let client = RpcClient::connect(&self.socket, move |n| {
            if n.method.is_empty() {
                let _ = closed_tx.send(());
            } else {
                route(&turns, &route_sink, n);
            }
        })
        .map_err(|e| format!("connect {}: {e}", self.socket.display()))?;
        let result = (|| {
            client
                .request(
                    "initialize",
                    json!({"protocolVersion": 1, "clientCapabilities": {}, "clientInfo": {"name": "optchat-chief", "version": env!("CARGO_PKG_VERSION")}}),
                )
                .map_err(|e| format!("initialize: {e}"))?;
            client
                .request("_acpmux/watch", json!({"enabled": true}))
                .map_err(|e| format!("watch: {e}"))?;
            sessions(&client)
        })();
        match result {
            Ok(list) => {
                self.install_presets(&client, log);
                *self
                    .client
                    .lock()
                    .unwrap_or_else(std::sync::PoisonError::into_inner) = Some(client);
                log(&format!("acpmux connected at {}", self.socket.display()));
                sink(AgentEvent::Up(list));
                Ok(closed_rx)
            }
            Err(e) => {
                client.close();
                Err(e)
            }
        }
    }
}

/// `args` without the newer preset allowlist words: `--setting-sources
/// <value>`, `--disable-slash-commands` and `--tools <names>` (`--tools ""`
/// stays, an older acpmux takes it); None when it has none of them.
pub fn without_isolation_args(args: &[Value]) -> Option<Vec<Value>> {
    let mut kept = Vec::new();
    let mut dropped = false;
    let mut words = args.iter();
    while let Some(word) = words.next() {
        match word.as_str() {
            Some("--setting-sources") => {
                words.next();
                dropped = true;
            }
            Some("--disable-slash-commands") => dropped = true,
            Some("--tools") => match words.next() {
                Some(value) if value.as_str() == Some("") => {
                    kept.push(word.clone());
                    kept.push(value.clone());
                }
                _ => dropped = true,
            },
            _ => kept.push(word.clone()),
        }
    }
    dropped.then_some(kept)
}

/// `args` without a `--tools <names>` list (`--tools ""` stays); None when
/// it has none.
pub fn without_tools_list(_args: &[Value]) -> Option<Vec<Value>> {
    None
}

/// Sends a notification to the turn that owns its session, or to the brain.
/// A running prompt's signals.
struct TurnRoute {
    tx: Sender<TurnSignal>,
    /// The harness streamed output in this prompt already.
    spoke: bool,
}

/// The first streamed output of a prompt: its response has started (the
/// API's `message_start` came, so the request's cache entry exists).
pub(crate) fn is_output(kind: &str) -> bool {
    matches!(
        kind,
        "agent_message_chunk" | "agent_thought_chunk" | "usage_update"
    )
}

fn route(turns: &Mutex<HashMap<String, TurnRoute>>, sink: &Sink, n: Notification) {
    let session = n
        .params
        .get("sessionId")
        .and_then(Value::as_str)
        .unwrap_or("");
    match n.method.as_str() {
        "session/update" | "_acpmux/event" => {
            let kind = n
                .params
                .pointer("/_meta/acpmux/kind")
                .or_else(|| n.params.pointer("/update/sessionUpdate"))
                .or_else(|| n.params.get("kind"))
                .and_then(Value::as_str)
                .unwrap_or("");
            let mut turns = turns
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            if let Some(turn) = turns.get_mut(session) {
                // Chunks are noise but for the first one, which says the
                // response started (the compactor's single-flight waits for it).
                let first = is_output(kind) && !turn.spoke;
                turn.spoke |= is_output(kind);
                if first || !is_noise(kind) {
                    let _ = turn.tx.send(TurnSignal::Changed);
                } else if kind == "agent_message_chunk" {
                    let _ = turn.tx.send(TurnSignal::Streamed);
                }
            }
        }
        "_acpmux/session_changed" => {
            if let Some(summary) = n
                .params
                .get("session")
                .and_then(|s| serde_json::from_value::<SessionSummary>(s.clone()).ok())
            {
                sink(AgentEvent::SessionChanged(summary));
            }
        }
        "_acpmux/permission_pending" => sink(AgentEvent::Permission {
            session_id: session.to_owned(),
            permission_id: n
                .params
                .get("permissionId")
                .and_then(Value::as_str)
                .unwrap_or("")
                .to_owned(),
            request: n.params.get("request").cloned().unwrap_or(Value::Null),
        }),
        _ => {}
    }
}

/// `_acpmux/sessions`, rows that do not parse skipped.
pub fn sessions(client: &RpcClient) -> Result<Vec<SessionSummary>, String> {
    let result = client
        .request("_acpmux/sessions", json!({}))
        .map_err(|e| format!("sessions: {e}"))?;
    Ok(result
        .get("sessions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|s| serde_json::from_value(s.clone()).ok())
        .collect())
}

/// `_acpmux/events` after `after`, every page.
pub fn events(client: &RpcClient, session: &str, after: u64) -> Result<Vec<AcpmuxEvent>, String> {
    const LIMIT: u64 = 10_000;
    let mut all: Vec<AcpmuxEvent> = Vec::new();
    let mut cursor = after;
    loop {
        let result = client
            .request(
                "_acpmux/events",
                json!({"sessionId": session, "afterSeq": cursor, "limit": LIMIT}),
            )
            .map_err(|e| format!("events: {e}"))?;
        let page: Vec<AcpmuxEvent> = result
            .get("events")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .filter_map(|e| serde_json::from_value(e.clone()).ok())
            .collect();
        let full = page.len() as u64 >= LIMIT;
        let last = page.iter().map(|e| e.seq).max().unwrap_or(cursor);
        all.extend(page);
        if !full || last <= cursor {
            return Ok(all);
        }
        cursor = last;
    }
}

/// `session/new` with acpmux's name, harness, policy, model and preset.
pub fn new_session(
    client: &RpcClient,
    spec: &SessionSpec,
    preset: Option<&str>,
) -> Result<String, String> {
    let mut meta = json!({"name": spec.name, "harness": spec.harness, "policy": spec.policy});
    if let Some(model) = &spec.model {
        meta["model"] = json!(model);
    }
    if let Some(effort) = &spec.effort {
        meta["effort"] = json!(effort);
    }
    if let Some(preset) = preset {
        meta["preset"] = json!(preset);
    }
    if !spec.env.is_empty() {
        meta["env"] = json!(spec.env);
    }
    let result = client
        .request(
            "session/new",
            json!({"cwd": spec.cwd, "mcpServers": [], "_meta": {"acpmux": meta}}),
        )
        .map_err(|e| format!("session/new: {e}"))?;
    let id = result
        .get("sessionId")
        .and_then(Value::as_str)
        .map(str::to_owned)
        .ok_or_else(|| "session/new answered without a sessionId".to_owned())?;
    // Right after creation: an untagged Chief session would count as one of
    // the user's agents (quit counts, endAgents), so it does not stay.
    if !spec.tags.is_empty()
        && let Err(e) = client.request("_acpmux/tag", json!({"sessionId": id, "set": spec.tags}))
    {
        let _ = client.request("_acpmux/kill", json!({"sessionId": id, "purge": true}));
        return Err(format!("tagging session {}: {e}", spec.name));
    }
    Ok(id)
}

impl AgentPort for Acpmux {
    fn new_session(&self, spec: &SessionSpec) -> Result<String, String> {
        let ready = self
            .ready
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let preset = match &spec.preset {
            Some(name) if ready.contains(name) => Some(name.as_str()),
            // Never a fallback to the user's own configuration.
            Some(name) => {
                return Err(format!(
                    "the acpmux preset {name} is not installed, and this session never starts without it"
                ));
            }
            None => self
                .preset
                .as_ref()
                .filter(|p| ready.contains(&p.name))
                .map(|p| p.name.as_str()),
        };
        new_session(&*self.client()?, spec, preset)
    }

    fn start_prompt(
        &self,
        session: &str,
        blocks: Vec<Value>,
        prompt_id: &str,
        signals: Sender<TurnSignal>,
    ) -> Result<(), String> {
        let client = self.client()?;
        self.turns
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .insert(
                session.to_owned(),
                TurnRoute {
                    tx: signals.clone(),
                    spoke: false,
                },
            );
        let answer = client.start(
            "session/prompt",
            json!({"sessionId": session, "prompt": blocks, "_meta": {"acpmux": {"promptId": prompt_id}}}),
        );
        std::thread::Builder::new()
            .name("acpmux-prompt".into())
            .spawn(move || {
                let done = match answer.recv() {
                    Ok(Ok(value)) => TurnSignal::Done(Ok(value)),
                    Ok(Err(RpcError::Remote { message, .. })) => TurnSignal::Done(Err(message)),
                    Ok(Err(RpcError::Closed | RpcError::Timeout(_))) | Err(_) => TurnSignal::Lost,
                };
                let _ = signals.send(done);
            })
            .map_err(|e| e.to_string())?;
        Ok(())
    }

    fn events(&self, session: &str, after: u64) -> Result<Vec<AcpmuxEvent>, String> {
        events(&*self.client()?, session, after)
    }

    fn end_session(&self, session: &str) -> Result<(), String> {
        self.turns
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .remove(session);
        self.client()?
            .request("_acpmux/kill", json!({"sessionId": session, "purge": true}))
            .map(|_| ())
            .map_err(|e| format!("kill: {e}"))
    }

    fn find(&self, name: &str) -> Result<Option<String>, String> {
        Ok(sessions(&*self.client()?)?
            .into_iter()
            .find(|s| s.name == name)
            .map(|s| s.session_id))
    }

    fn session(&self, id: &str) -> Result<Option<SessionSummary>, String> {
        Ok(sessions(&*self.client()?)?
            .into_iter()
            .find(|s| s.session_id == id))
    }

    fn cancel(&self, session: &str) -> Result<(), String> {
        self.client()?
            .request("session/cancel", json!({"sessionId": session}))
            .map(|_| ())
            .map_err(|e| format!("cancel: {e}"))
    }

    fn harness_catalog(&self) -> Result<Value, String> {
        self.client()?
            .request("_acpmux/harnesses", json!({}))
            .map_err(|e| format!("harnesses: {e}"))
    }

    fn respond_permission(
        &self,
        session: &str,
        permission: &str,
        option: Option<&str>,
    ) -> Result<(), String> {
        let mut params = json!({"sessionId": session, "permissionId": permission});
        if let Some(option) = option {
            params["optionId"] = json!(option);
        }
        self.client()?
            .request("_acpmux/permission_respond", params)
            .map(|_| ())
            .map_err(|e| format!("permission_respond: {e}"))
    }

    fn steer(&self, session: &str, blocks: Vec<Value>, prompt_id: &str) -> Result<(), String> {
        // No timeout: acpmux answers when the harness reads the message, at
        // its next tool boundary, however long the running tool takes.
        let answer = self.client()?.start(
            "session/prompt",
            json!({"sessionId": session, "prompt": blocks, "_meta": {"acpmux": {"promptId": prompt_id, "steer": true, "steerOnly": true}}}),
        );
        match answer.recv() {
            Ok(Ok(v)) if v.get("stopReason").and_then(Value::as_str) == Some("steered") => Ok(()),
            Ok(Ok(v)) => Err(format!("acpmux did not steer the message ({v})")),
            Ok(Err(e)) => Err(format!("steer: {e}")),
            Err(_) => Err("steer: the acpmux connection closed".into()),
        }
    }

    fn prewarm(
        &self,
        harness: &str,
        preset: Option<&str>,
        cwd: &std::path::Path,
    ) -> Result<(), String> {
        // The same preset `new_session` gives a session that names none.
        let ready = self
            .ready
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .clone();
        let preset = match preset {
            Some(name) if ready.contains(name) => Some(name.to_owned()),
            Some(_) => return Ok(()),
            None => self
                .preset
                .as_ref()
                .filter(|p| ready.contains(&p.name))
                .map(|p| p.name.clone()),
        };
        let mut params = json!({"harness": harness, "cwd": cwd});
        if let Some(preset) = preset {
            params["preset"] = json!(preset);
        }
        self.client()?
            .request("_acpmux/prewarm", params)
            .map(|_| ())
            .map_err(|e| format!("prewarm: {e}"))
    }

    fn preset_args(&self, preset: &str) -> bool {
        self.with_args
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(preset)
    }

    fn system_prompt(&self, preset: &str) -> bool {
        self.with_prompt
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .contains(preset)
    }

    fn set_system_prompt(&self, preset: &str, text: &str) -> Result<(), String> {
        if !self.system_prompt(preset) {
            return Err(format!(
                "the acpmux preset {preset} was not installed with a system prompt"
            ));
        }
        self.client()?
            .request(
                "_acpmux/presets",
                json!({"name": preset, "set": {"systemPrompt": text}}),
            )
            .map(|_| ())
            .map_err(|e| format!("setting the system prompt of preset {preset}: {e}"))
    }
}
