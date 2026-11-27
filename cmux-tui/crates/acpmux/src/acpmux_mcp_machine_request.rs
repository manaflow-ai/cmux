//! The `acpmux` MCP server's `machine_request` tool: `cmux machine request` for an agent on a
//! cmux Cloud machine (cmux-tui `cli/machine_request.rs`), as a tool call.
//!
//! Leo, 2026-11-25: "but what if we want even more than the 32vcpu machines? how can an agent
//! know/ask for more capacity?" and "when they're on the vm that is". cmuxterm-hq RFD draft
//! `docs/rfd/drafts/agent-work-placement.md`, sections 9 and 13.
//!
//! The ask goes over this machine's agent socket as `{"machine_request": {...}}`; cmux-host
//! (`cloud/machine_request.rs`) sends `cloud.vm.machine.request` as the machine's own `vm`
//! install, so no person's token is involved and the machine is always this one. The answer is
//! at once: fits, grow, over_plan, fanout, unavailable, or a refusal with its code.

use super::error_result;
use cmux_host::cloud::machine_request::{REQUEST_KEY, check_ask};
use serde_json::{Value, json};
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};

pub(super) const NAME: &str = "machine_request";

/// The agent's own bound is one platform op; above it, the answer is lost.
const ASK_BOUND: Duration = Duration::from_secs(90);
const MAX_REPLY: u64 = 1 << 20;

pub(super) fn tool() -> Value {
    json!({
        "name": NAME,
        "description": "Ask for more capacity for THIS cmux Cloud machine (vCPU, memory), as `cmux machine request` does. Answers at once: fits (already has it), grow (resizing now, within the plan), over_plan (the largest the plan takes, and what lifts it), fanout (past 32 vCPU / 64 GiB: K machines made now, answered as a handle with each machine id), or unavailable. Only on a cmux Cloud machine.",
        "inputSchema": {
            "type": "object",
            "properties": {
                "vcpu": {"type": "integer", "minimum": 1, "description": "Total vCPUs wanted."},
                "mem_gib": {"type": "integer", "minimum": 1, "description": "Total GiB of memory (default 2 per vCPU)."},
                "fanout": {"type": "integer", "minimum": 1, "maximum": 64, "description": "Split over this many machines."},
                "kind": {"type": "string", "enum": ["linux", "mac", "gpu"]},
                "for": {"type": "string", "description": "What the capacity is for."},
                "until": {"type": "string", "description": "DONE (default) or a duration: 30m, 2h, 1d."}
            },
            "required": ["vcpu", "for"]
        }
    })
}

/// The tool result for a reply line from the agent socket.
pub(super) fn result_for(reply: &Value) -> Value {
    if reply.get("ok") != Some(&json!(true)) {
        let code =
            reply.pointer("/error/code").and_then(Value::as_str).unwrap_or("machine.unavailable");
        let message = reply
            .pointer("/error/message")
            .and_then(Value::as_str)
            .unwrap_or("this machine's cmux Cloud agent refused the machine request");
        return error_result(format!("{code}: {message}"));
    }
    let mut structured = reply.clone();
    if let Some(map) = structured.as_object_mut() {
        map.remove("ok");
    }
    let outcome = reply.get("outcome").and_then(Value::as_str).unwrap_or("");
    let message = reply.get("message").and_then(Value::as_str).unwrap_or("");
    super::ok(format!("{outcome}: {message}"), structured)
}

pub(super) async fn call(args: &Value) -> Value {
    let ask = match check_ask(args) {
        Ok(ask) => ask,
        Err(message) => return error_result(message),
    };
    let Some(socket) = crate::hosted_mcp::cloud_socket() else {
        return error_result(
            "machine.unavailable: machine_request runs on a cmux Cloud machine; this is not one"
                .to_owned(),
        );
    };
    let line = json!({ (REQUEST_KEY): Value::Object(ask.0) });
    match ask_socket(&socket, &line).await {
        Ok(reply) => result_for(&reply),
        Err(message) => error_result(format!("machine.unreachable: {message}")),
    }
}

async fn ask_socket(socket: &std::path::Path, line: &Value) -> Result<Value, String> {
    let unreachable = || "this machine's cmux Cloud agent is not reachable".to_owned();
    let exchange = async {
        #[cfg(unix)]
        let mut stream =
            tokio::net::UnixStream::connect(socket).await.map_err(|_| unreachable())?;
        // The Cloud agent's socket is a unix socket, on a Cloud machine: none elsewhere.
        #[cfg(not(unix))]
        let mut stream: tokio::io::DuplexStream = {
            let _ = socket;
            return Err(unreachable());
        };
        let mut text = line.to_string();
        text.push('\n');
        stream.write_all(text.as_bytes()).await.map_err(|_| unreachable())?;
        let mut reply = String::new();
        BufReader::new(stream)
            .take(MAX_REPLY)
            .read_line(&mut reply)
            .await
            .map_err(|_| unreachable())?;
        serde_json::from_str::<Value>(&reply)
            .map_err(|_| "this machine's cmux Cloud agent sent no answer".to_owned())
    };
    tokio::time::timeout(ASK_BOUND, exchange)
        .await
        .map_err(|_| "the machine request had no answer in 90 s".to_owned())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn grow_is_a_result_and_a_refusal_an_error() {
        let ok = result_for(
            &json!({"ok": true, "outcome": "grow", "message": "Growing", "machine": "vm_1"}),
        );
        assert_eq!(ok["isError"], false);
        assert_eq!(ok["content"][0]["text"], "grow: Growing");
        assert_eq!(
            ok["structuredContent"],
            json!({"outcome": "grow", "message": "Growing", "machine": "vm_1"})
        );
        let no =
            result_for(&json!({"ok": false, "error": {"code": "auth.refused", "message": "no"}}));
        assert_eq!(no["isError"], true);
    }

    #[tokio::test]
    async fn a_bad_ask_never_reaches_the_socket() {
        assert_eq!(call(&json!({"vcpu": 4})).await["isError"], true);
    }
}
