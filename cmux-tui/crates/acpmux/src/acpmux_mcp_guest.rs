//! The acpmux MCP server's guest mode: the server an app outside acpmux runs because `acpmux
//! desktop link` gave it one (`desktop_link.rs`): the Claude desktop app, Claude Code, Codex.
//! Leo, 2026-11-09: "even if somebody say still wants to keep using [the Codex desktop app] and/or claude
//! desktop, to be always saying "yeah i want to keep using cmux-next :) they give a good
//! transport between everybody :)"".
//!
//! A guest chat is no acpmux session, so it gets the tools that need none: read and message the
//! sessions on this machine, its paired machines and Cloud machines (`ls`, `last`, `info`,
//! `search`, `send`, `send_status`), list those machines (`machines`), start a session on one of
//! them (`new`), and the person's cmux artifacts when signed in. The session-bound tools (inbox,
//! background tasks, goal, wrap-up, watch, `machine_info`, `who_else`) are left out: each
//! refuses without a session.
//!
//! Who a guest is: it connects with no caller token, so the daemon never takes it for an acpmux
//! session or for the person (`hub/person.rs`). Its MCP client's own name (`clientInfo`) goes
//! beside each message it sends, self-reported (`sender_harness.rs`), and a session it starts
//! carries `origin=<app>`, so the chat that came from Claude desktop reads that way in cmux.
//!
//! The same entry reaches a session acpmux runs, because Claude Code and Codex read their
//! user-scope config there too. That session has its own `cmux` server, which replaces this
//! entry by name; and if one ever does not, the guest lists no tools inside an acpmux session.
//!
//! `machines` and `new` run this binary's own CLI (`acpmux --json machine ls`, `acpmux --json new
//! --detach`), bounded under the shortest harness tool timeout, so they place, name and start a
//! session exactly as the CLI does and can do nothing it cannot.

use super::*;
use std::process::Stdio;

/// The tools of the full server a guest keeps, by name.
const KEPT: &[&str] = &["send", "send_status", "ls", "last", "info", "search"];
pub(super) const NEW: &str = "new";
pub(super) const MACHINES: &str = "machines";
/// How long a CLI call may take: under Codex's 60 s MCP tool timeout.
const CLI_WAIT: Duration = Duration::from_secs(50);
const MACHINES_WAIT: Duration = Duration::from_secs(20);

/// What a guest chat is told.
pub(super) const STEER: &str = "These tools are cmux's transport: they reach the agent sessions \
(Claude, Codex and others) on this machine, on the person's paired machines and on their cmux \
Cloud machines. machines lists the machines; new starts a session on one with a task and returns \
at once (it keeps working after this chat ends, and asks the person in cmux NEXT or on their \
phone before anything risky); ls, info and last read sessions; send messages one; search finds \
words in one. Give the person the session's link so they can follow it in cmux. If a tool says \
there is no acpmux daemon, cmux NEXT is not running on this machine: ask the person to open it.";

/// The guest's tools: [`KEPT`] of `all` (the full server's list, artifacts included when signed
/// in), then `machines` and `new`.
pub(super) fn tools(all: &Value) -> Value {
    let mut out: Vec<Value> = all
        .as_array()
        .into_iter()
        .flatten()
        .filter(|t| {
            let name = t["name"].as_str().unwrap_or_default();
            KEPT.contains(&name) || artifacts::TOOLS.contains(&name)
        })
        .cloned()
        .collect();
    out.push(machines_tool());
    out.push(new_tool());
    Value::Array(out)
}

fn machines_tool() -> Value {
    json!({
        "name": MACHINES,
        "description": "List the machines cmux reaches from here: this machine, the person's paired machines and their cmux Cloud machines, each with its connection state. Name one as new's machine.",
        "inputSchema": {"type": "object", "properties": {}}
    })
}

fn new_tool() -> Value {
    json!({
        "name": NEW,
        "description": "Start an agent session with a task, on this machine or another, and return at once with its name and link. The session keeps working after this chat ends; read it with last or info, message it with send. It starts asking the person before risky actions; they answer in cmux NEXT or on their phone.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "prompt": {"type": "string", "description": "The task, self-contained: the session has none of this chat's context."},
                "harness": {"type": "string", "description": "claude or codex, optionally with a model (claude/opus, codex/gpt-5.5). Default: the person's default."},
                "machine": {"type": "string", "description": "A machine from machines, or auto for the one with the most room. Default: as acpmux new places it."},
                "folder": {"type": "string", "description": "The folder to work in, on that machine. Default: a scratch folder there."},
                "name": {"type": "string", "description": "A short readable name, 2 to 5 words (spaces become -). Default: made from the app's name."},
                "showInCmux": {"type": "boolean", "description": "Also open it in cmux NEXT's sidebar on this Mac now (default false)."}
            },
            "required": ["prompt"]
        }
    })
}

/// The argv (after the binary) of `new` for guest `app`, or the refusal.
pub(super) fn new_argv(app: &str, args: &Value) -> Result<(String, Vec<String>), String> {
    let Some(prompt) = args.get("prompt").and_then(Value::as_str).filter(|p| !p.trim().is_empty())
    else {
        return Err("prompt is required".to_owned());
    };
    let name = match arg(args, "name") {
        Some(name) => name.to_owned(),
        None => format!("{app}-{}", &uuid::Uuid::now_v7().simple().to_string()[24..]),
    };
    let mut argv: Vec<String> =
        ["--json", "new", "--detach", "--name", &name].iter().map(|s| (*s).to_owned()).collect();
    for (key, flag) in [("harness", "--model"), ("machine", "--machine"), ("folder", "--cwd")] {
        if let Some(value) = arg(args, key) {
            if value.starts_with('-') {
                return Err(format!("{key} may not start with -"));
            }
            argv.extend([flag.to_owned(), value.to_owned()]);
        }
    }
    argv.extend(["--tag".to_owned(), format!("origin={app}")]);
    if args.get("showInCmux").and_then(Value::as_bool) == Some(true) {
        let group = crate::desktop_link::App::parse(app).map_or(app, |a| a.label());
        argv.extend(["--group".to_owned(), group.to_owned()]);
    }
    argv.extend(["--".to_owned(), prompt.to_owned()]);
    Ok((name, argv))
}

/// The harness a link names for a session's harness or profile name (`claude-opus` is Claude).
fn link_harness(harness: &str) -> &str {
    ["claude", "codex"].into_iter().find(|h| harness.starts_with(h)).unwrap_or(harness)
}

/// What `new` answers for the CLI's `--json` record of the created session.
pub(super) fn new_result(name: &str, record: &Value) -> Value {
    let id = record["sessionId"].as_str().unwrap_or_default();
    let peer = record["peer"].as_str().filter(|p| !p.is_empty());
    let shown = record["name"].as_str().unwrap_or(name);
    let harness = record["harness"].as_str().or_else(|| record["agent"].as_str()).unwrap_or("");
    let link = record["agentSessionId"].as_str().and_then(|session| {
        crate::agent_link::AgentLink {
            harness: link_harness(harness).to_owned(),
            session: session.to_owned(),
            host: peer.map(str::to_owned),
            name: Some(shown.to_owned()),
            ..Default::default()
        }
        .web_url()
    });
    let at = peer.map(|p| format!(" on {p}")).unwrap_or_default();
    let mut text = format!("Started {shown}{at} ({id}).");
    match &link {
        Some(link) => text.push_str(&format!(" Follow it in cmux: {link}")),
        None => text.push_str(" It is in cmux NEXT's chat list; read it here with last."),
    }
    let mut structured = json!({"name": shown, "sessionId": id});
    if let Some(peer) = peer {
        structured["machine"] = json!(peer);
    }
    if let Some(link) = link {
        structured["link"] = json!(link);
    }
    ok(text, structured)
}

pub(super) async fn new(app: &str, args: &Value) -> Value {
    let (name, argv) = match new_argv(app, args) {
        Ok(v) => v,
        Err(e) => return error_result(e),
    };
    match run_cli(&argv, CLI_WAIT).await {
        Ok(out) => match serde_json::from_str::<Value>(out.trim()) {
            Ok(record) => new_result(&name, &record),
            Err(_) => ok(format!("Started {name}. {}", out.trim()), json!({"name": name})),
        },
        Err(CliError::Late) => ok(
            format!(
                "{name} is still starting (over {} s); check it with info or ls in a minute.",
                CLI_WAIT.as_secs()
            ),
            json!({"name": name, "starting": true}),
        ),
        Err(CliError::Failed(why)) => error_result(why),
    }
}

pub(super) async fn machines() -> Value {
    let argv = ["--json", "machine", "ls"].map(str::to_owned);
    match run_cli(&argv, MACHINES_WAIT).await {
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

/// The machines of `acpmux --json machine ls` (`peers`, each with its health and paths), each as
/// the few fields a guest needs: name, link state, OS and live sessions.
pub(super) fn machine_rows(list: &Value) -> Vec<Value> {
    list["peers"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|m| {
            let name = m["name"].as_str()?;
            let mut row =
                json!({"name": name, "connected": m["connected"].as_bool().unwrap_or(false)});
            for (key, at) in
                [("link", "/link"), ("os", "/health/os"), ("liveSessions", "/health/liveSessions")]
            {
                if let Some(v) = m.pointer(at).filter(|v| !v.is_null()) {
                    row[key] = v.clone();
                }
            }
            Some(row)
        })
        .collect()
}

/// One line per machine, this machine first.
pub(super) fn machines_text(rows: &[Value]) -> String {
    let mut lines = vec!["this machine  [local]".to_owned()];
    lines.extend(rows.iter().map(|m| {
        let name = m["name"].as_str().unwrap_or("?");
        let state =
            m["link"].as_str().unwrap_or(if m["connected"] == true { "connected" } else { "down" });
        match m["liveSessions"].as_u64() {
            Some(n) => format!("{name}  [{state}]  {n} live sessions"),
            None => format!("{name}  [{state}]"),
        }
    }));
    lines.join("\n")
}

pub(super) enum CliError {
    /// Past the wait; the command goes on.
    Late,
    Failed(String),
}

/// Run this binary with `argv`, its stdout on success, else its last stderr line.
async fn run_cli(argv: &[String], wait: Duration) -> Result<String, CliError> {
    let me = crate::self_command::SelfCommand::current()
        .map_err(|e| CliError::Failed(format!("{e}")))?;
    let mut command = me.tokio_command(argv);
    command
        // Never as a session: a guest is none.
        .env_remove(SESSION_ENV)
        .env_remove(crate::desktop_link::GUEST_ENV)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let child = command.spawn().map_err(|e| CliError::Failed(format!("{e}")))?;
    match tokio::time::timeout(wait, child.wait_with_output()).await {
        Err(_) => Err(CliError::Late),
        Ok(Err(e)) => Err(CliError::Failed(format!("{e}"))),
        Ok(Ok(out)) if out.status.success() => {
            Ok(String::from_utf8_lossy(&out.stdout).into_owned())
        }
        Ok(Ok(out)) => {
            let err = String::from_utf8_lossy(&out.stderr);
            let why = err.lines().rfind(|l| !l.trim().is_empty()).unwrap_or("").to_owned();
            Err(CliError::Failed(format!("acpmux {} failed ({}): {why}", argv[1], out.status)))
        }
    }
}

/// Runs the guest server for `app` on stdin and stdout.
pub(super) async fn run(app: String, artifacts: Option<Arc<artifacts::Artifacts>>) -> Result<()> {
    let inside = std::env::var(SESSION_ENV).is_ok_and(|s| !s.trim().is_empty());
    let tools = if inside { json!([]) } else { tools(&tools_with_artifacts(artifacts.is_some())) };
    let steer = (!inside).then(|| STEER.to_owned());
    crate::secret_mcp::serve_as(
        SERVER_NAME,
        String::new(),
        tools,
        steer,
        move |daemon, _, params| {
            let artifacts = artifacts.clone();
            let app = app.clone();
            async move {
                if inside {
                    return error_result(
                        "this chat runs in acpmux: use its own cmux tools".to_owned(),
                    );
                }
                let name = params.get("name").and_then(Value::as_str).unwrap_or_default();
                let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
                if !args.is_object() {
                    return error_result("arguments must be an object".to_owned());
                }
                if artifacts::TOOLS.contains(&name) {
                    return match &artifacts {
                        Some(client) => artifacts::call(client, name, &args).await,
                        None => error_result(
                            "the artifact tools need a cmux sign-in on this machine".to_owned(),
                        ),
                    };
                }
                match name {
                    NEW => new(&app, &args).await,
                    MACHINES => machines().await,
                    "search" => search_tool(&daemon, "", &args).await,
                    "send_status" => send_status::call(&daemon, "", &args).await,
                    n if KEPT.contains(&n) => call_as(&daemon, &params, None).await,
                    other => error_result(crate::mcp_hint::unknown_tool(
                        other,
                        crate::mcp_hint::names(&tools_list()),
                    )),
                }
            }
        },
    )
    .await
}

fn tools_list() -> Value {
    tools(&tools_with_artifacts(false))
}

#[cfg(test)]
#[path = "acpmux_mcp_guest_tests.rs"]
mod tests;
