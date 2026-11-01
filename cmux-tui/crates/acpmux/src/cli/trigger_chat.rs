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

fn required(input: &Value, key: &str, max: usize) -> Result<String> {
    input
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty() && v.len() <= max && !v.chars().any(char::is_control))
        .map(str::to_owned)
        .ok_or_else(|| anyhow!("trigger-chat: missing or invalid {key}"))
}

fn prompt(input: &Value, key: &str) -> Result<String> {
    let value = input
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty() && v.len() <= 64 * 1024)
        .ok_or_else(|| anyhow!("trigger-chat: missing or invalid {key}"))?;
    if value.chars().any(|c| c.is_control() && !matches!(c, '\n' | '\r' | '\t')) {
        return Err(anyhow!("trigger-chat: prompt contains a forbidden control"));
    }
    Ok(value.to_owned())
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
pub async fn run(protocol: &str, principal_fd: i32) -> Result<()> {
    if protocol != "trigger-chat-v1" {
        return Err(anyhow!("trigger-chat: --protocol must be trigger-chat-v1"));
    }
    if principal_fd != 0 {
        return Err(anyhow!("trigger-chat: --principal-fd must be 0"));
    }
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
    let token = required(&input, "token", 8192)?;
    let client = crate::daemon::connect_without_caller(true).await?;
    if !client.daemon_lists(crate::capabilities::TRIGGER_CHAT) {
        return Err(anyhow::Error::new(
            crate::cli::errors::AppError::new(
                crate::cli::errors::Code::Runtime,
                "trigger_unsupported",
                "trigger-chat unsupported: daemon lacks trigger-chat-v1",
            )
            .with_exit(82),
        ));
    }
    let result = match op {
        "ensure" => {
            client
                .request(
                    method::TRIGGER_CHAT_ENSURE,
                    json!({
                        "operation": "ensure", "token": token.clone(),
                        "workspace": required(&input, "workspace", 256)?,
                        "session": required(&input, "session", 256)?,
                        "delivery": required(&input, "delivery", 512)?,
                        "cwd": required(&input, "cwd", 4096)?,
                        "harness": required(&input, "harness", 256)?,
                    }),
                )
                .await?
        }
        "send" => {
            let prompt = prompt(&input, "prompt")?;
            client
                .request(
                    method::TRIGGER_CHAT_SEND,
                    json!({
                        "operation": "send", "token": token.clone(), "body": prompt,
                        "workspace": required(&input, "workspace", 256)?,
                        "session": required(&input, "session", 256)?,
                        "delivery": required(&input, "delivery", 512)?,
                    }),
                )
                .await?
        }
        "status" => {
            client
                .request(
                    method::TRIGGER_CHAT_STATUS,
                    json!({
                        "operation": "status", "token": token.clone(),
                        "workspace": required(&input, "workspace", 256)?,
                        "session": required(&input, "session", 256)?,
                        "delivery": required(&input, "delivery", 512)?,
                        "turn": required(&input, "turn", 256)?,
                    }),
                )
                .await?
        }
        _ => unreachable!(),
    };
    serde_json::to_writer(std::io::stdout(), &result)?;
    println!();
    Ok(())
}
