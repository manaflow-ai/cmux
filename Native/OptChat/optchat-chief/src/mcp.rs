//! `optchat-chief mcp --socket PATH`: a stdio MCP server with the two memory
//! tools, which forwards each call to the running host (tools.rs). The tool
//! descriptions are the spec's, verbatim (section 7.1), and the list never
//! changes, so the turn's tool list stays byte-identical (section 7.2).

use std::io::{BufRead, Write};
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use crate::prompt::{
    AUTOMATION_DESCRIPTION, CLOUD_WORKSPACE_DESCRIPTION, CONTROL_DESCRIPTION, DATE_DESCRIPTION,
    ESCALATE_AUTH_DESCRIPTION, PEER_TELL_DESCRIPTION, PEERS_DESCRIPTION, REACT_DESCRIPTION,
    REMEMBER_DESCRIPTION, REPLY_DESCRIPTION, SEND_DESCRIPTION, SLEEP_DESCRIPTION,
    SPAWN_CWD_DESCRIPTION, SPAWN_DESCRIPTION, STOP_DESCRIPTION, TELL_DESCRIPTION,
    TRANSCRIPT_DESCRIPTION, VERSION_DESCRIPTION, ZOOM_AGENT_DESCRIPTION, ZOOM_DESCRIPTION,
};
use crate::tools::{self, Call};

/// The MCP revision this server speaks when the client names none it knows.
const PROTOCOL: &str = "2025-06-18";
const KNOWN: [&str; 4] = ["2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"];

/// The Chief's tools: zoom, date, spawn and tell (section 9).
pub fn tool_list() -> Value {
    tools_for(false)
}

/// A subagent gets zoom and date, not spawn (section 9); the Chief all four.
pub fn tools_for(subagent: bool) -> Value {
    tools_granted(subagent, &crate::chief_profile::Grant::all())
}

/// The list for a Chief whose person granted `grant` (chief_profile.rs):
/// zoom and date always, then spawn, tell, profile and chiefs when granted,
/// then react and reply (a Chief's own conversation, always).
pub fn tools_granted(subagent: bool, grant: &crate::chief_profile::Grant) -> Value {
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
            "kind": {"type": "string", "enum": crate::tools::AUTH_KINDS, "description": "password, passkey, 2fa (a code or security key after the password) or oauth (a Sign in with ... page)."}},
          "required": ["site", "url", "reason", "kind"], "additionalProperties": false}}));
        list.push(json!({"name": "peers", "description": PEERS_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}}));
        list.push(json!({"name": "tell", "description": PEER_TELL_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"id": text, "message": text, "key": {"type": "string", "minLength": 1, "description": "Optional idempotency key: a repeat with the same key is not sent again."}}, "required": ["id", "message"], "additionalProperties": false}}));
    }
    if !subagent && grant.allows("spawn") {
        list.push(json!({"name": "spawn", "description": SPAWN_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"tasks": {"type": "array", "items": text, "minItems": 1}, "cwd": {"type": "string", "minLength": 1, "description": SPAWN_CWD_DESCRIPTION}, "effort": {"type": "string", "enum": crate::tools::EFFORTS, "description": "How hard they think; by default, as hard as you."}, "place": {"type": "string", "enum": crate::tools::PLACES, "description": "cloud: in the cloud (with `control cloud freestyle` its own Freestyle VM; cloud:small for design/docs/edits, cloud:medium for bun/node/go tests, cloud:large only when asked; Swift/Rust/app builds go to the Mac-mini fleet); local: on this Mac (its app, UI, screenshots, computer use, sign-ins). By default: the `control cloud` setting, and a task that needs the Mac stays here."}}, "required": ["tasks"], "additionalProperties": false}}));
    }
    if !subagent && grant.allows("tell") {
        list.push(json!({"name": "tell", "description": TELL_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {"id": text, "message": text, "key": {"type": "string", "minLength": 1, "description": "Optional idempotency key: a repeat with the same key is not sent again."}, "queue": {"type": "boolean", "description": "true: a low-priority FYI that waits for the running turn to end. Default false: it is steered in, else the turn is interrupted and this is its next prompt."}}, "required": ["id", "message"], "additionalProperties": false}}));
        list.push(json!({"name": "control", "description": CONTROL_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "action": {"type": "string", "enum": crate::tools::CONTROL_ACTIONS},
            "id": {"type": "string", "minLength": 1, "description": "The subagent (a<N>); status without it shows all."},
            "message": {"type": "string", "minLength": 1, "description": "interrupt/restart/resume: the prompt sent once it has stopped."},
            "option": {"type": "string", "minLength": 1, "description": "answer: deny (only the user can allow, in the app)."},
            "n": {"type": "integer", "minimum": 0, "description": "cap: subagents at work at once; 0 is no cap."},
            "peer": {"type": "string", "minLength": 1, "description": "cloud: the acpmux peers (acpmux host ls, comma-separated) new subagents run on by default, each on the least busy, or off; without it, shows the setting."}},
          "required": ["action"], "additionalProperties": false}}));
    }
    // A Cloud machine and its workspace for a task: on the spawn grant.
    if !subagent && grant.allows("spawn") {
        list.push(json!({"name": "cloud_workspace", "description": CLOUD_WORKSPACE_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "title": {"type": "string", "minLength": 1, "description": "The task in 2-5 words: the machine's name (lowercased, with dashes) and its sidebar group."},
            "size": {"type": "string", "enum": crate::cloud_workspace::SIZES, "description": "The machine's size; by default the app's. small for docs and edits, medium for builds and tests; large or xlarge only when asked."},
            "machine": {"type": "string", "minLength": 1, "description": "An existing Cloud machine (machine:<id> from `cmux cloud list-machines`): open another workspace on it instead of making a machine."}},
          "required": ["title"], "additionalProperties": false}}));
    }
    if !subagent && grant.allows("profile") {
        list.push(crate::chief_profile::profile_tool());
    }
    if !subagent && grant.allows("chiefs") {
        list.push(crate::chief_profile::chiefs_tool());
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
            "attachments": {"type": "array", "items": text, "maxItems": crate::tools::MAX_SEND_ATTACHMENTS, "description": "Files to attach: local paths (/abs, ~/rel, file://; images and videos show inline, any other file as a file, up to 50 MB each) or http(s) URLs (a link card)."},
            "reply_to": {"type": "integer", "minimum": 0, "description": "A user message's line id: the message goes into its thread. Without it: the top level."}},
          "additionalProperties": false}}));
        list.push(json!({"name": "transcript", "description": TRANSCRIPT_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "n": {"type": "integer", "minimum": 1, "maximum": crate::brain::TRANSCRIPT_MAX, "description": "How many messages, newest last (default 20)."},
            "before": {"type": "integer", "minimum": 1, "description": "A message's #seq: only messages older than it (to page back)."}},
          "additionalProperties": false}}));
        list.push(json!({"name": "stop", "description": STOP_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {}, "additionalProperties": false}}));
        list.push(json!({"name": "sleep", "description": SLEEP_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "seconds": {"type": "integer", "minimum": 0, "maximum": crate::tools::SLEEP_MAX_SECONDS, "description": "30 to 86400 seconds until the wake; 0 clears every pending wake."},
            "note": {"type": "string", "description": "What to do when you wake: shown to you in the wake message."},
            "until": {"type": "string", "enum": ["time", "event"], "description": "time (default): wake at the time whatever happens. event: a user message or subagent report that comes first replaces the wake."}},
          "required": ["seconds"], "additionalProperties": false}}));
        list.push(json!({"name": "automation", "description": AUTOMATION_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "action": {"type": "string", "enum": crate::automations::ACTIONS, "description": "add: make one; list: see them all; pause, resume, delete, run (now): one by id."},
            "id": {"type": "string", "minLength": 1, "description": "pause, resume, delete, run: the automation (au<N>)."},
            "name": {"type": "string", "minLength": 1, "maxLength": crate::automations::NAME_MAX, "description": "add: a short name the person sees in Chief settings, e.g. \"Morning PR summary\"."},
            "prompt": {"type": "string", "minLength": 1, "maxLength": crate::automations::PROMPT_MAX, "description": "add: the whole task you do at each fire, standing alone (you will not see this turn then)."},
            "cron": {"type": "string", "minLength": 1, "description": "add, a schedule: five fields in this Mac's time zone (minute hour day-of-month month day-of-week), e.g. \"0 9 * * *\" every day at 9, \"0 9 * * 1-5\" weekdays; or @hourly, @daily, @weekly."},
            "event": {"type": "string", "enum": crate::automations::EVENTS, "description": "add, an event instead of cron: agent_done (one of your subagents finished). Each event fires it once."},
            "match": {"type": "string", "minLength": 1, "description": "agent_done: only subagents whose title has this text."}},
          "additionalProperties": false}}));
        list.push(json!({"name": "remember", "description": REMEMBER_DESCRIPTION,
         "inputSchema": {"type": "object", "properties": {
            "text": {"type": "string", "minLength": 1, "maxLength": crate::remember::REMEMBER_MAX, "description": "The preference as one short rule in the person's own terms, e.g. \"Reply in one short bullet list.\""}},
          "required": ["text"], "additionalProperties": false}}));
    }
    Value::Array(list)
}

/// How a tool call reaches the memory: the host socket, or a test memory.
pub trait Backend {
    fn call(&self, call: Call) -> Result<String, String>;
    /// A subagent's server: zoom and date only.
    fn subagent(&self) -> bool {
        false
    }
    /// The Chief home this server belongs to (the move tool), if known.
    fn home(&self) -> Option<PathBuf> {
        None
    }
    /// The model tools this Chief may use (asked of the host at tools/list).
    fn grant(&self) -> crate::chief_profile::Grant {
        crate::chief_profile::Grant::all()
    }
    /// The `version` tool's answer (version_tool.rs). It runs here, in the
    /// MCP server, never through the host: it only reads.
    fn version(&self) -> Result<String, String> {
        Ok(crate::version_tool::answer(&crate::paths::mux_home()))
    }
}

/// The host socket; `subagent` marks a subagent's server (no spawn, tell).
pub struct SocketBackend(pub PathBuf, pub bool);

impl Backend for SocketBackend {
    fn call(&self, call: Call) -> Result<String, String> {
        tools::ask_as(&self.0, tools::with_turn_key(call), self.1)
    }

    fn subagent(&self) -> bool {
        self.1
    }

    /// `<home>/optchat/tools.sock`: the home is two levels up.
    fn home(&self) -> Option<PathBuf> {
        self.0.parent()?.parent().map(Path::to_path_buf)
    }

    /// The live host's grant. A host that does not answer the question (an
    /// older host) grants what it always did; one that cannot be reached
    /// answers no tool call either, so zoom and date alone are listed.
    fn grant(&self) -> crate::chief_profile::Grant {
        match tools::ask_grant(&self.0) {
            Ok(value) => crate::chief_profile::Grant::from_mcp_value(Some(&value)),
            Err(e) if e.contains("unknown tool") => crate::chief_profile::Grant::all(),
            Err(_) => crate::chief_profile::Grant::from_mcp_value(Some("none")),
        }
    }
}

/// The answer to one JSON-RPC message, or None for a notification.
pub fn handle(message: &Value, backend: &dyn Backend) -> Option<Value> {
    let id = message.get("id").cloned()?;
    let method = message.get("method").and_then(Value::as_str).unwrap_or("");
    let params = message.get("params").cloned().unwrap_or(Value::Null);
    let result = match method {
        "initialize" => {
            let asked = params
                .get("protocolVersion")
                .and_then(Value::as_str)
                .unwrap_or("");
            let version = if KNOWN.contains(&asked) {
                asked
            } else {
                PROTOCOL
            };
            Ok(json!({
                "protocolVersion": version,
                "capabilities": {"tools": {"listChanged": false}},
                "serverInfo": {"name": "optchat", "version": env!("CARGO_PKG_VERSION")},
            }))
        }
        "ping" => Ok(json!({})),
        "tools/list" => Ok(json!({"tools": if backend.subagent() {
            tools_for(true)
        } else {
            tools_granted(false, &backend.grant())
        }})),
        "tools/call" => {
            let name = params.get("name").and_then(Value::as_str).unwrap_or("");
            let args = params.get("arguments").cloned().unwrap_or(json!({}));
            let answer = if name == "version" {
                backend.version()
            } else if name == "move" {
                match (backend.subagent(), backend.home()) {
                    (true, _) => Err(format!("unknown tool {name}")),
                    (false, None) => Err("move: this server does not know its Chief home".into()),
                    (false, Some(home)) => move_call(&home, &args),
                }
            } else {
                Call::parse(name, &args).and_then(|call| match call {
                    Call::Spawn { .. }
                    | Call::React { .. }
                    | Call::Reply { .. }
                    | Call::Send(_)
                    | Call::Transcript { .. }
                    | Call::Stop
                    | Call::Sleep(_)
                    | Call::Remember { .. }
                    | Call::Control(_)
                    | Call::Automation(_)
                    | Call::CloudWorkspace(_)
                    | Call::Profile { .. }
                    | Call::Chiefs { .. }
                        if backend.subagent() =>
                    {
                        Err(format!("unknown tool {name}"))
                    }
                    call => backend.call(call),
                })
            };
            Ok(match answer {
                Ok(text) => json!({"content": [{"type": "text", "text": text}], "isError": false}),
                Err(error) => {
                    json!({"content": [{"type": "text", "text": error}], "isError": true})
                }
            })
        }
        _ => Err(json!({"code": -32601, "message": format!("method not found: {method}")})),
    };
    Some(match result {
        Ok(result) => json!({"jsonrpc": "2.0", "id": id, "result": result}),
        Err(error) => json!({"jsonrpc": "2.0", "id": id, "error": error}),
    })
}

/// Serves newline-delimited JSON-RPC on `input` and `output` until EOF.
pub fn serve(
    input: impl BufRead,
    mut output: impl Write,
    backend: &dyn Backend,
) -> std::io::Result<()> {
    for line in input.lines() {
        let line = line?;
        if line.trim().is_empty() {
            continue;
        }
        let answer = match serde_json::from_str::<Value>(&line) {
            Ok(message) => handle(&message, backend),
            Err(e) => Some(
                json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": e.to_string()}}),
            ),
        };
        if let Some(answer) = answer {
            writeln!(output, "{answer}")?;
            output.flush()?;
        }
    }
    Ok(())
}

/// The `mcp` subcommand (`--subagent`: a subagent's server).
pub fn run(socket: &Path, subagent: bool) -> std::io::Result<()> {
    let stdin = std::io::stdin();
    serve(
        stdin.lock(),
        std::io::stdout().lock(),
        &SocketBackend(socket.to_owned(), subagent),
    )
}

/// The `move` tool (plans/cmux-next/chief-migration-DESIGN.md section 8):
/// the Chief moves itself. `dry_run` checks the target and answers at once;
/// a real move runs `optchat-chief move --detach`, which waits for this turn
/// to end, stops the host, and writes its report to `state/move.json`.
/// `status` reads that report, `reach` probes what this home reached before
/// a move, `rollback` lets the old copy answer again.
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

/// Runs the move tool for the Chief of `home` with this binary.
pub fn move_call(home: &Path, args: &Value) -> Result<String, String> {
    let action = args["action"].as_str().unwrap_or("move");
    let exe = std::env::current_exe().map_err(|e| e.to_string())?;
    let mut argv: Vec<String> = vec!["move".into()];
    match action {
        "status" => {
            return std::fs::read_to_string(home.join("state").join("move.json"))
                .map_err(|_| "no move has run from this home".to_owned());
        }
        "reach" => argv.push("reach".into()),
        "rollback" => argv.push("rollback".into()),
        "move" => {
            let to = args["to"].as_str().ok_or("move needs `to`")?;
            argv.extend(["--to".into(), to.into()]);
            argv.push(
                if args["dry_run"] == true {
                    "--dry-run"
                } else {
                    "--detach"
                }
                .into(),
            );
            if args["without_transcripts"] == true {
                argv.push("--without-transcripts".into());
            }
            if let Some(name) = args["name"].as_str() {
                argv.extend(["--name".into(), name.into()]);
            }
        }
        other => return Err(format!("unknown move action {other}")),
    }
    for (key, flag) in [
        ("remote_bin", "--remote-bin"),
        ("session_token_file", "--session-token-file"),
    ] {
        if let Some(v) = args[key].as_str() {
            argv.extend([flag.into(), v.into()]);
        }
    }
    argv.extend(["--home".into(), home.to_string_lossy().into_owned()]);
    let out = std::process::Command::new(exe)
        .args(&argv)
        .stdin(std::process::Stdio::null())
        .output()
        .map_err(|e| e.to_string())?;
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    if out.status.success() {
        Ok(text)
    } else {
        Err(text)
    }
}
