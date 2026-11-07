//! Computer Use waits while this Mac's screen is locked (design/lock-bridge.md, item 3).
//!
//! A locked screen shows only the lock screen: a screenshot would see it, and a click or a
//! keystroke would land on it (its password field). So while [`crate::mac_lock::locked`], every
//! `tools/call` an agent sends to a Computer Use server is answered here with the typed
//! [`MAC_LOCKED`](crate::mac_lock::MAC_LOCKED) result and never reaches the helper; `tools/list`
//! and everything else pass. This holds whatever `sessions.keepAwakeWhenLocked` says: it is the
//! safe answer on any locked Mac, not part of the opt-in.
//!
//! Both drivers go through it: the helper v2 bridge (`acpmux cua-mcp`, `cua_v2::serve`) asks
//! [`gate`] for each request, and the legacy `cmux-cua mcp` proxy runs under
//! `acpmux cua-lock-gate -- <cmux-cua> mcp ...` ([`run`]), which passes every other message
//! through both ways and ends with the helper. A call is gated in every form: a request, a
//! notification, a batch. The gate only refuses: it never answers a call as done, never approves
//! anything, and never reads the helper's tokens (they stay in the child's env).

use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};

use crate::mac_lock::{MAC_LOCKED, MAC_LOCKED_TEXT};

/// The acpmux command word of the legacy driver's gate (`acpmux cua-lock-gate -- CMD ARGS`).
pub const COMMAND: &str = "cua-lock-gate";

/// The `tools/call` result a gated call gets: an error result with the typed reason.
pub fn locked_result() -> Value {
    json!({
        "content": [{"type": "text", "text": MAC_LOCKED_TEXT}],
        "structuredContent": {"error": MAC_LOCKED},
        "isError": true,
    })
}

/// What the gate does with one agent message.
#[derive(Debug, Clone, PartialEq)]
pub enum Gated {
    /// Not gated: it goes on to the helper.
    Pass,
    /// Answered here: the helper never sees it.
    Reply(Value),
    /// Dropped: it must not reach the helper, and nothing waits for an answer.
    Drop,
}

/// What happens to one agent message: while `locked()` says the screen is locked, a `tools/call`
/// never passes, whatever its form. A request is answered here; one sent as a notification (no
/// `id`) is dropped, since nothing waits for its answer; a batch that holds a call gets one answer
/// per request in it, and none of it passes. Anything else passes (`locked` is only asked for a
/// call).
pub fn gate(message: &Value, locked: impl FnOnce() -> bool) -> Gated {
    let has_call = match message {
        Value::Array(items) => items.iter().any(is_call),
        _ => is_call(message),
    };
    if !has_call || !locked() {
        return Gated::Pass;
    }
    match message {
        Value::Array(items) => {
            let replies: Vec<Value> = items.iter().filter_map(locked_reply).collect();
            if replies.is_empty() { Gated::Drop } else { Gated::Reply(Value::Array(replies)) }
        }
        _ => locked_reply(message).map_or(Gated::Drop, Gated::Reply),
    }
}

fn is_call(message: &Value) -> bool {
    message["method"] == "tools/call"
}

/// The answer, while locked, to one request of a message that holds a call: a call gets the
/// typed result, another request the same reason as an error. A notification gets none.
fn locked_reply(message: &Value) -> Option<Value> {
    let id = message.get("id")?;
    message.get("method")?;
    Some(if is_call(message) {
        json!({"jsonrpc": "2.0", "id": id, "result": locked_result()})
    } else {
        json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": MAC_LOCKED_TEXT}})
    })
}

/// `acpmux cua-lock-gate -- CMD ARGS`: runs CMD as the agent's MCP server, passing its stdio
/// through line by line, and answers gated calls itself. Ends when either side closes: the
/// process exits then, since a read of stdin cannot be cancelled and would hold it open.
pub async fn run(args: &[String]) -> Result<()> {
    let args = args.strip_prefix(&["--".to_owned()]).unwrap_or(args);
    let (program, rest) =
        args.split_first().ok_or_else(|| anyhow!("{COMMAND}: no server command"))?;
    crate::parent_watch::exit_with_parent();
    let stdin = BufReader::new(tokio::io::stdin());
    run_with(program, rest, stdin, tokio::io::stdout(), crate::mac_lock::locked).await?;
    std::process::exit(0)
}

/// [`run`] over the given agent side, with the screen lock read passed in.
pub async fn run_with<R, W>(
    program: &str,
    args: &[String],
    input: R,
    output: W,
    locked: impl Fn() -> bool,
) -> Result<()>
where
    R: AsyncBufRead + Unpin,
    W: AsyncWrite + Unpin + Send + 'static,
{
    let mut child = tokio::process::Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("{COMMAND}: start {program}"))?;
    let mut to_child = child.stdin.take().context("child stdin")?;
    let from_child = child.stdout.take().context("child stdout")?;
    // One writer for the agent side: the server's lines and the gate's replies.
    let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(async move {
        let mut output = output;
        while let Some(line) = out_rx.recv().await {
            if output.write_all(line.as_bytes()).await.is_err() || output.flush().await.is_err() {
                return;
            }
        }
    });
    let server_out = out_tx.clone();
    let from_server = tokio::spawn(async move {
        let mut lines = BufReader::new(from_child).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if server_out.send(format!("{line}\n")).is_err() {
                return;
            }
        }
    });
    // The helper reads what the gate read: each message goes on as the gate parsed it, so a line
    // two parsers read differently (a repeated key) cannot pass as one thing and act as another.
    // A line that does not parse goes on as it is, unless the screen is locked.
    let mut lines = input.lines();
    let mut from_server = from_server;
    let mut server_ended = false;
    loop {
        let line = tokio::select! {
            _ = &mut from_server => {
                server_ended = true;
                break; // the server is gone: so is the gate
            }
            line = lines.next_line() => line?,
        };
        let Some(line) = line else { break };
        let (gated, text) = match serde_json::from_str::<Value>(&line) {
            Ok(message) => (gate(&message, &locked), message.to_string()),
            Err(_) if locked() => (Gated::Drop, String::new()),
            Err(_) => (Gated::Pass, line),
        };
        match gated {
            Gated::Reply(reply) => {
                let _ = out_tx.send(format!("{reply}\n"));
            }
            Gated::Drop => {}
            Gated::Pass => {
                if to_child.write_all(format!("{text}\n").as_bytes()).await.is_err() {
                    break; // the server is gone
                }
                let _ = to_child.flush().await;
            }
        }
    }
    drop(to_child); // stdin closed: the server ends
    if server_ended {
        let _ = child.start_kill(); // it closed its output: nothing more comes from it
    } else {
        let _ = from_server.await;
    }
    drop(out_tx);
    let _ = writer.await;
    let _ = child.wait().await;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_tool_call_while_locked_gets_the_typed_result_and_nothing_else_is_gated() {
        let call = json!({"jsonrpc": "2.0", "id": 7, "method": "tools/call",
            "params": {"name": "click", "arguments": {"x": 1, "y": 2}}});
        let Gated::Reply(reply) = gate(&call, || true) else { panic!("gated") };
        assert_eq!(reply["id"], 7);
        assert_eq!(reply["result"]["isError"], true);
        assert_eq!(reply["result"]["structuredContent"]["error"], "mac_locked");
        assert!(reply["result"]["content"][0]["text"].as_str().unwrap().starts_with("mac_locked:"));
        assert_eq!(gate(&call, || false), Gated::Pass, "unlocked: the call passes");
        let list = json!({"jsonrpc": "2.0", "id": 8, "method": "tools/list"});
        assert_eq!(gate(&list, || panic!("not asked for a list")), Gated::Pass);
    }

    /// A call sent as a notification (no `id`) or inside a batch is still a call (review of
    /// cmux#37239): while locked, it never reaches the helper.
    #[test]
    fn a_tool_call_without_an_id_or_in_a_batch_never_passes_while_locked() {
        let note = json!({"jsonrpc": "2.0", "method": "tools/call",
            "params": {"name": "type", "arguments": {"text": "hunter2"}}});
        assert_eq!(gate(&note, || true), Gated::Drop, "nothing to answer, nothing forwarded");
        assert_eq!(gate(&note, || false), Gated::Pass);
        let batch = json!([
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {"name": "click"}},
            {"jsonrpc": "2.0", "method": "tools/call", "params": {"name": "click"}},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        ]);
        let Gated::Reply(Value::Array(replies)) = gate(&batch, || true) else {
            panic!("a batch with a call is answered here")
        };
        assert_eq!(replies.len(), 2, "one answer per request: {replies:?}");
        assert_eq!(replies[0]["result"]["structuredContent"]["error"], "mac_locked");
        assert_eq!(replies[1]["id"], 2);
        assert_eq!(
            gate(&json!([{"jsonrpc": "2.0", "method": "tools/call"}]), || true),
            Gated::Drop
        );
        assert_eq!(gate(&batch, || false), Gated::Pass);
        let list_only = json!([{"jsonrpc": "2.0", "id": 3, "method": "tools/list"}]);
        assert_eq!(gate(&list_only, || panic!("no call in it")), Gated::Pass);
    }

    /// The agent side, run through `run_with` with `cat` as the helper: whatever reaches the
    /// helper comes back.
    async fn through_cat(locked: bool, lines: &[&str]) -> Vec<String> {
        let (mut agent, input) = tokio::io::duplex(1 << 16);
        let (output, mut agent_out) = tokio::io::duplex(1 << 16);
        let mut text = lines.join("\n");
        text.push('\n');
        agent.write_all(text.as_bytes()).await.unwrap();
        drop(agent);
        let run = run_with("cat", &[], BufReader::new(input), output, move || locked);
        tokio::time::timeout(std::time::Duration::from_secs(20), run).await.unwrap().unwrap();
        let mut seen = String::new();
        tokio::io::AsyncReadExt::read_to_string(&mut agent_out, &mut seen).await.unwrap();
        seen.lines().map(str::to_owned).collect()
    }

    #[tokio::test]
    async fn while_locked_no_form_of_a_tool_call_reaches_the_helper() {
        let lines = [
            r#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"type"}}"#,
            // Two `method` keys: a parser that takes the first sees a call.
            r#"{"jsonrpc":"2.0","method":"tools/call","method":"tools/list","params":{}}"#,
            r#"{"jsonrpc":"2.0","method":"tools/call" "#,
            r#"{"jsonrpc":"2.0","id":9,"method":"tools/list"}"#,
        ];
        let seen = through_cat(true, &lines).await;
        assert!(seen.iter().all(|line| !line.contains("tools/call")), "{seen:?}");
        assert!(seen.iter().any(|line| line.contains("tools/list")), "the rest passes: {seen:?}");
        let unlocked = through_cat(false, &lines[..1]).await;
        assert_eq!(unlocked.len(), 1, "unlocked, the call passes: {unlocked:?}");
    }

    /// The gate ends with its helper (review of cmux#37239): an agent that keeps its side open
    /// does not keep a dead helper's gate running.
    #[tokio::test]
    async fn the_gate_ends_when_the_helper_exits() {
        let (_agent, input) = tokio::io::duplex(64);
        let (output, _agent_out) = tokio::io::duplex(64);
        let run = run_with("true", &[], BufReader::new(input), output, || false);
        let ended = tokio::time::timeout(std::time::Duration::from_secs(20), run).await;
        assert!(ended.is_ok(), "the gate outlived its helper");
    }
}
