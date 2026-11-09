//! Computer Use waits while this Mac's screen is locked (design/lock-bridge.md, item 3).
//!
//! A locked screen shows only the lock screen: a screenshot would see it, and a click or a
//! keystroke would land on it (its password field). So while [`crate::mac_lock::computer_use_held`]
//! (locked, or a lock state the window server did not report), every
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
//!
//! The gate reads the lock as a call comes in, and a call can then wait in the helper (on consent,
//! on fronting its target) while the Mac locks. So the legacy helper must read the lock again right
//! before it acts, and its `initialize` answer must say so ([`LOCK_AT_EXECUTION_CAPABILITY`],
//! `scripts/cmux-cua-lock-at-execution.patch`). `cmux-cua mcp` usually proxies to a separately
//! installed daemon that runs the calls, so the proxy says it only because it sends each call as a
//! request that only a daemon reading the lock runs; an older daemon refuses it unrun. A helper
//! that does not say it (one built before that check, or a v1 proxy that said it from its own
//! build) gets no call at all: each one is answered with [`HELPER_OUTDATED`], which says to update
//! cmux.

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};

use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt, BufReader};

use crate::mac_lock::{MAC_LOCKED, MAC_LOCKED_TEXT};

/// The acpmux command word of the legacy driver's gate (`acpmux cua-lock-gate -- CMD ARGS`).
pub const COMMAND: &str = "cua-lock-gate";

/// The `capabilities.experimental` key of the legacy helper's `initialize` answer when its calls
/// run only where the screen lock is read right before dispatch
/// (`scripts/cmux-cua-lock-at-execution.patch`). v1 was said by the proxy from its own build,
/// whatever daemon ran its calls, so it passes nothing.
pub const LOCK_AT_EXECUTION_CAPABILITY: &str = "cmux/lock-at-execution-v2";

/// The typed reason a call gets when the legacy helper does not say it checks the lock at execution.
pub const HELPER_OUTDATED: &str = "cua_helper_outdated";

/// The text of a [`HELPER_OUTDATED`] answer.
pub const HELPER_OUTDATED_TEXT: &str = "cua_helper_outdated: this Mac's Computer Use helper is too \
    old to check the screen lock right before it acts, so cmux sends it no steps. The step was not \
    run. Update cmux, which updates the helper, then start a new chat.";

/// The `tools/call` result a gated call gets: an error result with the typed reason.
pub fn locked_result() -> Value {
    refused_result(MAC_LOCKED, MAC_LOCKED_TEXT)
}

/// The `tools/call` result a call gets when its helper does not read the lock at execution.
pub fn outdated_result() -> Value {
    refused_result(HELPER_OUTDATED, HELPER_OUTDATED_TEXT)
}

fn refused_result(reason: &str, text: &str) -> Value {
    json!({
        "content": [{"type": "text", "text": text}],
        "structuredContent": {"error": reason},
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
    refuse_calls(message, locked, MAC_LOCKED, MAC_LOCKED_TEXT)
}

/// [`gate`] with the reason a held call is answered with.
fn refuse_calls(message: &Value, held: impl FnOnce() -> bool, reason: &str, text: &str) -> Gated {
    let has_call = match message {
        Value::Array(items) => items.iter().any(is_call),
        _ => is_call(message),
    };
    if !has_call || !held() {
        return Gated::Pass;
    }
    let reply = |message: &Value| refused_reply(message, reason, text);
    match message {
        Value::Array(items) => {
            let replies: Vec<Value> = items.iter().filter_map(reply).collect();
            if replies.is_empty() { Gated::Drop } else { Gated::Reply(Value::Array(replies)) }
        }
        _ => reply(message).map_or(Gated::Drop, Gated::Reply),
    }
}

fn is_call(message: &Value) -> bool {
    message.get("method").and_then(Value::as_str) == Some("tools/call")
}

/// The answer, while held, to one request of a message that holds a call: a call gets the
/// typed result, another request the same reason as an error. A notification gets none.
fn refused_reply(message: &Value, reason: &str, text: &str) -> Option<Value> {
    let id = message.get("id")?;
    message.get("method")?;
    Some(if is_call(message) {
        json!({"jsonrpc": "2.0", "id": id, "result": refused_result(reason, text)})
    } else {
        json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32000, "message": text}})
    })
}

/// The ids of the agent's `initialize` requests in one message.
fn initialize_ids(message: &Value) -> Vec<Value> {
    let one = |item: &Value| {
        let initialize = item.get("method").and_then(Value::as_str) == Some("initialize");
        if initialize { item.get("id").cloned() } else { None }
    };
    match message {
        Value::Array(items) => items.iter().filter_map(one).collect(),
        _ => one(message).into_iter().collect(),
    }
}

/// What the helper's answers in one message say about the lock check at execution, for the
/// `initialize` requests in `pending` (each one answered is taken out): `Some` for the last one
/// answered, `None` when the message answers none of them.
fn lock_check_answer(message: &Value, pending: &mut Vec<Value>) -> Option<bool> {
    let items = match message {
        Value::Array(items) => items.as_slice(),
        _ => std::slice::from_ref(message),
    };
    let mut said = None;
    for item in items {
        if item.get("method").is_some() {
            continue; // a request or notification from the helper, not an answer
        }
        let Some(at) = item.get("id").and_then(|id| pending.iter().position(|p| p == id)) else {
            continue;
        };
        pending.swap_remove(at);
        let experimental = item.pointer("/result/capabilities/experimental");
        said = Some(experimental.and_then(|e| e.get(LOCK_AT_EXECUTION_CAPABILITY)).is_some());
    }
    said
}

/// `acpmux cua-lock-gate -- CMD ARGS`: runs CMD as the agent's MCP server, passing its stdio
/// through line by line, and answers gated calls itself. Ends when either side closes.
pub async fn run(args: &[String]) -> Result<()> {
    let args = args.strip_prefix(&["--".to_owned()]).unwrap_or(args);
    let (program, rest) =
        args.split_first().ok_or_else(|| anyhow!("{COMMAND}: no server command"))?;
    crate::parent_watch::exit_with_parent();
    let stdin = BufReader::new(stdin_feed());
    run_with(program, rest, stdin, tokio::io::stdout(), crate::mac_lock::computer_use_held).await
}

/// This process's stdin, read on a thread of its own. Tokio's stdin reads on its blocking pool,
/// and that read cannot be cancelled: once the helper is gone, the runtime would wait on it at
/// the end until the agent wrote another line. A plain thread ends with the process.
fn stdin_feed() -> tokio::io::DuplexStream {
    let (mut feed, input) = tokio::io::duplex(1 << 16);
    let handle = tokio::runtime::Handle::current();
    std::thread::spawn(move || {
        let mut stdin = std::io::stdin().lock();
        let mut buf = [0u8; 8192];
        loop {
            let read = match std::io::Read::read(&mut stdin, &mut buf) {
                Ok(0) | Err(_) => return, // the agent closed its side: `feed` drops, input ends
                Ok(n) => buf.get(..n).unwrap_or_default(),
            };
            if handle.block_on(feed.write_all(read)).is_err() {
                return; // the gate ended
            }
        }
    });
    input
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
    // Whether the helper said, answering `initialize`, that it reads the lock right before it
    // acts. It is set before that answer reaches the agent, and an MCP client calls a tool only
    // after it has the answer, so no call is refused for a helper that does say it.
    let checks_lock = Arc::new(AtomicBool::new(false));
    let pending_initialize = Arc::new(std::sync::Mutex::new(Vec::<Value>::new()));
    let server_out = out_tx.clone();
    let (server_checks_lock, server_pending) = (checks_lock.clone(), pending_initialize.clone());
    let from_server = tokio::spawn(async move {
        let mut lines = BufReader::new(from_child).lines();
        while let Ok(Some(line)) = lines.next_line().await {
            if let Ok(message) = serde_json::from_str::<Value>(&line) {
                let mut pending = server_pending.lock().unwrap_or_else(|e| e.into_inner());
                if !pending.is_empty()
                    && let Some(said) = lock_check_answer(&message, &mut pending)
                {
                    server_checks_lock.store(said, Ordering::SeqCst);
                }
            }
            if server_out.send(format!("{line}\n")).is_err() {
                return;
            }
        }
    });
    let outdated = || !checks_lock.load(Ordering::SeqCst);
    // The helper reads what the gate read: each message goes on as the gate parsed it, so a line
    // two parsers read differently (a repeated key) cannot pass as one thing and act as another.
    // A line that does not parse goes on as it is, unless the screen is locked or the helper is
    // one that gets no call.
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
            Ok(message) => {
                let ids = initialize_ids(&message);
                if !ids.is_empty() {
                    pending_initialize.lock().unwrap_or_else(|e| e.into_inner()).extend(ids);
                }
                let gated =
                    match refuse_calls(&message, outdated, HELPER_OUTDATED, HELPER_OUTDATED_TEXT) {
                        Gated::Pass => gate(&message, &locked),
                        refused => refused,
                    };
                (gated, message.to_string())
            }
            Err(_) if outdated() || locked() => (Gated::Drop, String::new()),
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

    /// The initialize answer of a helper that reads the screen lock right before it acts.
    const CHECKS_LOCK: &str = r#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{},"experimental":{"cmux/lock-at-execution-v2":{}}},"serverInfo":{"name":"cmux-cua","version":"0.8.12"}}}"#;
    /// The answer of a proxy that said v1 from its own build alone, whatever helper ran its calls
    /// (review of cmux#37239, round 7).
    const V1_ONLY: &str = r#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{},"experimental":{"cmux/lock-at-execution-v1":{}}},"serverInfo":{"name":"cmux-cua","version":"0.8.12"}}}"#;
    /// The same answer from a helper built before that check.
    const OLDER: &str = r#"{"jsonrpc":"2.0","id":0,"result":{"protocolVersion":"2025-06-18","capabilities":{"tools":{}},"serverInfo":{"name":"cmux-cua","version":"0.8.12"}}}"#;

    /// The agent side, run through `run_with` with a stand-in helper that answers `initialize`
    /// with `answer` and echoes every other line: whatever reaches the helper comes back. The
    /// agent sends `initialize` and reads its answer before it sends `lines`, as an MCP client
    /// does.
    async fn through_helper(answer: &str, locked: bool, lines: &[&str]) -> Vec<String> {
        let (mut agent, input) = tokio::io::duplex(1 << 16);
        let (output, agent_out) = tokio::io::duplex(1 << 16);
        let script = r#"while IFS= read -r line; do case "$line" in *'"initialize"'*) printf '%s\n' "$1";; *) printf '%s\n' "$line";; esac; done"#;
        let args = ["-c".to_owned(), script.to_owned(), "sh".to_owned(), answer.to_owned()];
        let run = tokio::spawn(async move {
            run_with("sh", &args, BufReader::new(input), output, move || locked).await
        });
        let mut agent_out = BufReader::new(agent_out);
        agent
            .write_all(b"{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{}}\n")
            .await
            .unwrap();
        let mut initialized = String::new();
        let read = agent_out.read_line(&mut initialized);
        tokio::time::timeout(std::time::Duration::from_secs(20), read).await.unwrap().unwrap();
        assert_eq!(serde_json::from_str::<Value>(&initialized).unwrap()["id"], 0, "{initialized}");
        let mut text = lines.join("\n");
        text.push('\n');
        agent.write_all(text.as_bytes()).await.unwrap();
        drop(agent);
        tokio::time::timeout(std::time::Duration::from_secs(20), run)
            .await
            .unwrap()
            .unwrap()
            .unwrap();
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
        let seen = through_helper(CHECKS_LOCK, true, &lines).await;
        assert!(seen.iter().all(|line| !line.contains("tools/call")), "{seen:?}");
        assert!(seen.iter().any(|line| line.contains("tools/list")), "the rest passes: {seen:?}");
        let unlocked = through_helper(CHECKS_LOCK, false, &lines[..1]).await;
        assert_eq!(unlocked.len(), 1, "unlocked, the call passes: {unlocked:?}");
        assert!(unlocked[0].contains("tools/call"), "{unlocked:?}");
    }

    /// A helper built before it read the screen lock right before it acts (review of
    /// cmux#37239): a call that passed here unlocked could wait on consent and run after the Mac
    /// locked. So the gate sends such a helper no call at all, locked or not, and answers each
    /// one with a typed reason that says to update; everything else still passes.
    #[tokio::test]
    async fn a_helper_that_does_not_say_it_checks_the_lock_gets_no_call() {
        let lines = [
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click"}}"#,
            r#"{"jsonrpc":"2.0","method":"tools/call","params":{"name":"type"}}"#,
            r#"[{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"click"}}]"#,
            r#"{"jsonrpc":"2.0","method":"tools/call" "#,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
        ];
        let seen = through_helper(OLDER, false, &lines).await;
        assert!(seen.iter().all(|line| !line.contains("tools/call")), "{seen:?}");
        let replies: Vec<Value> =
            seen.iter().map(|line| serde_json::from_str(line).unwrap()).collect();
        let first = replies.iter().find(|reply| reply["id"] == 1).expect("the call is answered");
        assert_eq!(first["result"]["isError"], true);
        assert_eq!(first["result"]["structuredContent"]["error"], "cua_helper_outdated");
        let text = first["result"]["content"][0]["text"].as_str().unwrap();
        assert!(text.starts_with("cua_helper_outdated:") && text.contains("Update cmux"), "{text}");
        let batch = replies.iter().find(|reply| reply.is_array()).expect("the batch is answered");
        assert_eq!(batch[0]["result"]["structuredContent"]["error"], "cua_helper_outdated");
        assert!(seen.iter().any(|line| line.contains("tools/list")), "the rest passes: {seen:?}");
    }

    /// A v1 proxy said it checks the lock from its own build, though the calls run in a separately
    /// installed helper that may be older (review of cmux#37239, round 7). Only v2, which the
    /// executing process says, passes calls: a v1 proxy in front of any helper gets none.
    #[tokio::test]
    async fn a_proxy_that_says_only_v1_gets_no_call() {
        let lines = [
            r#"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"click"}}"#,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/list"}"#,
        ];
        let seen = through_helper(V1_ONLY, false, &lines).await;
        assert!(seen.iter().all(|line| !line.contains("tools/call")), "{seen:?}");
        let first: Value =
            serde_json::from_str(seen.iter().find(|l| l.contains("\"id\":1")).unwrap()).unwrap();
        assert_eq!(first["result"]["structuredContent"]["error"], "cua_helper_outdated");
        assert!(seen.iter().any(|line| line.contains("tools/list")), "the rest passes: {seen:?}");
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
