//! Chief fast evals (plans/cmux-next/agent-evals-DESIGN.md, "Chief fast
//! evals"): the real Chief prompt, tool list, memory and view, on the
//! Messages API, with every side effect stubbed. One process, no app, no
//! acpmux, no daemon: runs on any Linux or Mac box that reaches the model.
//!
//!   cargo run --example chief_eval -- [--cases DIR] [--only PREFIX] [--out DIR]
//!       [--jobs N] [--model M] [--effort E] [--judge-model M] [--compactor api|fake]
//!       [--repeat N] [--min-pass F] [--baseline SUMMARY_JSON_OR_DIR]
//!   chief_eval shim NAME ARGS...   (the stubs on a turn's PATH call this)
//!
//! What a turn sends is what a production Chief turn on a Claude harness
//! sends: `prompt::system_text` over the case's person profile, the view
//! and delta of `OptChat::turn_input` laid out by `prompt::input_layout`
//! (its three cache marks), and the `optchat` MCP tools of
//! `mcp::tools_granted` as `mcp__optchat__*`. Not sent: Claude Code's own
//! system prompt and built-in tools (bash stands in for them).

use std::collections::BTreeMap;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use optchat_chief::prompt::{CacheTtl, Tools, input_layout, system_text};
use optchat_host::{
    AnthropicModel, CompactModel, CompactRequest, Config, Followup, Kind, ModelError, OptChat,
    Reply, SystemClock, cap_tool_result,
};
use regex::Regex;
use serde::Deserialize;
use serde_json::{Value, json};

const MCP_PREFIX: &str = "mcp__optchat__";
const SHIMS: &[&str] = &[
    "cmux", "chief", "gh", "cmux-ci", "stripe", "git", "ssh", "open",
];
const MAX_STEPS: usize = 24;
/// The first system block of every Claude Code request: production turns run
/// in Claude Code, and the team gateways take only Claude Code traffic.
const CLAUDE_CODE: &str = "You are Claude Code, Anthropic's official CLI for Claude.";

/// The Messages API, shaped as Claude Code sends it (user agent), not
/// streamed: the eval needs the whole message and its usage.
struct Model {
    agent: ureq::Agent,
    url: String,
    key: String,
}

impl Model {
    fn new(base_url: &str, key: String) -> Model {
        Model {
            agent: ureq::AgentBuilder::new()
                .timeout_connect(Duration::from_secs(20))
                .timeout(Duration::from_secs(600))
                .build(),
            url: format!("{}/v1/messages", base_url.trim_end_matches('/')),
            key,
        }
    }

    /// One call; Err((message, retry)).
    fn send(&self, body: &Value) -> Result<Value, (String, bool)> {
        let mut body = body.clone();
        body["stream"] = json!(false);
        match self
            .agent
            .post(&self.url)
            .set("x-api-key", &self.key)
            .set("anthropic-version", "2023-06-01")
            .set("user-agent", "claude-cli/2.1.300 (external, cli)")
            .send_json(&body)
        {
            Ok(r) => r.into_json::<Value>().map_err(|e| (e.to_string(), true)),
            Err(ureq::Error::Status(code, r)) => {
                let text = r.into_string().unwrap_or_default();
                Err((
                    format!("HTTP {code}: {}", &text[..text.len().min(300)]),
                    code == 429 || code >= 500,
                ))
            }
            Err(e) => Err((e.to_string(), true)),
        }
    }
}

// ------------------------------------------------------------------ cases

#[derive(Deserialize, Clone, Default)]
#[serde(default)]
struct Case {
    id: String,
    group: String,
    owner: String,
    about: String,
    /// The person's profile (person.md); default `evals/person.md`.
    person: Option<String>,
    history: Vec<Item>,
    stubs: Vec<Stub>,
    files: BTreeMap<String, String>,
    /// This Chief reads every message of its group chats (OPTCHAT_GROUP_WAKE
    /// every): the system prompt gets the brain's Channels paragraph.
    channels: bool,
    /// false: the first turn starts while the compactor still works on the
    /// history (a Chief whose summaries lag, as the Cloud Chief's did).
    settle: Option<bool>,
    turns: Vec<Turn>,
}

#[derive(Deserialize, Clone, Default)]
#[serde(default)]
struct Item {
    kind: String,
    text: String,
    /// Group chat: the conversation title and author, labelled as the brain
    /// labels side messages: `[in conv <id> "<title>" from person "<name>"]`.
    conv: Option<String>,
    author: Option<String>,
    author_kind: Option<String>,
}

#[derive(Deserialize, Clone, Default)]
#[serde(default)]
struct Turn {
    #[serde(flatten)]
    item: Item,
    /// More messages delivered in the same turn (after `item`).
    also: Vec<Item>,
    /// Per-turn state after the delta (`Subagents at work now: a12.`).
    tail: Option<String>,
    checks: Vec<Check>,
}

#[derive(Deserialize, serde::Serialize, Clone, Default)]
#[serde(default)]
struct Stub {
    cmd: String,
    #[serde(rename = "match")]
    pattern: String,
    stdout: String,
    exit: i32,
}

#[derive(Deserialize, Clone, Default, serde::Serialize)]
#[serde(default)]
struct Check {
    #[serde(rename = "type")]
    kind: String,
    re: Option<String>,
    cmd: Option<String>,
    #[serde(rename = "match")]
    pattern: Option<String>,
    n: Option<usize>,
    path: Option<String>,
    rubric: Option<String>,
}

// ------------------------------------------------------------------ shims

/// The shim side: log the call, answer from the first matching stub.
fn shim(name: &str, args: &[String]) -> ! {
    let dir = PathBuf::from(std::env::var("CHIEF_EVAL_DIR").expect("CHIEF_EVAL_DIR"));
    let argv = args.join(" ");
    let stubs: Vec<Stub> =
        serde_json::from_str(&std::fs::read_to_string(dir.join("stubs.json")).unwrap_or_default())
            .unwrap_or_default();
    let hit = stubs
        .iter()
        .find(|s| s.cmd == name && (s.pattern.is_empty() || argv.contains(&s.pattern)));
    let mut log = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("calls.jsonl"))
        .unwrap();
    writeln!(log, "{}", json!({"cmd": name, "argv": argv})).unwrap();
    match hit {
        Some(s) => {
            print!("{}", s.stdout);
            std::process::exit(s.exit)
        }
        None => std::process::exit(0),
    }
}

// ------------------------------------------------------------------ compactor

/// Offline compactor: the step's last 200 characters on one line.
struct FakeCompactor;

impl CompactModel for FakeCompactor {
    fn call(&self, request: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        let flat: String = request
            .step
            .split_whitespace()
            .collect::<Vec<_>>()
            .join(" ");
        let start = flat.char_indices().rev().nth(199).map_or(0, |(i, _)| i);
        Ok(Reply::text(flat[start..].to_owned()))
    }
}

/// The production compactor's request (`AnthropicModel::body`, the Chief's
/// own system text as its prompt), sent Claude Code shaped.
struct ApiCompactor {
    inner: AnthropicModel,
    model: Model,
}

impl CompactModel for ApiCompactor {
    fn call(&self, request: &CompactRequest, followups: &[Followup]) -> Result<Reply, ModelError> {
        let mut body = self.inner.body(request, followups);
        let mut system = vec![json!({"type": "text", "text": CLAUDE_CODE})];
        system.extend(body["system"].as_array().cloned().unwrap_or_default());
        body["system"] = Value::Array(system);
        let v = self
            .model
            .send(&body)
            .map_err(|(e, _)| ModelError::new(e))?;
        if v["stop_reason"] == "max_tokens" || v["stop_reason"] == "refusal" {
            return Err(ModelError::new(format!("stop {}", v["stop_reason"])));
        }
        let text: String = v["content"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|b| b["type"] == "text")
            .filter_map(|b| b["text"].as_str())
            .collect();
        Ok(Reply {
            text,
            content: v["content"].clone(),
        })
    }
}

// ------------------------------------------------------------------ run state

#[derive(Clone)]
struct Opts {
    model: String,
    effort: String,
    judge_model: String,
    compactor: String,
    base_url: String,
    key: String,
    evals_dir: PathBuf,
    /// The reply ledger as the brain had it before 2026-10-26 (`--ledger
    /// pre`): a tapback answers nothing and stop is never refused.
    ledger_pre: bool,
}

#[derive(Default, Clone, serde::Serialize)]
struct Call {
    cmd: String,
    argv: String,
}

#[derive(Default, Clone, serde::Serialize)]
struct TurnResult {
    reply: String,
    posted: Vec<String>,
    calls: Vec<Call>,
    checks: Vec<Value>,
    pass: bool,
    error: Option<String>,
    wall_ms: u64,
    first_ms: u64,
    requests: usize,
    input: u64,
    output: u64,
    cache_read: u64,
    cache_write: u64,
    first_cache_read: u64,
    unsummarized: usize,
    view_bytes: usize,
    ended_by_tool: bool,
    #[serde(skip)]
    unanswered: Option<(u64, String)>,
    /// `[no reply]` retry turns the reply ledger started after this turn.
    retry_turns: u32,
}

fn label(item: &Item) -> String {
    match (&item.conv, &item.author) {
        (Some(title), author) => {
            let id = format!("conv_{}", short_hash(title));
            match author {
                Some(name) => format!(
                    "[in conv {id} \"{title}\" from {} \"{name}\"] {}",
                    item.author_kind.as_deref().unwrap_or("person"),
                    item.text
                ),
                None => format!("[in conv {id} \"{title}\"] {}", item.text),
            }
        }
        _ => item.text.clone(),
    }
}

fn short_hash(s: &str) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in s.bytes() {
        h = (h ^ b as u64).wrapping_mul(0x100000001b3);
    }
    format!("{:08x}", h as u32)
}

fn kind_of(k: &str) -> Kind {
    match k {
        "" | "work" => Kind::User,
        other => Kind::parse(other).unwrap_or_else(|| panic!("unknown kind {other}")),
    }
}

/// The optchat MCP tools as Claude Code shows them to the model.
fn tool_list() -> Value {
    let mut tools = vec![json!({"type": "bash_20250124", "name": "bash"})];
    for t in optchat_chief::mcp::tools_granted(false, &optchat_chief::chief_profile::Grant::all())
        .as_array()
        .unwrap()
    {
        tools.push(json!({
            "name": format!("{MCP_PREFIX}{}", t["name"].as_str().unwrap()),
            "description": t["description"],
            "input_schema": t["inputSchema"],
        }));
    }
    Value::Array(tools)
}

struct CaseRun<'a> {
    case: &'a Case,
    opts: &'a Opts,
    dir: PathBuf,
    chat: Arc<OptChat>,
    system: String,
    model: Model,
    spawned: Mutex<u32>,
    /// The subagents this run spawned (id, title), for `control status`.
    running: Mutex<Vec<(String, String)>>,
    frozen: Mutex<Option<optchat_core::Frozen>>,
    /// The running turn's tail, and whether stop or sleep ended it.
    tail: Mutex<String>,
    ended: Mutex<bool>,
    /// The running turn's person message waits for an answer (the reply
    /// ledger, brain/reply_ledger.rs): its line id and preview.
    open: Mutex<Option<(u64, String)>>,
    /// The conversation as the transcript tool shows it: (author, text).
    transcript: Mutex<Vec<(String, String)>>,
}

impl CaseRun<'_> {
    fn bash(&self, command: &str) -> (String, bool) {
        let bin = self.dir.join("bin");
        let out_path = self.dir.join("bash.out");
        let file = std::fs::File::create(&out_path).unwrap();
        let child = std::process::Command::new("bash")
            .arg("-c")
            .arg(command)
            .current_dir(self.dir.join("home"))
            .env_clear()
            .env(
                "PATH",
                format!("{}:/usr/local/bin:/usr/bin:/bin", bin.display()),
            )
            .env("HOME", self.dir.join("home"))
            .env("CHIEF_EVAL_DIR", &self.dir)
            .env("TERM", "dumb")
            .stdin(std::process::Stdio::null())
            .stdout(file.try_clone().unwrap())
            .stderr(file)
            .spawn();
        let mut child = match child {
            Ok(c) => c,
            Err(e) => return (format!("bash failed: {e}"), true),
        };
        let deadline = Instant::now() + Duration::from_secs(30);
        let status = loop {
            if let Ok(Some(s)) = child.try_wait() {
                break Some(s);
            }
            if Instant::now() > deadline {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            std::thread::sleep(Duration::from_millis(20));
        };
        let text =
            String::from_utf8_lossy(&std::fs::read(&out_path).unwrap_or_default()).into_owned();
        match status {
            Some(s) => (text, !s.success()),
            None => (format!("{text}\n(timed out after 30 s)"), true),
        }
    }

    fn log_call(&self, cmd: &str, argv: &str) {
        let mut f = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(self.dir.join("calls.jsonl"))
            .unwrap();
        writeln!(f, "{}", json!({"cmd": cmd, "argv": argv})).unwrap();
    }

    /// An `optchat` MCP tool: the memory tools answer from the real memory,
    /// every other one from the case's stubs or a default like the brain's.
    fn mcp(&self, name: &str, input: &Value, posted: &mut Vec<String>) -> (String, bool) {
        let argv = input.to_string();
        self.log_call(name, &argv);
        if let Some(s) = self
            .case
            .stubs
            .iter()
            .find(|s| s.cmd == name && (s.pattern.is_empty() || argv.contains(&s.pattern)))
        {
            if matches!(name, "send" | "reply") {
                posted.push(input["text"].as_str().unwrap_or("").to_owned());
                *self.open.lock().unwrap() = None;
            }
            return (s.stdout.clone(), s.exit != 0);
        }
        let n = |k: &str| input[k].as_u64();
        match name {
            // The memory tools parse as production does (tools::Call).
            "zoom" | "date" => match optchat_chief::tools::Call::parse(name, input) {
                Ok(optchat_chief::tools::Call::Zoom { id, n }) => match self.chat.zoom(id, n) {
                    Ok(t) => (t, false),
                    Err(e) => (format!("{e:?}"), true),
                },
                Ok(optchat_chief::tools::Call::Date { id }) => (
                    self.chat
                        .date(id)
                        .unwrap_or_else(|| "no such message".into()),
                    false,
                ),
                Ok(_) => ("no subagent by that id".into(), true),
                Err(e) => (e, true),
            },
            // The conversation's last messages (person and Chief), as
            // brain/transcript.rs renders them: header, then indented text.
            "transcript" => {
                let n = n("n").unwrap_or(20) as usize;
                let msgs = self.transcript.lock().unwrap();
                let start = msgs.len().saturating_sub(n);
                let out: Vec<String> = msgs[start..]
                    .iter()
                    .enumerate()
                    .map(|(i, (who, text))| {
                        let body: Vec<String> = text.lines().map(|l| format!("  {l}")).collect();
                        format!(
                            "#{} 2026-10-25T21:{:02}:00Z {who}\n{}",
                            start + i + 1,
                            (start + i) % 60,
                            body.join("\n")
                        )
                    })
                    .collect();
                (out.join("\n"), false)
            }
            "spawn" => {
                let mut out = Vec::new();
                let cwd = input["cwd"].as_str().unwrap_or("/home/person/work");
                for task in input["tasks"].as_array().cloned().unwrap_or_default() {
                    let mut k = self.spawned.lock().unwrap();
                    *k += 1;
                    let id = format!("a{}", 900 + *k);
                    let task = task.as_str().unwrap_or("");
                    let title = task
                        .lines()
                        .find_map(|l| l.strip_prefix("Title:"))
                        .map(str::trim)
                        .unwrap_or_else(|| task.lines().next().unwrap_or("Task"));
                    let ws = format!(
                        "ws_{}{}{}{}",
                        short_hash(&id),
                        short_hash(title),
                        short_hash(cwd),
                        short_hash(&format!("{id}{title}"))
                    );
                    self.running
                        .lock()
                        .unwrap()
                        .push((id.clone(), title.to_owned()));
                    out.push(format!(
                        "{id} spawned in {cwd}, workspace \"{title}\" ({ws})"
                    ));
                }
                (out.join("\n"), false)
            }
            "send" | "reply" => {
                posted.push(input["text"].as_str().unwrap_or("").to_owned());
                *self.open.lock().unwrap() = None;
                match n("reply_to").or(n("id")) {
                    Some(id) => (
                        format!("outcome: done. sent in the thread of message {id}"),
                        false,
                    ),
                    None => ("outcome: done. sent".into(), false),
                }
            }
            "tell" => (
                format!(
                    "outcome: done. sent to {}; read between tool calls or after its turn",
                    input["id"].as_str().unwrap_or("?")
                ),
                false,
            ),
            "react" => {
                let mut open = self.open.lock().unwrap();
                if !self.opts.ledger_pre
                    && open.as_ref().is_some_and(|(id, _)| Some(*id) == n("id"))
                {
                    *open = None;
                }
                ("outcome: done. reacted".into(), false)
            }
            // As the real tool: the line goes into the person's profile.
            "remember" => {
                let p = self.dir.join("home/optchat/person.md");
                let mut text = std::fs::read_to_string(&p).unwrap_or_default();
                text.push_str(&format!("\n- {}\n", input["text"].as_str().unwrap_or("")));
                let _ = std::fs::write(&p, text);
                ("outcome: done. remembered".into(), false)
            }
            // The subagents this run started are running (none: the old answer).
            "control" => {
                let running = self.running.lock().unwrap();
                if running.is_empty() {
                    ("outcome: done. No subagents in the last 2 h.".into(), false)
                } else {
                    let lines: Vec<String> = running
                        .iter()
                        .map(|(id, title)| format!("- {id} [running] {title}: working"))
                        .collect();
                    (format!("outcome: done.\n{}", lines.join("\n")), false)
                }
            }
            "sleep" | "stop" if !self.opts.ledger_pre && self.open.lock().unwrap().is_some() => {
                let (id, preview) = self.open.lock().unwrap().clone().unwrap();
                (
                    format!(
                        "{name}: refused, the user's message has no reply yet: line {id} \"{preview}\". Reply first in words (send, reply, or your final text), or react when it only acknowledges; then {name}."
                    ),
                    true,
                )
            }
            "sleep" => {
                *self.ended.lock().unwrap() = true;
                (
                    "outcome: done. waking later; the turn ends now".into(),
                    false,
                )
            }
            "stop" => {
                *self.ended.lock().unwrap() = true;
                (
                    "outcome: done. the turn ends now; nothing more is posted".into(),
                    false,
                )
            }
            "version" => (
                "cmux 0.64.0-nightly.1234 (cli is the app's own); engine claude-opus-5-5".into(),
                false,
            ),
            _ => ("outcome: done.".into(), false),
        }
    }

    fn run_turn(&self, turn: &Turn) -> TurnResult {
        let mut r = TurnResult::default();
        let calls_before = read_calls(&self.dir).len();
        *self.tail.lock().unwrap() = turn.tail.clone().unwrap_or_default();
        *self.ended.lock().unwrap() = false;
        let wake = Instant::now();
        // As the brain does: log the new messages, then take the turn input.
        let first_new = self
            .chat
            .append(kind_of(&turn.item.kind), &label(&turn.item))
            .unwrap();
        for item in &turn.also {
            self.chat.append(kind_of(&item.kind), &label(item)).unwrap();
        }
        // A person's message of the Chief conversation (not a group chat,
        // a report or a note) joins the reply ledger.
        let person = matches!(turn.item.kind.as_str(), "" | "user")
            && turn.item.conv.is_none()
            && !turn.item.text.starts_with('[');
        *self.open.lock().unwrap() = person.then(|| {
            (
                first_new,
                turn.item.text.chars().take(120).collect::<String>(),
            )
        });
        let frozen = self.frozen.lock().unwrap().clone();
        let (input, delta_end) = self.chat.turn_input(frozen.as_ref(), first_new);
        *self.frozen.lock().unwrap() = Some(input.frozen.clone());
        // As turns.rs: the previous request's end gets a mark when the view stayed.
        let prev_end = (!input.rerendered)
            .then(|| {
                input
                    .frozen
                    .cuts
                    .iter()
                    .rev()
                    .find(|c| **c < delta_end)
                    .copied()
            })
            .flatten()
            .and_then(|end| optchat_chief::prompt::block_ending_at(&input.delta, end));
        r.unsummarized = input.view.matches(optchat_core::PLACEHOLDER).count()
            + input
                .delta
                .iter()
                .map(|d| d.matches(optchat_core::PLACEHOLDER).count())
                .sum::<usize>();
        r.view_bytes = input.view.len();
        let layout = input_layout(
            &self.system,
            &input.view,
            &input.delta,
            prev_end,
            &[],
            turn.tail.as_deref().unwrap_or(""),
            Some(CacheTtl::FiveMinutes),
        );
        let mut messages = vec![json!({"role": "user", "content": layout.blocks})];
        let tools = tool_list();
        let mut posted = Vec::new();
        let mut last_text = String::new();
        for step in 0..MAX_STEPS {
            let body = json!({
                "model": self.opts.model,
                "max_tokens": 32000,
                "stream": true,
                "system": [{"type": "text", "text": CLAUDE_CODE}, {"type": "text", "text": self.system, "cache_control": CacheTtl::FiveMinutes.cache_control()}],
                "tools": tools,
                "messages": messages,
                "output_config": {"effort": self.opts.effort},
            });
            let message = match send_retry(&self.model, &body) {
                Ok(m) => m,
                Err(e) => {
                    r.error = Some(e);
                    break;
                }
            };
            r.requests += 1;
            let u = &message["usage"];
            let g = |k: &str| u[k].as_u64().unwrap_or(0);
            r.input += g("input_tokens");
            r.output += g("output_tokens");
            r.cache_read += g("cache_read_input_tokens");
            r.cache_write += g("cache_creation_input_tokens");
            if step == 0 {
                r.first_ms = wake.elapsed().as_millis() as u64;
                r.first_cache_read = g("cache_read_input_tokens");
            }
            let content = message["content"].as_array().cloned().unwrap_or_default();
            let mut results = Vec::new();
            for block in &content {
                match block["type"].as_str() {
                    Some("text") => {
                        let t = block["text"].as_str().unwrap_or("").trim();
                        if !t.is_empty() {
                            let _ = self.chat.append(Kind::Talk, t);
                            last_text = t.to_owned();
                        }
                    }
                    Some("tool_use") => {
                        let name = block["name"].as_str().unwrap_or("");
                        let input = &block["input"];
                        let _ = self.chat.append(Kind::Tool, &format!("{name} {input}"));
                        let (text, err) = if name == "bash" {
                            if input["restart"].as_bool() == Some(true) {
                                ("restarted".into(), false)
                            } else {
                                self.bash(input["command"].as_str().unwrap_or(""))
                            }
                        } else if let Some(tool) = name.strip_prefix(MCP_PREFIX) {
                            self.mcp(tool, input, &mut posted)
                        } else {
                            (format!("unknown tool {name}"), true)
                        };
                        let mut text = cap_tool_result(&text).into_owned();
                        if text.trim().is_empty() {
                            text = if err {
                                "(failed, no output)".into()
                            } else {
                                "(no output)".into()
                            };
                        }
                        let _ = self.chat.append(
                            Kind::Echo,
                            &if err {
                                format!("error: {text}")
                            } else {
                                text.clone()
                            },
                        );
                        let mut res = json!({"type": "tool_result", "tool_use_id": block["id"], "content": text});
                        if err {
                            res["is_error"] = json!(true);
                        }
                        results.push(res);
                    }
                    _ => {}
                }
            }
            messages.push(json!({"role": "assistant", "content": content}));
            // stop and sleep end the turn (brain/wakes.rs): nothing more is
            // generated, and text after the last send is dropped.
            if *self.ended.lock().unwrap() {
                r.ended_by_tool = true;
                break;
            }
            if message["stop_reason"] == "tool_use" && !results.is_empty() {
                messages.push(json!({"role": "user", "content": results}));
                continue;
            }
            break;
        }
        r.wall_ms = wake.elapsed().as_millis() as u64;
        r.reply = last_text.clone();
        if !r.ended_by_tool && !last_text.is_empty() && last_text.trim() != "NO_REPLY" {
            posted.push(last_text);
            *self.open.lock().unwrap() = None;
        }
        r.unanswered = self.open.lock().unwrap().clone();
        {
            let mut t = self.transcript.lock().unwrap();
            t.push((
                turn.item.author.clone().unwrap_or_else(|| "you".into()),
                turn.item.text.clone(),
            ));
            for p in &posted {
                t.push(("Chief (me)".into(), p.clone()));
            }
        }
        r.posted = posted;
        r.calls = read_calls(&self.dir)
            .into_iter()
            .skip(calls_before)
            .collect();
        r
    }
}

fn send_retry(model: &Model, body: &Value) -> Result<Value, String> {
    let mut wait = Duration::from_secs(2);
    for attempt in 0..5 {
        match model.send(body) {
            Ok(m) => return Ok(m),
            Err((_, true)) if attempt < 4 => {
                std::thread::sleep(wait);
                wait *= 2;
            }
            Err((e, _)) => return Err(e),
        }
    }
    unreachable!()
}

fn read_calls(dir: &Path) -> Vec<Call> {
    std::fs::read_to_string(dir.join("calls.jsonl"))
        .unwrap_or_default()
        .lines()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .map(|v| Call {
            cmd: v["cmd"].as_str().unwrap_or("").into(),
            argv: v["argv"].as_str().unwrap_or("").into(),
        })
        .collect()
}

// ------------------------------------------------------------------ checks

/// The posted text with every Markdown link `[text](target)` replaced by
/// `LINK`, and code fences dropped: what is left must hold no raw id.
fn unlinked(text: &str) -> String {
    let link = Regex::new(r"\[[^\]\n]*\]\([^)\s]*\)").unwrap();
    link.replace_all(text, "LINK").into_owned()
}

/// Raw ids, shas, URLs and paths outside links (the link rule).
pub fn raw_ids(text: &str) -> Vec<String> {
    let rest = unlinked(text);
    let pats = [
        r"\b(?:ws|tab|pane|grp|term|conv)_[0-9a-zA-Z]{6,}",
        r"(?:cmux|https?|file)://\S+",
        r"(?:^|[\s(`])(/(?:Users|home|tmp|private|var)/[^\s`)]+)",
        r"\b[0-9a-f]{7,40}\b",
        r"(?:^|[\s(])#\d{3,}\b",
    ];
    let mut out = Vec::new();
    for p in pats {
        for m in Regex::new(p).unwrap().find_iter(&rest) {
            let s = m.as_str().trim();
            // A sha needs a letter and a digit (not a plain number or word).
            if p.contains("0-9a-f]{7") {
                let has_digit = s.chars().any(|c| c.is_ascii_digit());
                let has_alpha = s.chars().any(|c| c.is_ascii_alphabetic());
                if !(has_digit && has_alpha) {
                    continue;
                }
            }
            out.push(s.to_owned());
        }
    }
    out
}

fn grade(run: &CaseRun, turn: &Turn, r: &mut TurnResult, history: &str) {
    let all = r.posted.join("\n\n");
    let mut pass = r.error.is_none();
    if let Some(e) = &r.error {
        r.checks
            .push(json!({"type": "turn", "pass": false, "why": e}));
    }
    for c in &turn.checks {
        let (ok, why): (bool, String) = match c.kind.as_str() {
            "reply_matches" | "reply_not_matches" => {
                let re = Regex::new(c.re.as_deref().unwrap_or("")).expect("bad re");
                let found = re.find(&all).map(|m| m.as_str().to_owned());
                if c.kind == "reply_matches" {
                    (found.is_some(), "no match".into())
                } else {
                    (found.is_none(), format!("matched {found:?}"))
                }
            }
            "no_raw_ids" => {
                let raw = raw_ids(&all);
                (raw.is_empty(), format!("raw: {raw:?}"))
            }
            "posted" => (!r.posted.is_empty(), "nothing posted".into()),
            "silent" => (r.posted.is_empty(), "posted something".into()),
            "called" | "not_called" => {
                let hit = r.calls.iter().any(|k| {
                    c.cmd.as_deref().is_none_or(|cmd| k.cmd == cmd)
                        && c.pattern.as_deref().is_none_or(|p| k.argv.contains(p))
                        && c.re
                            .as_deref()
                            .is_none_or(|re| Regex::new(re).unwrap().is_match(&k.argv))
                });
                if c.kind == "called" {
                    (hit, "not called".into())
                } else {
                    (!hit, "called".into())
                }
            }
            "max_calls" => {
                let n = r
                    .calls
                    .iter()
                    .filter(|k| c.cmd.as_deref().is_none_or(|cmd| k.cmd == cmd))
                    .count();
                (n <= c.n.unwrap_or(0), format!("{n} calls"))
            }
            "max_words" => {
                let n = all.split_whitespace().count();
                (n <= c.n.unwrap_or(80), format!("{n} words"))
            }
            "no_question" => {
                let q = all.lines().filter(|l| l.trim_end().ends_with('?')).count();
                (q == 0, format!("{q} question lines"))
            }
            "file_contains" => {
                let path = run.dir.join("home").join(c.path.as_deref().unwrap_or(""));
                let text = std::fs::read_to_string(&path).unwrap_or_default();
                let re = Regex::new(c.re.as_deref().unwrap_or("")).unwrap();
                (re.is_match(&text), format!("{} lacks it", path.display()))
            }
            "judge" => judge(run, c.rubric.as_deref().unwrap_or(""), history, turn, r),
            other => (false, format!("unknown check {other}")),
        };
        pass &= ok;
        r.checks
            .push(json!({"type": c.kind, "pass": ok, "why": if ok { String::new() } else { why }}));
    }
    r.pass = pass;
}

fn judge(
    run: &CaseRun,
    rubric: &str,
    history: &str,
    turn: &Turn,
    r: &TurnResult,
) -> (bool, String) {
    let calls: Vec<String> = r
        .calls
        .iter()
        .map(|c| format!("{} {}", c.cmd, c.argv))
        .collect();
    let prompt = format!(
        "You grade one turn of an AI assistant (\"Chief\") that works for one person.\n\
Rubric: {rubric}\n\n<history>\n{history}\n</history>\n\n<new_message>\n{}\n</new_message>\n\n\
<tool_calls>\n{}\n</tool_calls>\n\n<posted_replies>\n{}\n</posted_replies>\n\n\
Answer with exactly one line: PASS or FAIL, a colon, and one short reason.",
        label(&turn.item),
        calls.join("\n"),
        r.posted.join("\n---\n")
    );
    let body = json!({
        "model": run.opts.judge_model, "max_tokens": 400,
        "system": [{"type": "text", "text": CLAUDE_CODE}],
        "messages": [{"role": "user", "content": prompt}],
    });
    // An empty or malformed verdict is asked again once.
    let mut last = String::new();
    for _ in 0..2 {
        match send_retry(&run.model, &body) {
            Ok(m) => {
                let text: String = m["content"]
                    .as_array()
                    .into_iter()
                    .flatten()
                    .filter_map(|b| b["text"].as_str())
                    .collect();
                let t = text.trim().to_owned();
                if t.starts_with("PASS") || t.starts_with("FAIL") {
                    return (t.starts_with("PASS"), t);
                }
                last = format!("judge gave no verdict: {t:?}");
            }
            Err(e) => last = format!("judge failed: {e}"),
        }
    }
    (false, last)
}

// ------------------------------------------------------------------ driver

fn run_case(case: &Case, opts: &Opts, root: &Path) -> Value {
    let dir = root.join(&case.id);
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(dir.join("bin")).unwrap();
    std::fs::create_dir_all(dir.join("home")).unwrap();
    let exe = std::env::current_exe().unwrap();
    let shim_names: std::collections::BTreeSet<&str> = SHIMS
        .iter()
        .copied()
        .chain(case.stubs.iter().map(|s| s.cmd.as_str()))
        .collect();
    for name in shim_names {
        let p = dir.join("bin").join(name);
        std::fs::write(
            &p,
            format!("#!/bin/sh\nexec '{}' shim {name} \"$@\"\n", exe.display()),
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&p, std::fs::Permissions::from_mode(0o755)).unwrap();
    }
    std::fs::write(
        dir.join("stubs.json"),
        serde_json::to_string(&case.stubs).unwrap(),
    )
    .unwrap();
    for (rel, text) in &case.files {
        let p = dir.join("home").join(rel);
        std::fs::create_dir_all(p.parent().unwrap()).unwrap();
        std::fs::write(p, text).unwrap();
    }
    let person = case.person.clone().unwrap_or_else(|| {
        std::fs::read_to_string(opts.evals_dir.join("person.md")).unwrap_or_default()
    });
    let profile_path = dir.join("home/optchat/person.md");
    std::fs::create_dir_all(profile_path.parent().unwrap()).unwrap();
    if !profile_path.exists() {
        std::fs::write(&profile_path, &person).unwrap();
    }
    let instructions = optchat_chief::prompt::chief_instructions(
        &profile_path,
        &dir.join("home/optchat/instructions.md"),
    );
    let channels = case
        .channels
        .then(|| {
            optchat_chief::membership::Membership {
                participant: "chief_eval".into(),
                owner: cmux_chief::rules::USER_LOCAL.into(),
                group_wake: cmux_chief::rules::GroupWake::Every,
                local_side: true,
            }
            .instructions()
        })
        .flatten();
    let instructions = match (instructions, channels) {
        (Some(base), Some(ch)) => Some(format!("{base}\n\n{ch}")),
        (base, ch) => base.or(ch),
    };
    let system = system_text(instructions.as_deref(), &Tools::Mcp);
    let config = Config {
        agent: optchat_chief::prompt::AGENT.to_owned(),
        prompt: optchat_host::CompactPrompt::Custom(system.clone()),
        reporter: Arc::new(|_| {}),
        base_url: opts.base_url.clone(),
        api_key: opts.key.clone(),
        ..Config::default()
    };
    let compactor: Arc<dyn CompactModel> = match opts.compactor.as_str() {
        "fake" => Arc::new(FakeCompactor),
        _ => Arc::new(ApiCompactor {
            inner: AnthropicModel::new(&config),
            model: Model::new(&opts.base_url, opts.key.clone()),
        }),
    };
    // The memory takes a lock socket in its directory: a short path under
    // /tmp keeps it inside SUN_LEN whatever --out is (a675); the case
    // directory links to it.
    let chat_dir = PathBuf::from(format!(
        "/tmp/ce-{}-{}",
        std::process::id(),
        short_hash(&dir.display().to_string())
    ));
    let _ = std::fs::remove_dir_all(&chat_dir);
    std::fs::create_dir_all(&chat_dir).unwrap();
    let _ = std::os::unix::fs::symlink(&chat_dir, dir.join("chat"));
    let chat =
        Arc::new(OptChat::open_with(&chat_dir, config, compactor, Arc::new(SystemClock)).unwrap());
    let mut history = String::new();
    for item in &case.history {
        let text = label(item);
        chat.append(kind_of(&item.kind), &text).unwrap();
        history.push_str(&format!("{}: {}\n", item.kind, text));
    }
    let settle = Instant::now();
    if case.settle != Some(false) {
        chat.wait_idle(None, Some(Duration::from_secs(120)));
    }
    let settle_ms = settle.elapsed().as_millis() as u64;
    let run = CaseRun {
        case,
        opts,
        dir: dir.clone(),
        chat: chat.clone(),
        system,
        model: Model::new(&opts.base_url, opts.key.clone()),
        spawned: Mutex::new(0),
        running: Mutex::new(Vec::new()),
        frozen: Mutex::new(None),
        tail: Mutex::new(String::new()),
        ended: Mutex::new(false),
        open: Mutex::new(None),
        transcript: Mutex::new(
            case.history
                .iter()
                .filter_map(|i| match i.kind.as_str() {
                    "user" | "work" | "" => Some((
                        i.author.clone().unwrap_or_else(|| "you".into()),
                        i.text.clone(),
                    )),
                    "talk" => Some(("Chief (me)".into(), i.text.clone())),
                    _ => None,
                })
                .collect(),
        ),
    };
    let mut turns = Vec::new();
    let mut pass = true;
    for turn in &case.turns {
        let mut r = run.run_turn(turn);
        // The reply ledger: a person message left unanswered gets a retry
        // turn on the brain's `[no reply]` note (reply_ledger.rs nudge_text).
        if let Some((id, preview)) = r.unanswered.clone() {
            let nudge = Turn {
                item: Item {
                    kind: "user".into(),
                    text: format!(
                        "[no reply] These messages of the user got no reply:\n- line {id} \"{preview}\" (the turn ended without a reply; retry 1 of 3)\nReply to each now, in words (send, reply, or your final text). NO_REPLY and a stop with nothing sent are not allowed for a person's message in this chat. If you cannot do what it asks, say so and why."
                    ),
                    ..Item::default()
                },
                tail: turn.tail.clone(),
                ..Turn::default()
            };
            let again = run.run_turn(&nudge);
            r.retry_turns += 1;
            r.posted.extend(again.posted);
            r.calls.extend(again.calls);
            // The brain waits 5 s (REPLY_RETRY_WAITS[0]) before the retry.
            r.wall_ms += 5_000 + again.wall_ms;
            r.requests += again.requests;
            r.input += again.input;
            r.output += again.output;
            r.cache_read += again.cache_read;
            r.cache_write += again.cache_write;
            r.error = r.error.or(again.error);
        }
        grade(&run, turn, &mut r, &history);
        history.push_str(&format!("user: {}\n", label(&turn.item)));
        for p in &r.posted {
            history.push_str(&format!("chief: {p}\n"));
        }
        pass &= r.pass;
        turns.push(serde_json::to_value(&r).unwrap());
        chat.wait_idle(None, Some(Duration::from_secs(60)));
    }
    json!({"id": case.id, "group": case.group, "owner": case.owner, "about": case.about,
           "pass": pass, "settle_ms": settle_ms, "turns": turns})
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("shim") {
        shim(&args[1], &args[2..]);
    }
    // One short call: does the model route answer? (CI skips the model
    // cases, with a warning, when it does not.)
    if args.first().map(String::as_str) == Some("preflight") {
        let config = Config::default();
        let body = json!({"model": "claude-haiku-5-5", "max_tokens": 8,
            "system": [{"type": "text", "text": CLAUDE_CODE}],
            "messages": [{"role": "user", "content": "Say ok."}]});
        let mut model = Model::new(&config.base_url, config.api_key.clone());
        model.agent = ureq::AgentBuilder::new()
            .timeout_connect(Duration::from_secs(5))
            .timeout(Duration::from_secs(30))
            .build();
        match model.send(&body) {
            Ok(_) => std::process::exit(0),
            Err((e, _)) => {
                eprintln!("preflight: {}: {e}", config.base_url);
                std::process::exit(1)
            }
        }
    }
    let flag = |name: &str| {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1).cloned())
    };
    let here = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("evals");
    let cases_dir = flag("--cases")
        .map(PathBuf::from)
        .unwrap_or(here.join("cases"));
    let only = flag("--only").unwrap_or_default();
    let out = flag("--out").map(PathBuf::from).unwrap_or_else(|| {
        std::env::temp_dir().join(format!("chief-evals-{}", std::process::id()))
    });
    let jobs: usize = flag("--jobs").and_then(|j| j.parse().ok()).unwrap_or(16);
    let config = Config::default();
    let opts = Opts {
        model: flag("--model").unwrap_or_else(|| "claude-opus-5-5".into()),
        effort: flag("--effort").unwrap_or_else(|| "medium".into()),
        judge_model: flag("--judge-model").unwrap_or_else(|| "claude-sonnet-5".into()),
        compactor: flag("--compactor").unwrap_or_else(|| "api".into()),
        base_url: config.base_url.clone(),
        key: config.api_key.clone(),
        evals_dir: here.clone(),
        ledger_pre: flag("--ledger").as_deref() == Some("pre"),
    };
    let mut cases: Vec<Case> = Vec::new();
    let mut paths: Vec<PathBuf> = std::fs::read_dir(&cases_dir)
        .expect("cases dir")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .collect();
    paths.sort();
    for p in paths {
        let mut c: Case = serde_json::from_str(&std::fs::read_to_string(&p).unwrap())
            .unwrap_or_else(|e| panic!("{}: {e}", p.display()));
        if c.id.is_empty() {
            c.id = p.file_stem().unwrap().to_string_lossy().into_owned();
        }
        if c.group.is_empty() {
            c.group = c.id.split('-').next().unwrap_or("").into();
        }
        if c.id.starts_with(&only) {
            let repeat: usize = flag("--repeat").and_then(|r| r.parse().ok()).unwrap_or(1);
            for k in 0..repeat {
                let mut c = c.clone();
                if repeat > 1 {
                    c.id = format!("{}#{k}", c.id);
                }
                cases.push(c);
            }
        }
    }
    std::fs::create_dir_all(&out).unwrap();
    let began = Instant::now();
    let queue = Arc::new(Mutex::new(
        cases.clone().into_iter().enumerate().collect::<Vec<_>>(),
    ));
    let results = Arc::new(Mutex::new(Vec::<(usize, Value)>::new()));
    std::thread::scope(|s| {
        for _ in 0..jobs.max(1) {
            let (queue, results, opts, out) = (queue.clone(), results.clone(), &opts, &out);
            s.spawn(move || {
                loop {
                    let Some((i, case)) = queue.lock().unwrap().pop() else { break };
                    let row = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                        run_case(&case, opts, out)
                    }))
                    .unwrap_or_else(|_| json!({"id": case.id, "group": case.group, "pass": false, "error": "harness panic"}));
                    let ok = if row["pass"] == true { "PASS" } else { "FAIL" };
                    eprintln!("{ok} {}", case.id);
                    results.lock().unwrap().push((i, row));
                }
            });
        }
    });
    let mut rows = results.lock().unwrap().clone();
    rows.sort_by_key(|(i, _)| *i);
    let rows: Vec<Value> = rows.into_iter().map(|(_, r)| r).collect();
    let wall = began.elapsed().as_secs_f64();
    let mut f = std::fs::File::create(out.join("rows.jsonl")).unwrap();
    for r in &rows {
        writeln!(f, "{r}").unwrap();
    }
    let summary = summarize(&rows, wall, &opts);
    std::fs::write(
        out.join("summary.json"),
        serde_json::to_string_pretty(&summary).unwrap(),
    )
    .unwrap();
    println!("{}", table(&rows, &summary));
    println!("\n{}", group_table(&summary));
    // Against a baseline: an earlier run's summary.json (or its directory).
    // Report only; the gate below stays the pass fraction.
    if let Some(path) = flag("--baseline").map(PathBuf::from) {
        let file = if path.is_dir() {
            path.join("summary.json")
        } else {
            path
        };
        match std::fs::read_to_string(&file)
            .map_err(|e| e.to_string())
            .and_then(|t| serde_json::from_str::<Value>(&t).map_err(|e| e.to_string()))
        {
            Ok(base) => {
                let d = baseline_diff(&summary, &base);
                let md = diff_markdown(&d, &file.display().to_string());
                std::fs::write(
                    out.join("diff.json"),
                    serde_json::to_string_pretty(&d).unwrap(),
                )
                .unwrap();
                std::fs::write(out.join("diff.md"), &md).unwrap();
                println!("\n{md}");
            }
            Err(e) => eprintln!("baseline {}: {e}", file.display()),
        }
    }
    println!("artifacts: {}", out.display());
    // The gate: every case passes, or with --min-pass F at least that
    // fraction (model cases are sampled: one run of a 90% case fails 1 in 10).
    let passed = rows.iter().filter(|r| r["pass"] == true).count() as f64;
    let floor: f64 = flag("--min-pass")
        .and_then(|f| f.parse().ok())
        .unwrap_or(1.0);
    if passed < floor * rows.len() as f64 {
        eprintln!("pass rate {passed}/{} is under {floor}", rows.len());
        std::process::exit(1);
    }
}

fn pct(v: &mut [u64], p: f64) -> u64 {
    if v.is_empty() {
        return 0;
    }
    v.sort();
    v[((v.len() as f64 - 1.0) * p).round() as usize]
}

fn summarize(rows: &[Value], wall: f64, opts: &Opts) -> Value {
    let turns: Vec<&Value> = rows
        .iter()
        .flat_map(|r| r["turns"].as_array().into_iter().flatten())
        .collect();
    let col = |k: &str| -> Vec<u64> { turns.iter().map(|t| t[k].as_u64().unwrap_or(0)).collect() };
    let sum = |k: &str| col(k).iter().sum::<u64>();
    let (read, write, input) = (sum("cache_read"), sum("cache_write"), sum("input"));
    let cases = case_counts(rows);
    let mut groups: BTreeMap<String, (u32, u32)> = BTreeMap::new();
    for (group, p, n) in cases.values() {
        let g = groups.entry(group.clone()).or_default();
        g.0 += p;
        g.1 += n;
    }
    json!({
        "model": opts.model, "effort": opts.effort, "judge": opts.judge_model,
        "cases": rows.len(), "passed": rows.iter().filter(|r| r["pass"] == true).count(),
        "wall_s": (wall * 10.0).round() / 10.0,
        "turns": turns.len(),
        "turn_ms_p50": pct(&mut col("wall_ms"), 0.5), "turn_ms_p90": pct(&mut col("wall_ms"), 0.9),
        "first_request_ms_p50": pct(&mut col("first_ms"), 0.5),
        "requests_per_turn": (sum("requests") as f64 / turns.len().max(1) as f64 * 10.0).round() / 10.0,
        "output_tokens_per_turn": sum("output") / turns.len().max(1) as u64,
        "input_tokens_per_turn": (input + read + write) / turns.len().max(1) as u64,
        "cache_hit": if input + read + write > 0 { ((read as f64 / (input + read + write) as f64) * 1000.0).round() / 1000.0 } else { 0.0 },
        "unsummarized_max": col("unsummarized").into_iter().max().unwrap_or(0),
        "retry_turns": sum("retry_turns"),
        "tokens_per_turn": (input + read + write + sum("output")) / turns.len().max(1) as u64,
        "groups": groups.iter().map(|(k, (p, n))| (k.clone(), json!(format!("{p}/{n}")))).collect::<serde_json::Map<_, _>>(),
        "group_pass_rate": groups.iter().map(|(k, (p, n))| (k.clone(), json!(rate(*p, *n)))).collect::<serde_json::Map<_, _>>(),
        // Per case (repeats folded into one id): what --baseline diffs.
        "case_results": cases.iter().map(|(id, (g, p, n))| (id.clone(), json!({"group": g, "passed": p, "runs": n}))).collect::<serde_json::Map<_, _>>(),
    })
}

fn rate(p: u32, n: u32) -> f64 {
    if n == 0 {
        0.0
    } else {
        (f64::from(p) / f64::from(n) * 1000.0).round() / 1000.0
    }
}

/// Case id (a `--repeat` suffix `#k` dropped) -> (group, passed, runs).
fn case_counts(rows: &[Value]) -> BTreeMap<String, (String, u32, u32)> {
    let mut cases: BTreeMap<String, (String, u32, u32)> = BTreeMap::new();
    for r in rows {
        let id = r["id"].as_str().unwrap_or("");
        let id = id.split_once('#').map_or(id, |(base, _)| base);
        let c = cases
            .entry(id.into())
            .or_insert_with(|| (r["group"].as_str().unwrap_or("").into(), 0, 0));
        c.1 += u32::from(r["pass"] == true);
        c.2 += 1;
    }
    cases
}

/// Group -> (passed, runs) of a summary.json. Summaries written before
/// `case_results` existed still carry `groups` as "p/n".
fn summary_groups(s: &Value) -> BTreeMap<String, (u32, u32)> {
    let mut groups: BTreeMap<String, (u32, u32)> = BTreeMap::new();
    if let Some(cases) = s["case_results"].as_object() {
        for c in cases.values() {
            let g = groups
                .entry(c["group"].as_str().unwrap_or("").into())
                .or_default();
            g.0 += c["passed"].as_u64().unwrap_or(0) as u32;
            g.1 += c["runs"].as_u64().unwrap_or(0) as u32;
        }
        return groups;
    }
    for (k, v) in s["groups"].as_object().into_iter().flatten() {
        let mut it = v
            .as_str()
            .unwrap_or("")
            .split('/')
            .map(|x| x.parse().unwrap_or(0));
        groups.insert(k.clone(), (it.next().unwrap_or(0), it.next().unwrap_or(0)));
    }
    groups
}

/// This run against a baseline summary: pass rate per group before and
/// after, the total over the groups both runs have (over the cases both
/// have when both carry `case_results`), and the cases whose pass rate went
/// down or up.
/// A group only the baseline ran is named in `groups_not_run`; a case only
/// one side ran is `added` or, within a group this run has, `removed`.
fn baseline_diff(now: &Value, base: &Value) -> Value {
    // With per-case results on both sides, the groups and the total compare
    // only the cases both runs have (an `--only` run, or new cases, keep it
    // like for like); `added`, `regressed` and the rest use every case.
    let (mut now_common, mut common) = (now.clone(), base.clone());
    if let (Some(n), Some(b)) = (
        now["case_results"].as_object(),
        base["case_results"].as_object(),
    ) {
        if let Some(m) = now_common["case_results"].as_object_mut() {
            m.retain(|id, _| b.contains_key(id));
        }
        if let Some(m) = common["case_results"].as_object_mut() {
            m.retain(|id, _| n.contains_key(id));
        }
    }
    let (gn, gb) = (summary_groups(&now_common), summary_groups(&common));
    let side = |g: Option<&(u32, u32)>| {
        g.map_or(
            Value::Null,
            |(p, n)| json!({"passed": p, "runs": n, "rate": rate(*p, *n)}),
        )
    };
    let delta = |a: &(u32, u32), b: &(u32, u32)| {
        ((rate(b.0, b.1) - rate(a.0, a.1)) * 1000.0).round() / 1000.0
    };
    let mut groups = serde_json::Map::new();
    let (mut tb, mut tn) = ((0, 0), (0, 0));
    let all_now = summary_groups(now);
    for (name, all_b) in &all_now {
        // A group with no shared case (also one whose cases moved to
        // another group) shows all its cases, as new.
        let (a, b) = match (gb.get(name), gn.get(name)) {
            (Some(a), Some(b)) => (Some(a), b),
            _ => (None, all_b),
        };
        if let Some(a) = a {
            tb = (tb.0 + a.0, tb.1 + a.1);
            tn = (tn.0 + b.0, tn.1 + b.1);
        }
        groups.insert(
            name.clone(),
            json!({"baseline": side(a), "now": side(Some(b)),
                   "delta": a.map_or(Value::Null, |a| json!(delta(a, b)))}),
        );
    }
    let all_base = summary_groups(base);
    let not_run: Vec<&String> = all_base
        .keys()
        .filter(|g| !all_now.contains_key(*g))
        .collect();
    let cases = |s: &Value| -> BTreeMap<String, (String, f64)> {
        s["case_results"]
            .as_object()
            .into_iter()
            .flatten()
            .map(|(id, c)| {
                let (p, n) = (
                    c["passed"].as_u64().unwrap_or(0),
                    c["runs"].as_u64().unwrap_or(0),
                );
                let group = c["group"].as_str().unwrap_or("").to_owned();
                (id.clone(), (group, rate(p as u32, n as u32)))
            })
            .collect()
    };
    let (cb, cn) = (cases(base), cases(now));
    // A baseline without `case_results` (older runs) diffs by group only.
    let (mut worse, mut better, mut added) = (vec![], vec![], vec![]);
    for (id, (_, r)) in &cn {
        match cb.get(id) {
            Some((_, b)) if r < b => worse.push(json!({"id": id, "baseline": b, "now": r})),
            Some((_, b)) if r > b => better.push(json!({"id": id, "baseline": b, "now": r})),
            Some(_) => {}
            None if !cb.is_empty() => added.push(json!(id)),
            None => {}
        }
    }
    let removed: Vec<&String> = cb
        .iter()
        .filter(|(id, (g, _))| !cn.contains_key(*id) && all_now.contains_key(g))
        .map(|(id, _)| id)
        .collect();
    json!({
        "total": {"baseline": side(Some(&tb)), "now": side(Some(&tn)), "delta": delta(&tb, &tn)},
        "groups": groups, "groups_not_run": not_run,
        "regressed": worse, "improved": better, "added": added, "removed": removed,
        "baseline_model": base["model"], "model": now["model"],
    })
}

fn fmt_side(v: &Value) -> String {
    if v.is_null() {
        return "-".into();
    }
    format!(
        "{}/{} ({:.0}%)",
        v["passed"],
        v["runs"],
        v["rate"].as_f64().unwrap_or(0.0) * 100.0
    )
}

fn fmt_delta(v: &Value) -> String {
    v.as_f64()
        .map_or("new".into(), |d| format!("{:+.0} pts", d * 100.0))
}

fn diff_markdown(d: &Value, baseline: &str) -> String {
    let mut out = format!(
        "### Against baseline {baseline}\n\n| group | baseline | now | change |\n| --- | --- | --- | --- |\n"
    );
    for (g, v) in d["groups"].as_object().into_iter().flatten() {
        out.push_str(&format!(
            "| {g} | {} | {} | {} |\n",
            fmt_side(&v["baseline"]),
            fmt_side(&v["now"]),
            fmt_delta(&v["delta"])
        ));
    }
    let t = &d["total"];
    out.push_str(&format!(
        "| **total** (cases in both runs) | {} | {} | {} |\n",
        fmt_side(&t["baseline"]),
        fmt_side(&t["now"]),
        fmt_delta(&t["delta"])
    ));
    let list = |key: &str, title: &str| -> String {
        let items: Vec<String> = d[key]
            .as_array()
            .into_iter()
            .flatten()
            .map(|c| match c.as_str() {
                Some(id) => id.to_string(),
                None => format!(
                    "{} ({:.0}% -> {:.0}%)",
                    c["id"].as_str().unwrap_or(""),
                    c["baseline"].as_f64().unwrap_or(0.0) * 100.0,
                    c["now"].as_f64().unwrap_or(0.0) * 100.0
                ),
            })
            .collect();
        if items.is_empty() {
            String::new()
        } else {
            format!("\n{title}: {}\n", items.join(", "))
        }
    };
    out.push_str(&list("regressed", "Regressed"));
    out.push_str(&list("improved", "Improved"));
    out.push_str(&list("added", "New cases"));
    out.push_str(&list("removed", "Cases not in this run"));
    out.push_str(&list("groups_not_run", "Groups not in this run"));
    if d["baseline_model"] != d["model"] {
        out.push_str(&format!(
            "\nModel changed: {} -> {}\n",
            d["baseline_model"].as_str().unwrap_or("?"),
            d["model"].as_str().unwrap_or("?")
        ));
    }
    out
}

/// Pass rate per group (category) of this run.
fn group_table(s: &Value) -> String {
    let mut out = String::from("| group | pass | rate |\n| --- | --- | --- |\n");
    for (g, (p, n)) in summary_groups(s) {
        out.push_str(&format!("| {g} | {p}/{n} | {:.0}% |\n", rate(p, n) * 100.0));
    }
    out
}

fn table(rows: &[Value], s: &Value) -> String {
    let mut out = String::from(
        "| case | pass | turns | ms | failed checks |\n| --- | --- | --- | --- | --- |\n",
    );
    for r in rows {
        let ts = r["turns"].as_array().cloned().unwrap_or_default();
        let ms: u64 = ts.iter().map(|t| t["wall_ms"].as_u64().unwrap_or(0)).sum();
        let failed: Vec<String> = ts
            .iter()
            .enumerate()
            .flat_map(|(i, t)| {
                t["checks"]
                    .as_array()
                    .cloned()
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|c| c["pass"] == false)
                    .map(move |c| {
                        let why: String =
                            c["why"].as_str().unwrap_or("").chars().take(90).collect();
                        format!(
                            "t{i} {}: {}",
                            c["type"].as_str().unwrap_or(""),
                            why.replace('|', "/").replace('\n', " ")
                        )
                    })
            })
            .collect();
        out.push_str(&format!(
            "| {} | {} | {} | {ms} | {} |\n",
            r["id"].as_str().unwrap_or(""),
            if r["pass"] == true { "PASS" } else { "FAIL" },
            ts.len(),
            failed.join("; ")
        ));
    }
    // The per-case results are the rows above; keep the line short.
    let mut s = s.clone();
    if let Some(m) = s.as_object_mut() {
        m.remove("case_results");
    }
    out.push_str(&format!("\nsummary: {s}"));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn row(id: &str, group: &str, pass: bool) -> Value {
        json!({"id": id, "group": group, "pass": pass, "turns": []})
    }

    fn summary(rows: &[Value]) -> Value {
        let opts = Opts {
            model: "m".into(),
            effort: String::new(),
            judge_model: String::new(),
            compactor: String::new(),
            base_url: String::new(),
            key: String::new(),
            evals_dir: PathBuf::new(),
            ledger_pre: false,
        };
        summarize(rows, 1.0, &opts)
    }

    #[test]
    fn repeats_fold_into_one_case_and_groups_get_a_rate() {
        let s = summary(&[
            row("links-a#0", "links", true),
            row("links-a#1", "links", false),
            row("tone-b", "tone", true),
        ]);
        assert_eq!(
            s["case_results"]["links-a"],
            json!({"group": "links", "passed": 1, "runs": 2})
        );
        assert_eq!(s["groups"]["links"], "1/2");
        assert_eq!(s["group_pass_rate"]["links"], 0.5);
        assert_eq!(s["group_pass_rate"]["tone"], 1.0);
        assert!(group_table(&s).contains("| links | 1/2 | 50% |"));
        assert!(!table(&[], &s).contains("case_results"));
    }

    #[test]
    fn diff_names_regressions_improvements_and_new_cases() {
        let base = summary(&[
            row("links-a", "links", true),
            row("links-b", "links", false),
            row("links-e", "links", true),
            row("memory-c", "memory", true),
        ]);
        let now = summary(&[
            row("links-a", "links", false),
            row("links-b", "links", true),
            row("links-f", "links", false),
            row("tone-d", "tone", true),
        ]);
        let d = baseline_diff(&now, &base);
        assert_eq!(
            d["regressed"],
            json!([{"id": "links-a", "baseline": 1.0, "now": 0.0}])
        );
        assert_eq!(
            d["improved"],
            json!([{"id": "links-b", "baseline": 0.0, "now": 1.0}])
        );
        assert_eq!(d["added"], json!(["links-f", "tone-d"]));
        // links-e left the links group; memory was not run at all.
        assert_eq!(d["removed"], json!(["links-e"]));
        assert_eq!(d["groups_not_run"], json!(["memory"]));
        assert!(d["groups"]["memory"].is_null());
        assert!(d["groups"]["tone"]["baseline"].is_null());
        // links-e is not in this run and links-f is new, so links compares
        // links-a and links-b only.
        assert_eq!(d["groups"]["links"]["delta"], 0.0);
        let md = diff_markdown(&d, "base/summary.json");
        assert!(
            md.contains("| links | 1/2 (50%) | 1/2 (50%) | +0 pts |"),
            "{md}"
        );
        assert!(md.contains("| tone | - | 1/1 (100%) | new |"), "{md}");
        // The total covers the cases both runs have: links-a and links-b.
        assert!(
            md.contains("| **total** (cases in both runs) | 1/2 (50%) | 1/2 (50%) | +0 pts |"),
            "{md}"
        );
        assert!(md.contains("Regressed: links-a (100% -> 0%)"), "{md}");
        assert!(md.contains("New cases: links-f, tone-d"), "{md}");
        assert!(md.contains("Groups not in this run: memory"), "{md}");
    }

    #[test]
    fn diff_reads_a_summary_from_before_case_results() {
        let base = json!({"model": "m", "groups": {"links": "3/4", "tenacity": "1/2"}});
        let now = summary(&[
            row("links-a", "links", true),
            row("tenacity-b", "tenacity", true),
        ]);
        let d = baseline_diff(&now, &base);
        assert_eq!(d["groups"]["links"]["baseline"]["rate"], 0.75);
        assert_eq!(d["groups"]["links"]["delta"], 0.25);
        assert_eq!(d["total"]["baseline"]["passed"], 4);
        // No per-case data on the old side: nothing is called new or gone.
        assert_eq!(d["added"], json!([]));
        assert_eq!(d["removed"], json!([]));
    }
}
