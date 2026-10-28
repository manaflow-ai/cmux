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
//! and the new messages go in as the next line. Messages that come while the drop is on its way
//! wait for its answer, then go in the line written after it.
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

/// A line Claude Code is asked to drop so it is written again (`rebatch-<uuid>`).
#[derive(Debug, Default)]
pub(super) struct Rewrite {
    /// Messages that came meanwhile, oldest first: they go in the line written next.
    held: Vec<Part>,
    /// Withdraws asked meanwhile (`MUX_STEER_WITHDRAW`): the promptId and the withdraw's ACP id.
    drops: Vec<(String, String)>,
}

/// The lines of other sessions' messages Claude Code has not read.
#[derive(Debug, Default)]
pub(super) struct Batches {
    /// By line uuid: its messages, oldest first.
    lines: HashMap<String, Vec<Part>>,
    /// By the uuid of the line being dropped.
    rewrites: HashMap<String, Rewrite>,
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
    /// while that line is dropped to be written again.
    pub(super) async fn write_steer(&self, id: &Id, p: &Value, content: Vec<Value>) -> Outbound {
        let prompt_id = p.pointer("/_meta/promptId").and_then(Value::as_str).map(str::to_owned);
        let now = p.pointer("/_meta/steerNow").and_then(Value::as_bool) == Some(true);
        let from = p.pointer("/_meta/batch/from").and_then(Value::as_str);
        let from = from.filter(|f| !now && !f.trim().is_empty());
        let part =
            Part { id: id.to_string(), prompt_id, from: from.unwrap_or("").to_owned(), content };
        let mut batches = self.batches.lock().await;
        let mut steers = self.steers.lock().await;
        if from.is_some() {
            let last = steers.back().map(|(uuid, _)| uuid.clone());
            // A line being written again that is the newest waiting, or that Claude Code read
            // meanwhile: this message waits with the ones held for it, so none overtakes another.
            let waits = batches
                .rewrites
                .keys()
                .find(|u| last.as_ref() == Some(*u) || !steers.iter().any(|(s, _)| s == *u));
            if let Some(u) = waits.cloned()
                && let Some(rewrite) = batches.rewrites.get_mut(&u)
            {
                rewrite.held.push(part);
                return Outbound::Lines(Vec::new());
            }
            if let Some(last) = last.filter(|l| !batches.no_drop && batches.lines.contains_key(l)) {
                batches.rewrites.insert(last.clone(), Rewrite { held: vec![part], drops: vec![] });
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

    /// `MUX_STEER_WITHDRAW` of a message in a line of several, or in one being written again:
    /// dropped there (`rebatched`). `None` when it is a line of its own (`withdraw_steer`).
    pub(super) async fn withdraw_batched(
        &self,
        batches: &mut Batches,
        id: &Id,
        prompt_id: &str,
        uuid: Option<&str>,
        steers: &std::collections::VecDeque<(String, String)>,
    ) -> Option<Outbound> {
        let held = |r: &Rewrite| r.held.iter().any(|p| p.prompt_id.as_deref() == Some(prompt_id));
        let rewriting = uuid
            .filter(|u| batches.rewrites.contains_key(*u))
            .map(str::to_owned)
            .or_else(|| batches.rewrites.iter().find(|(_, r)| held(r)).map(|(u, _)| u.clone()));
        let asked = (prompt_id.to_owned(), id.to_string());
        let out = if let Some(u) = rewriting {
            batches.rewrites.get_mut(&u)?.drops.push(asked);
            Outbound::Lines(Vec::new())
        } else {
            let uuid = uuid?;
            if steers.iter().filter(|(u, _)| u == uuid).count() < 2 {
                return None;
            }
            batches.rewrites.insert(uuid.to_owned(), Rewrite { held: vec![], drops: vec![asked] });
            Outbound::Lines(vec![drop_request(uuid)])
        };
        self.pending.lock().await.insert(id.to_string(), Pending::Withdraw);
        Some(out)
    }

    /// Claude Code's answer to `drop_request` for line `uuid`: dropped, its messages and those
    /// held for it go in one new line, less any withdrawn meanwhile; read first (or the drop
    /// refused), it stands and only the held ones go in.
    pub(super) async fn rebatched(&self, uuid: &str, ok: bool, inner: &Value) -> Vec<Message> {
        let mut batches = self.batches.lock().await;
        let Some(rewrite) = batches.rewrites.remove(uuid) else { return Vec::new() };
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
        parts.extend(rewrite.held);
        let mut out = Vec::new();
        let mut withdrawn = HashSet::new();
        parts.retain(|part| {
            let asked = rewrite.drops.iter().find(|(p, _)| part.prompt_id.as_ref() == Some(p));
            let Some((_, withdraw)) = asked else { return true };
            withdrawn.insert(withdraw.clone());
            out.push(Message::err(acp_id(&part.id), RpcError::internal(STEER_WITHDRAWN)));
            false
        });
        if !parts.is_empty() {
            if self.in_turn.load(Ordering::SeqCst) {
                let (new, line) = self.steer_line(&mut steers, &parts).await;
                batches.lines.insert(new, parts);
                self.stdin_replies.lock().await.push(line);
            } else {
                out.extend(parts.iter().map(|part| {
                    Message::err(acp_id(&part.id), RpcError::invalid_params(STEER_NO_TURN))
                }));
            }
        }
        drop(steers);
        drop(batches);
        for (_, withdraw) in rewrite.drops {
            if self.pending.lock().await.remove(&withdraw).is_some() {
                let taken = withdrawn.contains(&withdraw);
                out.push(Message::ok(acp_id(&withdraw), json!({"withdrawn": taken})));
            }
        }
        out
    }

    /// At a turn's end or a lost answer: the lines' records go, and the messages held for a line
    /// being written again, which never reached Claude Code, are answered `message` (one withdrawn
    /// meanwhile `STEER_WITHDRAWN`). A withdraw still in `pending` is answered here.
    pub(super) async fn end_batches(&self, message: &str) -> Vec<Message> {
        let mut batches = self.batches.lock().await;
        batches.lines.clear();
        let mut out = Vec::new();
        for (_, rewrite) in batches.rewrites.drain() {
            let mut withdrawn = HashSet::new();
            for part in rewrite.held {
                let asked = rewrite.drops.iter().find(|(p, _)| part.prompt_id.as_ref() == Some(p));
                let why = match asked {
                    Some((_, withdraw)) => {
                        withdrawn.insert(withdraw.clone());
                        RpcError::internal(STEER_WITHDRAWN)
                    }
                    None => RpcError::invalid_params(message),
                };
                out.push(Message::err(acp_id(&part.id), why));
            }
            for (_, withdraw) in rewrite.drops {
                if self.pending.lock().await.remove(&withdraw).is_some() {
                    let taken = withdrawn.contains(&withdraw);
                    out.push(Message::ok(acp_id(&withdraw), json!({"withdrawn": taken})));
                }
            }
        }
        out
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
