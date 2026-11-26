//! The chat's own start tools (ask-b2eab8745d): list the machines this one reaches (`machines`),
//! start a Cloud machine or resume a paused one (`machine_start`), start a chat on any of them
//! (`new`) and fork a chat, here or on a peer (`fork`). Leo, 2026-11-20: "these paths ought to be
//! first class inside of the cmux chat blah blah cli commands that we can do / starting machines,
//! starting chats, all that, after you've connected to whatever or something".
//!
//! Each is the command the chat's agent could run in its shell, run here instead so the chat
//! draws a tool call with a typed answer, not a command block: `machines` and `new` run this
//! binary's own CLI (`acpmux --json machine ls`, `acpmux --json new --detach ... --prompt-file -`)
//! with the session's env, caller token included, so the daemon takes them as this session's
//! own, as from its Bash tool, and places, names and admits the chat exactly as the CLI does.
//! `fork` is the request `acpmux session fork` makes (`session/fork`) on this server's
//! connection, which carries the same caller token. `machine_start` runs `cmux vm resume NAME` or
//! `cmux vm new` (`CMUX_BIN`, else `cmux` on PATH): with the cmux app the app makes the machine
//! and asks the person to confirm an agent's create, as it does for that command in a shell.
//! None can do anything its CLI cannot. Unlike a guest's `new` (`acpmux_mcp_guest.rs`), a
//! session's start takes the policy and harness its CLI would: the session is the person's
//! agent, not an outside app.

use super::guest::{CliError, machine_rows, machines_text, new_result, run_bounded, session_name};
use super::*;
use cmux_json::JsonSet as _;

pub(super) const MACHINES: &str = "machines";
pub(super) const NEW: &str = "new";
pub(super) const FORK: &str = "fork";
pub(super) const MACHINE_START: &str = "machine_start";
pub(super) const TOOLS: &[&str] = &[MACHINES, NEW, FORK, MACHINE_START];
/// How long a start may take before the tool answers that it is still starting: under Codex's
/// 60 s MCP tool timeout. The command goes on.
const CLI_WAIT: Duration = Duration::from_secs(50);
// timeout: a read-only `machines` listing for the agent's tool call; past it the tool says so and nothing is lost
const MACHINES_WAIT: Duration = Duration::from_secs(20);

pub(super) fn tools() -> Vec<Value> {
    vec![
        json!({
            "name": MACHINES,
            "description": "List the machines cmux reaches from here: this machine, the person's paired machines and their cmux Cloud machines, each with its connection state and live sessions. Name one as new's machine.",
            "inputSchema": {"type": "object", "properties": {}}
        }),
        json!({
            "name": MACHINE_START,
            "description": "Start a cmux Cloud machine: resume a paused one by name, or make a new one. Returns once it answers (or says it is still starting); then start chats on it with new. With the cmux app, the app may ask the person to confirm.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "machine": {"type": "string", "description": "A Cloud machine to resume, by name or id. Leave out to make a new one."},
                    "name": {"type": "string", "description": "The new machine's name (only without machine)."},
                    "size": {"type": "string", "enum": ["small", "medium", "large", "xlarge"], "description": "The new machine's size (default: the app's)."},
                    "repo": {"type": "string", "description": "OWNER/NAME[@REF] to clone on the new machine."}
                }
            }
        }),
        json!({
            "name": NEW,
            "description": "Start an agent chat with a task, on this machine or another (machines lists them), and return at once with its name and link; use it instead of acpmux new in a shell. It keeps working after this turn; read it with last or info, message it with send.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "prompt": {"type": "string", "description": "The task, self-contained: the new chat has none of this chat's context."},
                    "machine": {"type": "string", "description": "A machine from machines, local for this one, or auto for the one with the most room. Default: as acpmux new places it."},
                    "harness": {"type": "string", "description": "The harness, optionally with a model (claude/opus, codex/gpt-5.5). Default: as acpmux new picks it."},
                    "folder": {"type": "string", "description": "The folder to work in, on that machine. Default: a scratch folder there."},
                    "name": {"type": "string", "description": "A short readable name, 2 to 5 words (spaces become -)."}
                },
                "required": ["prompt"]
            }
        }),
        json!({
            "name": FORK,
            "description": "Fork a chat into a new one that shares its history so far, on the machine the chat is on: a name here, or HOST/CHAT for a chat on a peer. Returns the fork's name.",
            "inputSchema": {
                "type": "object",
                "properties": {
                    "chat": {"type": "string", "description": "The chat to fork: name, id or HOST/CHAT."},
                    "name": {"type": "string", "description": "The fork's name."},
                    "folder": {"type": "string", "description": "The fork's folder (default: the chat's)."},
                    "harness": {"type": "string", "description": "Continue on another harness (a family or profile)."}
                },
                "required": ["chat"]
            }
        }),
    ]
}

pub(super) async fn call(daemon: &Arc<Client>, name: &str, args: &Value) -> Value {
    match name {
        MACHINES => machines().await,
        NEW => new(args).await,
        FORK => fork(daemon, args).await,
        MACHINE_START => machine_start(args).await,
        other => error_result(format!("unknown start tool {other}")),
    }
}

/// A word an argv takes from the agent: never one a parser reads as a flag.
fn word<'a>(args: &'a Value, key: &str) -> Result<Option<&'a str>, String> {
    match arg(args, key) {
        Some(v) if v.starts_with('-') => Err(format!("{key} may not start with -")),
        v => Ok(v),
    }
}

/// What `new` runs: the session's name, the argv after the binary, and the prompt, which goes
/// on stdin so a detached `--json new` returns once the chat exists.
pub(super) fn new_argv(args: &Value) -> Result<(String, Vec<String>, String), String> {
    let Some(prompt) = args.get("prompt").and_then(Value::as_str).filter(|p| !p.trim().is_empty())
    else {
        return Err("prompt is required".to_owned());
    };
    let name =
        word(args, "name")?.map(session_name).filter(|n| !n.is_empty()).unwrap_or_else(|| {
            let id = uuid::Uuid::now_v7().simple().to_string();
            format!("chat-{}", id.get(24..).unwrap_or_default())
        });
    if name.starts_with('-') {
        return Err("name may not start with -".to_owned());
    }
    let mut argv: Vec<String> =
        ["--json", "new", "--detach", "--name", &name].map(str::to_owned).to_vec();
    for (key, flag) in [("harness", "--model"), ("machine", "--machine"), ("folder", "--cwd")] {
        if let Some(value) = word(args, key)? {
            argv.extend([flag.to_owned(), value.to_owned()]);
        }
    }
    argv.extend(["--prompt-file".to_owned(), "-".to_owned()]);
    Ok((name, argv, prompt.to_owned()))
}

async fn new(args: &Value) -> Value {
    let (name, argv, prompt) = match new_argv(args) {
        Ok(v) => v,
        Err(e) => return error_result(e),
    };
    match run_acpmux(&argv, Some(&prompt), CLI_WAIT).await {
        Ok(out) => match serde_json::from_str::<Value>(out.trim()) {
            Ok(record) => new_result(&name, &record),
            Err(_) => ok(format!("Started {name}. {}", out.trim()), json!({"name": name})),
        },
        Err(CliError::Late) => still_starting(&name),
        Err(CliError::Failed(why)) => error_result(why),
    }
}

fn still_starting(name: &str) -> Value {
    ok(
        format!(
            "{name} is still starting (over {} s); check it with info or ls in a minute.",
            CLI_WAIT.as_secs()
        ),
        json!({"name": name, "starting": true}),
    )
}

async fn machines() -> Value {
    let argv = ["--json", "machine", "ls"].map(str::to_owned);
    match run_acpmux(&argv, None, MACHINES_WAIT).await {
        Ok(out) => match serde_json::from_str::<Value>(out.trim()) {
            Ok(list) => {
                let rows = machine_rows(&list);
                ok(machines_text(&rows), json!({"machines": rows}))
            }
            Err(_) => ok(out.trim().to_owned(), json!({})),
        },
        Err(CliError::Late) => error_result(format!(
            "machine ls did not answer in {} s; try again",
            MACHINES_WAIT.as_secs()
        )),
        Err(CliError::Failed(why)) => error_result(why),
    }
}

/// The `session/fork` params `acpmux session fork` sends for `args`, with the resolved `id`.
pub(super) fn fork_params(id: &str, args: &Value) -> Value {
    let mut acpmux = json!({});
    for key in ["name", "harness"] {
        if let Some(v) = arg(args, key) {
            acpmux.set(key, json!(v));
        }
    }
    let mut p = json!({"sessionId": id, "mcpServers": [], "_meta": {"acpmux": acpmux}});
    if let Some(cwd) = arg(args, "folder") {
        p.set("cwd", json!(cwd));
    }
    p
}

async fn fork(daemon: &Arc<Client>, args: &Value) -> Value {
    let Some(chat) = arg(args, "chat") else {
        return error_result("chat is required".to_owned());
    };
    let id = match crate::cli::run::resolve_id(daemon, chat).await {
        Ok(id) => id,
        Err(e) => return refusal(e),
    };
    match daemon.request(method::SESSION_FORK, fork_params(&id, args)).await {
        Ok(v) => {
            let name = v.pointer("/_meta/acpmux/name").and_then(Value::as_str).unwrap_or("?");
            let session = v["sessionId"].as_str().unwrap_or_default();
            let peer = chat.split_once('/').map(|(host, _)| host);
            let at = peer.map(|p| format!(" on {p}")).unwrap_or_default();
            let mut structured = json!({"name": name, "sessionId": session, "from": chat});
            if let Some(peer) = peer {
                structured.set("machine", json!(peer));
            }
            ok(format!("Forked {chat} into {name}{at} ({session})."), structured)
        }
        Err(e) => refusal(e),
    }
}

/// What `machine_start` runs after `cmux`: `vm resume NAME` for a named machine, else `vm new`
/// with the name, size and repo given.
pub(super) fn machine_start_argv(args: &Value) -> Result<Vec<String>, String> {
    let mut argv: Vec<String> = vec!["vm".to_owned()];
    if let Some(machine) = word(args, "machine")? {
        argv.extend(["resume".to_owned(), machine.to_owned()]);
    } else {
        argv.push("new".to_owned());
        for (key, flag) in [("name", "--name"), ("size", "--size"), ("repo", "--repo")] {
            if let Some(value) = word(args, key)? {
                argv.extend([flag.to_owned(), value.to_owned()]);
            }
        }
    }
    argv.push("--json".to_owned());
    Ok(argv)
}

async fn machine_start(args: &Value) -> Value {
    let argv = match machine_start_argv(args) {
        Ok(v) => v,
        Err(e) => return error_result(e),
    };
    let cmux = crate::login_env::cmux_cli();
    let mut command = cmux_process::Command::new(cmux);
    command.args(&argv);
    match run_bounded(command, "cmux", &argv, None, CLI_WAIT).await {
        Ok(out) => {
            let record = serde_json::from_str::<Value>(out.trim()).unwrap_or(json!({}));
            let shown = ["name", "id", "machine"]
                .iter()
                .find_map(|k| record[*k].as_str())
                .or_else(|| arg(args, "machine"))
                .unwrap_or("the machine")
                .to_owned();
            let verb = if arg(args, "machine").is_some() { "Resumed" } else { "Started" };
            ok(
                format!("{verb} {shown}. Start a chat on it with new (machine: {shown})."),
                json!({"machine": shown, "record": record}),
            )
        }
        Err(CliError::Late) => ok(
            format!(
                "the machine is still starting (over {} s); machines lists it once it is up.",
                CLI_WAIT.as_secs()
            ),
            json!({"starting": true}),
        ),
        Err(CliError::Failed(why)) => error_result(why),
    }
}

/// This binary's CLI with `argv`, in the session's own env (its caller token: the daemon takes
/// the call as this session's, as from its shell).
async fn run_acpmux(
    argv: &[String],
    stdin: Option<&str>,
    wait: Duration,
) -> Result<String, CliError> {
    let me = crate::self_command::SelfCommand::current()
        .map_err(|e| CliError::Failed(format!("{e}")))?;
    run_bounded(me.process_command(argv), "acpmux", argv, stdin, wait).await
}

#[cfg(test)]
#[path = "acpmux_mcp_start_tests.rs"]
mod tests;
