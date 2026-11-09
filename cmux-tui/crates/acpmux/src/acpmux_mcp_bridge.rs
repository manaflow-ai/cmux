//! `acpmux bridge mcp --as APP`: the MCP stdio server `acpmux bridge connect` adds to Claude
//! Desktop and Codex Desktop (`desktop_bridge.rs`), so a chat in one messages the other and any
//! cmux agent session. Its tools: `send` (to the other app's mailbox, or to a session through
//! `acpmux send --no-wait --from APP`, the CLI's own sender claim, never the person's words),
//! `inbox` (this app's mailbox), and the `acpmux` server's `ls` and `last`, which only read.
//!
//! The configs it is added to are the harness's user-wide ones, so a chat cmux itself runs loads
//! it too; that chat already has the `acpmux` server and is a session, so here it gets no tools.

use super::*;
use crate::desktop_bridge::{self, App, Bridge};

pub const SERVER_NAME: &str = "cmux-bridge";
/// How long a send to a session may take before the server answers; the outbox goes on after.
const SEND_TIMEOUT: Duration = Duration::from_secs(20);

fn tools(me: App) -> Value {
    let others = desktop_bridge::APPS
        .iter()
        .filter(|a| a.address != me.address)
        .map(|a| format!("{} ({})", a.address, a.name))
        .collect::<Vec<_>>()
        .join(", ");
    let mut all = json!([
        {
            "name": "send",
            "description": format!("Message {others} or a cmux agent session, through cmux. A desktop app gets it in its inbox; a session gets it in its chat, from {}, with how to reply. It does not wait for an answer.", me.name),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "to": {"type": "string", "description": format!("{others}, or a session's name, id or host/name (as ls lists them).")},
                    "text": {"type": "string", "description": "The message, self-contained."}
                },
                "required": ["to", "text"]
            }
        },
        {
            "name": "inbox",
            "description": format!("Read the messages left for {}: from the other desktop app and from cmux sessions, oldest first. Each is returned once unless peek is true.", me.name),
            "inputSchema": {
                "type": "object",
                "properties": {
                    "peek": {"type": "boolean", "description": "true: leave them unread."}
                }
            }
        }
    ]);
    if let (Some(list), Some(base)) = (all.as_array_mut(), base_tools().as_array()) {
        list.extend(
            base.iter().filter(|t| matches!(t["name"].as_str(), Some("ls" | "last"))).cloned(),
        );
    }
    all
}

fn instructions(me: App) -> String {
    format!(
        "This is cmux, the bridge between Claude Desktop, Codex Desktop and the cmux agent \
sessions; you are {}. send messages the other desktop app or a session (find one with ls, read \
its answer with last); inbox reads what they sent you. cmux cannot start a turn here, so read the \
inbox at the start of a task and whenever the person mentions messages, cmux, Claude or Codex.",
        me.name
    )
}

/// Runs the server for `app` (`claude-desktop`, `codex-desktop`) on stdin and stdout.
pub async fn run(app: &str) -> Result<()> {
    let me = desktop_bridge::app(app)
        .ok_or_else(|| anyhow::anyhow!("unknown app {app:?}: claude-desktop or codex-desktop"))?;
    // A chat cmux runs is a session with the acpmux server: nothing to bridge.
    let in_session = std::env::var_os(SESSION_ENV).is_some();
    let (tools, steer) =
        if in_session { (json!([]), None) } else { (tools(me), Some(instructions(me))) };
    crate::secret_mcp::serve_as(
        SERVER_NAME,
        me.address.to_owned(),
        tools,
        steer,
        move |daemon, _, params| async move {
            if in_session {
                return error_result(
                    "this chat is a cmux session: use the acpmux tools".to_owned(),
                );
            }
            let args = params.get("arguments").cloned().unwrap_or_else(|| json!({}));
            match params["name"].as_str().unwrap_or_default() {
                "send" => send(me, &args).await,
                "inbox" => inbox(me, &args),
                "ls" | "last" => call_as(&daemon, &params, None).await,
                name => error_result(crate::mcp_hint::unknown_tool(
                    name,
                    ["send", "inbox", "ls", "last"],
                )),
            }
        },
    )
    .await
}

async fn send(me: App, args: &Value) -> Value {
    let (Some(to), Some(text)) = (arg(args, "to"), arg(args, "text")) else {
        return error_result("to and text are required".to_owned());
    };
    if let Some(app) = desktop_bridge::app(to) {
        if app == me {
            return error_result(format!(
                "{} is you; send to the other app or a session",
                me.address
            ));
        }
        return match Bridge::current().send(me.name, app, text) {
            Ok(m) => ok(format!("Left for {} ({}).", app.name, m.id), json!({"message": m})),
            Err(e) => refusal(e),
        };
    }
    match send_to_session(me, to, text).await {
        Ok(out) => ok(format!("Sent to {to}. {}", out.trim()).trim().to_owned(), json!({"to": to})),
        Err(e) => refusal(e),
    }
}

/// `acpmux send --no-wait --from APP -- TO TEXT`: the CLI names the sender, so the session reads
/// the message as the app's, not as the person's own prompt (`cli/sender.rs`).
async fn send_to_session(me: App, to: &str, text: &str) -> Result<String> {
    let exe = std::env::current_exe()?;
    let message = format!("{text}{}", desktop_bridge::reply_hint(me));
    let run = tokio::process::Command::new(exe)
        .args(["send", "--no-wait", "--from", me.name, "--", to, &message])
        .stdin(std::process::Stdio::null())
        .kill_on_drop(true)
        .output();
    let out = tokio::time::timeout(SEND_TIMEOUT, run)
        .await
        .map_err(|_| anyhow::anyhow!("acpmux send took over {}s", SEND_TIMEOUT.as_secs()))??;
    if !out.status.success() {
        let err = String::from_utf8_lossy(&out.stderr);
        anyhow::bail!("acpmux send failed: {}", err.trim());
    }
    Ok(String::from_utf8_lossy(&out.stdout).into_owned())
}

fn inbox(me: App, args: &Value) -> Value {
    let peek = args.get("peek").and_then(Value::as_bool).unwrap_or(false);
    match Bridge::current().inbox(me, !peek) {
        Ok((messages, more)) => ok(
            desktop_bridge::inbox_text(me, &messages, more),
            json!({"messages": messages, "more": more}),
        ),
        Err(e) => refusal(e),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_app_lists_send_inbox_ls_and_last_and_names_the_other_app() {
        for me in desktop_bridge::APPS {
            let tools = tools(*me);
            let names: Vec<_> =
                tools.as_array().unwrap().iter().map(|t| t["name"].as_str().unwrap()).collect();
            assert_eq!(names, ["send", "inbox", "ls", "last"]);
            let other = desktop_bridge::APPS.iter().find(|a| a != &me).unwrap();
            assert!(tools[0]["description"].as_str().unwrap().contains(other.address));
            assert!(!tools[0]["description"].as_str().unwrap().contains(me.address));
        }
    }
}
