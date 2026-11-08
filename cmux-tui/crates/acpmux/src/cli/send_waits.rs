//! The line `acpmux send` prints the moment its prompt waits for an unreachable machine
//! (`_acpmux/prompt_accepted` with `state: "outbox"`, `server/prompt_outbox.rs`). Without it a
//! send wrapped in `timeout 60` reads as a hang, and the caller that gives up and sends again
//! with a new prompt id would run the prompt twice: the line names the id to reuse and the
//! delivery to check.

use serde_json::Value;

/// The line for acceptance `p` of prompt `prompt_id`, when the daemon keeps it waiting; None for
/// any other acceptance. The deadline is in this machine's local time.
pub(crate) fn line(p: &Value, prompt_id: &str) -> Option<String> {
    line_at(p, prompt_id, &chrono::Local)
}

pub(crate) fn line_at<Tz: chrono::TimeZone>(p: &Value, prompt_id: &str, tz: &Tz) -> Option<String>
where
    Tz::Offset: std::fmt::Display,
{
    if p.get("state").and_then(Value::as_str) != Some("outbox")
        || p.get("promptId").and_then(Value::as_str) != Some(prompt_id)
    {
        return None;
    }
    let host = p.get("peer").and_then(Value::as_str).unwrap_or("its machine");
    let until = p
        .get("expiresAt")
        .and_then(Value::as_i64)
        .and_then(|ms| chrono::DateTime::from_timestamp_millis(ms))
        .map(|at| format!(", until {}", at.with_timezone(tz).format("%H:%M")))
        .unwrap_or_default();
    let check = p
        .get("deliveryId")
        .and_then(Value::as_str)
        .map(|id| format!("; check it with `acpmux send --status {id}`"))
        .unwrap_or_default();
    Some(format!(
        "waits for {host}{until}; runs once when it is back. It stays queued if this command exits: \
         to send again, reuse --prompt-id {prompt_id}{check}"
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn an_outbox_acceptance_says_what_it_waits_for_until_when_and_how_to_resend() {
        // 2026-11-08 09:15:00 UTC.
        let p = json!({"promptId": "p1", "state": "outbox", "peer": "build-mac",
                       "expiresAt": 1_794_129_300_000_i64, "deliveryId": "d1", "turnId": null});
        assert_eq!(
            line_at(&p, "p1", &chrono::Utc).as_deref(),
            Some(
                "waits for build-mac, until 09:15; runs once when it is back. It stays queued if \
                 this command exits: to send again, reuse --prompt-id p1; check it with \
                 `acpmux send --status d1`"
            )
        );
    }

    #[test]
    fn only_this_prompts_outbox_acceptance_prints_a_line() {
        let started = json!({"promptId": "p1", "state": "started", "turnId": "t1", "peer": "b"});
        assert_eq!(line_at(&started, "p1", &chrono::Utc), None);
        let other = json!({"promptId": "p2", "state": "outbox", "peer": "b"});
        assert_eq!(line_at(&other, "p1", &chrono::Utc), None);
        let bare = json!({"promptId": "p1", "state": "outbox"});
        assert_eq!(
            line_at(&bare, "p1", &chrono::Utc).as_deref(),
            Some(
                "waits for its machine; runs once when it is back. It stays queued if this \
                 command exits: to send again, reuse --prompt-id p1"
            )
        );
    }
}
