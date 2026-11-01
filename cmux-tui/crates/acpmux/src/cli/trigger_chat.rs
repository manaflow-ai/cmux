//! Cloud trigger chat bridge.
//!
//! A platform trigger worker writes exactly one JSON operation to stdin.  The
//! worker authenticates the short-lived principal before invoking this command;
//! this process never accepts an owner token and never puts the principal in a
//! prompt or environment.  The local daemon is then used through its normal
//! ACP socket, with bounded trigger provenance on the prompt.

use anyhow::{Context, Result, anyhow};
use serde_json::{Value, json};
use std::io::Read;

use crate::rpc::method;

const MAX_INPUT_BYTES: usize = 128 * 1024;

fn required(input: &Value, key: &str) -> Result<String> {
    input
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty() && v.len() <= 256 && !v.chars().any(char::is_control))
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("trigger-chat: missing or invalid {key}"))
}

fn operation(input: Value) -> Result<&'static str> {
    match input.get("operation").and_then(Value::as_str) {
        Some("ensure") => Ok("ensure"),
        Some("send") => Ok("send"),
        Some("status") => Ok("status"),
        _ => Err(anyhow!("trigger-chat: operation must be ensure, send or status")),
    }
}

/// Read and execute one trigger operation. A daemon that does not advertise
/// `trigger-chat-v1` is a hard unsupported result for callers (exit 82 is
/// applied by the package launcher); this command never falls back to a normal
/// person prompt.
pub async fn run() -> Result<()> {
    let mut bytes = Vec::new();
    std::io::stdin()
        .take((MAX_INPUT_BYTES + 1) as u64)
        .read_to_end(&mut bytes)
        .context("read trigger-chat stdin")?;
    if bytes.len() > MAX_INPUT_BYTES {
        return Err(anyhow!("trigger-chat: input exceeds {MAX_INPUT_BYTES} bytes"));
    }
    let input: Value = serde_json::from_slice(&bytes).context("trigger-chat: invalid JSON")?;
    let op = operation(input.clone())?;
    // The token is consumed by the fixed platform authorize call in the
    // provider/guest wrapper. It is intentionally never forwarded to the
    // daemon or included in a session log.
    let _token = required(&input, "token")?;
    let principal = input
        .get("principal")
        .cloned()
        .ok_or_else(|| anyhow!("trigger-chat: platform authorization is required"))?;
    let client = crate::daemon::connect(true).await?;
    if !client.daemon_lists(crate::capabilities::TRIGGER_CHAT) {
        return Err(anyhow!("trigger-chat unsupported: daemon lacks trigger-chat-v1"));
    }
    let result = match op {
        "ensure" => {
            client
                .request(
                    method::TRIGGER_CHAT_ENSURE,
                    json!({"operation": "ensure", "principal": principal}),
                )
                .await?
        }
        "send" => {
            let prompt = required(&input, "prompt")?;
            client
                .request(
                    method::TRIGGER_CHAT_SEND,
                    json!({"operation": "send", "body": prompt, "principal": principal}),
                )
                .await?
        }
        "status" => {
            client
                .request(
                    method::TRIGGER_CHAT_STATUS,
                    json!({"operation": "status", "principal": principal}),
                )
                .await?
        }
        _ => unreachable!(),
    };
    serde_json::to_writer(std::io::stdout(), &result)?;
    println!();
    Ok(())
}
