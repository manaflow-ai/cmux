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
        "errorKind": last.get("errorKind"),
        "recovery": last.get("recovery"),
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
        // A typed failure keeps its kind and recovery (`recovery.rs`), as the turn's own
        // prompt gets them, so the wait's error names them (`output::agent_error`).
        let typed: serde_json::Map<String, Value> = ["errorKind", "recovery"]
            .into_iter()
            .filter_map(|k| msg.get(k).filter(|v| v.is_string()).map(|v| (k.to_owned(), v.clone())))
            .collect();
        if typed.is_empty() {
            Err(anyhow!("{error}"))
        } else {
            let mut e = crate::rpc::RpcError::internal(error);
            e.data = Some(Value::Object(typed));
            Err(crate::client::DaemonError(e).into())
        }
    } else {
        let stop = msg.get("stopReason").filter(|s| s.is_string()).cloned();
        let stop = stop.unwrap_or_else(|| json!("end_turn"));
        Ok(json!({"stopReason": stop, "_meta": {"acpmux": {"turnId": turn, "steer": true}}}))
    };
    Some((turn, end))
}

#[cfg(test)]
mod tests;
