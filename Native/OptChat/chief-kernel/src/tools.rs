//! The Chief's tool contract: the tool list every engine offers (the host's
//! MCP server, the Cloud Chief's pi tools), with the limits the schemas name,
//! and each tool's replay flag for a durable engine (section 13, export 2).

use serde_json::{Value, json};

use crate::prompt::{
    CLOUD_WORKSPACE_DESCRIPTION, CONTROL_DESCRIPTION, DATE_DESCRIPTION, ESCALATE_AUTH_DESCRIPTION,
    PEER_TELL_DESCRIPTION, PEERS_DESCRIPTION, REACT_DESCRIPTION, REMEMBER_DESCRIPTION,
    REPLY_DESCRIPTION, SEND_DESCRIPTION, SLEEP_DESCRIPTION, SPAWN_CWD_DESCRIPTION,
    SPAWN_DESCRIPTION, SPAWN_HARNESS_DESCRIPTION, STOP_DESCRIPTION, TELL_DESCRIPTION,
    TRANSCRIPT_DESCRIPTION, VERSION_DESCRIPTION, WATCH_DESCRIPTION, ZOOM_AGENT_DESCRIPTION,
    ZOOM_DESCRIPTION,
};

/// Most attachments one `send` takes.
pub const MAX_SEND_ATTACHMENTS: usize = 10;

/// Shortest `sleep` (a turn costs more than a shorter wait saves).
pub const SLEEP_MIN_SECONDS: u64 = 30;
/// Longest `sleep`: a day.
pub const SLEEP_MAX_SECONDS: u64 = 86_400;

/// A `watch` with no `timeout_seconds` fires as timed out after 30 min.
pub const WATCH_DEFAULT_SECONDS: u64 = 1_800;
/// Shortest `watch` timeout.
pub const WATCH_MIN_SECONDS: u64 = 10;
/// Longest `watch` timeout: a day.
pub const WATCH_MAX_SECONDS: u64 = 86_400;
/// How long a `watch` waits before it runs a command that exited without
/// matching `until` again.
pub const WATCH_POLL_SECONDS: u64 = 15;
/// Most watches pending at once.
pub const WATCHES_KEPT: usize = 8;

/// The kinds of sign-in `escalate_auth` takes.
pub const AUTH_KINDS: [&str; 4] = ["password", "passkey", "2fa", "oauth"];

/// The efforts `spawn` takes (acpmux maps them onto the harness's own).
pub const EFFORTS: [&str; 5] = ["low", "medium", "high", "xhigh", "max"];

/// Where `spawn` runs its subagents (`place`).
/// `cloud:SIZE` also picks the VM size with one VM per subagent.
pub const PLACES: [&str; 5] = [
    "cloud",
    "local",
    "cloud:small",
    "cloud:medium",
    "cloud:large",
];

/// The `control` tool's actions.
pub const CONTROL_ACTIONS: [&str; 13] = [
    "status",
    "interrupt",
    "answer",
    "pause",
    "resume",
    "cancel",
    "restart",
    "priority",
    "show",
    "hide",
    "cap",
    "cloud",
    "sessions",
];

/// The sizes `cmux cloud new-machine --size` takes.
pub const SIZES: [&str; 4] = ["small", "medium", "large", "xlarge"];

/// The most messages one `transcript` call returns.
pub const TRANSCRIPT_MAX: u32 = 100;

/// The longest preference `remember` keeps, in characters.
pub const REMEMBER_MAX: usize = 400;

/// The `profile` tool's definition, shared with the docs.
const TOOL_FILE: &str = include_str!("../../../../schemas/chief-profile/tool.json");

/// The `chiefs` tool's definition.
const CHIEFS_TOOL_FILE: &str = include_str!("../../../../schemas/chief-profile/chiefs-tool.json");

/// The `profile` tool (name, description, input schema).
pub fn profile_tool() -> Value {
    let file: Value = serde_json::from_str(TOOL_FILE).unwrap_or_else(|_| json!({}));
    file.get("tool")
        .cloned()
        .unwrap_or_else(|| json!({"name": "profile"}))
}

/// The `chiefs` tool (name, description, input schema).
pub fn chiefs_tool() -> Value {
    let file: Value = serde_json::from_str(CHIEFS_TOOL_FILE).unwrap_or_else(|_| json!({}));
    file.get("tool")
        .cloned()
        .unwrap_or_else(|| json!({"name": "chiefs"}))
}

pub const MOVE_DESCRIPTION: &str = "Move yourself (your memory, conversations, settings, subagent transcripts and grants) to another machine, or back. action move (default): to = ssh:HOST[:DIR] (a Mac mini or a Linux VM you reach over SSH), local:DIR, or cloud / cloud:staging (the hosted Cloud Chief; needs the person's cloud session token file). Run dry_run true first and tell the person what it found; a real move starts when this turn ends, stops you here and keeps this copy for rollback, so say goodbye in this turn. status: the last move's report. reach: after a move, which SSH hosts, tailnet, fleet and model route answer from this machine. rollback: the old copy answers again. Keys and tokens are never copied: missing ones come back as blockers to give the person.";

/// The move tool's schema.
pub fn move_tool() -> Value {
    json!({"name": "move", "description": MOVE_DESCRIPTION,
     "inputSchema": {"type": "object", "properties": {
        "action": {"type": "string", "enum": ["move", "status", "reach", "rollback"]},
        "to": {"type": "string", "minLength": 1},
        "dry_run": {"type": "boolean"},
        "without_transcripts": {"type": "boolean", "description": "Leave subagent transcripts behind (smaller move)."},
        "remote_bin": {"type": "string", "minLength": 1, "description": "The target's optchat-chief, when it is not on its PATH and the target's OS differs from this one."},
        "session_token_file": {"type": "string", "minLength": 1, "description": "cloud: the person's session token file (0600); never read it aloud."},
        "name": {"type": "string", "minLength": 1, "description": "cloud: the hosted Chief's name (default Chief)."}},
      "additionalProperties": false}})
}

/// The list for a Chief (or, with `subagent`, a subagent) whose grant
/// `allows` a tool name: zoom and date always, then spawn, tell, profile and
/// chiefs when granted, then react, reply and the Chief's own words. The
/// order and the text never change, so the tool list stays byte-identical
/// across turns (section 7.2).
pub fn tool_list(subagent: bool, allows: &dyn Fn(&str) -> bool) -> Value {
    let int = json!({"type": "integer", "minimum": 0});
    let text = json!({"type": "string", "minLength": 1});
    let mut list = vec![
        json!({"name": "zoom", "description": format!("{ZOOM_DESCRIPTION}{ZOOM_AGENT_DESCRIPTION}"),
         "inputSchema": {"type": "object", "properties": {"id": {"type": ["integer", "string"]}, "n": int, "at": int}, "required": ["id"], "additionalProperties": false}}),
        json!({"name": "date", "description": DATE_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"id": int}, "required": ["id"], "additionalProperties": false}}),
    ];
    // A subagent asks its Chief to drive a sign-in, lists the other
    // subagents and tells one (acp-chief-issues.md #11).
    if subagent {
        list.push(json!({"name": "escalate_auth", "description": ESCALATE_AUTH_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "site": {"type": "string", "minLength": 1, "description": "The site's host name, for example npmjs.com."},
            "url": {"type": "string", "minLength": 1, "description": "The http(s) page where the sign-in starts."},
            "reason": {"type": "string", "minLength": 1, "description": "One line: what you need the sign-in for."},
            "kind": {"type": "string", "enum": AUTH_KINDS, "description": "password, passkey, 2fa (a code or security key after the password) or oauth (a Sign in with ... page)."}},
          "required": ["site", "url", "reason", "kind"], "additionalProperties": false}}));
        list.push(json!({"name": "peers", "description": PEERS_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}}));
        list.push(json!({"name": "tell", "description": PEER_TELL_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"id": text, "message": text, "key": {"type": "string", "minLength": 1, "description": "Optional idempotency key: a repeat with the same key is not sent again."}}, "required": ["id", "message"], "additionalProperties": false}}));
    }
    if !subagent && allows("spawn") {
        list.push(json!({"name": "spawn", "description": SPAWN_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"tasks": {"type": "array", "items": text, "minItems": 1}, "cwd": {"type": "string", "minLength": 1, "description": SPAWN_CWD_DESCRIPTION}, "effort": {"type": "string", "enum": EFFORTS, "description": "How hard they think; by default, as hard as you."}, "place": {"type": "string", "enum": PLACES, "description": "cloud: in the cloud (with `control cloud freestyle` its own Freestyle VM; cloud:small for design/docs/edits, cloud:medium for bun/node/go tests, cloud:large only when asked; Swift/Rust/app builds go to the Mac-mini fleet); local: on this Mac (its app, UI, screenshots, computer use, sign-ins). By default: the `control cloud` setting, and a task that needs the Mac stays here."}, "harness": {"type": "string", "minLength": 1, "description": SPAWN_HARNESS_DESCRIPTION}}, "required": ["tasks"], "additionalProperties": false}}));
    }
    if !subagent && allows("tell") {
        list.push(json!({"name": "tell", "description": TELL_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"id": text, "message": text, "key": {"type": "string", "minLength": 1, "description": "Optional idempotency key: a repeat with the same key is not sent again."}, "queue": {"type": "boolean", "description": "true: a low-priority FYI that waits for the running turn to end. Default false: it is steered in, else the turn is interrupted and this is its next prompt."}}, "required": ["id", "message"], "additionalProperties": false}}));
        list.push(json!({"name": "control", "description": CONTROL_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "action": {"type": "string", "enum": CONTROL_ACTIONS},
            "id": {"type": "string", "minLength": 1, "description": "The subagent (a<N>); status without it shows all."},
            "message": {"type": "string", "minLength": 1, "description": "interrupt/restart/resume: the prompt sent once it has stopped."},
            "option": {"type": "string", "minLength": 1, "description": "answer: deny (only the user can allow, in the app)."},
            "n": {"type": "integer", "minimum": 0, "description": "cap: subagents at work at once; 0 is no cap."},
            "peer": {"type": "string", "minLength": 1, "description": "cloud: the acpmux peers (acpmux host ls, comma-separated) new subagents run on by default, each on the least busy, or off; without it, shows the setting."}},
          "required": ["action"], "additionalProperties": false}}));
    }
    // A Cloud machine and its workspace for a task: on the spawn grant.
    if !subagent && allows("spawn") {
        list.push(json!({"name": "cloud_workspace", "description": CLOUD_WORKSPACE_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "title": {"type": "string", "minLength": 1, "description": "The task in 2-5 words: the machine's name (lowercased, with dashes) and its sidebar group."},
            "size": {"type": "string", "enum": SIZES, "description": "The machine's size; by default the app's. small for docs and edits, medium for builds and tests; large or xlarge only when asked."},
            "machine": {"type": "string", "minLength": 1, "description": "An existing Cloud machine (machine:<id> from `cmux cloud list-machines`): open another workspace on it instead of making a machine."}},
          "required": ["title"], "additionalProperties": false}}));
    }
    if !subagent && allows("profile") {
        list.push(profile_tool());
    }
    if !subagent && allows("chiefs") {
        list.push(chiefs_tool());
    }
    // Read-only, for the Chief and its subagents: never a grant to withhold.
    list.push(
        json!({"name": "version", "description": VERSION_DESCRIPTION,
     "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}}),
    );
    // Moving itself to another machine (migrate.rs): the Chief's own home.
    if !subagent {
        list.push(move_tool());
    }
    // The Chief's own words in its conversation: never a grant to withhold.
    if !subagent {
        list.push(json!({"name": "react", "description": REACT_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"id": int, "reaction": {"type": "string", "description": crate::prompt::REACT_REACTION_DESCRIPTION}}, "required": ["id", "reaction"], "additionalProperties": false}}));
        list.push(json!({"name": "reply", "description": REPLY_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"id": int, "text": text}, "required": ["id", "text"], "additionalProperties": false}}));
        list.push(json!({"name": "send", "description": SEND_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "text": {"type": "string", "description": "The message, in Markdown."},
            "attachments": {"type": "array", "items": text, "maxItems": MAX_SEND_ATTACHMENTS, "description": "Files to attach: local paths (/abs, ~/rel, file://; images and videos show inline, any other file as a file, up to 50 MB each) or http(s) URLs (a link card)."},
            "reply_to": {"type": "integer", "minimum": 0, "description": "A user message's line id: the message goes into its thread. Without it: the top level."}},
          "additionalProperties": false}}));
        list.push(json!({"name": "transcript", "description": TRANSCRIPT_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "n": {"type": "integer", "minimum": 1, "maximum": TRANSCRIPT_MAX, "description": "How many messages, newest last (default 20)."},
            "before": {"type": "integer", "minimum": 1, "description": "A message's #seq: only messages older than it (to page back)."}},
          "additionalProperties": false}}));
        list.push(json!({"name": "stop", "description": STOP_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}}));
        list.push(json!({"name": "sleep", "description": SLEEP_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "seconds": {"type": "integer", "minimum": 0, "maximum": SLEEP_MAX_SECONDS, "description": "30 to 86400 seconds until the wake; 0 clears every pending wake."},
            "note": {"type": "string", "description": "What to do when you wake: shown to you in the wake message."},
            "until": {"type": "string", "enum": ["time", "event"], "description": "time (default): wake at the time whatever happens. event: a user message or subagent report that comes first replaces the wake."}},
          "required": ["seconds"], "additionalProperties": false}}));
        list.push(json!({"name": "watch", "description": WATCH_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "command": {"type": "string", "minLength": 1, "description": "A shell command (sh -c) the host runs on this machine, off your turn: a streaming one (tail -f, gh run watch) or a short check, run again every 15 s while `until` does not match."},
            "until": {"type": "string", "minLength": 1, "description": "A regex on its output lines (stdout and stderr): the watch fires at the first match. Without it, the watch fires when the command exits."},
            "timeout_seconds": {"type": "integer", "minimum": WATCH_MIN_SECONDS, "maximum": WATCH_MAX_SECONDS, "description": "The watch fires as timed out after this (default 1800, at most 86400)."},
            "note": {"type": "string", "description": "What to do when it fires: shown to you in the watch message."},
            "cancel": {"type": "string", "minLength": 1, "description": "A watch id (w<N>) or all: cancels instead of starting one. With no command and no cancel, lists the pending watches."}},
          "additionalProperties": false}}));
        list.push(json!({"name": "remember", "description": REMEMBER_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "text": {"type": "string", "minLength": 1, "maxLength": REMEMBER_MAX, "description": "The preference as one short rule in the person's own terms, e.g. \"Reply in one short bullet list.\""}},
          "required": ["text"], "additionalProperties": false}}));
    }
    Value::Array(list)
}

/// Tools a durable engine must not run twice after a crash: each one starts
/// something new each call (an agent, a wake, a Chief, a move) or changes a
/// record. Every other tool only reads, or is deduped by its key.
const ONCE: &[&str] = &[
    "spawn",
    "tell",
    "control",
    "sleep",
    "watch",
    "profile",
    "chiefs",
    "move",
    "escalate_auth",
];

/// Tools only a host on the person's machine can do: the Mac's app
/// (`version`), moving the Chief's home (`move`) and running a command off
/// the turn (`watch`).
const HOST_ONLY: &[&str] = &["version", "move", "watch"];

/// The engines that take specs; a cloud engine drops the host-only tools.
const SPEC_ENGINES: &[(&str, bool)] = &[
    ("pi-durable", true),
    ("native", false),
    ("claude", false),
    ("codex", false),
];

/// The tool specs of `engine` for a Chief granted `grant_json`
/// (`{tools?: [names]}`; without `tools`, every tool but profile and chiefs,
/// as the host does for a Chief with no record): `[{name, description,
/// json_schema, replay: "safe" | "once"}]`.
pub fn specs(engine: &str, grant_json: &str) -> Result<Value, String> {
    let cloud = SPEC_ENGINES
        .iter()
        .find(|(e, _)| *e == engine)
        .map(|(_, cloud)| *cloud)
        .ok_or_else(|| format!("engine: no engine {engine:?}"))?;
    let grant: Value = serde_json::from_str(grant_json).map_err(|e| format!("grant: {e}"))?;
    let granted: Option<Vec<String>> = grant.get("tools").and_then(Value::as_array).map(|a| {
        a.iter()
            .filter_map(Value::as_str)
            .map(str::to_owned)
            .collect()
    });
    let allows = |tool: &str| match &granted {
        _ if matches!(tool, "zoom" | "date" | "version") => true,
        None => !matches!(tool, "profile" | "chiefs"),
        Some(set) => set.iter().any(|t| t == tool),
    };
    let list = tool_list(false, &allows);
    let out: Vec<Value> = list
        .as_array()
        .into_iter()
        .flatten()
        .filter(|t| !(cloud && HOST_ONLY.contains(&t["name"].as_str().unwrap_or(""))))
        .map(|t| {
            let name = t["name"].as_str().unwrap_or("");
            json!({
                "name": name,
                "description": t["description"],
                "json_schema": t["inputSchema"],
                "replay": if ONCE.contains(&name) { "once" } else { "safe" },
            })
        })
        .collect();
    Ok(Value::Array(out))
}
