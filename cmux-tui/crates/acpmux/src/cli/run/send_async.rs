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
            Some(delivery) => format!("Delivery {delivery} is recorded; check it with {} send --status {delivery}, or resend with --prompt-id {} to reuse the same delivery.", crate::cli::entry::program(), prompt_id.id),
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
    let handoff = handed_off(&key, &queued, &status)?;
    if json_out {
        print_json(&handoff_json(&handoff, &key, &id, &prompt_id.id, &status, superseding));
    } else {
        warn_host_pressure(&status["accepted"], crate::cli::host_budget::Done::Queued);
        for line in handoff_lines(&handoff, &key, &id, &status, superseding) {
            println!("{line}");
        }
    }
    Ok(())
}

/// How far a send got once it left the sender: the word its first stdout line and `--json`'s
/// `state` give, so a script reads success from the exit code and this word, never from the
/// human sentence after it (a lane resent one report 7 times on 2026-11-22: its retry
/// loop read `held in its inbox` and `queued` as failures).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum SentState {
    /// In this daemon's outbox (the target not reached yet, or its machine down), or in the
    /// target's queue behind its running turn.
    Queued,
    /// In the idle receiver's inbox, which goes with its next turn.
    Held,
    /// The target took it: a turn of its own, or its queue.
    Delivered,
    /// Into the target's running turn, read at its next tool step.
    Steered,
}

impl SentState {
    pub(crate) fn name(self) -> &'static str {
        match self {
            SentState::Queued => "queued",
            SentState::Held => "held",
            SentState::Delivered => "delivered",
            SentState::Steered => "steered",
        }
    }

    /// What the target's acceptance says (`_acpmux/prompt_accepted`).
    pub(crate) fn of_accepted(accepted: &Value) -> Self {
        if accepted.get(super::super::output::HELD_IN_INBOX) == Some(&json!(true)) {
            SentState::Held
        } else if accepted.get("steer") == Some(&json!(true)) {
            SentState::Steered
        } else {
            SentState::Delivered
        }
    }
}

/// The first stdout line of every send that returns once handed off: `sent STATE id=ID to=TARGET`.
/// Its words stay as they are; the lines after it are for people and may change.
pub(crate) fn sent_line(state: SentState, id: &str, target: &str) -> String {
    format!("sent {} id={id} to={target}", state.name())
}

/// A send the outbox took, as [`handed_off`] reads its first status.
#[derive(Debug)]
pub(crate) struct Handoff {
    pub state: SentState,
    /// The outbox's own word: queued, delivering or delivered.
    pub status: String,
    /// Queued because the target's machine is down.
    pub unreachable: bool,
}

/// The outbox's answers for one send (`send_queue`, then the first `send_status`): a hand-off,
/// or the refusal the target gave at once (exit 4 for no such session, 7 for any other).
pub(crate) fn handed_off(key: &str, queued: &Value, status: &Value) -> Result<Handoff> {
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
            .with_session(key)
            .into());
        }
        let detail = status.get("reason").and_then(Value::as_str).unwrap_or("delivery_refused");
        return Err(errors::AppError::new(errors::Code::Refused, detail, error)
            .with_session(key)
            .into());
    }
    // Queued because the target's machine is down: said, so a sender knows it waits for it.
    let unreachable = queued.get("hostUnreachable") == Some(&json!(true))
        || (state == "queued"
            && status
                .get("error")
                .and_then(Value::as_str)
                .is_some_and(|e| e.contains("peer_unreachable")));
    let sent = if state == "delivered" {
        SentState::of_accepted(status.get("accepted").unwrap_or(&Value::Null))
    } else {
        SentState::Queued
    };
    Ok(Handoff { state: sent, status: state.to_owned(), unreachable })
}

/// What a hand-off prints without `--json`: [`sent_line`], then what it means for a person.
pub(crate) fn handoff_lines(
    handoff: &Handoff,
    key: &str,
    id: &str,
    status: &Value,
    superseding: bool,
) -> Vec<String> {
    let mut lines = vec![sent_line(handoff.state, id, key)];
    let program = crate::cli::entry::program();
    if handoff.status == "delivered" {
        let accepted = status.get("accepted").cloned().unwrap_or(Value::Null);
        let mut said = sent_lines_to(&accepted, superseding, key);
        said[0].push_str(&format!(" (delivery {id})"));
        lines.extend(said);
    } else if handoff.unreachable {
        lines.push(format!(
            "queued; host unreachable, will retry (delivery {id}; {program} send --status {id})"
        ));
    } else {
        lines.push(format!("queued for delivery {id} ({program} send --status {id})"));
    }
    lines
}

/// What a hand-off prints with `--json`: `ok`, `state` and `id` as [`sent_line`] names them,
/// beside the outbox's own fields.
pub(crate) fn handoff_json(
    handoff: &Handoff,
    key: &str,
    id: &str,
    prompt_id: &str,
    status: &Value,
    superseding: bool,
) -> Value {
    let steered = status.pointer("/accepted/steer") == Some(&json!(true));
    let session_id = status.pointer("/accepted/sessionId").cloned().unwrap_or(json!(key));
    let accepted = status.get("accepted").cloned().unwrap_or(Value::Null);
    let mut out = json!({
        "ok": true,
        "state": handoff.state.name(),
        "id": id,
        "deliveryId": id,
        "target": key,
        "sessionId": session_id,
        "promptId": prompt_id,
        "status": handoff.status,
        "queued": !steered,
        "steered": steered,
        "accepted": accepted,
        "hostUnreachable": handoff.unreachable,
    });
    if superseding {
        // null until delivered, or when the target's daemon predates the key.
        out["replaced"] = accepted.get("replaced").cloned().unwrap_or(Value::Null);
        out["replacedPromptIds"] =
            accepted.get("replacedPromptIds").cloned().unwrap_or(Value::Null);
    }
    out
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
    // No outbox, so no delivery id: the prompt id names this send.
    let state = SentState::of_accepted(&accepted);
    if json_out {
        let mut out = json!({
            "ok": true,
            "state": state.name(),
            "id": prompt_id.id,
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
        println!("{}", sent_line(state, &prompt_id.id, key));
        for line in sent_lines_to(&accepted, superseding, key) {
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
    println!("{}", status_line(&v));
    Ok(())
}

/// One delivery's `send_status` answer as `--status ID` prints it: its state, target, attempts,
/// the turn that took it, and the last error.
pub(crate) fn status_line(v: &Value) -> String {
    let field = |k: &str| v.get(k).and_then(Value::as_str).unwrap_or_default();
    let attempts = v.get("attempts").and_then(Value::as_u64).unwrap_or(0);
    let mut line = format!("{}  {}  attempt {attempts}", state_label(v), field("target"));
    if let Some(turn) = v.pointer("/accepted/turnId").and_then(Value::as_str) {
        line.push_str(&format!("  turn {turn}"));
    }
    if v.pointer("/accepted/steer") == Some(&json!(true)) {
        line.push_str("  (steered)");
    }
    if v.pointer(&format!("/accepted/{}", super::super::output::HELD_IN_INBOX))
        == Some(&json!(true))
    {
        line.push_str(&format!("  ({})", super::super::output::HELD_LINE));
    }
    if let Some(error) = v.get("error").and_then(Value::as_str) {
        line.push_str(&format!("  last error: {error}"));
    }
    line
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

    /// The process's exit status for a send's outcome, as `errors::exit_with` gives it.
    fn exit_of(r: &Result<Handoff>) -> i32 {
        match r {
            Ok(_) => 0,
            Err(e) => errors::classify(e).exit_status(),
        }
    }

    fn delivered(accepted: Value) -> Value {
        json!({"status": "delivered", "accepted": accepted})
    }

    /// Every hand-off exits 0 and opens with `sent STATE id=ID to=TARGET`, in text and as
    /// `--json`'s `ok`, `state` and `id`: queued in the outbox (the target busy or its machine
    /// down), held in an idle receiver's inbox, delivered, or steered into a running turn.
    #[test]
    fn each_hand_off_exits_0_and_opens_with_its_state() {
        let queued = json!({"deliveryId": "d1"});
        let cases = [
            (queued.clone(), json!({"status": "queued"}), "queued"),
            (queued.clone(), json!({"status": "delivering"}), "queued"),
            (
                json!({"deliveryId": "d1", "hostUnreachable": true}),
                json!({"status": "queued"}),
                "queued",
            ),
            (queued.clone(), json!({"status": "queued", "error": "peer_unreachable"}), "queued"),
            (queued.clone(), delivered(json!({"heldInInbox": true})), "held"),
            (queued.clone(), delivered(json!({"heldInInbox": true, "steer": true})), "held"),
            (queued.clone(), delivered(json!({"steer": true})), "steered"),
            (queued.clone(), delivered(json!({"steer": false})), "delivered"),
            (queued.clone(), delivered(Value::Null), "delivered"),
        ];
        for (queued, status, want) in cases {
            let r = handed_off("gcp-agent-lane-1/lane", &queued, &status);
            assert_eq!(exit_of(&r), 0, "{status}");
            let handoff = r.unwrap();
            assert_eq!(handoff.state.name(), want, "{status}");
            let lines = handoff_lines(&handoff, "gcp-agent-lane-1/lane", "d1", &status, false);
            assert_eq!(lines[0], format!("sent {want} id=d1 to=gcp-agent-lane-1/lane"), "{status}");
            assert!(lines.len() >= 2, "the human line follows: {lines:?}");
            let out = handoff_json(&handoff, "gcp-agent-lane-1/lane", "d1", "p1", &status, false);
            assert_eq!(
                (&out["ok"], &out["state"], &out["id"]),
                (&json!(true), &json!(want), &json!("d1")),
                "{out}"
            );
        }
    }

    /// The human wording stays after the stable line: what each state means for a person.
    #[test]
    fn the_human_line_follows_the_stable_one() {
        let held = delivered(json!({"heldInInbox": true}));
        let h = handed_off("lane", &json!({}), &held).unwrap();
        let lines = handoff_lines(&h, "lane", "d2", &held, false);
        assert_eq!(lines[1], format!("{} (delivery d2)", super::super::super::output::HELD_LINE));
        let down = json!({"status": "queued"});
        let h = handed_off("lane", &json!({"hostUnreachable": true}), &down).unwrap();
        assert!(
            handoff_lines(&h, "lane", "d3", &down, false)[1]
                .starts_with("queued; host unreachable, will retry (delivery d3;")
        );
        let steered = delivered(json!({"steer": true, "replaced": 2}));
        let h = handed_off("lane", &json!({}), &steered).unwrap();
        assert_eq!(
            handoff_lines(&h, "lane", "d4", &steered, true),
            ["sent steered id=d4 to=lane", "steered (delivery d4)", "replaced 2 queued"]
        );
    }

    /// A refusal the target gave at once exits nonzero and prints no `sent` line: 4 for no such
    /// session, 7 for any other (a paused or full pair is the outbox's `held`, not an inbox's).
    #[test]
    fn a_refusal_exits_4_or_7() {
        let no_session = json!({"status": "failed", "reason": "no_session",
            "error": "no_session: no session proc-title on host; did you mean: feed-lane"});
        assert_eq!(exit_of(&handed_off("host/proc-title", &json!({}), &no_session)), 4);
        let refused = json!({"status": "failed", "error": "folder is not trusted"});
        let r = handed_off("lane", &json!({}), &refused);
        assert_eq!(exit_of(&r), 7);
        let app = errors::classify(r.as_ref().unwrap_err());
        assert_eq!((app.code.name(), app.message.as_str()), ("refused", "folder is not trusted"));
        let paused =
            json!({"status": "held", "reason": "pair_paused", "error": "the pair is paused"});
        let r = handed_off("lane", &json!({}), &paused);
        assert_eq!(exit_of(&r), 7);
        assert_eq!(errors::classify(r.as_ref().unwrap_err()).detail, "pair_paused");
        assert_eq!(exit_of(&handed_off("lane", &json!({}), &json!({"status": "failed"}))), 7);
    }

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
