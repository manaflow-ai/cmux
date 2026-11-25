//! The Chief's MCP hub (docs/chief-mcp-hub.md): the
//! person says "connect to <server>" and the Chief adds it itself with its
//! `mcp` tool. The hub keeps the server (`<optchat root>/mcp/`), connects on
//! first use over stdio or Streamable HTTP (signing in with OAuth when the
//! server asks), and serves its tools to the Chief and its subagents in code
//! mode: one fixed `mcp` tool, whatever servers are added, so the turn's tool
//! list never changes and no schema sits in the prompt until asked for.
//!
//! Long work and pushed changes reach the Chief like a subagent's report:
//! an MCP task (2025-11-25 core Tasks, or the 2026-07-28 Tasks extension; a
//! server without tasks gets a call the hub runs off the turn) wakes the
//! Chief once with its result, and an event subscription (a resource it
//! watches, or a notification method) wakes it like a `watch`.
//!
//! Every action is one JSON object (`{"action": "add", "target": ...}`): the
//! same shape from the `mcp` tool, the host socket and the CLI.

pub mod client;
pub mod codemode;
pub mod oauth;
pub mod store;
pub mod wire;

use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, Weak};
use std::time::Duration;

use serde_json::{Value, json};

use client::{Client, ClientError, Era};
use store::{Dir, Secrets, Server, State, Subscription, Task, Transport};
use wire::{HttpWire, OnMessage, StdioWire, Wire, WireError};

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// `text` with tokens masked (cmux-mcp-connect's rules).
pub fn redact(text: &str) -> String {
    cmux_mcp_connect::redact::redact(text)
}

/// Who makes a call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Caller {
    /// The Chief's own turn.
    Chief,
    /// A subagent (its id, `a12`): it may use servers, not add or remove them.
    Subagent(String),
}

impl Caller {
    fn label(&self) -> String {
        match self {
            Caller::Chief => "you".into(),
            Caller::Subagent(id) => id.clone(),
        }
    }
}

/// How a note reaches the Chief (the brain queues it and wakes the Chief).
pub type Notify = Arc<dyn Fn(String) + Send + Sync>;

/// Reads one environment variable (tests pass their own).
pub type EnvFn = Arc<dyn Fn(&str) -> Option<String> + Send + Sync>;

/// The longest a tool call waits by default.
pub const CALL_TIMEOUT: Duration = Duration::from_secs(120);
/// A task's default lifetime (the `ttl` the hub asks for).
pub const TASK_TTL_MS: u64 = 6 * 3600 * 1000;
/// Events of one subscription within this window wake the Chief once.
pub const EVENT_COALESCE: Duration = Duration::from_secs(3);
/// The least time between two wakes of one subscription.
pub const EVENT_MIN_GAP_MS: u64 = 20_000;
/// A connection with no subscription or task closes after this idle time.
pub const IDLE_CLOSE_MS: u64 = 10 * 60 * 1000;
/// The most characters of a result a wake note carries.
pub const NOTE_RESULT_CHARS: usize = 3000;

struct Live {
    client: Client,
    streams: Mutex<HashSet<String>>,
    last_used: AtomicU64,
}

#[derive(Default)]
struct EventBuffer {
    lines: Vec<String>,
    count: usize,
    scheduled: bool,
    last_fire_ms: u64,
}

struct Inner {
    dir: Dir,
    /// The Chief's own skills folder (MCP prompts become skills there).
    skills: Option<PathBuf>,
    state: Mutex<State>,
    live: Mutex<HashMap<String, Arc<Live>>>,
    connecting: Mutex<HashMap<String, Arc<Mutex<()>>>>,
    events: Mutex<HashMap<String, EventBuffer>>,
    signing_in: Mutex<HashSet<String>>,
    notify: Notify,
    env: EnvFn,
    stopped: AtomicBool,
}

/// The hub. Clones share one hub.
#[derive(Clone)]
pub struct McpHub {
    inner: Arc<Inner>,
}

enum ConnectError {
    /// The server needs a sign-in: the `WWW-Authenticate` header.
    Auth(String),
    Other(String),
}

impl From<ClientError> for ConnectError {
    fn from(e: ClientError) -> Self {
        match e {
            ClientError::Wire(WireError::Auth(h)) => ConnectError::Auth(h),
            e => ConnectError::Other(redact(&e.to_string())),
        }
    }
}

fn arg<'a>(args: &'a Value, key: &str) -> Option<&'a str> {
    args.get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|s| !s.is_empty())
}

/// A server name: `[a-z0-9_]`, starting with a letter.
pub fn clean_name(raw: &str) -> String {
    let mut s: String = raw
        .trim()
        .to_ascii_lowercase()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() { c } else { '_' })
        .collect();
    while s.contains("__") {
        s = s.replace("__", "_");
    }
    let s = s.trim_matches('_').to_owned();
    if s.chars().next().is_some_and(|c| c.is_ascii_alphabetic()) {
        s
    } else {
        format!("s_{s}")
    }
}

/// The name a URL's server gets: the host's most telling label
/// (`mcp.deepwiki.com` -> `deepwiki`).
pub fn name_for_url(url: &str) -> String {
    let host = url::Url::parse(url)
        .ok()
        .and_then(|u| u.host_str().map(str::to_owned))
        .unwrap_or_default();
    let labels: Vec<&str> = host.split('.').collect();
    let skip = ["mcp", "www", "api", "app", "server", "localhost", "127"];
    let pick = labels
        .iter()
        .take(labels.len().saturating_sub(1).max(1))
        .find(|l| !skip.contains(*l) && !l.is_empty())
        .or(labels.first())
        .copied()
        .unwrap_or("server");
    clean_name(pick)
}

/// Finds `program` on PATH or in the usual install folders (the host may run
/// with the app's short PATH).
pub fn which(program: &str, env: &dyn Fn(&str) -> Option<String>) -> Option<PathBuf> {
    if program.contains('/') {
        let p = PathBuf::from(program);
        return p.is_file().then_some(p);
    }
    let home = env("HOME").unwrap_or_default();
    let mut dirs: Vec<PathBuf> = env("PATH")
        .unwrap_or_default()
        .split(':')
        .filter(|d| !d.is_empty())
        .map(PathBuf::from)
        .collect();
    for extra in [
        ".local/bin",
        ".bun/bin",
        ".deno/bin",
        ".cargo/bin",
        ".volta/bin",
    ] {
        dirs.push(Path::new(&home).join(extra));
    }
    dirs.extend(["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"].map(PathBuf::from));
    dirs.into_iter()
        .map(|d| d.join(program))
        .find(|p| p.is_file())
}

fn flagged(tool: &Value) -> bool {
    cmux_mcp_connect::screen::screen_tool(tool)
        .iter()
        .any(|f| !matches!(f, cmux_mcp_connect::screen::Flag::TooLong(_)))
}

fn cut(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        text.to_owned()
    } else {
        format!("{}... [cut]", text.chars().take(max).collect::<String>())
    }
}

fn human(ms: u64) -> String {
    let s = ms / 1000;
    match s {
        0..=59 => format!("{s}s"),
        60..=3599 => format!("{}m {}s", s / 60, s % 60),
        _ => format!("{}h {}m", s / 3600, (s % 3600) / 60),
    }
}

impl McpHub {
    /// A hub keeping its servers in `dir` (`<optchat root>/mcp`), writing
    /// MCP prompts as skills into `skills` (the Chief's own skills folder),
    /// and waking the Chief through `notify`.
    pub fn new(dir: PathBuf, skills: Option<PathBuf>, notify: Notify) -> Self {
        Self::with_env(
            dir,
            skills,
            notify,
            Arc::new(|k: &str| std::env::var(k).ok()),
        )
    }

    pub fn with_env(dir: PathBuf, skills: Option<PathBuf>, notify: Notify, env: EnvFn) -> Self {
        let dir = Dir(dir);
        let mut state = dir.load();
        // A call the hub ran itself died with the last host.
        for t in state
            .tasks
            .iter_mut()
            .filter(|t| !t.ended() && t.remote.is_none())
        {
            t.status = "failed".into();
            t.message = "the Chief host restarted while it ran".into();
            t.ended_ms = Some(now_ms());
        }
        Self {
            inner: Arc::new(Inner {
                dir,
                skills,
                state: Mutex::new(state),
                live: Mutex::default(),
                connecting: Mutex::default(),
                events: Mutex::default(),
                signing_in: Mutex::default(),
                notify,
                env,
                stopped: AtomicBool::new(false),
            }),
        }
    }

    /// Resumes what outlives a restart: server tasks are polled again and
    /// event subscriptions armed again (each on its own thread), and idle
    /// connections are reaped from now on.
    pub fn start(&self) {
        let pending: Vec<Task> = self
            .state()
            .tasks
            .iter()
            .filter(|t| !t.ended())
            .cloned()
            .collect();
        for t in pending {
            self.spawn_poller(t.id.clone());
        }
        let servers: HashSet<String> = self
            .state()
            .subscriptions
            .iter()
            .map(|s| s.server.clone())
            .collect();
        for name in servers {
            let hub = self.clone();
            let _ = std::thread::Builder::new()
                .name("mcp-arm".into())
                .spawn(move || {
                    if hub.connect(&name).is_ok() {
                        hub.arm_all(&name);
                    }
                });
        }
        let weak = Arc::downgrade(&self.inner);
        let _ = std::thread::Builder::new()
            .name("mcp-reaper".into())
            .spawn(move || {
                loop {
                    std::thread::sleep(Duration::from_secs(60));
                    let Some(inner) = weak.upgrade() else { return };
                    if inner.stopped.load(Ordering::SeqCst) {
                        return;
                    }
                    McpHub { inner }.reap();
                }
            });
    }

    /// Closes every connection (the host is stopping).
    pub fn stop(&self) {
        self.inner.stopped.store(true, Ordering::SeqCst);
        let live: Vec<Arc<Live>> = self
            .inner
            .live
            .lock()
            .unwrap()
            .drain()
            .map(|(_, l)| l)
            .collect();
        for l in live {
            l.client.close();
        }
    }

    fn state(&self) -> std::sync::MutexGuard<'_, State> {
        self.inner.state.lock().unwrap()
    }

    fn save(&self) {
        let state = self.state().clone();
        let _ = self.inner.dir.save(&state);
    }

    fn note(&self, text: String) {
        (self.inner.notify)(text);
    }

    /// One action of the `mcp` tool.
    pub fn handle(&self, args: &Value, caller: &Caller) -> Result<String, String> {
        let action = arg(args, "action").unwrap_or("list");
        let chief_only = matches!(action, "add" | "connect" | "remove" | "signin");
        if chief_only && let Caller::Subagent(id) = caller {
            return Err(format!(
                "mcp {action}: only the Chief adds and removes servers; {id} can ask it (tell) to"
            ));
        }
        match action {
            "add" | "connect" => self.add(args, caller),
            "list" | "servers" => Ok(self.list()),
            "remove" => self.remove(
                arg(args, "server")
                    .or(arg(args, "name"))
                    .ok_or("mcp remove: name the `server`")?,
            ),
            "signin" => {
                let name = arg(args, "server")
                    .or(arg(args, "name"))
                    .ok_or("mcp signin: name the `server`")?;
                self.reconnect_or_sign_in(name)
            }
            "search" => Ok(self.search(arg(args, "query").unwrap_or(""), arg(args, "server"))),
            "describe" => self.describe(
                arg(args, "server").ok_or("mcp describe: name the `server`")?,
                arg(args, "tool"),
            ),
            "call" => self.call_action(args, caller),
            "run" => self.run_code(args),
            "tasks" => Ok(self.tasks_list()),
            "task" => self.task_action(args),
            "subscribe" => self.subscribe(args, caller),
            "unsubscribe" => self.unsubscribe(
                arg(args, "id")
                    .ok_or("mcp unsubscribe: give the subscription `id` (e<N>) or all")?,
            ),
            "events" => Ok(self.events_list()),
            "resources" => {
                self.resources(arg(args, "server").ok_or("mcp resources: name the `server`")?)
            }
            "read" => self.read(
                arg(args, "server").ok_or("mcp read: name the `server`")?,
                arg(args, "uri").ok_or("mcp read: give the `uri`")?,
            ),
            "prompts" => Ok(self.prompts_list(arg(args, "server"))),
            "prompt" => self.prompt(args),
            other => Err(format!(
                "mcp: unknown action {other:?}; use add, list, remove, signin, search, describe, call, run, tasks, task, subscribe, unsubscribe, events, resources, read, prompts or prompt"
            )),
        }
    }

    // ---- add, list, remove ----

    fn add(&self, args: &Value, caller: &Caller) -> Result<String, String> {
        let target = arg(args, "target")
            .or(arg(args, "url"))
            .or(arg(args, "command"))
            .ok_or("mcp add: give `target`: a server name (linear), an https URL, or a command (npx -y @scope/server)")?;
        let registry = cmux_mcp_connect::registry::Registry::builtin();
        let resolved = cmux_mcp_connect::resolve::resolve(target, &registry)
            .map_err(|e| format!("mcp add: {e}"))?;
        use cmux_mcp_connect::resolve::Resolved;
        let (default_name, transport, publisher, verified) = match &resolved {
            Resolved::Known { entry, target } => (
                clean_name(&entry.name),
                Transport::Http {
                    url: target.url.clone(),
                },
                target.publisher.clone(),
                resolved.verified(),
            ),
            Resolved::Remote { target } => (
                name_for_url(&target.url),
                Transport::Http {
                    url: target.url.clone(),
                },
                target.publisher.clone(),
                false,
            ),
            Resolved::Local { command } => {
                let program = &command.argv[0];
                let base = program.rsplit('/').next().unwrap_or(program);
                // `npx -y @scope/x-mcp` is named for its package, not npx.
                let named = if command.fetches_code {
                    command.argv[1..]
                        .iter()
                        .find(|a| !a.starts_with('-'))
                        .map(String::as_str)
                        .unwrap_or(base)
                } else {
                    base
                };
                let named = named.rsplit('/').next().unwrap_or(named);
                let named = named
                    .trim_start_matches("server-")
                    .trim_start_matches("mcp-server-")
                    .trim_end_matches("-mcp-server")
                    .trim_end_matches("-mcp")
                    .trim_end_matches(".py")
                    .trim_end_matches(".js");
                (
                    clean_name(named.split('@').next().unwrap_or(named)),
                    Transport::Stdio {
                        command: program.clone(),
                        args: command.argv[1..].to_vec(),
                        cwd: arg(args, "cwd").map(str::to_owned),
                    },
                    "local".to_owned(),
                    false,
                )
            }
            Resolved::Unknown { near } => {
                return Err(format!(
                    "mcp add: no known server is called {target:?}{}. Give its https URL or the command that runs it.",
                    if near.is_empty() {
                        String::new()
                    } else {
                        format!(" (close: {})", near.join(", "))
                    }
                ));
            }
        };
        let name = arg(args, "name").map(clean_name).unwrap_or(default_name);
        let replace = args
            .get("replace")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let mut secrets = Secrets::default();
        for (key, into) in [("headers", &mut secrets.headers), ("env", &mut secrets.env)] {
            if let Some(map) = args.get(key).and_then(Value::as_object) {
                for (k, v) in map {
                    let v = v
                        .as_str()
                        .ok_or(format!("mcp add: {key}.{k} must be text"))?;
                    into.insert(k.clone(), v.to_owned());
                }
            }
        }
        {
            let mut state = self.state();
            if let Some(old) = state.server(&name)
                && old.transport.as_ref() != Some(&transport)
                && !replace
            {
                return Err(format!(
                    "mcp add: a server {name} is added already ({}); pass a different `name`, or `replace`: true",
                    old.transport
                        .as_ref()
                        .map(Transport::label)
                        .unwrap_or_default()
                ));
            }
            state.servers.retain(|s| s.name != name);
            let mut secret_names: Vec<String> = secrets
                .headers
                .keys()
                .chain(secrets.env.keys())
                .cloned()
                .collect();
            secret_names.sort();
            state.servers.push(Server {
                name: name.clone(),
                transport: Some(transport.clone()),
                publisher,
                verified,
                added_ms: now_ms(),
                added_by: caller.label(),
                secret_names,
                state: "connecting".into(),
                ..Server::default()
            });
        }
        if !secrets.headers.is_empty() || !secrets.env.is_empty() || replace {
            self.inner.dir.save_secrets(&name, &secrets)?;
        }
        self.save();
        self.drop_live(&name);
        match self.connect(&name) {
            Ok(_) => Ok(format!("outcome: done. {}", self.summary(&name, true))),
            Err(ConnectError::Auth(header)) => self.sign_in(&name, &header),
            Err(ConnectError::Other(why)) => {
                self.set_state(&name, &format!("failed: {why}"));
                Err(format!(
                    "mcp add: {name} is saved but did not connect: {why}. Fix it and `add` again with `replace`: true, or `remove` it."
                ))
            }
        }
    }

    fn set_state(&self, name: &str, text: &str) {
        if let Some(s) = self.state().server_mut(name) {
            s.state = text.to_owned();
        }
        self.save();
    }

    /// One server's lines for `add` and `list`.
    fn summary(&self, name: &str, long: bool) -> String {
        let state = self.state();
        let Some(s) = state.server(name) else {
            return format!("no server {name}");
        };
        let caps = &s.capabilities;
        let mut can = Vec::new();
        if !caps["tasks"].is_null() || !caps["extensions"][client::TASKS_EXTENSION].is_null() {
            can.push("tasks");
        }
        if caps["resources"]["subscribe"] == json!(true) {
            can.push("resource subscriptions");
        }
        if !caps["resources"].is_null() {
            can.push("resources");
        }
        let names: Vec<&str> = s.tools.iter().filter_map(|t| t["name"].as_str()).collect();
        let mut out = format!(
            "{} ({}{}, {}): {} tool(s){}{}",
            s.name,
            s.transport
                .as_ref()
                .map(Transport::label)
                .unwrap_or_default(),
            if s.verified { ", verified" } else { "" },
            if s.state.is_empty() {
                "added"
            } else {
                s.state.as_str()
            },
            s.tools.len(),
            if s.prompts.is_empty() {
                String::new()
            } else {
                format!(", {} prompt(s)", s.prompts.len())
            },
            if can.is_empty() {
                String::new()
            } else {
                format!(", {}", can.join(", "))
            },
        );
        if long {
            out.push_str(&format!(
                "\nTools: {}{}",
                cut(&names.join(", "), 1500),
                if s.flagged.is_empty() {
                    String::new()
                } else {
                    format!("\nFlagged (description withheld, looks like instructions to the model): {}", s.flagged.join(", "))
                }
            ));
            out.push_str(&format!(
                "\nUse it in code mode: `mcp` action describe (server {0}) for the TypeScript API, then action run with code like `const r = await mcp.{0}.{1}({{...}}); console.log(r)`. Declarations are also in {2}.",
                s.name,
                names.first().copied().unwrap_or("tool"),
                self.inner.dir.api_path(&s.name).display()
            ));
        }
        out
    }

    fn list(&self) -> String {
        let names: Vec<String> = self
            .state()
            .servers
            .iter()
            .map(|s| s.name.clone())
            .collect();
        if names.is_empty() {
            return "outcome: noop. no MCP servers are added; add one with action add, target: a name, an https URL or a command".into();
        }
        let lines: Vec<String> = names
            .iter()
            .map(|n| {
                let live = self.inner.live.lock().unwrap().contains_key(n);
                format!(
                    "- {}{}",
                    self.summary(n, false),
                    if live { " [live]" } else { "" }
                )
            })
            .collect();
        format!(
            "outcome: done. {} MCP server(s):\n{}",
            names.len(),
            lines.join("\n")
        )
    }

    fn remove(&self, name: &str) -> Result<String, String> {
        let name = clean_name(name);
        let existed = {
            let mut state = self.state();
            let before = state.servers.len();
            state.servers.retain(|s| s.name != name);
            state.subscriptions.retain(|s| s.server != name);
            before != state.servers.len()
        };
        if !existed {
            return Err(format!("mcp remove: no server {name}"));
        }
        self.drop_live(&name);
        self.inner.dir.forget(&name);
        let skills = self.write_prompt_skills(&name, &[]);
        self.save();
        Ok(format!(
            "outcome: done. removed {name}: its secrets, subscriptions{} are gone",
            if skills > 0 { " and prompt skills" } else { "" }
        ))
    }

    fn drop_live(&self, name: &str) {
        if let Some(l) = self.inner.live.lock().unwrap().remove(name) {
            l.client.close();
        }
    }

    fn reap(&self) {
        let busy: HashSet<String> = {
            let s = self.state();
            s.subscriptions
                .iter()
                .map(|x| x.server.clone())
                .chain(
                    s.tasks
                        .iter()
                        .filter(|t| !t.ended())
                        .map(|t| t.server.clone()),
                )
                .collect()
        };
        let now = now_ms();
        let idle: Vec<String> = self
            .inner
            .live
            .lock()
            .unwrap()
            .iter()
            .filter(|(n, l)| {
                !busy.contains(*n)
                    && now.saturating_sub(l.last_used.load(Ordering::SeqCst)) > IDLE_CLOSE_MS
            })
            .map(|(n, _)| n.clone())
            .collect();
        for n in idle {
            self.drop_live(&n);
        }
    }

    // ---- connecting ----

    fn on_message_for(&self, name: &str) -> OnMessage {
        let weak: Weak<Inner> = Arc::downgrade(&self.inner);
        let name = name.to_owned();
        Arc::new(move |msg: Value| {
            if let Some(inner) = weak.upgrade() {
                McpHub { inner }.on_message(&name, msg);
            }
        })
    }

    fn headers_for(&self, name: &str) -> wire::Headers {
        let dir = self.inner.dir.clone();
        let name = name.to_owned();
        Arc::new(move || {
            let mut secrets = dir.secrets(&name);
            let mut out: Vec<(String, String)> = secrets.headers.clone().into_iter().collect();
            if let Some(tokens) = secrets.oauth.clone() {
                let mut access = tokens.access_token.clone();
                if tokens.expires_ms > 0
                    && tokens.expires_ms < now_ms() + 60_000
                    && tokens.refresh_token.is_some()
                    && let Ok(fresh) = oauth::refresh(&tokens)
                {
                    access = fresh.access_token.clone();
                    secrets.oauth = Some(fresh);
                    let _ = dir.save_secrets(&name, &secrets);
                }
                out.retain(|(k, _)| !k.eq_ignore_ascii_case("authorization"));
                out.push(("Authorization".into(), format!("Bearer {access}")));
            }
            out
        })
    }

    /// The live connection to `name`, connecting (and listing its tools)
    /// when there is none.
    fn connect(&self, name: &str) -> Result<Arc<Live>, ConnectError> {
        let gate = self
            .inner
            .connecting
            .lock()
            .unwrap()
            .entry(name.to_owned())
            .or_default()
            .clone();
        let _held = gate.lock().unwrap();
        let existing = self.inner.live.lock().unwrap().get(name).cloned();
        if let Some(l) = existing
            && l.client.wire.alive()
        {
            l.last_used.store(now_ms(), Ordering::SeqCst);
            return Ok(l);
        }
        self.drop_live(name);
        let server = self
            .state()
            .server(name)
            .cloned()
            .ok_or_else(|| ConnectError::Other(format!("no server {name}; add it first")))?;
        let transport = server
            .transport
            .clone()
            .ok_or_else(|| ConnectError::Other("no transport".into()))?;
        let secrets = self.inner.dir.secrets(name);
        let wire: Arc<dyn Wire> = match &transport {
            Transport::Http { url } => {
                let target = cmux_mcp_connect::target::check_url(url)
                    .map_err(|e| ConnectError::Other(e.to_string()))?;
                check_dns(&target).map_err(ConnectError::Other)?;
                Arc::new(HttpWire::new(
                    url,
                    self.headers_for(name),
                    self.on_message_for(name),
                ))
            }
            Transport::Stdio { command, args, cwd } => {
                let program = which(command, &*self.inner.env).ok_or_else(|| {
                    ConnectError::Other(format!("`{command}` is not installed on this machine"))
                })?;
                let mut env: Vec<(String, String)> = secrets.env.clone().into_iter().collect();
                // npx, uvx and friends find node and python on PATH.
                if let Some(dir) = program.parent() {
                    let path = (self.inner.env)("PATH").unwrap_or_default();
                    env.push((
                        "PATH".into(),
                        format!(
                            "{}:{path}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
                            dir.display()
                        ),
                    ));
                }
                Arc::new(
                    StdioWire::start(
                        &program.to_string_lossy(),
                        args,
                        &env,
                        cwd.as_deref(),
                        &self.inner.dir.log_path(name),
                        self.on_message_for(name),
                    )
                    .map_err(|e| ConnectError::Other(e.to_string()))?,
                )
            }
        };
        let client = Client::connect(wire)?;
        let tools = client.list_all("tools/list", "tools").unwrap_or_default();
        let prompts = if client.has(&["prompts"]) {
            client
                .list_all("prompts/list", "prompts")
                .unwrap_or_default()
        } else {
            Vec::new()
        };
        let live = Arc::new(Live {
            client,
            streams: Mutex::default(),
            last_used: AtomicU64::new(now_ms()),
        });
        self.store_lists(name, &live.client, tools, Some(prompts));
        self.inner
            .live
            .lock()
            .unwrap()
            .insert(name.to_owned(), live.clone());
        Ok(live)
    }

    /// Keeps a fresh tool (and prompt) list: screened, cached, declared.
    fn store_lists(
        &self,
        name: &str,
        client: &Client,
        tools: Vec<Value>,
        prompts: Option<Vec<Value>>,
    ) {
        let flagged_tools: Vec<String> = tools
            .iter()
            .filter(|t| flagged(t))
            .filter_map(|t| t["name"].as_str().map(str::to_owned))
            .collect();
        let mut write_prompts = None;
        {
            let mut state = self.state();
            if let Some(s) = state.server_mut(name) {
                s.tools = tools.clone();
                s.flagged = flagged_tools.clone();
                s.protocol = client.protocol.clone();
                s.capabilities = client.capabilities.clone();
                s.state = "connected".into();
                if let Some(p) = prompts {
                    s.prompts = p.clone();
                    write_prompts = Some(p);
                }
            }
        }
        self.save();
        let decl = codemode::declarations(name, &tools, &flagged_tools, None);
        let path = self.inner.dir.api_path(name);
        if let Some(d) = path.parent() {
            let _ = std::fs::create_dir_all(d);
        }
        let _ = std::fs::write(path, decl);
        if let Some(p) = write_prompts {
            self.write_prompt_skills(name, &p);
        }
    }

    // ---- sign-in ----

    fn sign_in(&self, name: &str, header: &str) -> Result<String, String> {
        let url = match self.state().server(name).and_then(|s| s.transport.clone()) {
            Some(Transport::Http { url }) => url,
            _ => {
                return Err(format!(
                    "mcp: {name} asked for a sign-in but is not a remote server"
                ));
            }
        };
        self.set_state(name, "needs sign-in");
        let started = oauth::start(&url, header).map_err(|why| {
            format!(
                "mcp add: {name} needs a sign-in, and its OAuth sign-in could not start: {why}. If the server takes a key, add it again with `headers`: {{\"Authorization\": \"Bearer <key>\"}} and `replace`: true."
            )
        })?;
        let authorize = started.authorize_url.clone();
        // Each sign-in has its own listener; the newest one the person finishes wins.
        self.inner
            .signing_in
            .lock()
            .unwrap()
            .insert(name.to_owned());
        let hub = self.clone();
        let name_owned = name.to_owned();
        let _ = std::thread::Builder::new().name("mcp-signin".into()).spawn(move || {
            let result = oauth::wait(started);
            hub.inner.signing_in.lock().unwrap().remove(&name_owned);
            match result {
                Ok(tokens) => {
                    let mut secrets = hub.inner.dir.secrets(&name_owned);
                    secrets.oauth = Some(tokens);
                    if let Err(e) = hub.inner.dir.save_secrets(&name_owned, &secrets) {
                        hub.note(format!("[mcp {name_owned}] the sign-in worked but its token could not be saved: {e}"));
                        return;
                    }
                    hub.drop_live(&name_owned);
                    match hub.connect(&name_owned) {
                        Ok(_) => hub.note(format!(
                            "[mcp {name_owned}] signed in and connected. {}\nGo on with what the person asked.",
                            hub.summary(&name_owned, true)
                        )),
                        Err(ConnectError::Auth(_)) => hub.note(format!(
                            "[mcp {name_owned}] the sign-in finished but the server still refuses the token (401). Try `mcp signin` once more."
                        )),
                        Err(ConnectError::Other(why)) => {
                            hub.note(format!("[mcp {name_owned}] signed in, but connecting failed: {why}"))
                        }
                    }
                }
                Err(why) => {
                    hub.set_state(&name_owned, "needs sign-in");
                    hub.note(format!("[mcp {name_owned}] the sign-in did not finish: {why}"))
                }
            }
        });
        Ok(format!(
            "outcome: waiting. {name} needs the person to sign in. Open this page for them (your auth-escalation flow: a cmux browser tab where they are signed in; they only approve):\n{authorize}\nThe hub waits for the approval off your turn (20 minutes) and wakes you with a note when {name} is connected. Do not poll."
        ))
    }

    fn reconnect_or_sign_in(&self, name: &str) -> Result<String, String> {
        let name = clean_name(name);
        self.drop_live(&name);
        match self.connect(&name) {
            Ok(_) => Ok(format!("outcome: done. {}", self.summary(&name, true))),
            Err(ConnectError::Auth(h)) => self.sign_in(&name, &h),
            Err(ConnectError::Other(why)) => Err(format!("mcp signin: {name}: {why}")),
        }
    }

    // ---- search and describe ----

    fn search(&self, query: &str, only: Option<&str>) -> String {
        let words: Vec<String> = query
            .to_lowercase()
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| w.len() > 1)
            .map(str::to_owned)
            .collect();
        let state = self.state();
        let mut hits: Vec<(usize, String)> = Vec::new();
        for s in state
            .servers
            .iter()
            .filter(|s| only.is_none_or(|o| clean_name(o) == s.name))
        {
            for t in &s.tools {
                let name = t["name"].as_str().unwrap_or("");
                let withheld = s.flagged.iter().any(|f| f == name);
                let desc = if withheld {
                    ""
                } else {
                    t["description"].as_str().unwrap_or("")
                };
                let (ln, ld) = (name.to_lowercase(), desc.to_lowercase());
                let score = if words.is_empty() {
                    1
                } else {
                    words
                        .iter()
                        .map(|w| {
                            3 * usize::from(ln.contains(w.as_str()))
                                + usize::from(ld.contains(w.as_str()))
                        })
                        .sum()
                };
                if score > 0 {
                    hits.push((
                        score,
                        format!(
                            "- mcp.{}.{}(args: {}) {}",
                            s.name,
                            codemode::prop(name),
                            codemode::one_line(&codemode::ts_type(&t["inputSchema"], 9), 200),
                            if withheld {
                                "[description withheld]".to_owned()
                            } else {
                                codemode::one_line(desc, 160)
                            }
                        ),
                    ));
                }
            }
            for p in &s.prompts {
                let name = p["name"].as_str().unwrap_or("");
                let desc = p["description"].as_str().unwrap_or("");
                let text = format!("{name} {desc}").to_lowercase();
                if words.is_empty() || words.iter().any(|w| text.contains(w.as_str())) {
                    hits.push((
                        1,
                        format!(
                            "- prompt {}/{}: {}",
                            s.name,
                            name,
                            codemode::one_line(desc, 160)
                        ),
                    ));
                }
            }
        }
        if hits.is_empty() {
            return format!(
                "outcome: noop. nothing matches {query:?} in {} server(s); try other words, or describe a server",
                state.servers.len()
            );
        }
        hits.sort_by_key(|h| std::cmp::Reverse(h.0));
        let n = hits.len();
        let shown: Vec<String> = hits.into_iter().take(20).map(|(_, l)| l).collect();
        format!(
            "outcome: done. {n} match(es){}:\n{}\nGet full types with describe (server, tool), then call them in run.",
            if n > 20 { ", best 20" } else { "" },
            shown.join("\n")
        )
    }

    fn describe(&self, server: &str, tool: Option<&str>) -> Result<String, String> {
        let name = clean_name(server);
        let cached = self
            .state()
            .server(&name)
            .cloned()
            .ok_or(format!("mcp describe: no server {name}"))?;
        if cached.tools.is_empty() {
            self.connect(&name)
                .map_err(|e| self.connect_error(&name, e))?;
        }
        let s = self.state().server(&name).cloned().unwrap_or(cached);
        if let Some(t) = tool
            && !s.tools.iter().any(|x| x["name"] == t)
        {
            return Err(format!("mcp describe: {name} has no tool {t}"));
        }
        Ok(format!(
            "{}\n// Each call returns structuredContent, else the text (parsed when it is JSON); an error result throws.\n// Use: action run, code: `const r = await mcp.{name}.<tool>({{...}}); console.log(r);`",
            codemode::declarations(&name, &s.tools, &s.flagged, tool)
        ))
    }

    fn connect_error(&self, name: &str, e: ConnectError) -> String {
        match e {
            ConnectError::Auth(_) => {
                self.set_state(name, "needs sign-in");
                format!(
                    "{name} needs the person to sign in again: use mcp action signin, server {name}"
                )
            }
            ConnectError::Other(why) => format!("{name} did not connect: {why}"),
        }
    }

    // ---- calls ----

    /// One `tools/call`, answering the CallToolResult. A task handle the
    /// server returns is waited for (up to `timeout`).
    pub fn call_tool(
        &self,
        server: &str,
        tool: &str,
        args: Value,
        timeout: Duration,
    ) -> Result<Value, String> {
        let name = clean_name(server);
        let args = if args.is_null() { json!({}) } else { args };
        let mut retried = false;
        loop {
            let live = self
                .connect(&name)
                .map_err(|e| self.connect_error(&name, e))?;
            live.last_used.store(now_ms(), Ordering::SeqCst);
            let required = self.task_support(&name, tool) == "required";
            let mut params = json!({"name": tool, "arguments": args});
            if required && live.client.era == Era::Session && live.client.does_tasks() {
                params["task"] = json!({"ttl": TASK_TTL_MS});
            }
            match live.client.request("tools/call", params, timeout) {
                Ok(result) => {
                    if let Some(handle) = client::task_handle(&result) {
                        return self.wait_task_inline(&live, &handle, timeout);
                    }
                    return Ok(result);
                }
                // The session ended or the process died: connect again, once.
                Err(ClientError::Wire(WireError::Gone)) if !retried => {
                    retried = true;
                    self.drop_live(&name);
                }
                Err(ClientError::Wire(WireError::Other(_)))
                    if !retried && !live.client.wire.alive() =>
                {
                    retried = true;
                    self.drop_live(&name);
                }
                Err(e) => return Err(self.connect_error(&name, ConnectError::from(e))),
            }
        }
    }

    fn task_support(&self, server: &str, tool: &str) -> String {
        self.state()
            .server(server)
            .and_then(|s| s.tools.iter().find(|t| t["name"] == tool).cloned())
            .and_then(|t| t["execution"]["taskSupport"].as_str().map(str::to_owned))
            .unwrap_or_else(|| "forbidden".into())
    }

    fn wait_task_inline(
        &self,
        live: &Live,
        handle: &Value,
        timeout: Duration,
    ) -> Result<Value, String> {
        let id = handle["taskId"]
            .as_str()
            .ok_or("the server's task has no taskId")?
            .to_owned();
        let deadline = std::time::Instant::now() + timeout;
        let mut status = handle.clone();
        loop {
            match status["status"].as_str().unwrap_or("working") {
                "completed" | "failed" | "cancelled" => {
                    return task_outcome(&live.client, &id, &status);
                }
                _ => {}
            }
            if std::time::Instant::now() > deadline {
                return Err(format!(
                    "task {id} still runs after {}s; start it with `task`: true to wait off the turn",
                    timeout.as_secs()
                ));
            }
            std::thread::sleep(poll_interval(&status));
            status = task_get(&live.client, &id).map_err(|e| e.to_string())?;
        }
    }

    fn call_action(&self, args: &Value, caller: &Caller) -> Result<String, String> {
        let server = arg(args, "server").ok_or("mcp call: name the `server`")?;
        let tool = arg(args, "tool").ok_or("mcp call: name the `tool`")?;
        let tool_args = args.get("args").cloned().unwrap_or(json!({}));
        let as_task = args.get("task").and_then(Value::as_bool).unwrap_or(false);
        if as_task {
            return self.start_task(
                server,
                tool,
                tool_args,
                arg(args, "note").unwrap_or(""),
                caller,
            );
        }
        let timeout = args
            .get("timeout_seconds")
            .and_then(Value::as_u64)
            .map(|s| Duration::from_secs(s.clamp(5, 600)))
            .unwrap_or(CALL_TIMEOUT);
        let result = self.call_tool(server, tool, tool_args, timeout)?;
        let text = codemode::result_text(&result);
        if result["isError"] == json!(true) {
            return Err(format!("{server}.{tool} failed: {}", codemode::cap(&text)));
        }
        Ok(codemode::cap(&text))
    }

    fn run_code(&self, args: &Value) -> Result<String, String> {
        let code = arg(args, "code").ok_or(
            "mcp run: give `code` (TypeScript/JavaScript; `await mcp.<server>.<tool>({...})`)",
        )?;
        let runtime = codemode::find_runtime(&*self.inner.env)
            .ok_or("mcp run: no JavaScript runtime (deno, node or bun) on this machine; use action call instead")?;
        let timeout = Duration::from_secs(
            args.get("timeout_seconds")
                .and_then(Value::as_u64)
                .unwrap_or(120)
                .clamp(5, 900),
        );
        let hub = self.clone();
        let call: codemode::CallFn = Arc::new(move |server: &str, tool: &str, a: Value| {
            if server == "$hub" {
                let mut a = a;
                a["action"] = json!(tool);
                return hub.handle(&a, &Caller::Chief).map(Value::String);
            }
            let result = hub.call_tool(server, tool, a, CALL_TIMEOUT)?;
            codemode::script_value(&result)
        });
        codemode::run(&runtime, code, &self.inner.dir.0.join("run"), timeout, call)
    }

    // ---- tasks ----

    fn start_task(
        &self,
        server: &str,
        tool: &str,
        args: Value,
        note: &str,
        caller: &Caller,
    ) -> Result<String, String> {
        let name = clean_name(server);
        let live = self
            .connect(&name)
            .map_err(|e| self.connect_error(&name, e))?;
        let support = self.task_support(&name, tool);
        let id = {
            let mut s = self.state();
            s.last_task += 1;
            format!("t{}", s.last_task)
        };
        let mut task = Task {
            id: id.clone(),
            server: name.clone(),
            tool: tool.to_owned(),
            remote: None,
            status: "working".into(),
            message: String::new(),
            note: note.to_owned(),
            by: caller.label(),
            started_ms: now_ms(),
            ended_ms: None,
            result: None,
        };
        let server_side = live.client.does_tasks()
            && (support != "forbidden" || live.client.era == Era::Stateless);
        if server_side {
            let mut params = json!({"name": tool, "arguments": args});
            if live.client.era == Era::Session {
                params["task"] = json!({"ttl": TASK_TTL_MS});
            }
            let result = live
                .client
                .request("tools/call", params, CALL_TIMEOUT)
                .map_err(|e| format!("mcp call {name}.{tool}: {e}"))?;
            match client::task_handle(&result) {
                Some(handle) => {
                    task.remote = handle["taskId"].as_str().map(str::to_owned);
                    task.status = handle["status"].as_str().unwrap_or("working").to_owned();
                    task.message = handle["statusMessage"].as_str().unwrap_or("").to_owned();
                    self.state().tasks.push(task);
                    self.save();
                    self.spawn_poller(id.clone());
                    return Ok(format!(
                        "outcome: started. task {id} runs on {name} (its task id {}). You wake once with its result when it ends; `task` {id} checks it now, op cancel stops it.",
                        handle["taskId"].as_str().unwrap_or("?")
                    ));
                }
                None => {
                    // The server answered at once.
                    let text = codemode::result_text(&result);
                    task.status = if result["isError"] == json!(true) {
                        "failed"
                    } else {
                        "completed"
                    }
                    .into();
                    task.ended_ms = Some(now_ms());
                    task.result = Some(cut(&text, 20_000));
                    self.state().tasks.push(task);
                    self.save();
                    return Ok(format!(
                        "outcome: done. {name}.{tool} finished at once (no task needed):\n{}",
                        codemode::cap(&text)
                    ));
                }
            }
        }
        self.state().tasks.push(task);
        self.save();
        let hub = self.clone();
        let tid = id.clone();
        let tool_owned = tool.to_owned();
        let _ = std::thread::Builder::new()
            .name("mcp-task".into())
            .spawn(move || {
                let outcome = hub.call_tool(&name, &tool_owned, args, Duration::from_secs(3600));
                let (status, text) = match outcome {
                    Ok(r) if r["isError"] == json!(true) => ("failed", codemode::result_text(&r)),
                    Ok(r) => ("completed", codemode::result_text(&r)),
                    Err(e) => ("failed", e),
                };
                hub.finish_task(&tid, status, &text);
            });
        Ok(format!(
            "outcome: started. task {id} runs {}.{} off your turn (the server has no MCP tasks, so the hub holds the call). You wake once with its result; `task` {id} checks it.",
            clean_name(server),
            tool
        ))
    }

    fn spawn_poller(&self, id: String) {
        let hub = self.clone();
        let _ = std::thread::Builder::new()
            .name("mcp-task-poll".into())
            .spawn(move || hub.poll_task(&id));
    }

    fn poll_task(&self, id: &str) {
        let mut failures = 0;
        let mut asked_input = false;
        loop {
            if self.inner.stopped.load(Ordering::SeqCst) {
                return;
            }
            let Some(task) = self.state().tasks.iter().find(|t| t.id == id).cloned() else {
                return;
            };
            if task.ended() {
                return;
            }
            let Some(remote) = task.remote.clone() else {
                return;
            };
            if now_ms().saturating_sub(task.started_ms) > TASK_TTL_MS * 4 {
                self.finish_task(id, "failed", "the task outlived its time to live");
                return;
            }
            let live = match self.connect(&task.server) {
                Ok(l) => l,
                Err(e) => {
                    failures += 1;
                    if failures > 8 {
                        let why = self.connect_error(&task.server, e);
                        self.finish_task(id, "failed", &format!("lost the server: {why}"));
                        return;
                    }
                    std::thread::sleep(Duration::from_secs(5 * failures));
                    continue;
                }
            };
            let status = match task_get(&live.client, &remote) {
                Ok(s) => {
                    failures = 0;
                    s
                }
                Err(e) => {
                    failures += 1;
                    if failures > 8 {
                        self.finish_task(
                            id,
                            "failed",
                            &format!("the server stopped answering about it: {e}"),
                        );
                        return;
                    }
                    std::thread::sleep(Duration::from_secs(3 * failures));
                    continue;
                }
            };
            let st = status["status"].as_str().unwrap_or("working").to_owned();
            if let Some(t) = self.state().tasks.iter_mut().find(|t| t.id == id) {
                t.status = st.clone();
                t.message = status["statusMessage"].as_str().unwrap_or("").to_owned();
            }
            match st.as_str() {
                "completed" | "failed" | "cancelled" => {
                    let text = match task_outcome(&live.client, &remote, &status) {
                        Ok(r) => codemode::result_text(&r),
                        Err(e) => e,
                    };
                    let word = if st == "completed" && text.starts_with("the tool failed") {
                        "failed"
                    } else {
                        st.as_str()
                    };
                    self.finish_task(id, word, &text);
                    return;
                }
                "input_required" if !asked_input => {
                    asked_input = true;
                    self.note(format!(
                        "[mcp task {id}] {}.{} needs input the hub cannot give yet: {}. Cancel it (task {id}, op cancel) or let it wait.",
                        task.server,
                        task.tool,
                        cut(&status.get("inputRequests").map(Value::to_string).unwrap_or_else(|| status["statusMessage"].to_string()), 600)
                    ));
                }
                _ => {}
            }
            std::thread::sleep(poll_interval(&status));
        }
    }

    fn finish_task(&self, id: &str, status: &str, text: &str) {
        let task = {
            let mut state = self.state();
            let Some(t) = state.tasks.iter_mut().find(|t| t.id == id) else {
                return;
            };
            if t.ended() {
                return;
            }
            t.status = status.to_owned();
            t.ended_ms = Some(now_ms());
            t.result = Some(cut(text, 20_000));
            let t = t.clone();
            state.trim_tasks();
            t
        };
        self.save();
        let took = human(task.ended_ms.unwrap_or(0).saturating_sub(task.started_ms));
        let mut note = format!(
            "[mcp task {}] {}.{} {} after {took} (started by {}){}",
            task.id,
            task.server,
            task.tool,
            status,
            task.by,
            if task.note.trim().is_empty() {
                String::new()
            } else {
                format!(": {}", task.note.trim())
            }
        );
        note.push_str(&format!(
            "\nResult:\n{}",
            cut(text.trim(), NOTE_RESULT_CHARS)
        ));
        if text.chars().count() > NOTE_RESULT_CHARS {
            note.push_str(&format!(
                "\n(The whole result: mcp action task, id {}.)",
                task.id
            ));
        }
        self.note(note);
    }

    fn tasks_list(&self) -> String {
        let state = self.state();
        if state.tasks.is_empty() {
            return "outcome: noop. no MCP tasks".into();
        }
        let now = now_ms();
        let lines: Vec<String> = state
            .tasks
            .iter()
            .map(|t| {
                format!(
                    "- {} {}.{}: {}{} ({} {}){}",
                    t.id,
                    t.server,
                    t.tool,
                    t.status,
                    if t.message.is_empty() {
                        String::new()
                    } else {
                        format!(", {}", cut(&t.message, 120))
                    },
                    if t.ended() { "took" } else { "for" },
                    human(t.ended_ms.unwrap_or(now).saturating_sub(t.started_ms)),
                    if t.note.is_empty() {
                        String::new()
                    } else {
                        format!(" [{}]", t.note)
                    }
                )
            })
            .collect();
        format!(
            "outcome: done. {} task(s):\n{}",
            lines.len(),
            lines.join("\n")
        )
    }

    fn task_action(&self, args: &Value) -> Result<String, String> {
        let id = arg(args, "id").ok_or("mcp task: give the task `id` (t<N>)")?;
        let op = arg(args, "op").unwrap_or("status");
        let task = self
            .state()
            .tasks
            .iter()
            .find(|t| t.id == id)
            .cloned()
            .ok_or(format!("mcp task: no task {id}"))?;
        match op {
            "cancel" => {
                if task.ended() {
                    return Ok(format!(
                        "outcome: noop. task {id} already ended ({})",
                        task.status
                    ));
                }
                if let Some(remote) = &task.remote {
                    let live = self
                        .connect(&task.server)
                        .map_err(|e| self.connect_error(&task.server, e))?;
                    live.client
                        .request(
                            "tasks/cancel",
                            json!({"taskId": remote}),
                            client::DEFAULT_TIMEOUT,
                        )
                        .map_err(|e| format!("mcp task cancel: {e}"))?;
                }
                self.finish_task(id, "cancelled", "cancelled by the Chief");
                Ok(format!("outcome: done. task {id} is cancelled"))
            }
            "wait" => {
                let secs = args
                    .get("wait_seconds")
                    .and_then(Value::as_u64)
                    .unwrap_or(60)
                    .clamp(1, 600);
                let deadline = std::time::Instant::now() + Duration::from_secs(secs);
                while std::time::Instant::now() < deadline {
                    if self.state().tasks.iter().any(|t| t.id == id && t.ended()) {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(250));
                }
                self.task_status(id)
            }
            _ => self.task_status(id),
        }
    }

    fn task_status(&self, id: &str) -> Result<String, String> {
        let t = self
            .state()
            .tasks
            .iter()
            .find(|t| t.id == id)
            .cloned()
            .ok_or(format!("no task {id}"))?;
        Ok(format!(
            "task {} {}.{}: {}{}{}",
            t.id,
            t.server,
            t.tool,
            t.status,
            if t.message.is_empty() {
                String::new()
            } else {
                format!(" ({})", t.message)
            },
            t.result
                .as_deref()
                .map(|r| format!("\nResult:\n{}", codemode::cap(r)))
                .unwrap_or_default()
        ))
    }

    // ---- events ----

    fn subscribe(&self, args: &Value, caller: &Caller) -> Result<String, String> {
        let name = clean_name(arg(args, "server").ok_or("mcp subscribe: name the `server`")?);
        let uri = arg(args, "uri").map(str::to_owned);
        let method = arg(args, "event").map(|e| {
            if e == "*" || e.starts_with("notifications/") {
                e.to_owned()
            } else {
                format!("notifications/{e}")
            }
        });
        if uri.is_none() && method.is_none() {
            return Err("mcp subscribe: give a resource `uri`, or an `event` (a notification method such as notifications/message, or *)".into());
        }
        let live = self
            .connect(&name)
            .map_err(|e| self.connect_error(&name, e))?;
        if uri.is_some()
            && !live.client.has(&["resources", "subscribe"])
            && live.client.era == Era::Session
        {
            return Err(format!(
                "mcp subscribe: {name} does not offer resource subscriptions (its capabilities lack resources.subscribe)"
            ));
        }
        let sub = {
            let mut s = self.state();
            s.last_subscription += 1;
            let sub = Subscription {
                id: format!("e{}", s.last_subscription),
                server: name.clone(),
                uri,
                method,
                note: arg(args, "note").unwrap_or("").to_owned(),
                by: caller.label(),
            };
            s.subscriptions.push(sub.clone());
            sub
        };
        self.save();
        if let Err(e) = self.arm(&live, &sub) {
            self.state().subscriptions.retain(|s| s.id != sub.id);
            self.save();
            return Err(format!("mcp subscribe: {e}"));
        }
        Ok(format!(
            "outcome: done. subscription {} on {name}: you wake with a note when {} (events within {}s come as one note; at most one note per {}s). unsubscribe {} ends it.",
            sub.id,
            match (&sub.uri, &sub.method) {
                (Some(u), _) => format!("{u} changes"),
                (None, Some(m)) if m == "*" => "the server sends any notification".into(),
                (None, Some(m)) => format!("the server sends {m}"),
                _ => String::new(),
            },
            EVENT_COALESCE.as_secs(),
            EVENT_MIN_GAP_MS / 1000,
            sub.id
        ))
    }

    fn arm_all(&self, name: &str) {
        let Ok(live) = self.connect(name) else { return };
        let subs: Vec<Subscription> = self
            .state()
            .subscriptions
            .iter()
            .filter(|s| s.server == name)
            .cloned()
            .collect();
        for s in subs {
            let _ = self.arm(&live, &s);
        }
    }

    /// Asks the server to push what `sub` needs, and keeps the stream open.
    fn arm(&self, live: &Arc<Live>, sub: &Subscription) -> Result<(), String> {
        let c = &live.client;
        match c.era {
            Era::Session => {
                if let Some(uri) = &sub.uri {
                    c.request(
                        "resources/subscribe",
                        json!({"uri": uri}),
                        client::DEFAULT_TIMEOUT,
                    )
                    .map_err(|e| e.to_string())?;
                }
                if sub
                    .method
                    .as_deref()
                    .is_some_and(|m| m == "notifications/message" || m == "*")
                    && c.has(&["logging"])
                {
                    let _ = c.request(
                        "logging/setLevel",
                        json!({"level": "info"}),
                        client::DEFAULT_TIMEOUT,
                    );
                }
                if !c.wire.is_stdio() {
                    self.keep_stream(live, sub.server.clone(), "get".into(), None);
                }
            }
            Era::Stateless => {
                let id = c.next_id();
                let mut filter = json!({"toolsListChanged": true, "promptsListChanged": true, "resourcesListChanged": true});
                if let Some(uri) = &sub.uri {
                    filter["resourceSubscriptions"] = json!([uri]);
                }
                let msg = c.message(id, "subscriptions/listen", json!({"notifications": filter}));
                if c.wire.is_stdio() {
                    c.wire.stream(Some(&msg)).map_err(|e| e.to_string())?;
                } else {
                    self.keep_stream(live, sub.server.clone(), sub.id.clone(), Some(msg));
                }
            }
        }
        Ok(())
    }

    /// Holds one HTTP push stream open (`key`: one GET per connection, or
    /// one `subscriptions/listen` per subscription), reopening it after a
    /// drop until the connection or the subscription is gone.
    fn keep_stream(&self, live: &Arc<Live>, server: String, key: String, open: Option<Value>) {
        if !live.streams.lock().unwrap().insert(key.clone()) {
            return;
        }
        let weak_live = Arc::downgrade(live);
        let hub = self.clone();
        let _ = std::thread::Builder::new()
            .name("mcp-stream".into())
            .spawn(move || {
                let mut backoff = 2;
                loop {
                    let Some(live) = weak_live.upgrade() else {
                        return;
                    };
                    if !live.client.wire.alive() || hub.inner.stopped.load(Ordering::SeqCst) {
                        return;
                    }
                    if key != "get" && !hub.state().subscriptions.iter().any(|s| s.id == key) {
                        live.streams.lock().unwrap().remove(&key);
                        return;
                    }
                    let wire = live.client.wire.clone();
                    drop(live);
                    match wire.stream(open.as_ref()) {
                        Err(WireError::Other(e)) if e.contains("no event stream") => return,
                        Err(WireError::Gone) => {
                            // A new session: connect again and re-arm.
                            hub.drop_live(&server);
                            if hub.connect(&server).is_ok() {
                                hub.arm_all(&server);
                            }
                            return;
                        }
                        _ => {}
                    }
                    std::thread::sleep(Duration::from_secs(backoff));
                    backoff = (backoff * 2).min(60);
                }
            });
    }

    fn unsubscribe(&self, which: &str) -> Result<String, String> {
        let gone: Vec<Subscription> = {
            let mut s = self.state();
            let gone: Vec<Subscription> = s
                .subscriptions
                .iter()
                .filter(|x| which == "all" || x.id == which)
                .cloned()
                .collect();
            s.subscriptions
                .retain(|x| !(which == "all" || x.id == which));
            gone
        };
        if gone.is_empty() {
            return Ok(format!("outcome: noop. no subscription {which}"));
        }
        self.save();
        for sub in &gone {
            let Some(uri) = &sub.uri else { continue };
            let still = self
                .state()
                .subscriptions
                .iter()
                .any(|x| x.server == sub.server && x.uri.as_ref() == Some(uri));
            if still {
                continue;
            }
            if let Some(live) = self.inner.live.lock().unwrap().get(&sub.server).cloned()
                && live.client.era == Era::Session
            {
                let _ = live.client.request(
                    "resources/unsubscribe",
                    json!({"uri": uri}),
                    client::DEFAULT_TIMEOUT,
                );
            }
        }
        Ok(format!(
            "outcome: done. ended {}",
            gone.iter()
                .map(|s| s.id.as_str())
                .collect::<Vec<_>>()
                .join(", ")
        ))
    }

    fn events_list(&self) -> String {
        let s = self.state();
        if s.subscriptions.is_empty() {
            return "outcome: noop. no event subscriptions".into();
        }
        let lines: Vec<String> = s
            .subscriptions
            .iter()
            .map(|x| {
                format!(
                    "- {} {}: {}{}",
                    x.id,
                    x.server,
                    x.uri.clone().or(x.method.clone()).unwrap_or_default(),
                    if x.note.is_empty() {
                        String::new()
                    } else {
                        format!(" [{}]", x.note)
                    }
                )
            })
            .collect();
        format!(
            "outcome: done. {} subscription(s):\n{}",
            lines.len(),
            lines.join("\n")
        )
    }

    /// A notification from `server`.
    fn on_message(&self, server: &str, msg: Value) {
        let method = msg["method"].as_str().unwrap_or("").to_owned();
        let params = &msg["params"];
        match method.as_str() {
            "notifications/tools/list_changed" | "notifications/prompts/list_changed" => {
                let hub = self.clone();
                let server = server.to_owned();
                let _ = std::thread::Builder::new()
                    .name("mcp-relist".into())
                    .spawn(move || {
                        let Some(live) = hub.inner.live.lock().unwrap().get(&server).cloned()
                        else {
                            return;
                        };
                        let tools = live
                            .client
                            .list_all("tools/list", "tools")
                            .unwrap_or_default();
                        let prompts = live.client.has(&["prompts"]).then(|| {
                            live.client
                                .list_all("prompts/list", "prompts")
                                .unwrap_or_default()
                        });
                        hub.store_lists(&server, &live.client, tools, prompts);
                    });
            }
            "notifications/tasks/status" | "notifications/tasks" => {
                let task = if params.get("task").is_some() {
                    &params["task"]
                } else {
                    params
                };
                if let Some(remote) = task["taskId"].as_str() {
                    let mut s = self.state();
                    if let Some(t) = s
                        .tasks
                        .iter_mut()
                        .find(|t| t.server == server && t.remote.as_deref() == Some(remote))
                        && let Some(m) = task["statusMessage"].as_str()
                    {
                        t.message = m.to_owned();
                    }
                }
            }
            "cmux/stream_closed" | "notifications/subscriptions/acknowledged" => return,
            _ => {}
        }
        let uri = params["uri"].as_str();
        let matching: Vec<Subscription> = self
            .state()
            .subscriptions
            .iter()
            .filter(|s| s.server == server)
            .filter(|s| match (&s.uri, &s.method) {
                (Some(u), _) => {
                    method == "notifications/resources/updated" && uri == Some(u.as_str())
                }
                (None, Some(m)) => m == "*" || *m == method,
                _ => false,
            })
            .cloned()
            .collect();
        for sub in matching {
            let detail = match (method.as_str(), uri) {
                ("notifications/resources/updated", Some(u)) => format!("{u} changed"),
                ("notifications/message", _) => format!(
                    "{} log: {}",
                    params["level"].as_str().unwrap_or("info"),
                    cut(
                        &params["data"]
                            .as_str()
                            .map(str::to_owned)
                            .unwrap_or_else(|| params["data"].to_string()),
                        300
                    )
                ),
                (m, _) => format!("{m} {}", cut(&strip_meta(params).to_string(), 300)),
            };
            self.queue_event(&sub, detail);
        }
    }

    fn queue_event(&self, sub: &Subscription, line: String) {
        let delay_ms = {
            let mut events = self.inner.events.lock().unwrap();
            let b = events.entry(sub.id.clone()).or_default();
            b.count += 1;
            if b.lines.len() < 10 && !b.lines.contains(&line) {
                b.lines.push(line);
            }
            if b.scheduled {
                return;
            }
            b.scheduled = true;
            let now = now_ms();
            (EVENT_COALESCE.as_millis() as u64)
                .max((b.last_fire_ms + EVENT_MIN_GAP_MS).saturating_sub(now))
        };
        let hub = self.clone();
        let id = sub.id.clone();
        let _ = std::thread::Builder::new()
            .name("mcp-event".into())
            .spawn(move || {
                std::thread::sleep(Duration::from_millis(delay_ms));
                hub.fire_event(&id);
            });
    }

    fn fire_event(&self, id: &str) {
        let (lines, count) = {
            let mut events = self.inner.events.lock().unwrap();
            let Some(b) = events.get_mut(id) else { return };
            b.scheduled = false;
            b.last_fire_ms = now_ms();
            (std::mem::take(&mut b.lines), std::mem::take(&mut b.count))
        };
        let Some(sub) = self
            .state()
            .subscriptions
            .iter()
            .find(|s| s.id == id)
            .cloned()
        else {
            return;
        };
        if lines.is_empty() {
            return;
        }
        let mut text = format!(
            "[mcp event {}] {}: {}{}",
            sub.id,
            sub.server,
            if sub.note.trim().is_empty() {
                "(no note)".into()
            } else {
                sub.note.trim().to_owned()
            },
            if count > 1 {
                format!(" ({count} events)")
            } else {
                String::new()
            }
        );
        for l in lines {
            text.push_str("\n  ");
            text.push_str(&l);
        }
        if let Some(uri) = &sub.uri {
            text.push_str(&format!(
                "\n(Read it: mcp action read, server {}, uri {uri}. Started by {}.)",
                sub.server, sub.by
            ));
        }
        self.note(text);
    }

    // ---- resources and prompts ----

    fn resources(&self, server: &str) -> Result<String, String> {
        let name = clean_name(server);
        let live = self
            .connect(&name)
            .map_err(|e| self.connect_error(&name, e))?;
        if !live.client.has(&["resources"]) {
            return Ok(format!("outcome: noop. {name} offers no resources"));
        }
        let list = live
            .client
            .list_all("resources/list", "resources")
            .map_err(|e| e.to_string())?;
        let templates = live
            .client
            .list_all("resources/templates/list", "resourceTemplates")
            .unwrap_or_default();
        let mut out: Vec<String> = list
            .iter()
            .take(50)
            .map(|r| {
                format!(
                    "- {} {}",
                    r["uri"].as_str().unwrap_or(""),
                    codemode::one_line(
                        r["name"]
                            .as_str()
                            .or(r["description"].as_str())
                            .unwrap_or(""),
                        120
                    )
                )
            })
            .collect();
        out.extend(templates.iter().take(20).map(|t| {
            format!(
                "- template {} {}",
                t["uriTemplate"].as_str().unwrap_or(""),
                codemode::one_line(t["name"].as_str().unwrap_or(""), 120)
            )
        }));
        Ok(format!(
            "outcome: done. {name}: {} resource(s), {} template(s){}:\n{}",
            list.len(),
            templates.len(),
            if live.client.has(&["resources", "subscribe"]) {
                ", subscribable"
            } else {
                ""
            },
            out.join("\n")
        ))
    }

    fn read(&self, server: &str, uri: &str) -> Result<String, String> {
        let name = clean_name(server);
        let live = self
            .connect(&name)
            .map_err(|e| self.connect_error(&name, e))?;
        let r = live
            .client
            .request("resources/read", json!({"uri": uri}), CALL_TIMEOUT)
            .map_err(|e| format!("mcp read: {e}"))?;
        let parts: Vec<String> = r["contents"]
            .as_array()
            .map(|c| {
                c.iter()
                    .map(|p| {
                        p["text"].as_str().map(str::to_owned).unwrap_or_else(|| {
                            format!(
                                "[{} bytes of {}]",
                                p["blob"].as_str().map_or(0, |b| b.len() * 3 / 4),
                                p["mimeType"].as_str().unwrap_or("binary")
                            )
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(codemode::cap(&parts.join("\n")))
    }

    fn prompts_list(&self, only: Option<&str>) -> String {
        let s = self.state();
        let lines: Vec<String> = s
            .servers
            .iter()
            .filter(|x| only.is_none_or(|o| clean_name(o) == x.name))
            .flat_map(|x| {
                x.prompts.iter().map(move |p| {
                    let args: Vec<String> = p["arguments"]
                        .as_array()
                        .map(|a| {
                            a.iter()
                                .map(|a| {
                                    format!(
                                        "{}{}",
                                        a["name"].as_str().unwrap_or(""),
                                        if a["required"] == json!(true) {
                                            ""
                                        } else {
                                            "?"
                                        }
                                    )
                                })
                                .collect()
                        })
                        .unwrap_or_default();
                    format!(
                        "- {}/{}({}): {}",
                        x.name,
                        p["name"].as_str().unwrap_or(""),
                        args.join(", "),
                        codemode::one_line(p["description"].as_str().unwrap_or(""), 160)
                    )
                })
            })
            .collect();
        if lines.is_empty() {
            return "outcome: noop. no server offers prompts".into();
        }
        format!(
            "outcome: done. {} prompt(s) (each is also a skill, mcp-<server>-<prompt>):\n{}",
            lines.len(),
            lines.join("\n")
        )
    }

    fn prompt(&self, args: &Value) -> Result<String, String> {
        let name = clean_name(arg(args, "server").ok_or("mcp prompt: name the `server`")?);
        let prompt = arg(args, "name").ok_or("mcp prompt: give the prompt `name`")?;
        let live = self
            .connect(&name)
            .map_err(|e| self.connect_error(&name, e))?;
        let mut pargs = serde_json::Map::new();
        if let Some(a) = args.get("args").and_then(Value::as_object) {
            for (k, v) in a {
                pargs.insert(
                    k.clone(),
                    Value::String(
                        v.as_str()
                            .map(str::to_owned)
                            .unwrap_or_else(|| v.to_string()),
                    ),
                );
            }
        }
        let r = live
            .client
            .request(
                "prompts/get",
                json!({"name": prompt, "arguments": pargs}),
                CALL_TIMEOUT,
            )
            .map_err(|e| format!("mcp prompt: {e}"))?;
        let msgs: Vec<String> = r["messages"]
            .as_array()
            .map(|m| {
                m.iter()
                    .map(|m| {
                        format!(
                            "[{}] {}",
                            m["role"].as_str().unwrap_or("user"),
                            codemode::result_text(&json!({"content": [m["content"].clone()]}))
                        )
                    })
                    .collect()
            })
            .unwrap_or_default();
        Ok(codemode::cap(&format!(
            "{}{}",
            r["description"]
                .as_str()
                .map(|d| format!("{d}\n"))
                .unwrap_or_default(),
            msgs.join("\n")
        )))
    }

    /// Writes one skill per MCP prompt of `server` into the Chief's skills
    /// folder (`mcp-<server>-<prompt>/SKILL.md`), so `/` and the skill list
    /// show them, and removes the ones that are gone. Answers how many.
    fn write_prompt_skills(&self, server: &str, prompts: &[Value]) -> usize {
        let Some(dir) = self.inner.skills.clone() else {
            return 0;
        };
        let marker = format!("mcp-server: {server}");
        let mut keep = HashSet::new();
        for p in prompts {
            let Some(pname) = p["name"].as_str() else {
                continue;
            };
            let slug: String = format!("mcp-{server}-{pname}")
                .to_ascii_lowercase()
                .chars()
                .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
                .collect();
            let withheld = flagged(p);
            let desc = if withheld {
                format!(
                    "The {pname} prompt of the {server} MCP server (description withheld: it looked like instructions)"
                )
            } else {
                codemode::one_line(p["description"].as_str().unwrap_or(pname), 300)
            };
            let args: Vec<String> = p["arguments"]
                .as_array()
                .map(|a| {
                    a.iter()
                        .map(|a| {
                            format!(
                                "- `{}`{}: {}",
                                a["name"].as_str().unwrap_or(""),
                                if a["required"] == json!(true) {
                                    " (required)"
                                } else {
                                    ""
                                },
                                if withheld {
                                    String::new()
                                } else {
                                    codemode::one_line(a["description"].as_str().unwrap_or(""), 200)
                                }
                            )
                        })
                        .collect()
                })
                .unwrap_or_default();
            let text = format!(
                "---\nname: {slug}\ndescription: {} (MCP prompt `{pname}` of the {server} server)\ncmux-managed: true\n{marker}\n---\n\n# {pname} ({server})\n\nThis skill is an MCP prompt of the `{server}` server, which the Chief added. Get its full text, filled in, with the `mcp` tool and follow it:\n\n```json\n{{\"action\": \"prompt\", \"server\": \"{server}\", \"name\": \"{pname}\", \"args\": {{}}}}\n```\n\n{}\n",
                desc.replace('\n', " "),
                if args.is_empty() {
                    "It takes no arguments.".to_owned()
                } else {
                    format!("Arguments:\n\n{}", args.join("\n"))
                }
            );
            let path = dir.join(&slug).join("SKILL.md");
            if let Some(d) = path.parent() {
                let _ = std::fs::create_dir_all(d);
            }
            if std::fs::read_to_string(&path).ok().as_deref() != Some(text.as_str()) {
                let _ = std::fs::write(&path, &text);
            }
            keep.insert(slug);
        }
        if let Ok(entries) = std::fs::read_dir(&dir) {
            for e in entries.flatten() {
                let slug = e.file_name().to_string_lossy().into_owned();
                if keep.contains(&slug) || !slug.starts_with("mcp-") {
                    continue;
                }
                let skill = e.path().join("SKILL.md");
                if std::fs::read_to_string(&skill).is_ok_and(|t| t.lines().any(|l| l == marker)) {
                    let _ = std::fs::remove_dir_all(e.path());
                }
            }
        }
        keep.len()
    }
}

/// `tasks/get`, answering the task (2025: the result is the task; some
/// servers wrap it in `task`).
fn task_get(client: &Client, id: &str) -> Result<Value, ClientError> {
    let r = client.request("tasks/get", json!({"taskId": id}), client::DEFAULT_TIMEOUT)?;
    Ok(
        if r.get("task").is_some_and(Value::is_object) && r.get("status").is_none() {
            let mut t = r["task"].clone();
            for k in ["result", "error"] {
                if let Some(v) = r.get(k) {
                    t[k] = v.clone();
                }
            }
            t
        } else {
            r
        },
    )
}

/// The final CallToolResult of an ended task: the 2026 `result` / `error`
/// carried by `tasks/get`, else 2025's `tasks/result`.
fn task_outcome(client: &Client, id: &str, status: &Value) -> Result<Value, String> {
    if let Some(r) = status.get("result").filter(|r| r.is_object()) {
        return Ok(r.clone());
    }
    if let Some(e) = status.get("error").filter(|e| !e.is_null()) {
        return Err(format!(
            "the tool failed: {}",
            e["message"]
                .as_str()
                .map(str::to_owned)
                .unwrap_or_else(|| e.to_string())
        ));
    }
    match status["status"].as_str() {
        Some("cancelled") => return Err("the task was cancelled".into()),
        Some("failed") if client.era == Era::Stateless => {
            return Err(format!(
                "the tool failed: {}",
                status["statusMessage"]
                    .as_str()
                    .unwrap_or("no reason given")
            ));
        }
        _ => {}
    }
    client
        .request("tasks/result", json!({"taskId": id}), CALL_TIMEOUT)
        .map_err(|e| format!("the tool failed: {e}"))
}

fn poll_interval(status: &Value) -> Duration {
    let ms = status["pollIntervalMs"]
        .as_u64()
        .or(status["pollInterval"].as_u64())
        .unwrap_or(2000);
    Duration::from_millis(ms.clamp(200, 30_000))
}

fn strip_meta(params: &Value) -> Value {
    let mut p = params.clone();
    if let Some(o) = p.as_object_mut() {
        o.remove("_meta");
    }
    p
}

/// Refuses a host name that resolves into private, link-local or metadata
/// ranges (DNS rebinding, threat T4), unless the URL is to this machine.
fn check_dns(target: &cmux_mcp_connect::target::RemoteTarget) -> Result<(), String> {
    if target.loopback {
        return Ok(());
    }
    use std::net::ToSocketAddrs;
    let host = target.host.trim_start_matches('[').trim_end_matches(']');
    let addrs = (host, 443)
        .to_socket_addrs()
        .map_err(|e| format!("{}: {e}", target.host))?;
    for a in addrs {
        cmux_mcp_connect::target::check_ip(a.ip())
            .map_err(|e| format!("{} resolves to {}: {e}", target.host, a.ip()))?;
    }
    Ok(())
}
