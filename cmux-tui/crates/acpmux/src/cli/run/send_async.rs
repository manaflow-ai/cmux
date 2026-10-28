//! `acpmux send --no-wait` and `acpmux send --status ID`: the message goes to this daemon's
//! outbox, which delivers it (`hub/outbox.rs`, `server/outbox.rs`), so the command returns at
//! once for a session here or on a peer, however slow the peer or busy the target.

use super::*;

/// How long `--no-wait` gives a target that takes the message at once (a session here) to say
/// whether it steered in, before it prints the delivery id alone.
const QUICK_WAIT_MS: u64 = 500;

pub(super) async fn queue(
    client: &std::sync::Arc<crate::client::Client>,
    session: &str,
    text: &str,
    steer: bool,
    prompt_id: &PromptId,
    superseding: bool,
    json_out: bool,
) -> Result<()> {
    let key = orchestrate::expand_session_key(session)?;
    let request = prompt_id.params(&key, text, steer, None);
    let queued = match client.request(method::MUX_SEND_QUEUE, json!({"request": request})).await {
        Ok(queued) => queued,
        Err(e) if method_not_found(&e) => {
            return queue_direct(client, &key, text, steer, prompt_id, superseding, json_out).await;
        }
        Err(e) if e.to_string().contains("no session") => {
            return Err(errors::AppError::no_session(&key).into());
        }
        Err(e) => return Err(e),
    };
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
    if !json_out {
        warn_host_pressure(&status["accepted"]);
    }
    if json_out {
        let session_id = status.pointer("/accepted/sessionId").cloned().unwrap_or(json!(key));
        let accepted = status.get("accepted").cloned().unwrap_or(Value::Null);
        let mut out = json!({
            "deliveryId": id,
            "target": key,
            "sessionId": session_id,
            "promptId": prompt_id.id,
            "status": state,
            "queued": !steered,
            "steered": steered,
            "accepted": accepted,
        });
        if superseding {
            // null until delivered, or when the target's daemon predates the key.
            out["replaced"] = accepted.get("replaced").cloned().unwrap_or(Value::Null);
            out["replacedPromptIds"] =
                accepted.get("replacedPromptIds").cloned().unwrap_or(Value::Null);
        }
        print_json(&out);
    } else if state == "delivered" {
        let accepted = status.get("accepted").cloned().unwrap_or(Value::Null);
        let mut lines = sent_lines(&accepted, superseding);
        lines[0].push_str(&format!(" (delivery {id})"));
        for line in lines {
            println!("{line}");
        }
    } else {
        println!("queued for delivery {id} (acpmux send --status {id})");
    }
    Ok(())
}

/// The daemon answered that it has no such method: it is older than this CLI.
fn method_not_found(e: &anyhow::Error) -> bool {
    e.downcast_ref::<crate::client::DaemonError>().is_some_and(|d| d.0.code == -32601)
}

/// `--no-wait` to a daemon from before the outbox (`_acpmux/send_queue`, #23880): send the prompt
/// straight to the session and return once the daemon recorded it, as `--no-wait` did then. A CLI
/// updated ahead of the app's daemon (cosmic-gray, 2026-10-22) keeps working; the daemon gets the
/// outbox when it restarts on the new build.
async fn queue_direct(
    client: &std::sync::Arc<crate::client::Client>,
    key: &str,
    text: &str,
    steer: bool,
    prompt_id: &PromptId,
    superseding: bool,
    json_out: bool,
) -> Result<()> {
    let build = client.daemon_build().unwrap_or_else(|| "unknown".to_owned());
    eprintln!(
        "acpmux: the daemon (build {build}) is older than this CLI and has no _acpmux/send_queue; \
         sending directly. Restart the daemon on the new build for the outbox."
    );
    let id = resolve_id(client, key).await?;
    let accepted = queue_prompt(client.clone(), &id, text, steer, None, prompt_id).await?;
    let steered = accepted.get("steer") == Some(&json!(true));
    if json_out {
        let mut out = json!({
            "sessionId": id,
            "target": key,
            "promptId": prompt_id.id,
            "status": "delivered",
            "queued": !steered,
            "steered": steered,
            "accepted": accepted,
        });
        if superseding {
            out["replaced"] = accepted.get("replaced").cloned().unwrap_or(Value::Null);
            out["replacedPromptIds"] =
                accepted.get("replacedPromptIds").cloned().unwrap_or(Value::Null);
        }
        print_json(&out);
    } else {
        for line in sent_lines(&accepted, superseding) {
            println!("{line}");
        }
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
