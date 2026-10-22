//! `acpmux send --no-wait` and `acpmux send --status ID`: the message goes to this daemon's
//! outbox, which delivers it (`hub/outbox.rs`, `server/outbox.rs`), so the command returns at
//! once for a session here or on a peer, however slow the peer or busy the target.

use super::*;

/// How long `--no-wait` gives a target that takes the message at once (a session here) to say
/// whether it steered in, before it prints the delivery id alone.
const QUICK_WAIT_MS: u64 = 500;

pub(super) async fn queue(
    client: &crate::client::Client,
    session: &str,
    text: &str,
    steer: bool,
    prompt_id: &PromptId,
    json_out: bool,
) -> Result<()> {
    let key = orchestrate::expand_session_key(session)?;
    let request = prompt_id.params(&key, text, steer, None);
    let queued =
        client.request(method::MUX_SEND_QUEUE, json!({"request": request})).await.map_err(|e| {
            if e.to_string().contains("no session") {
                anyhow::Error::from(errors::AppError::no_session(&key))
            } else {
                e
            }
        })?;
    let id = queued.get("deliveryId").and_then(Value::as_str).unwrap_or_default().to_owned();
    let status = client
        .request(method::MUX_SEND_STATUS, json!({"deliveryId": id, "waitMs": QUICK_WAIT_MS}))
        .await
        .unwrap_or(queued);
    let state = status.get("status").and_then(Value::as_str).unwrap_or("queued");
    // A refusal the target gave at once (its folder's trust, a bad prompt, a paused or full agent
    // pair) is this send's error, as it was before the outbox.
    if matches!(state, "failed" | "held") {
        let error = status.get("error").and_then(Value::as_str).unwrap_or("delivery failed");
        return Err(anyhow!("{error}"));
    }
    let steered = status.pointer("/accepted/steer") == Some(&json!(true));
    if json_out {
        let session_id = status.pointer("/accepted/sessionId").cloned().unwrap_or(json!(key));
        print_json(&json!({
            "deliveryId": id,
            "target": key,
            "sessionId": session_id,
            "promptId": prompt_id.id,
            "status": state,
            "queued": !steered,
            "steered": steered,
            "accepted": status.get("accepted"),
        }));
    } else if state == "delivered" {
        println!("{} (delivery {id})", if steered { "steered" } else { "queued" });
    } else {
        println!("queued for delivery {id} (acpmux send --status {id})");
    }
    Ok(())
}

pub(super) async fn status(
    client: &crate::client::Client,
    delivery: &str,
    json_out: bool,
) -> Result<()> {
    let v = client.request(method::MUX_SEND_STATUS, json!({"deliveryId": delivery})).await?;
    if json_out {
        print_json(&v);
        return Ok(());
    }
    let field = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default();
    let attempts = v.get("attempts").and_then(Value::as_u64).unwrap_or(0);
    let mut line = format!("{}  {}  attempt {attempts}", field("status"), field("target"));
    if let Some(turn) = v.pointer("/accepted/turnId").and_then(Value::as_str) {
        line.push_str(&format!("  turn {turn}"));
    }
    if v.pointer("/accepted/steer") == Some(&json!(true)) {
        line.push_str("  (steered)");
    }
    if let Some(error) = v.get("error").and_then(Value::as_str) {
        line.push_str(&format!("  last error: {error}"));
    }
    println!("{line}");
    Ok(())
}
