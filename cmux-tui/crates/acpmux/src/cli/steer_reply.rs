//! The reply of a waiting `acpmux send` that steered: the reply of the turn it went into.
//!
//! An agent's send steers by default (`run/standard.rs` `send_steers`), whether or not it waits
//! for the reply. Claude Code answers a steer `steered` as soon as it reads the message, at its
//! next tool boundary, and the turn runs on (`claude_stdio`); codex-acp answers it only when the
//! turn ends (`hub/steer_end.rs`). So after a `steered` answer the send waits for that turn's
//! end in the session's events (`turn_end`, `turn_error`, `turn_result`) and answers with it,
//! and its reply is that turn's last words, read from the log. A steer whose turn ended before
//! the agent read it runs as the next prompt (`steer_end.rs`), whose answer comes back as any
//! prompt's does.
//!
//! The end may not come as an event: the turn ended before the send attached (a resend of the
//! same `--prompt-id` answered with the first run's `steered`), the daemon dropped events for a
//! slow reader (`_acpmux/lagged`), or a peer went away. So beside the events the send asks the
//! daemon itself (`wait_end`): it reads the turn's end from the log if the turn no longer runs,
//! else blocks in `_acpmux/wait` (server side, never dropped) until that turn ended. An error of
//! either is the send's error.

use crate::client::Client;
use crate::rpc::method;
use anyhow::{Result, anyhow};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::sync::Arc;

/// A send's wait for the end of the turn it steered into (`wait_end`); dropping it stops it.
pub(crate) type EndWait =
    std::pin::Pin<Box<dyn std::future::Future<Output = Result<Value>> + Send>>;

/// What a waiting send heard of its steer.
#[derive(Default)]
pub(crate) struct SteerReply {
    /// The send's prompt id: its records name it.
    prompt_id: String,
    /// It was sent as a steer (`_meta.acpmux.steer`).
    asked: bool,
    /// Its prompt runs a turn of its own: it queued, started one, or fell back to the queue
    /// after a steer its turn ended before reading (`hub/steer_end.rs`).
    own_turn: bool,
    /// The turn the steer went into, once the agent answered `steered`.
    into: Option<String>,
    /// The turns that ended before that answer came, and how.
    ended: HashMap<String, Result<Value>>,
}

impl SteerReply {
    pub(crate) fn new(prompt_id: &str, asked: bool) -> Self {
        Self { prompt_id: prompt_id.to_owned(), asked, ..Self::default() }
    }

    /// The prompt's answer: what the send answers, or `None` while the turn it steered into
    /// runs on. A steer keeps that turn (`turn`) either way, even when its end came first: the
    /// send's reply is that turn's.
    pub(crate) fn answered(&mut self, answer: Result<Value>) -> Option<Result<Value>> {
        let Some(turn) = answer.as_ref().ok().and_then(steered_into) else {
            return Some(answer);
        };
        let end = self.ended.remove(&turn);
        self.into = Some(turn);
        end
    }

    /// A notification of the session: what the send answers when it ends the turn the steer
    /// went into.
    pub(crate) fn heard(&mut self, m: &str, p: &Value) -> Option<Result<Value>> {
        self.note_prompt(m, p);
        let (turn, end) = turn_end(m, p)?;
        match &self.into {
            Some(into) => (*into == turn).then_some(end),
            None => {
                self.ended.insert(turn, end);
                None
            }
        }
    }

    /// Where its prompt went, from the records that name it.
    fn note_prompt(&mut self, m: &str, p: &Value) {
        if m != method::MUX_EVENT || p.get("dir").and_then(Value::as_str) != Some("mux") {
            return;
        }
        let Some(msg) = p.get("msg") else { return };
        if msg.get("promptId").and_then(Value::as_str) != Some(self.prompt_id.as_str()) {
            return;
        }
        let steered_in = msg.get("steer").and_then(Value::as_bool) == Some(true);
        match p.get("kind").and_then(Value::as_str) {
            Some("user_message") if !steered_in => self.own_turn = true,
            Some("queued") => self.own_turn = true,
            _ => {}
        }
    }

    /// It waits for the end of another prompt's turn, which is not the send's to stop.
    pub(crate) fn waiting(&self) -> bool {
        self.into.is_some()
    }

    /// The turn its steer went into, once the agent read it: the send's reply is that turn's.
    pub(crate) fn turn(&self) -> Option<&str> {
        self.into.as_deref()
    }

    /// Its prompt may have gone into another prompt's running turn: a timeout leaves that turn
    /// running. A steer counts as one until a record shows it runs a turn of its own, since its
    /// steer record may still be on its way when the timeout passes.
    pub(crate) fn in_another_turn(&self) -> bool {
        self.into.is_some() || (self.asked && !self.own_turn)
    }
}

/// The end of turn `turn` of session `id`, from the daemon rather than the events. While the
/// turn runs, `_acpmux/wait` (server side, never dropped) blocks until it ended (`turnEnded`,
/// `server/wait.rs`), and the session's `lastTurn` gives the end; a turn that no longer runs has
/// its end in the log. Each wait is bounded (`RECHECK_MS`) and the session is read again after
/// it, so a daemon older than `turnEnded` (which waits only for ready or closed) still ends it.
/// A failed request, a session on a machine that is unreachable, and a session whose turn is
/// over with no end of it recorded within `WRITING_END_MS` are errors: the send never waits on
/// a turn nobody can see end.
pub(crate) async fn wait_end(client: Arc<Client>, id: String, turn: String) -> Result<Value> {
    let mut gone_since: Option<std::time::Instant> = None;
    loop {
        let info = json!({"sessionId": id, "waitLogs": false});
        let info = client.request(method::MUX_INFO, info).await?;
        if info.get("stale").and_then(Value::as_bool) == Some(true) {
            return Err(anyhow!(
                "the machine of {id} is unreachable; the turn it steered into may run on"
            ));
        }
        if let Some(end) = last_turn_end(&info, &turn) {
            return end;
        }
        let running = info.pointer("/turn/turnId").and_then(Value::as_str) == Some(turn.as_str());
        let mut wait_ms = RECHECK_MS;
        if !running {
            if let Some(end) = logged_end(&client, &id, &turn).await? {
                return end;
            }
            // Its end is being written (`lastTurn` names it shortly), unless the session is
            // closed or the time for that passed.
            let since = *gone_since.get_or_insert_with(std::time::Instant::now);
            let left = WRITING_END_MS.saturating_sub(since.elapsed().as_millis() as u64);
            let status = info.get("status").and_then(Value::as_str).unwrap_or("ended");
            if status == "closed" || left == 0 {
                return Err(anyhow!(
                    "{id} is {status} with no end of the turn the message steered into \
                     (acpmux last {id})"
                ));
            }
            wait_ms = wait_ms.min(left);
        }
        // Running: it ends after its start (`server/wait.rs`).
        let started_at =
            info.pointer("/turn/startedAt").and_then(Value::as_u64).filter(|_| running);
        let wait = json!({
            "sessions": [id],
            "until": ["ready", "closed"],
            "turnEnded": {"turnId": turn, "startedAt": started_at.unwrap_or(u64::MAX)},
            "timeoutMs": wait_ms,
        });
        let waited = client.request(method::MUX_WAIT, wait).await?;
        let row = waited.pointer("/resolved/0").cloned().unwrap_or(Value::Null);
        if let Some(end) = last_turn_end(&row, &turn) {
            return end;
        }
    }
}

/// How long one `_acpmux/wait` of `wait_end` lasts before it reads the session again.
const RECHECK_MS: u64 = 10_000;

/// How long a turn that no longer runs may take to record its end.
const WRITING_END_MS: u64 = 30_000;

/// Turn `turn`'s end as a session row's `lastTurn` gives it, when it is that turn's.
fn last_turn_end(row: &Value, turn: &str) -> Option<Result<Value>> {
    let last =
        row.get("lastTurn").filter(|t| t.get("turnId").and_then(Value::as_str) == Some(turn))?;
    let msg = json!({
        "turnId": turn,
        "status": last.get("status"),
        "stopReason": last.get("stopReason"),
        "error": last.get("errorText"),
    });
    turn_end(method::MUX_EVENT, &json!({"dir": "mux", "kind": "turn_result", "msg": msg}))
        .map(|(_, end)| end)
}

/// Turn `turn`'s end in session `id`'s log, if it is there.
async fn logged_end(client: &Arc<Client>, id: &str, turn: &str) -> Result<Option<Result<Value>>> {
    let query = json!({"sessionId": id, "limit": 2000, "kinds": ["turn_result"]});
    let events = crate::cli::output::with_older(client, query).await?;
    let of_turn = |e: &Value| turn_end(method::MUX_EVENT, e).filter(|(t, _)| t == turn);
    Ok(events.iter().rev().find_map(of_turn).map(|(_, end)| end))
}

/// The turn an answer says its steer went into while that turn runs on.
fn steered_into(answer: &Value) -> Option<String> {
    if answer.get("stopReason").and_then(Value::as_str) != Some("steered") {
        return None;
    }
    let turn = answer.pointer("/_meta/acpmux/turnId").and_then(Value::as_str)?;
    (!turn.is_empty()).then(|| turn.to_owned())
}

/// A turn's end among the session's events: its id, and its answer as the turn's prompt got it.
fn turn_end(m: &str, p: &Value) -> Option<(String, Result<Value>)> {
    if m != method::MUX_EVENT || p.get("dir").and_then(Value::as_str) != Some("mux") {
        return None;
    }
    let msg = p.get("msg")?;
    let turn = msg.get("turnId").and_then(Value::as_str)?.to_owned();
    let failed = match p.get("kind").and_then(Value::as_str)? {
        "turn_end" => false,
        "turn_error" => true,
        "turn_result" => msg.get("status").and_then(Value::as_str) == Some("failed"),
        _ => return None,
    };
    let end = if failed {
        let error = msg.get("error").and_then(Value::as_str).unwrap_or("the turn failed");
        Err(anyhow!("{error}"))
    } else {
        let stop = msg.get("stopReason").filter(|s| s.is_string()).cloned();
        let stop = stop.unwrap_or_else(|| json!("end_turn"));
        Ok(json!({"stopReason": stop, "_meta": {"acpmux": {"turnId": turn, "steer": true}}}))
    };
    Some((turn, end))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn event(kind: &str, msg: Value) -> Value {
        json!({"sessionId": "s", "seq": 1, "at": 0, "dir": "mux", "kind": kind, "msg": msg})
    }

    fn steered(turn: &str) -> Result<Value> {
        Ok(json!({"stopReason": "steered", "_meta": {"acpmux": {"turnId": turn, "steer": true}}}))
    }

    #[test]
    fn a_steered_answer_waits_for_its_turns_end() {
        let mut s = SteerReply::new("p1", true);
        assert!(s.answered(steered("t1")).is_none());
        assert!(s.waiting());
        let other = event("turn_end", json!({"turnId": "t0", "stopReason": "end_turn"}));
        assert!(s.heard(method::MUX_EVENT, &other).is_none(), "another turn's end");
        let end = event("turn_end", json!({"turnId": "t1", "stopReason": "end_turn"}));
        let r = s.heard(method::MUX_EVENT, &end).unwrap().unwrap();
        assert_eq!(r["stopReason"], "end_turn");
        assert_eq!(r.pointer("/_meta/acpmux/turnId"), Some(&json!("t1")));
    }

    #[test]
    fn a_turn_that_ended_before_the_steered_answer_came_answers_at_once() {
        let mut s = SteerReply::new("p1", true);
        let end = event(
            "turn_result",
            json!({"turnId": "t1", "status": "cancelled", "stopReason": "cancelled"}),
        );
        assert!(s.heard(method::MUX_EVENT, &end).is_none());
        let r = s.answered(steered("t1")).unwrap().unwrap();
        assert_eq!(r["stopReason"], "cancelled");
        assert_eq!(s.turn(), Some("t1"), "its reply is that turn's, read from the log");
    }

    #[test]
    fn a_failed_turn_fails_the_send() {
        let mut s = SteerReply::new("p1", true);
        assert!(s.answered(steered("t1")).is_none());
        let failed = event("turn_error", json!({"turnId": "t1", "error": "agent process closed"}));
        let e = s.heard(method::MUX_EVENT, &failed).unwrap().unwrap_err();
        assert_eq!(e.to_string(), "agent process closed");
    }

    /// A timeout before any record of the steer arrived leaves the turn it may have gone into
    /// running; a steer that fell back to the queue (its turn ended first) runs a turn of its own,
    /// which a timeout stops, as it does a send that never steered.
    #[test]
    fn a_steer_is_in_another_turn_until_a_record_shows_its_own() {
        let mut s = SteerReply::new("p1", true);
        assert!(s.in_another_turn(), "no record yet: maybe steered in");
        let steer = event("user_message", json!({"promptId": "p1", "steer": true, "turnId": "t1"}));
        s.heard(method::MUX_EVENT, &steer);
        assert!(s.in_another_turn() && !s.waiting(), "steered in, not read yet");
        let other = event("queued", json!({"promptId": "p0", "turnId": "t2"}));
        s.heard(method::MUX_EVENT, &other);
        assert!(s.in_another_turn(), "another prompt queued");
        let fallback = event("queued", json!({"promptId": "p1", "turnId": "t2"}));
        s.heard(method::MUX_EVENT, &fallback);
        assert!(!s.in_another_turn(), "fell back: its own turn");
        let mut started = SteerReply::new("p1", true);
        let own = event("user_message", json!({"promptId": "p1", "turnId": "t3"}));
        started.heard(method::MUX_EVENT, &own);
        assert!(!started.in_another_turn(), "a steer to an idle session started its own turn");
        assert!(!SteerReply::new("p1", false).in_another_turn(), "never sent as a steer");
    }

    #[test]
    fn a_rows_last_turn_gives_its_end_only_when_it_is_that_turn() {
        let row = |last: Value| json!({"sessionId": "s", "lastTurn": last});
        let done = row(json!({"turnId": "t1", "status": "completed", "stopReason": "end_turn"}));
        assert_eq!(last_turn_end(&done, "t1").unwrap().unwrap()["stopReason"], "end_turn");
        assert!(last_turn_end(&done, "t2").is_none(), "another turn's");
        let failed =
            row(json!({"turnId": "t1", "status": "failed", "errorText": "agent process closed"}));
        let e = last_turn_end(&failed, "t1").unwrap().unwrap_err();
        assert_eq!(e.to_string(), "agent process closed");
        assert!(last_turn_end(&json!({"sessionId": "s", "lastTurn": null}), "t1").is_none());
    }

    #[test]
    fn any_other_answer_is_the_sends_own() {
        let mut s = SteerReply::new("p1", true);
        // codex-acp answers a steer at the turn's end; a steer taken back answers `withdrawn`.
        for stop in ["end_turn", "withdrawn", "cancelled"] {
            let answer = json!({"stopReason": stop, "_meta": {"acpmux": {"turnId": "t1"}}});
            assert_eq!(s.answered(Ok(answer.clone())).unwrap().unwrap(), answer);
        }
        assert!(s.answered(Err(anyhow!("refused"))).unwrap().is_err());
        // An older daemon's steered answer names no turn: nothing to wait for.
        let bare = json!({"stopReason": "steered"});
        assert_eq!(s.answered(Ok(bare.clone())).unwrap().unwrap(), bare);
        assert!(!s.waiting());
        // A session update is no turn's end.
        let update = json!({"sessionId": "s", "update": {"sessionUpdate": "agent_message_chunk"}});
        assert!(s.heard(method::SESSION_UPDATE, &update).is_none());
    }
}
