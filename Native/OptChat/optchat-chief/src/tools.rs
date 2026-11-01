//! The memory tools `zoom` and `date` (section 7.1), answered by the host from
//! the live memory on a Unix socket in `$MUX_HOME/optchat/`. The `mcp`
//! subcommand, which the turn session runs as its MCP server, forwards each
//! call here, so the answers always come from the one process that owns the
//! chat. Wire: one JSON line per request and per answer.

// The tool limits the schemas name are the kernel's (chief-kernel tools.rs).
pub use chief_kernel::tools::{
    AUTH_KINDS, CONTROL_ACTIONS, EFFORTS, MAX_SEND_ATTACHMENTS, PLACES, SLEEP_MAX_SECONDS,
    SLEEP_MIN_SECONDS, WATCH_DEFAULT_SECONDS, WATCH_MAX_SECONDS, WATCH_MIN_SECONDS, WATCHES_KEPT,
};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::Path;
use std::sync::Arc;
use std::time::Duration;

use optchat_host::OptChat;
use serde_json::{Value, json};

/// What the tools read.
pub trait Memory: Send + Sync {
    fn zoom(&self, id: u64, n: u64) -> String;
    fn date(&self, id: u64) -> String;
    /// The whole memory as one HTML page (`optchat-chief browse`).
    fn browse(&self) -> String {
        "browsing is not available".to_owned()
    }
}

impl Memory for OptChat {
    fn zoom(&self, id: u64, n: u64) -> String {
        // A bad address answers "No line id+n." (section 7.1), not an error.
        OptChat::zoom(self, id, n).unwrap_or_else(|e| e.to_string())
    }

    fn date(&self, id: u64) -> String {
        OptChat::date(self, id).unwrap_or_else(|| format!("No message {id}."))
    }

    fn browse(&self) -> String {
        crate::browse::html(self)
    }
}

/// The Chief tools a turn another person started may call only with
/// some arguments (`approval::CHIEF_TOOLS`, by their socket names).
const TURN_GATED: [&str; 12] = [
    "send",
    "reply",
    "react",
    "stop",
    "sleep",
    "watch",
    "spawn",
    "tell",
    "control",
    "profile",
    "remember",
    "cloud_workspace",
];

/// Section 9's subagent tools, answered by the host (subagents.rs).
pub trait Orchestrator: Send + Sync {
    /// Starts one subagent per task, in `cwd` when it exists on this host;
    /// answers their ids, each one's workspace (or why it has none) and the
    /// directory they run in.
    fn spawn(&self, tasks: Vec<String>, cwd: Option<String>) -> Result<String, String>;
    /// `spawn` at `effort` (None: as hard as the calling turn).
    fn spawn_with_effort(
        &self,
        tasks: Vec<String>,
        cwd: Option<String>,
        effort: Option<String>,
    ) -> Result<String, String> {
        let _ = effort;
        self.spawn(tasks, cwd)
    }
    /// `spawn` at `effort` and `place` (`"cloud"`: on the cloud peer,
    /// `"local"`: on this host; None: the saved default
    /// (`control cloud`), else `OPTCHAT_SUBAGENT_PEER`, else local).
    fn spawn_placed(
        &self,
        tasks: Vec<String>,
        cwd: Option<String>,
        effort: Option<String>,
        place: Option<String>,
    ) -> Result<String, String> {
        let _ = place;
        self.spawn_with_effort(tasks, cwd, effort)
    }
    /// Sends `message` to subagent `id`.
    fn tell(&self, id: &str, message: &str) -> Result<String, String>;
    /// `tell` with an idempotency key: a repeat of `key` is not sent again.
    fn tell_keyed(&self, id: &str, message: &str, key: Option<&str>) -> Result<String, String> {
        let _ = key;
        self.tell(id, message)
    }
    /// `tell_keyed` with `queue`: true waits for the running turn (a
    /// low-priority FYI) instead of interrupting it.
    fn tell_with(
        &self,
        id: &str,
        message: &str,
        key: Option<&str>,
        queue: bool,
    ) -> Result<String, String> {
        let _ = queue;
        self.tell_keyed(id, message, key)
    }
    /// Whether the running turn may call Chief tool `tool` with `input`
    /// (`Brain::turn_gate`); a host with no turns allows it.
    fn turn_gate(&self, _tool: &str, _input: &Value) -> Result<(), String> {
        Ok(())
    }

    /// `control(action, ...)`: see, interrupt, answer, pause, resume,
    /// cancel, restart, reorder subagents and set the live cap.
    fn control(&self, request: ControlCall) -> Result<String, String> {
        let _ = request;
        Err("this Chief host has no subagent control".into())
    }
    /// Subagent `id`'s whole chat (`zoom("a<N>")`), one page from
    /// character `at`.
    fn agent_chat(&self, id: &str, at: u64) -> Result<String, String>;
    /// `react(id, reaction)`: a tapback on the user message of view line `id`.
    fn react(&self, id: u64, reaction: &str) -> Result<String, String> {
        let _ = (id, reaction);
        Err("this Chief host cannot react".into())
    }
    /// `transcript(n, before)`: the last `n` messages of the Chief
    /// conversation (before seq `before`) as the daemon stores them.
    fn transcript(&self, n: u32, before: Option<u64>) -> Result<String, String> {
        let _ = (n, before);
        Err("this Chief host has no conversation to read".into())
    }
    /// `reply(id, text)`: `text` now, in the thread of the user message of
    /// view line `id`.
    fn reply(&self, id: u64, text: &str) -> Result<String, String> {
        let _ = (id, text);
        Err("this Chief host cannot reply in a thread".into())
    }
    /// `send(text, attachments, reply_to)`: one message posted now.
    fn send(&self, call: SendCall) -> Result<String, String> {
        let _ = call;
        Err("this Chief host cannot send".into())
    }
    /// `stop()`: ends the running turn now; its final text is not posted.
    fn stop_turn(&self) -> Result<String, String> {
        Err("this Chief host cannot stop a turn".into())
    }
    /// `sleep(seconds, note, until)`: ends the turn and wakes the Chief later.
    fn sleep(&self, call: SleepCall) -> Result<String, String> {
        let _ = call;
        Err("this Chief host cannot sleep".into())
    }
    /// `watch(command, until, timeout_seconds, note)`, or `cancel`, or the
    /// list (brain/watches.rs): the host runs the command off the turn and
    /// wakes the Chief once.
    fn watch(&self, call: WatchCall) -> Result<String, String> {
        let _ = call;
        Err("this Chief host cannot watch".into())
    }
    /// `remember(text)` (remember.rs): keeps a lasting preference of the
    /// person in their profile.
    fn remember(&self, text: &str) -> Result<String, String> {
        let _ = text;
        Err("this Chief host has no person profile to remember in".into())
    }
    /// `cloud_workspace` (cloud_workspace.rs): a cmux Cloud machine and a
    /// workspace on it for a task, in the person's sidebar.
    fn cloud_workspace(&self, request: &crate::cloud_workspace::Request) -> Result<String, String> {
        let _ = request;
        Err("cloud_workspace: this Chief host has no cmux app to make Cloud workspaces in".into())
    }
    /// `escalate_auth`: subagent `agent` needs the user's sign-in; the Chief
    /// gets it as an urgent note (ahead of the queue, steered into a running
    /// turn) and drives the sign-in (skill `chief-auth-escalation`).
    fn escalate_auth(&self, agent: &str, request: &AuthEscalation) -> Result<String, String> {
        let _ = (agent, request);
        Err("this Chief host takes no sign-in escalations".into())
    }
    /// `peers` for subagent `caller`: every other subagent with its title
    /// and state (acp-chief-issues.md #11).
    fn peers(&self, caller: &str) -> Result<String, String> {
        let _ = caller;
        Err("this Chief host runs no subagents".into())
    }
    /// `tell` from subagent `from` to subagent `id`: the message says who
    /// sent it; never to itself.
    fn peer_tell(
        &self,
        from: &str,
        id: &str,
        message: &str,
        key: Option<&str>,
    ) -> Result<String, String> {
        let _ = (from, id, message, key);
        Err("this Chief host runs no subagents".into())
    }
}

/// One `send` call (plans/cmux-next/chief-tools-DESIGN.md).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SendCall {
    /// The message's Markdown text.
    pub text: Option<String>,
    /// Local paths (`/abs`, `~/rel`, `file://`) uploaded as attachments, or
    /// `http(s)` URLs added as their own lines.
    pub attachments: Vec<String>,
    /// The view line id of the user message whose thread it goes into.
    pub reply_to: Option<u64>,
}

impl SendCall {
    fn parse(args: &Value) -> Result<SendCall, String> {
        let text = args
            .get("text")
            .and_then(Value::as_str)
            .map(str::trim)
            .filter(|t| !t.is_empty())
            .map(str::to_owned);
        let attachments: Vec<String> = match args.get("attachments") {
            None | Some(Value::Null) => Vec::new(),
            Some(Value::Array(items)) => items
                .iter()
                .map(|v| {
                    v.as_str()
                        .map(str::trim)
                        .filter(|t| !t.is_empty())
                        .map(str::to_owned)
                        .ok_or("send: each attachment must be a path or URL text")
                })
                .collect::<Result<_, _>>()?,
            Some(Value::String(one)) if !one.trim().is_empty() => vec![one.trim().to_owned()],
            Some(_) => return Err("send: `attachments` must be a list of paths or URLs".into()),
        };
        if attachments.len() > MAX_SEND_ATTACHMENTS {
            return Err(format!(
                "send: at most {MAX_SEND_ATTACHMENTS} attachments per message"
            ));
        }
        if text.is_none() && attachments.is_empty() {
            return Err("send: give `text`, `attachments` or both".into());
        }
        let reply_to = match args.get("reply_to") {
            None | Some(Value::Null) => None,
            Some(v) => Some(
                v.as_u64()
                    .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
                    .ok_or("send: `reply_to` must be a message's line id")?,
            ),
        };
        Ok(SendCall {
            text,
            attachments,
            reply_to,
        })
    }

    fn to_json(&self) -> Value {
        let mut v = json!({"tool": "send"});
        if let Some(t) = &self.text {
            v["text"] = json!(t);
        }
        if !self.attachments.is_empty() {
            v["attachments"] = json!(self.attachments);
        }
        if let Some(id) = self.reply_to {
            v["reply_to"] = json!(id);
        }
        v
    }
}

impl SleepCall {
    fn parse(args: &Value) -> Result<SleepCall, String> {
        let seconds = args
            .get("seconds")
            .and_then(|v| {
                v.as_u64()
                    .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
            })
            .ok_or("sleep: `seconds` must be a non-negative integer")?;
        if seconds != 0 && !(SLEEP_MIN_SECONDS..=SLEEP_MAX_SECONDS).contains(&seconds) {
            return Err(format!(
                "sleep: `seconds` is {SLEEP_MIN_SECONDS} to {SLEEP_MAX_SECONDS} (0 clears every pending wake)"
            ));
        }
        let text = |key: &str| {
            args.get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|t| !t.is_empty())
                .map(str::to_owned)
        };
        let until = text("until");
        if let Some(u) = until.as_deref()
            && !matches!(u, "time" | "event")
        {
            return Err("sleep: `until` is time or event".into());
        }
        Ok(SleepCall {
            seconds,
            note: text("note"),
            until,
        })
    }

    fn to_json(&self) -> Value {
        let mut v = json!({"tool": "sleep", "seconds": self.seconds});
        if let Some(n) = &self.note {
            v["note"] = json!(n);
        }
        if let Some(u) = &self.until {
            v["until"] = json!(u);
        }
        v
    }
}

/// One `watch` call: with `command`, a new watch; with `cancel`, a cancel
/// (a `w<N>` id or `all`); with neither, the list.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct WatchCall {
    /// The shell command (`sh -c`) the host runs off the turn.
    pub command: Option<String>,
    /// A regex on its output lines; None: the watch fires when it exits.
    pub until: Option<String>,
    /// When it fires as timed out; None: [`WATCH_DEFAULT_SECONDS`].
    pub timeout_seconds: Option<u64>,
    /// What to do when it fires: shown in the note.
    pub note: Option<String>,
    /// A watch id or `all` to cancel.
    pub cancel: Option<String>,
}

impl WatchCall {
    fn parse(args: &Value) -> Result<WatchCall, String> {
        let text = |key: &str| {
            args.get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|t| !t.is_empty())
                .map(str::to_owned)
        };
        let command = text("command");
        let until = text("until");
        let cancel = text("cancel");
        let timeout_seconds = match args.get("timeout_seconds") {
            None | Some(Value::Null) => None,
            Some(v) => Some(
                v.as_u64()
                    .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
                    .ok_or("watch: `timeout_seconds` must be a whole number of seconds")?,
            ),
        };
        if let Some(t) = timeout_seconds
            && !(WATCH_MIN_SECONDS..=WATCH_MAX_SECONDS).contains(&t)
        {
            return Err(format!(
                "watch: `timeout_seconds` is {WATCH_MIN_SECONDS} to {WATCH_MAX_SECONDS}"
            ));
        }
        if cancel.is_some() && command.is_some() {
            return Err(
                "watch: give `command` to start a watch or `cancel` to stop one, not both".into(),
            );
        }
        if command.is_none() && (until.is_some() || timeout_seconds.is_some()) {
            return Err("watch: `until` and `timeout_seconds` need a `command`".into());
        }
        if let Some(u) = &until {
            regex::Regex::new(u).map_err(|e| format!("watch: `until` is not a regex: {e}"))?;
        }
        Ok(WatchCall {
            command,
            until,
            timeout_seconds,
            note: text("note"),
            cancel,
        })
    }

    fn to_json(&self) -> Value {
        let mut v = json!({"tool": "watch"});
        if let Some(c) = &self.command {
            v["command"] = json!(c);
        }
        if let Some(u) = &self.until {
            v["until"] = json!(u);
        }
        if let Some(t) = self.timeout_seconds {
            v["timeout_seconds"] = json!(t);
        }
        if let Some(n) = &self.note {
            v["note"] = json!(n);
        }
        if let Some(c) = &self.cancel {
            v["cancel"] = json!(c);
        }
        v
    }
}

/// One `sleep` call.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct SleepCall {
    /// How long until the wake; 0 clears every pending wake.
    pub seconds: u64,
    /// Why: shown in the wake note.
    pub note: Option<String>,
    /// `time` (default) or `event`.
    pub until: Option<String>,
}

/// What a subagent's `escalate_auth` asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct AuthEscalation {
    /// The site's host name, for example `npmjs.com`.
    pub site: String,
    /// The page where the sign-in starts.
    pub url: String,
    /// Why the subagent needs it (one line).
    pub reason: String,
    /// One of [`AUTH_KINDS`].
    pub kind: String,
}

impl AuthEscalation {
    /// The note the Chief reads: who, where, what, and the skill to follow.
    pub fn note(&self, agent: &str) -> String {
        format!(
            "[{agent}] needs a sign-in ({kind}) on {site}: {reason}. Page: {url}. Urgent: follow the chief-auth-escalation skill now: open or reuse a browser tab in Home's right pane on that page, fill what you may (never read or type a password; use passkeys, the password manager's autofill or WebAuthn), press the passkey or security-key button so macOS shows the Touch ID sheet, then post one line \"Needs you: touch the sensor ({site})\", watch the tab and tell({agent}) when it is signed in.",
            kind = self.kind,
            site = self.site,
            reason = self.reason,
            url = self.url,
        )
    }
}

/// The subagent id (`a<N>`) in an acpmux session name
/// (`optchat-sub-<home id>-a<N>`, maybe with acpmux's `-<n>` suffix).
pub fn subagent_of_session(name: &str) -> Option<String> {
    let rest = name.trim().strip_prefix("optchat-sub-")?;
    // The home id first, then the subagent id.
    rest.split('-')
        .skip(1)
        .find(|part| {
            part.len() > 1 && part.starts_with('a') && part[1..].chars().all(|c| c.is_ascii_digit())
        })
        .map(str::to_owned)
}

/// What `chief zoom|date|spawn|tell WORDS` asks: the tool call, its usage
/// asked for (`--help`, `-h`), or its usage for words that do not fit.
#[derive(Debug, PartialEq)]
pub enum Command {
    Call(Call),
    Help(String),
    Usage(String),
}

/// The command line form of the memory and subagent tools.
pub fn command(tool: &str, args: &[&str]) -> Result<Command, String> {
    // A flag is never a task or a message: asking for help starts nothing.
    if args.iter().any(|a| matches!(*a, "--help" | "-h")) {
        return Ok(Command::Help(usage(tool)));
    }
    let call = match (tool, args) {
        ("zoom", [id]) if agent_id(id) => Call::parse("zoom", &serde_json::json!({"id": id})),
        ("zoom", [id, at]) if agent_id(id) => {
            Call::parse("zoom", &serde_json::json!({"id": id, "at": at}))
        }
        ("zoom", [id, n]) => Call::parse("zoom", &serde_json::json!({"id": id, "n": n})),
        ("date", [id]) => Call::parse("date", &serde_json::json!({"id": id})),
        ("spawn", ["--cwd", dir, tasks @ ..]) if !tasks.is_empty() => {
            Call::parse("spawn", &serde_json::json!({"tasks": tasks, "cwd": dir}))
        }
        ("spawn", tasks) if !tasks.is_empty() && tasks[0] != "--cwd" => {
            Call::parse("spawn", &serde_json::json!({"tasks": tasks}))
        }
        ("react", [id, reaction]) => Call::parse(
            "react",
            &serde_json::json!({"id": id, "reaction": reaction}),
        ),
        ("reply", [id, text @ ..]) if !text.is_empty() => Call::parse(
            "reply",
            &serde_json::json!({"id": id, "text": text.join(" ")}),
        ),
        ("send", ["--reply-to", id, text @ ..]) if !text.is_empty() => Call::parse(
            "send",
            &serde_json::json!({"reply_to": id, "text": text.join(" ")}),
        ),
        ("send", text) if !text.is_empty() && text[0] != "--reply-to" => {
            Call::parse("send", &serde_json::json!({"text": text.join(" ")}))
        }
        ("cloud-workspace" | "cloud_workspace", words) if !words.is_empty() => {
            // `[--size S] [--machine M] TITLE...`, the flags in any place.
            let mut v = serde_json::json!({});
            let mut title = Vec::new();
            let mut rest = words.iter();
            while let Some(word) = rest.next() {
                match *word {
                    flag @ ("--size" | "--machine") => match rest.next() {
                        Some(value) => v[&flag[2..]] = serde_json::json!(value),
                        None => return Ok(Command::Usage(usage(tool))),
                    },
                    word => title.push(word),
                }
            }
            v["title"] = serde_json::json!(title.join(" "));
            Call::parse("cloud_workspace", &v)
        }
        ("stop", []) => Call::parse("stop", &serde_json::json!({})),
        ("transcript", []) => Call::parse("transcript", &serde_json::json!({})),
        ("transcript", [n]) => Call::parse("transcript", &serde_json::json!({"n": n})),
        ("transcript", [n, "--before", before]) => {
            Call::parse("transcript", &serde_json::json!({"n": n, "before": before}))
        }
        ("sleep", [seconds, note @ ..]) => {
            let mut v = serde_json::json!({"seconds": seconds});
            if !note.is_empty() {
                v["note"] = serde_json::json!(note.join(" "));
            }
            Call::parse("sleep", &v)
        }
        ("watch", []) => Call::parse("watch", &serde_json::json!({})),
        ("watch", ["--cancel", id]) => Call::parse("watch", &serde_json::json!({"cancel": id})),
        ("watch", [args]) if args.trim_start().starts_with('{') => {
            match serde_json::from_str::<Value>(args) {
                Ok(v @ Value::Object(_)) => Call::parse("watch", &v),
                _ => return Ok(Command::Usage(usage(tool))),
            }
        }
        ("remember", text) if !text.is_empty() => {
            Call::parse("remember", &serde_json::json!({"text": text.join(" ")}))
        }
        ("peers", []) => Call::parse("peers", &serde_json::json!({})),
        ("profile", []) => Call::parse("profile", &serde_json::json!({})),
        ("profile", [args]) => match serde_json::from_str::<Value>(args) {
            Ok(v @ Value::Object(_)) => Call::parse("profile", &v),
            _ => return Ok(Command::Usage(usage(tool))),
        },
        ("chiefs", []) => Call::parse("chiefs", &serde_json::json!({"action": "list"})),
        ("chiefs", [args]) => match serde_json::from_str::<Value>(args) {
            Ok(v @ Value::Object(_)) => Call::parse("chiefs", &v),
            _ => return Ok(Command::Usage(usage(tool))),
        },
        ("control", []) => Call::parse("control", &serde_json::json!({"action": "status"})),
        ("control", ["status", id]) => Call::parse(
            "control",
            &serde_json::json!({"action": "status", "id": id}),
        ),
        ("control", ["cap", n]) => {
            Call::parse("control", &serde_json::json!({"action": "cap", "n": n}))
        }
        ("control", ["cloud", peer]) => Call::parse(
            "control",
            &serde_json::json!({"action": "cloud", "peer": peer}),
        ),
        ("control", ["answer", id, option]) => Call::parse(
            "control",
            &serde_json::json!({"action": "answer", "id": id, "option": option}),
        ),
        ("control", [action, id, message @ ..]) => {
            let mut v = serde_json::json!({"action": action, "id": id});
            if !message.is_empty() {
                v["message"] = serde_json::json!(message.join(" "));
            }
            Call::parse("control", &v)
        }
        ("control", [action]) => Call::parse("control", &serde_json::json!({"action": action})),
        ("tell", ["--queue", id, message @ ..]) if !message.is_empty() => Call::parse(
            "tell",
            &serde_json::json!({"id": id, "message": message.join(" "), "queue": true}),
        ),
        ("escalate-auth" | "escalate_auth", [kind, site, url, reason @ ..])
            if !reason.is_empty() =>
        {
            Call::parse(
                "escalate_auth",
                &serde_json::json!({"kind": kind, "site": site, "url": url, "reason": reason.join(" ")}),
            )
        }
        ("tell", [id, message @ ..]) if !message.is_empty() => Call::parse(
            "tell",
            &serde_json::json!({"id": id, "message": message.join(" ")}),
        ),
        _ => return Ok(Command::Usage(usage(tool))),
    };
    call.map(Command::Call)
}

/// `usage: optchat-chief TOOL ARGS`.
pub fn usage(tool: &str) -> String {
    format!(
        "usage: optchat-chief {tool} {}",
        match tool {
            "zoom" => "ID N | SUBAGENT [AT]",
            "date" => "ID",
            "react" => "ID like|love|laugh|emphasize|question|dislike|ack",
            "reply" => "ID \"text\"",
            "send" => "[--reply-to ID] \"text\"",
            "stop" => "",
            "transcript" => "[N] [--before SEQ]",
            "sleep" => "SECONDS [\"note\"]",
            "watch" =>
                "['{\"command\": \"...\", \"until\": \"REGEX\", \"timeout_seconds\": 1800, \"note\": \"...\"}'] | --cancel ID|all",
            "remember" => "\"the preference, one short line\"",
            "escalate-auth" | "escalate_auth" =>
                "password|passkey|2fa|oauth SITE URL \"why you need it\"",
            "peers" => "",
            "spawn" => "[--cwd DIR] \"task\" [\"task\" ...]",
            "cloud-workspace" | "cloud_workspace" => {
                "[--size small|medium|large|xlarge] [--machine machine:ID] \"task title\""
            }
            "profile" => "['{\"role\": \"...\", \"avatar_path\": \"/path/pic.png\"}']",
            "chiefs" =>
                "['{\"action\": \"create\", \"display_name\": \"...\", \"role\": \"...\"}']",
            "control" =>
                "status [ID] | interrupt ID [\"message\"] | answer ID OPTION|deny | pause ID | resume ID [\"message\"] | cancel ID | restart ID [\"message\"] | priority ID | cap N | cloud [PEER[,PEER...]|off]",
            "tell" => "[--queue] ID \"message\"",
            _ => "ID \"message\"",
        }
    )
}

/// A subagent id (`a<N>`) where zoom takes a message id: it starts with a letter.
pub fn agent_id(id: &str) -> bool {
    id.trim().starts_with(|c: char| c.is_ascii_alphabetic())
}

/// One `control` call.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct ControlCall {
    pub action: String,
    pub id: Option<String>,
    pub message: Option<String>,
    pub option: Option<String>,
    pub n: Option<u64>,
    /// `cloud`: the acpmux peer cloud subagents run on, or `off`.
    pub peer: Option<String>,
}

impl ControlCall {
    fn parse(args: &Value) -> Result<ControlCall, String> {
        let text = |key: &str| {
            args.get(key)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|t| !t.is_empty())
                .map(str::to_owned)
        };
        let action = text("action").unwrap_or_else(|| "status".to_owned());
        if !CONTROL_ACTIONS.contains(&action.as_str()) {
            return Err(format!(
                "control: no action {action}; one of {}",
                CONTROL_ACTIONS.join(", ")
            ));
        }
        let n = match args.get("n") {
            None | Some(Value::Null) => None,
            Some(v) => Some(
                v.as_u64()
                    .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
                    .ok_or("control: `n` must be a non-negative integer")?,
            ),
        };
        let call = ControlCall {
            action,
            id: text("id"),
            message: text("message"),
            option: text("option"),
            n,
            peer: text("peer"),
        };
        let needs_id = !matches!(call.action.as_str(), "status" | "cap" | "cloud");
        if needs_id && call.id.is_none() {
            return Err(format!("control {}: `id` is required", call.action));
        }
        if call.action == "answer" && call.option.is_none() {
            return Err("control answer: `option` is required (an option id, or `deny`)".into());
        }
        if call.action == "cap" && call.n.is_none() {
            return Err("control cap: `n` is required (0: no cap)".into());
        }
        Ok(call)
    }

    fn to_json(&self) -> Value {
        let mut v = json!({"tool": "control", "action": self.action});
        if let Some(id) = &self.id {
            v["id"] = json!(id);
        }
        if let Some(m) = &self.message {
            v["message"] = json!(m);
        }
        if let Some(o) = &self.option {
            v["option"] = json!(o);
        }
        if let Some(n) = self.n {
            v["n"] = json!(n);
        }
        if let Some(p) = &self.peer {
            v["peer"] = json!(p);
        }
        v
    }
}

/// One tool call.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Call {
    Zoom {
        id: u64,
        n: u64,
    },
    /// `zoom("a<N>")`: a subagent's whole chat from character `at`.
    ZoomAgent {
        id: String,
        at: u64,
    },
    Date {
        id: u64,
    },
    Spawn {
        tasks: Vec<String>,
        /// The subagents' working directory on the Chief's host (`~` is
        /// its home); None is the default subagent directory.
        cwd: Option<String>,
        /// How hard they think; None: as hard as the calling turn.
        effort: Option<String>,
        /// `cloud` or `local`; None: the saved default (`control cloud`).
        place: Option<String>,
    },
    Tell {
        id: String,
        message: String,
        /// Idempotency key: a repeat is not sent again.
        key: Option<String>,
        /// Wait for the running turn instead of interrupting it (a
        /// low-priority FYI); false: steer, else interrupt.
        queue: bool,
    },
    /// `react` (brain/replies.rs): a tapback on the user message of view
    /// line `id`.
    React {
        id: u64,
        reaction: String,
    },
    /// `reply` (brain/replies.rs): `text` now, in the thread of the user
    /// message of view line `id`.
    Reply {
        id: u64,
        text: String,
    },
    /// `send` (brain/send.rs): one message now, with files, optionally in
    /// a thread.
    Send(SendCall),
    /// `transcript` (brain/transcript.rs): the last `n` messages of the
    /// Chief conversation, before seq `before` (None: the newest), as the
    /// daemon stores them.
    Transcript {
        n: u32,
        before: Option<u64>,
    },
    /// `stop` (brain/wakes.rs): ends the running turn now.
    Stop,
    /// `sleep` (brain/wakes.rs): ends the turn and wakes the Chief later.
    Sleep(SleepCall),
    /// `watch` (brain/watches.rs): a command the host runs off the turn,
    /// waking the Chief once.
    Watch(WatchCall),
    /// `remember` (remember.rs): a lasting preference into the profile.
    Remember {
        text: String,
    },
    /// `control` (brain/control.rs): subagent control.
    Control(ControlCall),
    /// `cloud_workspace` (cloud_workspace.rs): a Cloud machine and its
    /// workspace for a task.
    CloudWorkspace(crate::cloud_workspace::Request),
    /// `escalate_auth` (a subagent's only write tool): the Chief drives a
    /// sign-in for it. `agent` is the caller's own id as it claims it; the
    /// host prefers the id its session binding gives (turn_caller.rs).
    EscalateAuth {
        request: AuthEscalation,
        agent: Option<String>,
    },
    /// `peers`: a subagent's list of the other subagents.
    Peers,
    /// `profile` (chief_profile.rs): read or change the Chief's own record.
    Profile {
        args: Value,
    },
    /// `chiefs` (chief_profile.rs): see, make and edit other Chiefs. Only a
    /// caller with this host's turn key (`turn_key`) gets an answer.
    Chiefs {
        args: Value,
        turn_key: Option<String>,
    },
}

impl Call {
    /// The call named `tool` with JSON `args`.
    pub fn parse(tool: &str, args: &Value) -> Result<Call, String> {
        let num = |key: &str| {
            args.get(key)
                .and_then(|v| {
                    v.as_u64()
                        .or_else(|| v.as_str().and_then(|s| s.trim().parse().ok()))
                })
                .ok_or_else(|| format!("{tool}: `{key}` must be a non-negative integer"))
        };
        match tool {
            "zoom" if args.get("id").and_then(Value::as_str).is_some_and(agent_id) => {
                Ok(Call::ZoomAgent {
                    id: args["id"].as_str().unwrap_or_default().trim().to_owned(),
                    at: if args.get("at").is_some() {
                        num("at")?
                    } else {
                        0
                    },
                })
            }
            "zoom" => Ok(Call::Zoom {
                id: num("id")?,
                n: num("n")?,
            }),
            "date" => Ok(Call::Date { id: num("id")? }),
            "spawn" => {
                let tasks: Vec<String> = match args.get("tasks") {
                    Some(Value::Array(items)) => items
                        .iter()
                        .filter_map(|t| t.as_str().map(str::trim).map(str::to_owned))
                        .filter(|t| !t.is_empty())
                        .collect(),
                    Some(Value::String(one)) if !one.trim().is_empty() => {
                        vec![one.trim().to_owned()]
                    }
                    _ => Vec::new(),
                };
                if tasks.is_empty() {
                    return Err("spawn: `tasks` must be a list of task texts".into());
                }
                let cwd = args
                    .get("cwd")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|d| !d.is_empty())
                    .map(str::to_owned);
                let effort = args
                    .get("effort")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|e| !e.is_empty())
                    .map(str::to_owned);
                if let Some(e) = effort.as_deref()
                    && !EFFORTS.contains(&e)
                {
                    return Err(format!(
                        "spawn: no effort {e}; one of {}",
                        EFFORTS.join(", ")
                    ));
                }
                let place = args
                    .get("place")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|e| !e.is_empty())
                    .map(str::to_owned);
                if let Some(p) = place.as_deref()
                    && !PLACES.contains(&p)
                    && !p
                        .strip_prefix("cloud:")
                        .is_some_and(|s| crate::subagents::SIZES.contains(&s))
                {
                    return Err(format!(
                        "spawn: no place {p}; one of {}, or cloud:small|medium|large",
                        PLACES.join(", ")
                    ));
                }
                Ok(Call::Spawn {
                    tasks,
                    cwd,
                    effort,
                    place,
                })
            }
            "tell" => {
                let text = |key: &str| {
                    args.get(key)
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|t| !t.is_empty())
                        .map(str::to_owned)
                        .ok_or_else(|| format!("tell: `{key}` must be a non-empty text"))
                };
                Ok(Call::Tell {
                    id: text("id")?,
                    message: text("message")?,
                    key: text("key").ok(),
                    queue: args.get("queue").and_then(Value::as_bool).unwrap_or(false),
                })
            }
            "transcript" => {
                let opt = |key: &str| -> Result<Option<u64>, String> {
                    match args.get(key) {
                        None | Some(Value::Null) => Ok(None),
                        Some(_) => num(key).map(Some),
                    }
                };
                let n = opt("n")?
                    .unwrap_or(u64::from(crate::brain::TRANSCRIPT_DEFAULT))
                    .clamp(1, u64::from(crate::brain::TRANSCRIPT_MAX));
                Ok(Call::Transcript {
                    n: n as u32,
                    before: opt("before")?,
                })
            }
            "react" => {
                let reaction = args
                    .get("reaction")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|t| !t.is_empty())
                    .ok_or("react: `reaction` must be one of like, love, laugh, emphasize, question, dislike, ack, or one emoji")?;
                crate::brain::reaction(reaction)?;
                Ok(Call::React {
                    id: num("id")?,
                    reaction: reaction.to_owned(),
                })
            }
            "reply" => {
                let text = args
                    .get("text")
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|t| !t.is_empty())
                    .ok_or("reply: `text` must be a non-empty text")?;
                Ok(Call::Reply {
                    id: num("id")?,
                    text: text.to_owned(),
                })
            }
            "send" => SendCall::parse(args).map(Call::Send),
            "stop" => Ok(Call::Stop),
            "sleep" => SleepCall::parse(args).map(Call::Sleep),
            "watch" => WatchCall::parse(args).map(Call::Watch),
            "remember" => {
                let text = args.get("text").and_then(Value::as_str).unwrap_or_default();
                crate::remember::clean(text).map(|text| Call::Remember { text })
            }
            "control" => ControlCall::parse(args).map(Call::Control),
            "cloud_workspace" => {
                let text = |key: &str| {
                    args.get(key)
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|t| !t.is_empty())
                        .map(str::to_owned)
                };
                let title = text("title").ok_or_else(|| {
                    "cloud_workspace: `title` names the task in a few words".to_owned()
                })?;
                Ok(Call::CloudWorkspace(crate::cloud_workspace::Request {
                    title,
                    size: text("size"),
                    machine: text("machine"),
                }))
            }
            "escalate_auth" => {
                let text = |key: &str| {
                    args.get(key)
                        .and_then(Value::as_str)
                        .map(str::trim)
                        .filter(|t| !t.is_empty())
                        .map(str::to_owned)
                        .ok_or_else(|| format!("escalate_auth: `{key}` must be a non-empty text"))
                };
                let kind = text("kind")?.to_ascii_lowercase();
                if !AUTH_KINDS.contains(&kind.as_str()) {
                    return Err(format!(
                        "escalate_auth: no kind {kind}; one of {}",
                        AUTH_KINDS.join(", ")
                    ));
                }
                let url = text("url")?;
                if !(url.starts_with("https://") || url.starts_with("http://")) {
                    return Err("escalate_auth: `url` must be an http(s) page".into());
                }
                let site = text("site")?;
                Ok(Call::EscalateAuth {
                    request: AuthEscalation {
                        site,
                        url,
                        reason: text("reason")?,
                        kind,
                    },
                    agent: text("agent").ok().filter(|a| agent_id(a)),
                })
            }
            "peers" => Ok(Call::Peers),
            "profile" => {
                let mut args = args.as_object().cloned().unwrap_or_default();
                // The socket request's own keys are not the tool's arguments.
                args.remove("tool");
                args.remove("from");
                Ok(Call::Profile {
                    args: Value::Object(args),
                })
            }
            "chiefs" => {
                let mut args = args.as_object().cloned().unwrap_or_default();
                args.remove("tool");
                args.remove("from");
                let turn_key = args
                    .remove("turn_key")
                    .and_then(|v| v.as_str().map(str::to_owned));
                Ok(Call::Chiefs {
                    args: Value::Object(args),
                    turn_key,
                })
            }
            other => Err(format!("unknown tool {other}")),
        }
    }

    /// The memory tools' answer (spawn and tell go to an `Orchestrator`).
    pub fn answer(self, memory: &dyn Memory) -> String {
        match self {
            Call::Zoom { id, n } => memory.zoom(id, n),
            Call::Date { id } => memory.date(id),
            Call::Spawn { .. }
            | Call::Tell { .. }
            | Call::React { .. }
            | Call::Reply { .. }
            | Call::Send(_)
            | Call::Transcript { .. }
            | Call::Stop
            | Call::Sleep(_)
            | Call::Watch(_)
            | Call::Remember { .. }
            | Call::Control(_)
            | Call::CloudWorkspace(_)
            | Call::Peers
            | Call::ZoomAgent { .. }
            | Call::EscalateAuth { .. }
            | Call::Profile { .. }
            | Call::Chiefs { .. } => {
                "spawn, tell, peers, profile, chiefs and a subagent's zoom are served by the Chief host"
                    .to_owned()
            }
        }
    }

    fn to_json(&self) -> Value {
        match self {
            Call::Zoom { id, n } => json!({"tool": "zoom", "id": id, "n": n}),
            Call::ZoomAgent { id, at } => json!({"tool": "zoom", "id": id, "at": at}),
            Call::Date { id } => json!({"tool": "date", "id": id}),
            Call::Peers => json!({"tool": "peers"}),
            Call::Spawn {
                tasks,
                cwd,
                effort,
                place,
            } => {
                let mut v = json!({"tool": "spawn", "tasks": tasks});
                if let Some(place) = place {
                    v["place"] = json!(place);
                }
                if let Some(cwd) = cwd {
                    v["cwd"] = json!(cwd);
                }
                if let Some(effort) = effort {
                    v["effort"] = json!(effort);
                }
                v
            }
            Call::Tell {
                id,
                message,
                key,
                queue,
            } => {
                let mut v = json!({"tool": "tell", "id": id, "message": message});
                if let Some(key) = key {
                    v["key"] = json!(key);
                }
                if *queue {
                    v["queue"] = json!(true);
                }
                v
            }
            Call::React { id, reaction } => {
                json!({"tool": "react", "id": id, "reaction": reaction})
            }
            Call::Reply { id, text } => json!({"tool": "reply", "id": id, "text": text}),
            Call::Transcript { n, before } => {
                let mut v = json!({"tool": "transcript", "n": n});
                if let Some(before) = before {
                    v["before"] = json!(before);
                }
                v
            }
            Call::Send(c) => c.to_json(),
            // `end_turn` marks the model's tool: the owner's chief.stop
            // reaches this socket as a bare `{"tool": "stop"}`.
            Call::Stop => json!({"tool": "stop", "end_turn": true}),
            Call::Sleep(c) => c.to_json(),
            Call::Watch(c) => c.to_json(),
            Call::Remember { text } => json!({"tool": "remember", "text": text}),
            Call::Control(c) => c.to_json(),
            Call::CloudWorkspace(r) => {
                let mut v = json!({"tool": "cloud_workspace", "title": r.title});
                if let Some(size) = &r.size {
                    v["size"] = json!(size);
                }
                if let Some(machine) = &r.machine {
                    v["machine"] = json!(machine);
                }
                v
            }
            Call::EscalateAuth { request, agent } => {
                let mut v = json!({
                    "tool": "escalate_auth",
                    "site": request.site,
                    "url": request.url,
                    "reason": request.reason,
                    "kind": request.kind,
                });
                if let Some(agent) = agent {
                    v["agent"] = json!(agent);
                }
                v
            }
            Call::Profile { args } => {
                let mut v = args.clone();
                if !v.is_object() {
                    v = json!({});
                }
                v["tool"] = json!("profile");
                v
            }
            Call::Chiefs { args, turn_key } => {
                let mut v = args.clone();
                if !v.is_object() {
                    v = json!({});
                }
                v["tool"] = json!("chiefs");
                if let Some(key) = turn_key {
                    v["turn_key"] = json!(key);
                }
                v
            }
        }
    }
}

/// The host's per-Chief settings over the socket (`optchat-chief settings`):
/// `Some((key, value))` sets one, None shows them all. Not a model tool:
/// the MCP server never offers it.
pub type Control = Arc<dyn Fn(ControlRequest) -> Result<String, String> + Send + Sync>;

/// What `optchat-chief settings` and `chief agents spawn` ask the host.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ControlRequest {
    /// The per-Chief settings as JSON.
    Show,
    /// Sets one setting.
    Set(String, String),
    /// The policy floor for a child spawned now: `ask`, or empty for none.
    SpawnPolicy,
    /// chief.engine.get / chief.engine.set: answers the brain's JSON value.
    Engine(crate::brain::EngineRequest),
    /// chief.stop: answers `{"stopped": bool}`.
    Stop,
    /// Reopen the last owner-stopped reply batch.
    Continue,
    /// Re-answer one owner message in the Chief conversation.
    Retry(String),
    /// chief.stop {name}: stops that one subagent.
    StopSubagent(String),
    /// chief.stop {all: true}: the turn and every subagent ("Stop all
    /// agents").
    StopAll,
    /// chief.stop {restart: [ids]}: those subagents go on (Restart on the
    /// stop-all toast).
    Restart(Vec<String>),
}

/// What the tools socket serves: the memory, the subagent tools when the
/// host runs them, and the host's settings control.
#[derive(Clone)]
pub struct Served {
    pub memory: Arc<dyn Memory>,
    pub orchestrator: Option<Arc<dyn Orchestrator>>,
    pub control: Option<Control>,
    /// The memory inspector's read-only API (`inspect` tool): a remote
    /// owner reaches it through the brain's daemon (`chief.inspect`).
    pub inspector: Option<Arc<crate::inspect::Inspector>>,
    /// This Chief's record and grant (chief_profile.rs); None: every tool,
    /// no `profile` (no registry, as before Chiefs had records).
    pub chief: Option<Arc<crate::chief_profile::ChiefTools>>,
    /// How a caller is bound to its acpmux session (`turn_caller.rs`): only
    /// a caller under one of this Chief's turn sessions gets `chiefs`, and a
    /// caller under one of its subagents is a subagent whatever it says.
    /// None: no caller is a turn.
    pub turn: Option<crate::turn_caller::TurnBinding>,
    /// The Chiefs on other machines (peer_chiefs.rs): `tell("chief:<name>")`
    /// posts to them through the agent hub and `chiefs` lists them. None: off.
    pub peers: Option<Arc<crate::peer_chiefs::PeerChiefs>>,
}

/// Serves the tools on `path` until the process ends. The host holds the
/// host lock, so a socket file left by an earlier host is stale and replaced.
pub fn serve(path: &Path, memory: Arc<dyn Memory>) -> std::io::Result<()> {
    serve_with(path, memory, None)
}

/// `serve`, with the host's settings `control`.
pub fn serve_with(
    path: &Path,
    memory: Arc<dyn Memory>,
    control: Option<Control>,
) -> std::io::Result<()> {
    serve_all(
        path,
        Served {
            memory,
            orchestrator: None,
            control,
            inspector: None,
            chief: None,
            turn: None,
            peers: None,
        },
    )
}

/// Serves the memory, the subagent tools and the settings control on `path`.
pub fn serve_all(path: &Path, served: Served) -> std::io::Result<()> {
    let _ = std::fs::remove_file(path);
    let listener = UnixListener::bind(path)?;
    std::thread::Builder::new()
        .name("tools".into())
        .spawn(move || {
            for conn in listener.incoming().flatten() {
                let served = served.clone();
                let _ = std::thread::Builder::new()
                    .name("tools-conn".into())
                    .spawn(move || connection(conn, &served));
            }
        })?;
    Ok(())
}

fn connection(conn: UnixStream, served: &Served) {
    let memory = &*served.memory;
    // The caller's session role, read once, when a call first needs it.
    let peer = crate::acpmux_peer::peer_pid(&conn).ok();
    let role_cell = std::cell::OnceCell::new();
    let role = || {
        *role_cell.get_or_init(|| match (&served.turn, peer) {
            (Some(binding), Some(pid)) => binding.role_of(pid),
            _ => crate::turn_caller::Role::Other,
        })
    };
    // The subagent id of a caller under a subagent session (its own
    // session name, never the request's word): who a `tell` comes from.
    let caller_cell = std::cell::OnceCell::new();
    let caller = || {
        caller_cell
            .get_or_init(|| match (&served.turn, peer) {
                (Some(binding), Some(pid)) => binding.subagent_of(pid),
                _ => None,
            })
            .clone()
    };
    let control = served.control.as_ref();
    let Ok(mut out) = conn.try_clone() else {
        return;
    };
    for line in BufReader::new(conn).lines() {
        let Ok(line) = line else { return };
        let answer = match serde_json::from_str::<Value>(&line) {
            Ok(req) => {
                let tool = req.get("tool").and_then(Value::as_str).unwrap_or("");
                // These are owner/host controls, not model tools. A caller
                // bound to one of this Chief's subagent sessions never gets
                // them, even if it clears the advisory `from` marker.
                if matches!(
                    tool,
                    "settings"
                        | "spawn_policy"
                        | "engine"
                        | "stop"
                        | "continue"
                        | "retry"
                        | "inspect"
                        | "grant"
                        | "browse"
                ) && role() == crate::turn_caller::Role::Subagent
                {
                    if writeln!(
                        out,
                        "{}",
                        json!({"error": "subagents have no owner controls"})
                    )
                    .is_err()
                    {
                        return;
                    }
                    continue;
                }
                // Not a model tool: the `browse` command asks the live host.
                if tool == "settings" || tool == "spawn_policy" {
                    let ask = match req.get("key").and_then(Value::as_str) {
                        _ if tool == "spawn_policy" => ControlRequest::SpawnPolicy,
                        Some(k) => {
                            let v = req.get("value").and_then(Value::as_str).unwrap_or("");
                            ControlRequest::Set(k.to_owned(), v.to_owned())
                        }
                        None => ControlRequest::Show,
                    };
                    let answer = match control {
                        Some(control) => match control(ask) {
                            Ok(text) => json!({"text": text}),
                            Err(e) => json!({"error": e}),
                        },
                        None => json!({"error": "settings are not served here"}),
                    };
                    if writeln!(out, "{answer}").is_err() {
                        return;
                    }
                    continue;
                }
                // chief.engine.get / chief.engine.set / chief.stop: the
                // brain's JSON value as the answer line (the daemon's
                // owner-gated chief-control forwards these lines). The
                // model's own `stop` tool (`end_turn`, or any call from a
                // turn session) only ends its turn: taken for chief.stop, it
                // stopped every subagent (2026-10-20).
                let model_stop = tool == "stop"
                    && (req.get("end_turn").and_then(Value::as_bool) == Some(true)
                        || role() == crate::turn_caller::Role::Turn);
                if matches!(tool, "continue" | "retry") && role() != crate::turn_caller::Role::Other
                {
                    let _ = writeln!(
                        out,
                        "{}",
                        json!({"error": {"code": "forbidden", "message": "owner control only"}})
                    );
                    continue;
                }
                if matches!(tool, "engine" | "continue" | "retry")
                    || (tool == "stop" && !model_stop)
                {
                    let field = |k: &str| req.get(k).and_then(Value::as_str).map(str::to_owned);
                    let ask = match (tool, field("action").as_deref()) {
                        ("continue", _) => Some(ControlRequest::Continue),
                        ("retry", _) => field("message")
                            .filter(|id| !id.trim().is_empty())
                            .map(ControlRequest::Retry),
                        ("stop", _) => {
                            let restart = req.get("restart").and_then(Value::as_array).map(|ids| {
                                ids.iter()
                                    .filter_map(Value::as_str)
                                    .map(str::to_owned)
                                    .collect::<Vec<_>>()
                            });
                            let all = req.get("all").and_then(Value::as_bool) == Some(true);
                            Some(
                                match (restart, all, field("name").filter(|n| !n.trim().is_empty()))
                                {
                                    (Some(ids), _, _) => ControlRequest::Restart(ids),
                                    (None, true, _) => ControlRequest::StopAll,
                                    (None, false, Some(name)) => {
                                        ControlRequest::StopSubagent(name.trim().to_owned())
                                    }
                                    (None, false, None) => ControlRequest::Stop,
                                },
                            )
                        }
                        (_, Some("show") | None) => {
                            Some(ControlRequest::Engine(crate::brain::EngineRequest::Show))
                        }
                        (_, Some("set")) => {
                            Some(ControlRequest::Engine(crate::brain::EngineRequest::Set {
                                harness: field("harness"),
                                model: field("model"),
                                effort: field("effort"),
                                speed: field("speed"),
                                compactor_speed: field("compactor_speed"),
                                compactor_harness: field("compactor_harness"),
                                compactor_model: field("compactor_model"),
                                reactions: Box::new(crate::brain::ReactionFields {
                                    classifier_harness: field("classifier_harness"),
                                    classifier_model: field("classifier_model"),
                                    classifier_prompt: field("classifier_prompt"),
                                    reactions_can_wake: field("reactions_can_wake"),
                                }),
                            }))
                        }
                        _ => None,
                    };
                    let answer = match (ask, control) {
                        (None, _) => {
                            json!({"error": {"code": "bad_request", "message": "engine action is show or set; retry requires message"}})
                        }
                        (Some(_), None) => {
                            json!({"error": {"code": "unavailable", "message": "the engine control is not served here"}})
                        }
                        (Some(ask), Some(control)) => match control(ask) {
                            Ok(text) => serde_json::from_str(&text).unwrap_or_else(
                                |_| json!({"error": {"code": "internal", "message": text}}),
                            ),
                            Err(e) => json!({"error": {"code": "unavailable", "message": e}}),
                        },
                    };
                    if writeln!(out, "{answer}").is_err() {
                        return;
                    }
                    continue;
                }
                if tool == "inspect" {
                    let answer = match &served.inspector {
                        // Changes only from a caller that is none of the
                        // Chief's own sessions (the app through its daemon,
                        // the owner's CLI): the Chief never rewrites its memory.
                        Some(inspector) => crate::inspect::tool_answer(
                            inspector,
                            &req,
                            crate::inspect::INSPECT_MAX_BYTES,
                            role() == crate::turn_caller::Role::Other
                                && req.get("from").and_then(Value::as_str) != Some("subagent")
                                && !peer.is_some_and(crate::turn_caller::under_this_process),
                        ),
                        None => {
                            json!({"status": 503, "error": "the inspector is off on this host"})
                        }
                    };
                    if writeln!(out, "{answer}").is_err() {
                        return;
                    }
                    continue;
                }
                // The model tools the `mcp` server may list (its tools/list).
                if tool == "grant" {
                    let value = served
                        .chief
                        .as_ref()
                        .map_or_else(|| "spawn,tell".to_owned(), |c| c.mcp_value());
                    if writeln!(out, "{}", json!({"text": value})).is_err() {
                        return;
                    }
                    continue;
                }
                if tool == "browse" {
                    let answer = json!({"text": memory.browse()});
                    if writeln!(out, "{answer}").is_err() {
                        return;
                    }
                    continue;
                }
                // Section 9 gives subagents zoom and date, not spawn. A
                // caller under a subagent session is one whatever it says;
                // its tools (MCP server or launcher) also say so, which can
                // only add the refusal.
                let subagent = req.get("from").and_then(Value::as_str) == Some("subagent")
                    || role() == crate::turn_caller::Role::Subagent;
                let grant = served.chief.as_ref().map(|c| c.grant());
                let grant = grant.as_ref();
                // The turn's settings allow the Chief's tools with no
                // permission request; a turn another person started is
                // held to its input rules here.
                let gated = if subagent || !TURN_GATED.contains(&tool) {
                    Ok(())
                } else {
                    let mut input = req.as_object().cloned().unwrap_or_default();
                    input.remove("tool");
                    input.remove("from");
                    served.orchestrator.as_ref().map_or(Ok(()), |o| {
                        o.turn_gate(&format!("mcp__optchat__{tool}"), &Value::Object(input))
                    })
                };
                let answer = match gated.and_then(|()| Call::parse(tool, &req)) {
                    // A subagent tells another subagent (acp-chief-issues.md
                    // #11), as the one its session is; never as the Chief.
                    Ok(Call::Tell {
                        id, message, key, ..
                    }) if subagent => match (&served.orchestrator, caller()) {
                        (Some(o), Some(from)) => o.peer_tell(&from, &id, &message, key.as_deref()),
                        (Some(_), None) => Err(
                            "tell: only a subagent session of this Chief may tell another subagent"
                                .to_owned(),
                        ),
                        (None, _) => Err("this Chief host runs no subagents".to_owned()),
                    },
                    Ok(Call::Peers) => match &served.orchestrator {
                        Some(o) => o.peers(&caller().unwrap_or_default()),
                        None => Err("this Chief host runs no subagents".to_owned()),
                    },
                    Ok(
                        Call::Spawn { .. }
                        | Call::React { .. }
                        | Call::Reply { .. }
                        | Call::Send(_)
                        | Call::Transcript { .. }
                        | Call::Stop
                        | Call::Sleep(_)
                        | Call::Watch(_)
                        | Call::Remember { .. }
                        | Call::Control(_)
                        | Call::CloudWorkspace(_)
                        | Call::Profile { .. }
                        | Call::Chiefs { .. },
                    ) if subagent => Err(
                        "subagents have no spawn, cloud_workspace, react, reply, send, transcript, stop, sleep, watch, remember, control, profile or chiefs"
                            .to_owned(),
                    ),
                    // `chiefs` only for this host's own turn: the turn key the
                    // host gave its turn sessions alone, from a caller that
                    // runs under one of them (rule C: a subagent, any other
                    // session or process, with the key or not, gets nothing).
                    Ok(Call::Chiefs { args, turn_key }) => match &served.chief {
                        Some(chief)
                            if chief.is_turn(turn_key.as_deref())
                                && role() == crate::turn_caller::Role::Turn =>
                        {
                            let answer = chief.chiefs_call(&args);
                            match &served.peers {
                                Some(peers) => peers.merge_list(&args, answer),
                                None => answer,
                            }
                        }
                        Some(_) => Err(NOT_THE_TURN.to_owned()),
                        None => Err(crate::chief_profile::Grant::refusal("chiefs")),
                    },
                    // The person's grant (chief_profile.rs), by the tool's name.
                    // cloud_workspace rides on the spawn grant: both start work elsewhere.
                    Ok(Call::Spawn { .. } | Call::CloudWorkspace(_))
                        if grant.is_some_and(|g| !g.allows("spawn")) =>
                    {
                        Err(crate::chief_profile::Grant::refusal("spawn"))
                    }
                    // control rides on the tell grant: both steer subagents.
                    Ok(Call::Tell { .. } | Call::Control(_))
                        if grant.is_some_and(|g| !g.allows("tell")) =>
                    {
                        Err(crate::chief_profile::Grant::refusal("tell"))
                    }
                    // A Chief on another machine (peer_chiefs.rs), through the agent hub.
                    Ok(Call::Tell {
                        ref id,
                        ref message,
                        ref key,
                        ..
                    }) if id.trim().starts_with(crate::peer_chiefs::PREFIX) => {
                        match &served.peers {
                            Some(peers) => peers.tell(id, message, key.as_deref()),
                            None => Err(format!(
                                "tell: no peer Chiefs are set up on this host, so {id} cannot be reached (peer-chiefs.json)"
                            )),
                        }
                    }
                    Ok(Call::Profile { args }) => match &served.chief {
                        Some(chief) => chief.profile_call(&args),
                        None => Err(crate::chief_profile::Grant::refusal("profile")),
                    },
                    Ok(Call::Spawn {
                        tasks,
                        cwd,
                        effort,
                        place,
                    }) => match &served.orchestrator {
                        Some(o) => o.spawn_placed(tasks, cwd, effort, place),
                        None => Err("this Chief host runs no subagents".to_owned()),
                    },
                    Ok(Call::Tell {
                        id,
                        message,
                        key,
                        queue,
                    }) => match &served.orchestrator {
                        Some(o) => o.tell_with(&id, &message, key.as_deref(), queue),
                        None => Err("this Chief host runs no subagents".to_owned()),
                    },
                    Ok(Call::React { id, reaction }) => match &served.orchestrator {
                        Some(o) => o.react(id, &reaction),
                        None => Err("this Chief host has no conversation to react in".to_owned()),
                    },
                    Ok(Call::Reply { id, text }) => match &served.orchestrator {
                        Some(o) => o.reply(id, &text),
                        None => Err("this Chief host has no conversation to reply in".to_owned()),
                    },
                    Ok(Call::Transcript { n, before }) => match &served.orchestrator {
                        Some(o) => o.transcript(n, before),
                        None => Err("this Chief host has no conversation to read".to_owned()),
                    },
                    Ok(Call::Send(call)) => match &served.orchestrator {
                        Some(o) => o.send(call),
                        None => Err("this Chief host has no conversation to send in".to_owned()),
                    },
                    Ok(Call::Stop) => match &served.orchestrator {
                        Some(o) => o.stop_turn(),
                        None => Err("this Chief host runs no turns".to_owned()),
                    },
                    Ok(Call::Sleep(call)) => match &served.orchestrator {
                        Some(o) => o.sleep(call),
                        None => Err("this Chief host runs no turns".to_owned()),
                    },
                    Ok(Call::Watch(call)) => match &served.orchestrator {
                        Some(o) => o.watch(call),
                        None => Err("this Chief host runs no turns".to_owned()),
                    },
                    Ok(Call::Remember { text }) => match &served.orchestrator {
                        Some(o) => o.remember(&text),
                        None => Err("this Chief host has no person profile to remember in".to_owned()),
                    },
                    Ok(Call::Control(request)) => match &served.orchestrator {
                        Some(o) => o.control(request),
                        None => Err("this Chief host runs no subagents".to_owned()),
                    },
                    Ok(Call::CloudWorkspace(request)) => match &served.orchestrator {
                        Some(o) => o.cloud_workspace(&request),
                        None => Err(
                            "cloud_workspace: this Chief host has no cmux app to make Cloud workspaces in"
                                .to_owned(),
                        ),
                    },
                    // Only a subagent escalates; its id comes from its bound
                    // session when there is one, else from what it says.
                    Ok(Call::EscalateAuth { request, agent }) => {
                        let bound = match (&served.turn, peer) {
                            (Some(binding), Some(pid)) => binding.subagent_of(pid),
                            _ => None,
                        };
                        match (&served.orchestrator, bound.or(agent)) {
                            (_, None) if !subagent => Err(
                                "escalate_auth is a subagent's tool; the Chief drives sign-ins itself"
                                    .to_owned(),
                            ),
                            (_, None) => Err(
                                "escalate_auth: cannot tell which subagent you are; pass `agent` (a<N>)"
                                    .to_owned(),
                            ),
                            (Some(o), Some(id)) => o.escalate_auth(&id, &request),
                            (None, Some(_)) => Err("this Chief host runs no subagents".to_owned()),
                        }
                    }
                    // A subagent may read another's chat too (the reference
                    // client gives zoom to every agent).
                    Ok(Call::ZoomAgent { id, at }) => match &served.orchestrator {
                        Some(o) => o.agent_chat(&id, at),
                        None => Err("this Chief host runs no subagents".to_owned()),
                    },
                    Ok(call) => Ok(call.answer(memory)),
                    Err(e) => Err(e),
                };
                match answer {
                    Ok(text) => json!({"text": text}),
                    Err(e) => json!({"error": e}),
                }
            }
            Err(e) => json!({"error": format!("bad request: {e}")}),
        };
        if writeln!(out, "{answer}").is_err() {
            return;
        }
    }
}

/// The answer to a `chiefs` call without this host's turn key.
pub const NOT_THE_TURN: &str = "chiefs: only this Chief's own turn may use it";

/// `call` with this process's turn key ([`crate::chief_profile::TURN_KEY_ENV`],
/// which only the host's own turn sessions have) when it is a `chiefs` call.
pub fn with_turn_key(call: Call) -> Call {
    match call {
        Call::Chiefs {
            args,
            turn_key: None,
        } => Call::Chiefs {
            args,
            turn_key: std::env::var(crate::chief_profile::TURN_KEY_ENV)
                .ok()
                .filter(|k| !k.is_empty()),
        },
        other => other,
    }
}

/// Asks the host on `path`; Err when it does not answer.
pub fn ask(path: &Path, call: Call) -> Result<String, String> {
    ask_json(path, &call.to_json())
}

/// `call` with the caller's own subagent id when it is an `escalate_auth`
/// that names none: from `ACPMUX_SESSION_NAME` (acpmux sets it for every
/// agent it starts, and a subagent's tools inherit it).
pub fn with_caller(call: Call, session_name: Option<&str>) -> Call {
    match call {
        Call::EscalateAuth {
            request,
            agent: None,
        } => Call::EscalateAuth {
            request,
            agent: session_name.and_then(subagent_of_session),
        },
        other => other,
    }
}

/// Asks the host on `path` as a subagent's tools (no spawn, no tell).
pub fn ask_as(path: &Path, call: Call, subagent: bool) -> Result<String, String> {
    let name = std::env::var("ACPMUX_SESSION_NAME").ok();
    let call = with_caller(call, name.as_deref());
    let mut request = call.to_json();
    if subagent {
        request["from"] = json!("subagent");
    }
    ask_json(path, &request)
}

/// The model tools the live host grants (`spawn,tell,profile`, `none`).
pub fn ask_grant(path: &Path) -> Result<String, String> {
    ask_json(path, &json!({"tool": "grant"}))
}

/// Shows (None) or sets (`Some((key, value))`) the live host's settings.
pub fn ask_settings(path: &Path, set: Option<(&str, &str)>) -> Result<String, String> {
    let request = match set {
        Some((key, value)) => json!({"tool": "settings", "key": key, "value": value}),
        None => json!({"tool": "settings"}),
    };
    ask_json(path, &request)
}

/// The live host's policy floor for a child spawned now (`Some("ask")`),
/// or None. Err when no host answers: the caller fails closed.
pub fn ask_spawn_policy(path: &Path) -> Result<Option<String>, String> {
    let text = ask_json(path, &json!({"tool": "spawn_policy"}))?;
    Ok((!text.is_empty()).then_some(text))
}

/// The browse page from the live host; Err when no host answers on `path`.
pub fn ask_browse(path: &Path) -> Result<String, String> {
    ask_json(path, &json!({"tool": "browse"}))
}

fn ask_json(path: &Path, request: &Value) -> Result<String, String> {
    let mut conn = UnixStream::connect(path)
        .map_err(|e| format!("the Chief host is not running ({}: {e})", path.display()))?;
    // spawn waits for the view to settle (subagents.rs SETTLE_LIMIT, 1 s)
    // and for its sessions to start.
    conn.set_read_timeout(Some(Duration::from_secs(300)))
        .map_err(|e| e.to_string())?;
    writeln!(conn, "{request}").map_err(|e| e.to_string())?;
    let mut line = String::new();
    BufReader::new(conn)
        .read_line(&mut line)
        .map_err(|e| format!("reading the answer: {e}"))?;
    let answer: Value = serde_json::from_str(&line).map_err(|e| format!("bad answer: {e}"))?;
    match (
        answer.get("text").and_then(Value::as_str),
        answer.get("error").and_then(Value::as_str),
    ) {
        (Some(text), _) => Ok(text.to_owned()),
        (None, Some(error)) => Err(error.to_owned()),
        (None, None) => Err("empty answer".to_owned()),
    }
}
