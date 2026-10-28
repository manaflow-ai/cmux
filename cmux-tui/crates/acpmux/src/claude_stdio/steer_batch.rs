//! Other sessions' messages steered into one step go in as one message (Leo, 2026-10-27: "i also
//! feel like there should be better batching for messages from other sessions so you can get to
//! things faster/more efficiently").
//!
//! A steer waits in Claude Code's command queue until its current step ends, one line per steer:
//! ten agents' sends during a long step were ten lines, and after a Send now (an interrupt) Claude
//! Code runs each waiting line as one more turn. Now another session's steer (`_meta.batch.from`,
//! which the hub sets on a plain agent message, `hub/steer_end.rs`) that comes while the newest
//! waiting line is other sessions' messages joins that line: Claude Code is asked to drop it
//! (`cancel_async_message`, as a withdraw does, `steer_withdraw.rs`) and one line with all of them
//! goes in its place. That line says how many messages from how many sessions, then gives each as
//! it was sent, oldest first, under a line naming its sender. Nothing is dropped, cut or
//! summarized. Each steer keeps its own request: the line's echo answers every one `steered`.
//! When Claude Code read the line first (`cancelled: false`) or cannot drop it, the line stands
//! and the new messages go in as the next line. One line is written again at a time: messages
//! that come while its drop is on its way wait for the answer, then go in the line written after
//! it, so the lines reach Claude Code in the order their messages came.
//!
//! A dropped line is always written again with at least the messages it held, so Claude Code
//! always has a line to echo: a turn whose result came while the line waited (it runs the line as
//! one more turn, `inbound.rs`) still ends. So a withdraw of one message of a batched line, or of
//! one held for one, takes nothing back (`withdrawn: false`), as for a message Claude Code read
//! first; the person's steers, the ones withdraws are for, are never batched.
//!
//! The person's steers, one read now (`steerNow`) and anything the hub did not mark are written at
//! once, as before, never held. A turn that ends before a held message was written answers it
//! `STEER_NO_TURN`, so the hub queues it for the next turn (`hub/steer_end.rs`).

use super::*;

/// One message of another session in a line of them.
#[derive(Debug, Clone)]
pub(super) struct Part {
    /// The steer's ACP request id (`Id::to_string`), answered at the line's echo.
    pub(super) id: String,
    /// The hub's promptId (`_meta.promptId`), which a withdraw names.
    pub(super) prompt_id: Option<String>,
    /// Its sender (`_meta.batch.from`).
    pub(super) from: String,
    /// Its content blocks, as Claude Code takes them.
    pub(super) content: Vec<Value>,
}

/// The lines of other sessions' messages Claude Code has not read.
#[derive(Debug, Default)]
pub(super) struct Batches {
    /// By line uuid: its messages, oldest first.
    lines: HashMap<String, Vec<Part>>,
    /// The one line asked to be dropped to be written again (`rebatch-<uuid>`), and the messages
    /// that came meanwhile, oldest first, which go in the line written next.
    rewrite: Option<(String, Vec<Part>)>,
    /// Claude Code refused a drop (one without `cancel_async_message`): each line stands.
    no_drop: bool,
}

/// The content of one line of `parts` (two or more): how many messages from how many sessions,
/// then each under its sender, its blocks as sent, oldest first.
pub(super) fn batch_content(parts: &[Part]) -> Vec<Value> {
    let total = parts.len();
    let mut senders: Vec<&str> = Vec::new();
    for part in parts {
        if !senders.contains(&part.from.as_str()) {
            senders.push(&part.from);
        }
    }
    let sessions = match senders.len() {
        1 => "1 session".to_owned(),
        n => format!("{n} sessions"),
    };
    let mut content = Vec::new();
    for (i, part) in parts.iter().enumerate() {
        let mut line = if i == 0 {
            format!(
                "{total} messages from {sessions} arrived during this step. Each follows as it \
                 was sent, oldest first.\n\n"
            )
        } else {
            "\n\n".to_owned()
        };
        line.push_str(&format!("[message {} of {total}] from {}\n", i + 1, part.from));
        content.push(json!({"type": "text", "text": line}));
        content.extend(part.content.iter().cloned());
    }
    content
}

/// The request that asks Claude Code to drop line `uuid` to write it again.
fn drop_request(uuid: &str) -> Value {
    json!({
        "type": "control_request",
        "request_id": format!("rebatch-{uuid}"),
        "request": {"subtype": "cancel_async_message", "message_uuid": uuid},
    })
}

impl Translator {
    /// A steer of the hub's (`session/prompt` with `_meta.steer`) during a turn: its line for
    /// Claude Code, another session's message joined to the newest waiting line of them, or held
    /// while a line is dropped to be written again.
    pub(super) async fn write_steer(&self, id: &Id, p: &Value, content: Vec<Value>) -> Outbound {
        let prompt_id = p.pointer("/_meta/promptId").and_then(Value::as_str).map(str::to_owned);
        let now = p.pointer("/_meta/steerNow").and_then(Value::as_bool) == Some(true);
        let from = p.pointer("/_meta/batch/from").and_then(Value::as_str);
        let from = from.filter(|f| !now && !f.trim().is_empty());
        let part =
            Part { id: id.to_string(), prompt_id, from: from.unwrap_or("").to_owned(), content };
        let mut batches = self.batches.lock().await;
        let mut steers = self.steers.lock().await;
        // The turn ended since `outbound` looked (its result clears `in_turn` before it fails what
        // waits, under these locks): nothing would ever answer this steer, so the hub queues it.
        if !self.in_turn.load(Ordering::SeqCst) {
            let no_turn = RpcError::invalid_params(STEER_NO_TURN);
            return Outbound::Reply(Message::err(id.clone(), no_turn));
        }
        if from.is_some() {
            // One line is written again at a time: while one is, every other session's message
            // waits with it, so the lines go to Claude Code in the order their messages came.
            if let Some((_, held)) = batches.rewrite.as_mut() {
                held.push(part);
                return Outbound::Lines(Vec::new());
            }
            let last = steers.back().map(|(uuid, _)| uuid.clone());
            if let Some(last) = last.filter(|l| !batches.no_drop && batches.lines.contains_key(l)) {
                batches.rewrite = Some((last.clone(), vec![part]));
                return Outbound::Lines(vec![drop_request(&last)]);
            }
        }
        let parts = vec![part];
        let (uuid, line) = self.steer_line(&mut steers, &parts).await;
        if from.is_some() {
            batches.lines.insert(uuid, parts);
        }
        drop(steers);
        drop(batches);
        // Sent now (`_meta.steerNow`): the current step stops, so it reads the line at once; the
        // turn runs on. Not while a subagent or a background shell runs (`interrupt_ends_work`).
        if now && !self.interrupt_ends_work().await {
            return Outbound::Lines(vec![line, self.step_interrupt(None)]);
        }
        Outbound::Lines(vec![line])
    }

    /// The line of `parts` (one steer as it was sent, or several sessions' messages), each
    /// waiting for its echo under the line's uuid and named by its promptId for a withdraw.
    async fn steer_line(
        &self,
        steers: &mut std::collections::VecDeque<(String, String)>,
        parts: &[Part],
    ) -> (String, Value) {
        // Claude Code echoes the line with this uuid when it reads it.
        let uuid = uuid::Uuid::now_v7().to_string();
        let content = match parts {
            [one] => one.content.clone(),
            many => batch_content(many),
        };
        let line =
            json!({"type": "user", "uuid": uuid, "message": {"role": "user", "content": content}});
        let mut lines = self.steer_lines.lock().await;
        lines.retain(|_, u| steers.iter().any(|(s, _)| s == u));
        for part in parts {
            steers.push_back((uuid.clone(), part.id.clone()));
            if let Some(prompt_id) = &part.prompt_id {
                lines.insert(prompt_id.clone(), uuid.clone());
            }
        }
        (uuid, line)
    }

    /// Whether `MUX_STEER_WITHDRAW` of `prompt_id` names a message batched with others (line
    /// `uuid` holds more than one), in the line being written again, or held for it: it is not
    /// taken back.
    pub(super) fn batched(
        batches: &Batches,
        prompt_id: &str,
        uuid: Option<&str>,
        steers: &std::collections::VecDeque<(String, String)>,
    ) -> bool {
        let held = batches.rewrite.as_ref().is_some_and(|(line, held)| {
            uuid == Some(line.as_str())
                || held.iter().any(|p| p.prompt_id.as_deref() == Some(prompt_id))
        });
        held || uuid.is_some_and(|u| {
            batches.lines.contains_key(u) && steers.iter().filter(|(s, _)| s == u).count() > 1
        })
    }

    /// Claude Code's answer to `drop_request` for line `uuid`: dropped, its messages and those
    /// held for it go in one new line; read first (or the drop refused), it stands and only the
    /// held ones go in. The answer to a drop no longer asked (the turn ended) changes nothing.
    pub(super) async fn rebatched(&self, uuid: &str, ok: bool, inner: &Value) -> Vec<Message> {
        let mut batches = self.batches.lock().await;
        if batches.rewrite.as_ref().is_none_or(|(u, _)| u != uuid) {
            return Vec::new();
        }
        let Some((_, held)) = batches.rewrite.take() else { return Vec::new() };
        batches.no_drop |= !ok;
        let mut steers = self.steers.lock().await;
        let cancelled = ok
            && inner.get("cancelled").and_then(Value::as_bool) == Some(true)
            && steers.iter().any(|(u, _)| u == uuid);
        let mut parts = Vec::new();
        if cancelled {
            steers.retain(|(u, _)| u != uuid);
            parts = batches.lines.remove(uuid).unwrap_or_default();
        }
        parts.extend(held);
        // Never empty: a rewrite holds the message that asked for it.
        let (new, line) = self.steer_line(&mut steers, &parts).await;
        batches.lines.insert(new, parts);
        drop(steers);
        drop(batches);
        self.stdin_replies.lock().await.push(line);
        Vec::new()
    }

    /// At a turn's end or a lost answer, with `batches` locked (before `steers`): the lines'
    /// records go, and the messages held for a line being written again, which never reached
    /// Claude Code, are answered `message`.
    pub(super) fn end_batches(batches: &mut Batches, message: &str) -> Vec<Message> {
        batches.lines.clear();
        let held = batches.rewrite.take().map(|(_, held)| held).unwrap_or_default();
        held.iter()
            .map(|part| Message::err(acp_id(&part.id), RpcError::internal(message)))
            .collect()
    }

    /// The records of line `uuid` once Claude Code read it or dropped it.
    pub(super) async fn forget_batch(&self, uuid: &str) {
        self.batches.lock().await.lines.remove(uuid);
    }
}

/// An ACP id kept as its `to_string`.
fn acp_id(k: &str) -> Id {
    serde_json::from_str(k).unwrap_or(Value::String(k.to_owned()))
}
