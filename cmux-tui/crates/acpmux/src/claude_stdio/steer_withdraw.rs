//! Taking back a steer Claude Code has not read (`MUX_STEER_WITHDRAW`, the X on a waiting
//! steer's row). A steered line waits in Claude Code's command queue until its current step
//! ends; Claude Code's `cancel_async_message` drops it from there by the line's uuid, and is a
//! no-op once Claude Code took it (`{cancelled: false}`). Dropped, the steer's own prompt answers
//! `STEER_WITHDRAWN`; otherwise it stays and is answered `steered` at its echo, as before.
//!
//! Another session's message in a line of several (`steer_batch.rs`) is taken back too, whatever
//! route sent it (Leo, 2026-11-06: "I can't ... cancel and edit these messages. Why? Is it because
//! the ... codex thing sent them?"): the whole line is dropped, and the line's other messages go
//! in again as one new line, each still answered at that line's echo. While that drop is on its
//! way the line is being written again (`Batches::rewrite`): other sessions' messages that come
//! meanwhile are held and go in after the line's own, in order, and no second drop of the same
//! line is asked. A message in a line being written again, or held for one, stays until Claude
//! Code answers the drop. So does one in a line another line waits behind: written again, it would
//! be read after that line.

use super::*;

impl Translator {
    /// `MUX_STEER_WITHDRAW {sessionId, promptId}`: asks Claude Code to drop the steer of that
    /// prompt (`_meta.promptId` of its `session/prompt`) while it still waits; answers
    /// `{withdrawn: false}` at once when none does.
    pub(super) async fn withdraw_steer(&self, id: &Id, p: &Value) -> Outbound {
        let prompt_id = p.get("promptId").and_then(Value::as_str).unwrap_or_default();
        // Under the steers lock, which `fail_pending` takes before it answers what waits: a steer
        // failed meanwhile is not asked for, and a withdraw registered here is answered by it.
        let mut batches = self.batches.lock().await;
        let steers = self.steers.lock().await;
        let uuid = self.steer_lines.lock().await.get(prompt_id).cloned();
        let uuid = uuid.filter(|u| steers.iter().any(|(s, _)| s == u));
        // Another session's message in a line being written again, or held for one: it stays,
        // as one Claude Code read first does (`steer_batch.rs`).
        if Self::rewriting(&batches, prompt_id, uuid.as_deref()) {
            return Outbound::Reply(Message::ok(id.clone(), json!({"withdrawn": false})));
        }
        let Some(uuid) = uuid else {
            return Outbound::Reply(Message::ok(id.clone(), json!({"withdrawn": false})));
        };
        // One of several messages in a line: the line is written again once dropped, so only the
        // newest waiting line, and it is held as written again until Claude Code answers.
        if batches.lines.get(&uuid).is_some_and(|parts| parts.len() > 1) {
            let newest = steers.back().is_some_and(|(last, _)| *last == uuid);
            if !newest || batches.rewrite.is_some() {
                return Outbound::Reply(Message::ok(id.clone(), json!({"withdrawn": false})));
            }
            batches.rewrite = Some((uuid.clone(), Vec::new()));
        }
        drop(batches);
        self.pending.lock().await.insert(id.to_string(), Pending::Withdraw(prompt_id.to_owned()));
        drop(steers);
        // The uuid rides in the request id: its answer names the line it dropped.
        Outbound::Lines(vec![json!({
            "type": "control_request",
            "request_id": format!("unsteer-{uuid}:{id}"),
            "request": {"subtype": "cancel_async_message", "message_uuid": uuid},
        })])
    }

    /// Claude Code's answer to `withdraw_steer` (`rest` is `<uuid>:<ACP id>`): the withdraw's
    /// reply, and the dropped steer's own answer.
    pub(super) async fn steer_withdrawn(
        &self,
        rest: &str,
        ok: bool,
        inner: &Value,
    ) -> Vec<Message> {
        let Some((uuid, acp)) = rest.split_once(':') else { return Vec::new() };
        let id: Id = serde_json::from_str(acp).unwrap_or(Value::String(acp.to_owned()));
        // Answered already (`fail_pending`): no second answer.
        let pending = self.pending.lock().await.remove(&id.to_string());
        let waited = pending.is_some();
        let cancelled = ok && inner.get("cancelled").and_then(Value::as_bool) == Some(true);
        let mut out = Vec::new();
        // Withdrawn only while its prompt still waits here: a steer answered meanwhile (the turn
        // ended, the agent's answers failed) has its own answer, and is not taken back.
        let mut withdrawn = false;
        let prompt_id = match pending {
            Some(Pending::Withdraw(prompt_id)) => Some(prompt_id),
            _ => None,
        };
        if let Some(gone) = self.unbatch(uuid, prompt_id.as_deref(), ok, cancelled).await {
            if let Some(steer) = gone {
                out.push(Message::err(steer, RpcError::internal(STEER_WITHDRAWN)));
                withdrawn = true;
            }
        } else if cancelled {
            let mut steers = self.steers.lock().await;
            if let Some(at) = steers.iter().position(|(u, _)| u == uuid)
                && let Some((_, k)) = steers.remove(at)
            {
                drop(steers);
                self.steer_lines.lock().await.retain(|_, u| u != uuid);
                self.forget_batch(uuid).await;
                let steer: Id = serde_json::from_str(&k).unwrap_or(Value::String(k));
                out.push(Message::err(steer, RpcError::internal(STEER_WITHDRAWN)));
                withdrawn = true;
            }
        }
        if waited {
            out.push(Message::ok(id, json!({"withdrawn": withdrawn})));
        }
        out
    }

    /// Claude Code's answer for line `uuid` of several messages, held as written again for a
    /// withdraw of `prompt_id` (`withdraw_steer`). Dropped (`cancelled`), the line's other
    /// messages and those held meanwhile go in again, in order, as one new line (or lines past
    /// `BATCH_MAX_BYTES`), and the withdrawn message's steer id is returned. Read first, the line
    /// stands and only the held messages go in. `None` when no such hold is this line's: a line
    /// of one message, which `steer_withdrawn` drops as before, or a hold a turn's end answered.
    async fn unbatch(
        &self,
        uuid: &str,
        prompt_id: Option<&str>,
        ok: bool,
        cancelled: bool,
    ) -> Option<Option<Id>> {
        let mut batches = self.batches.lock().await;
        if batches.rewrite.as_ref().is_none_or(|(line, _)| line != uuid) {
            return None;
        }
        let (_, held) = batches.rewrite.take()?;
        // A Claude Code that refused the drop is not asked for another (`write_steer`).
        batches.no_drop |= !ok;
        let mut steers = self.steers.lock().await;
        let mut parts = Vec::new();
        let mut gone = None;
        if cancelled && steers.iter().any(|(u, _)| u == uuid) {
            parts = batches.lines.remove(uuid).unwrap_or_default();
            steers.retain(|(u, _)| u != uuid);
            let at = parts
                .iter()
                .position(|p| prompt_id.is_some() && p.prompt_id.as_deref() == prompt_id);
            gone = at.map(|at| parts.remove(at));
        }
        parts.extend(held);
        let mut written = Vec::new();
        for parts in super::steer_batch::lines_of(parts) {
            let (new, line) = self.steer_line(&mut steers, &parts).await;
            batches.lines.insert(new, parts);
            written.push(line);
        }
        drop(steers);
        drop(batches);
        self.stdin_replies.lock().await.extend(written);
        Some(gone.map(|g| serde_json::from_str(&g.id).unwrap_or(Value::String(g.id))))
    }
}
