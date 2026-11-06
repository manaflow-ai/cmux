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
//! `acpmux cua-lock-gate -- <cmux-cua> mcp ...` ([`run`]), which passes every other line through
//! unchanged both ways. The gate only refuses: it never answers a call as done, never approves
//! anything, and never reads the helper's tokens (they stay in the child's env).

use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};

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

/// The reply for one agent message when it must not reach the helper: a `tools/call` request
/// while `locked()` says the screen is locked. `None` lets it pass (`locked` is only asked then).
pub fn gate(message: &Value, locked: impl FnOnce() -> bool) -> Option<Value> {
    let id = message.get("id")?;
    if message["method"] != "tools/call" || !locked() {
        return None;
    }
    Some(json!({"jsonrpc": "2.0", "id": id, "result": locked_result()}))
}

/// `acpmux cua-lock-gate -- CMD ARGS`: runs CMD as the agent's MCP server, passing its stdio
/// through line by line, and answers gated calls itself. Ends when either side closes.
pub async fn run(args: &[String]) -> Result<()> {
    let args = args.strip_prefix(&["--".to_owned()]).unwrap_or(args);
    let (program, rest) =
        args.split_first().ok_or_else(|| anyhow!("{COMMAND}: no server command"))?;
    crate::parent_watch::exit_with_parent();
    let mut child = tokio::process::Command::new(program)
        .args(rest)
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::inherit())
        .kill_on_drop(true)
        .spawn()
        .with_context(|| format!("{COMMAND}: start {program}"))?;
    let mut to_child = child.stdin.take().context("child stdin")?;
    let from_child = child.stdout.take().context("child stdout")?;
    // One writer for this process's stdout: the server's lines and the gate's replies.
    let (out_tx, mut out_rx) = tokio::sync::mpsc::unbounded_channel::<String>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(line) = out_rx.recv().await {
            if stdout.write_all(line.as_bytes()).await.is_err() || stdout.flush().await.is_err() {
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
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        let reply = serde_json::from_str::<Value>(&line)
            .ok()
            .and_then(|message| gate(&message, crate::mac_lock::locked));
        match reply {
            Some(reply) => {
                let _ = out_tx.send(format!("{reply}\n"));
            }
            None => {
                if to_child.write_all(format!("{line}\n").as_bytes()).await.is_err() {
                    break; // the server is gone
                }
                let _ = to_child.flush().await;
            }
        }
    }
    drop(to_child); // stdin closed: the server ends
    let _ = from_server.await;
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
        let reply = gate(&call, || true).expect("gated");
        assert_eq!(reply["id"], 7);
        assert_eq!(reply["result"]["isError"], true);
        assert_eq!(reply["result"]["structuredContent"]["error"], "mac_locked");
        assert!(reply["result"]["content"][0]["text"].as_str().unwrap().starts_with("mac_locked:"));
        assert_eq!(gate(&call, || false), None, "unlocked: the call passes");
        let list = json!({"jsonrpc": "2.0", "id": 8, "method": "tools/list"});
        assert_eq!(gate(&list, || panic!("not asked for a list")), None);
        let note = json!({"jsonrpc": "2.0", "method": "tools/call"});
        assert_eq!(gate(&note, || true), None, "a notification has no reply to give");
    }
}
