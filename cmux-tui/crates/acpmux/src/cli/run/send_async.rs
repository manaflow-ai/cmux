//! `acpmux send --no-wait` and `acpmux send --status ID`: the message goes to this daemon's
//! outbox, which delivers it (`hub/outbox.rs`, `server/outbox.rs`), so the command returns at
//! once for a session here or on a peer, however slow the peer or busy the target.

use super::*;
use cmux_json::JsonSet as _;

/// How long `--no-wait` gives a target that takes the message at once (a session here) to say
/// whether it steered in, before it prints the delivery id alone.
const QUICK_WAIT_MS: u64 = 500;

#[allow(clippy::too_many_arguments)]
pub(super) async fn queue(
    client: &std::sync::Arc<crate::client::Client>,
    session: &str,
    text: &str,
    steer: bool,
    prompt_id: &PromptId,
    superseding: bool,
    json_out: bool,
    deadline: Option<tokio::time::Instant>,
) -> Result<()> {
    let mut delivery_id = None;
    let outcome = async {
        match before_deadline(
            deadline,
            session,
            queue_once(
                client,
                session,
                text,
                steer,
                prompt_id,
                superseding,
                json_out,
                &mut delivery_id,
            ),
        )
        .await
        {
            Ok(()) => Ok(()),
            Err(error) if super::super::output::daemon_closed_error(&error) => {
                let replacement = before_deadline(deadline, session, async {
                    super::super::output::reconnect_after_update().await.map_err(|e| {
                        prompt_id.closed(
                            client,
                            session,
                            &format!("reconnecting after daemon update: {e}"),
                        )
                    })
                })
                .await?;
                let mut retry = prompt_id.clone();
                retry.resend = true;
                before_deadline(
                    deadline,
                    session,
                    queue_once(
                        &replacement,
                        session,
                        text,
                        steer,
                        &retry,
                        superseding,
                        json_out,
                        &mut delivery_id,
                    ),
                )
                .await
            }
            Err(error) => Err(error),
        }
    }
    .await;
    outcome.map_err(|error| {
        let Some(app) = error.downcast_ref::<errors::AppError>() else { return error };
        if app.code != errors::Code::Timeout { return error; }
        let recovery = match &delivery_id {
            Some(delivery) => format!("Delivery {delivery} is recorded; check it with acpmux send --status {delivery}, or resend with --prompt-id {} to reuse the same delivery.", prompt_id.id),
            None => format!("The prompt may have been accepted; resend with --prompt-id {} to recover its outcome without running it twice.", prompt_id.id),
        };
        let mut data = json!({"resend": true, "recovery": recovery});
        if let Some(delivery) = delivery_id { data["deliveryId"] = json!(delivery); }
        app.clone().with_session(session).with_prompt(&prompt_id.id).retryable().with_data(data).into()
    })
}

#[allow(clippy::too_many_arguments)]
async fn queue_once(
    client: &std::sync::Arc<crate::client::Client>,
    session: &str,
    text: &str,
    steer: bool,
    prompt_id: &PromptId,
    superseding: bool,
    json_out: bool,
    delivery_id: &mut Option<String>,
) -> Result<()> {
    let key = orchestrate::expand_session_key(session)?;
    let request = prompt_id.params(&key, text, steer, None);
    let queued = match client.request(method::MUX_SEND_QUEUE, json!({"request": request})).await {
        Ok(queued) => queued,
        Err(e) if method_not_found(&e) => {
            return queue_direct(client, &key, text, steer, prompt_id, superseding, json_out).await;
        }
        Err(e) if e.to_string().contains("no session") => {
            return Err(errors::AppError::no_session_from(&key, &e).into());
        }
        Err(e) if super::super::output::daemon_closed_error(&e) => {
            return Err(prompt_id.closed(client, &key, "queueing the prompt"));
        }
        Err(e) => return Err(e),
    };
    let id = queued.get("deliveryId").and_then(Value::as_str).unwrap_or_default().to_owned();
    *delivery_id = (!id.is_empty()).then(|| id.clone());
    let status = client
        .request(
            method::MUX_SEND_STATUS,
            json!({"deliveryId": id, "waitMs": QUICK_WAIT_MS, "firstAttempt": true}),
        )
        .await
        .unwrap_or_else(|_| queued.clone());
    let state = status.get("status").and_then(Value::as_str).unwrap_or("queued");
    // A refusal the target gave at once (its folder's trust, a bad prompt, a paused or full agent
    // pair) is this send's error, as it was before the outbox.
    if matches!(state, "failed" | "held") {
        let error = status.get("error").and_then(Value::as_str).unwrap_or("delivery failed");
        // The target's machine has no such session: exit 4, with its close names. Its own
        // detail: a delivery's failure is never handed to `sendRelay` (`send_relay.rs`).
        if let Some(text) = error.strip_prefix(crate::hub::no_session::NO_SESSION_PREFIX) {
            return Err(errors::AppError::new(
                errors::Code::NoSession,
                "delivery_no_session",
                text,
            )
            .with_session(&key)
            .into());
        }
        return Err(anyhow!("{error}"));
    }
    // Queued because the target's machine is down: said, so a sender knows it waits for it.
    let unreachable = queued.get("hostUnreachable") == Some(&json!(true))
        || (state == "queued"
            && status
                .get("error")
                .and_then(Value::as_str)
                .is_some_and(|e| e.contains("peer_unreachable")));
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
            "hostUnreachable": unreachable,
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
    } else if unreachable {
        println!("queued; host unreachable, will retry (delivery {id}; acpmux send --status {id})");
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
    let mut line = format!("{}  {}  attempt {attempts}", state_label(&v), field("target"));
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

/// `acpmux send --status` with no id: every message this daemon was handed to deliver (or only
/// `caller`'s), newest first, one line each: its state, target, attempts and age, and the last
/// error of one still waiting.
pub(crate) async fn list(
    client: &crate::client::Client,
    caller: Option<&str>,
    json_out: bool,
) -> Result<()> {
    let mut params = json!({"list": true});
    if let Some(caller) = caller {
        params.set("caller", json!(caller));
    }
    let v = client.request(method::MUX_SEND_STATUS, params).await?;
    if json_out {
        print_json(&v);
        return Ok(());
    }
    for line in list_lines(&v, crate::store::now_ms()) {
        println!("{line}");
    }
    Ok(())
}

/// A delivery's state as `--status` prints it: `failed: no_session` for one whose target's
/// machine has no such session, else its state.
fn state_label(d: &Value) -> String {
    let state = d.get("status").and_then(Value::as_str).unwrap_or_default();
    match d.get("reason").and_then(Value::as_str) {
        Some(reason) if state == "failed" => format!("failed: {reason}"),
        _ => state.to_owned(),
    }
}

/// What [`list`] prints for a `send_status {list: true}` answer, as of `now` (ms).
pub(crate) fn list_lines(v: &Value, now: u64) -> Vec<String> {
    let deliveries = v.get("deliveries").and_then(Value::as_array).cloned().unwrap_or_default();
    if deliveries.is_empty() {
        return vec!["no messages queued or sent in the last day".to_owned()];
    }
    let pending = v.get("pending").and_then(Value::as_u64).unwrap_or(0);
    let mut lines = vec![format!("{pending} waiting, {} in all", deliveries.len())];
    for d in &deliveries {
        let field = |k: &str| d.get(k).and_then(Value::as_str).unwrap_or_default();
        let at = d.get("createdAt").and_then(Value::as_u64).unwrap_or(now);
        let age = now.saturating_sub(at) / 1000;
        let age = if age < 120 {
            format!("{age}s")
        } else if age < 7200 {
            format!("{}m", age / 60)
        } else {
            format!("{}h", age / 3600)
        };
        let attempts = d.get("attempts").and_then(Value::as_u64).unwrap_or(0);
        let mut line = format!(
            "{:<10}  {}  {} ago  attempt {attempts}  {}",
            state_label(d),
            field("target"),
            age,
            field("deliveryId")
        );
        if matches!(field("status"), "queued" | "delivering" | "failed" | "held")
            && let Some(error) = d.get("error").and_then(Value::as_str)
        {
            line.push_str(&format!("  last error: {}", super::super::output::short(error, 120)));
        }
        lines.push(line);
    }
    lines
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_delivery_with_no_such_session_reads_failed_no_session() {
        let v = json!({"pending": 0, "deliveries": [
            {"deliveryId": "d3", "target": "host/proc-title", "status": "failed", "attempts": 1,
             "createdAt": 10_000, "reason": "no_session",
             "error": "no_session: no session proc-title on host; did you mean: feed-lane"},
        ]});
        assert_eq!(
            list_lines(&v, 70_000)[1],
            "failed: no_session  host/proc-title  60s ago  attempt 1  d3  last error: no_session: no session proc-title on host; did you mean: feed-lane"
        );
        assert_eq!(state_label(&json!({"status": "queued", "reason": null})), "queued");
    }

    #[test]
    fn list_lines_show_state_target_age_and_the_waiting_ones_error() {
        assert_eq!(
            list_lines(&json!({"deliveries": []}), 0),
            ["no messages queued or sent in the last day"]
        );
        let v = json!({"pending": 1, "deliveries": [
            {"deliveryId": "d2", "target": "gcp-agent-lane-1/lane", "status": "queued", "attempts": 3,
             "createdAt": 10_000, "error": "peer_unreachable"},
            {"deliveryId": "d1", "target": "lane", "status": "delivered", "attempts": 1,
             "createdAt": 1_000, "error": null},
        ]});
        assert_eq!(
            list_lines(&v, 70_000),
            [
                "1 waiting, 2 in all",
                "queued      gcp-agent-lane-1/lane  60s ago  attempt 3  d2  last error: peer_unreachable",
                "delivered   lane  69s ago  attempt 1  d1",
            ]
        );
    }
}
