//! Other sessions' messages steered into one step go in as one message (Leo, 2026-10-27: "i also
//! feel like there should be better batching for messages from other sessions so you can get to
//! things faster/more efficiently").
//!
//! A steer waits in Claude Code's command queue until its step ends, one line per steer; after a
//! Send now Claude Code runs each waiting line as one more turn. Now another session's steer
//! (`_meta.batch.from`, set by the hub, `hub/steer_end.rs`) that comes while the newest waiting
//! line is other sessions' messages joins it: Claude Code drops that line (`cancel_async_message`)
//! and one line with all of them goes in its place, saying how many messages from how many
//! sessions, then each as sent, oldest first, under its sender. Nothing is cut. A line holds at
//! most [`BATCH_MAX_BYTES`]; past it the next message starts a new line, whole. Each steer keeps
//! its request, answered `steered` at the line's echo. A line read first (`cancelled: false`) or
//! one Claude Code cannot drop stands, and the new messages go next. One line is written again at
//! a time; messages that come meanwhile go in the line written after it, keeping their order.
//!
//! A dropped line is always written again with all it held, so Claude Code always has a line to
//! echo and a turn whose result came meanwhile still ends. A withdraw of one message in a line of
//! several drops the line and writes the others again without it (`steer_withdraw.rs`); one of a
//! line being written again, or held for one, takes nothing back (`withdrawn: false`) until that
//! drop is answered, as for one read first. One read now (`steerNow`) is never batched. A turn
//! that ends before a held message was written answers it `STEER_NO_TURN`, and the hub queues it.
//!
//! The person's own steers batch the same way (Leo, 2026-11-25: "ugh our queuing of batching user
//! messages is awkward as s***. we need to improve them"; one message of his had gone in as
//! several). A person's steer (`_meta.batch.person`, its author, `hub/steer_end.rs`) joins the
//! newest waiting line when that line holds the same person's steers: one line, their words a
//! blank line apart with no headers, so Claude Code reads them together, and a line unread at the
//! turn's end carries as one turn (`carry.rs`), not one turn per steer. The two kinds never share a
//! line, and two people of a shared chat never share one.

use super::*;

/// What a steer that stops the step (Send now) says after its own words. Claude Code answers the
/// step it stops as a person's rejection ("The user doesn't want to proceed with this tool use ...
/// STOP what you are doing and wait for the user to tell you how to proceed") with `[Request
/// interrupted by user for tool use]`, and the model took that for a person's stop order: lanes
/// held for hours on an agent's blocker steered in now, each answering every later message "still
/// holding on your stop order" (NOW's hold-no-lift red, 2026-11-27: ios-shared-logic-rust,
/// moved-feed-relaunch-should-ke-252345-0c92 and six more lanes, none sent a stop).
/// The line comes right after that text, so it says what the stop was.
pub(super) const STEP_STOPPED_NOTE: &str = "[acpmux] The interruption just before this message \
     was acpmux delivering it at once, not anyone stopping you: no one asked you to stop or to \
     wait for the user. Read this message, then go on with your work.";

/// One message of another session in a line of them.
#[derive(Debug, Clone)]
pub(super) struct Part {
    /// The steer's ACP request id (`Id::to_string`), answered at the line's echo.
    pub(super) id: String,
    /// The hub's promptId (`_meta.promptId`), which a withdraw names.
    pub(super) prompt_id: Option<String>,
    /// Its sender (`_meta.batch.from`); empty for the person's steer.
    pub(super) from: String,
    /// The person's steer: its author (`_meta.batch.person`, empty for the owner). `None` for
    /// another session's message.
    pub(super) person: Option<String>,
    /// Its content blocks, as Claude Code takes them.
    pub(super) content: Vec<Value>,
    /// Their size as written (`part_bytes`), counted against [`BATCH_MAX_BYTES`].
    pub(super) bytes: usize,
}

/// Most bytes of messages one batched line holds: a message that would take a line past it starts
/// the next line, whole, so no line nears the agent host's frame limit (64 MiB) however many
/// messages come, and nothing is cut. One message larger than this goes in a line of its own, as
/// it did before batching.
pub(super) const BATCH_MAX_BYTES: usize = 4 * 1024 * 1024;

/// The bytes `content` takes in the line written to Claude Code (its JSON).
fn part_bytes(content: &[Value]) -> usize {
    content.iter().map(|b| serde_json::to_string(b).map_or(0, |s| s.len())).sum()
}

/// `parts` in order, as lines that each hold whole messages of one kind (`same_kind`) and at most
/// [`BATCH_MAX_BYTES`] (a larger message alone).
pub(super) fn lines_of(parts: Vec<Part>) -> Vec<Vec<Part>> {
    let mut lines: Vec<Vec<Part>> = Vec::new();
    let mut size = 0;
    for part in parts {
        match lines.last_mut() {
            Some(line) if size + part.bytes <= BATCH_MAX_BYTES && same_kind(line, &part) => {
                size += part.bytes;
                line.push(part);
            }
            _ => {
                size = part.bytes;
                lines.push(vec![part]);
            }
        }
    }
    lines
}

/// The lines of other sessions' messages Claude Code has not read.
#[derive(Debug, Default)]
pub(super) struct Batches {
    /// By line uuid: its messages, oldest first.
    pub(super) lines: HashMap<String, Vec<Part>>,
    /// The one line asked to be dropped to be written again (`rebatch-<uuid>`), and the messages
    /// that came meanwhile, oldest first, which go in the line written next.
    pub(super) rewrite: Option<(String, Vec<Part>)>,
    /// Claude Code refused a drop (one without `cancel_async_message`): each line stands.
    pub(super) no_drop: bool,
}

/// The content of one line of `parts` (two or more): how many messages from how many sessions,
/// then each under its sender, its blocks as sent, oldest first.
pub(super) fn batch_content(parts: &[Part]) -> Vec<Value> {
    if parts.first().is_some_and(|p| p.person.is_some()) {
        return person_content(parts);
    }
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

/// The content of one line of the person's steers: each as sent, oldest first, a blank line
/// between two. The shared-chat label each carries (`author::agent_label`) is said once, at the
/// start: every steer of a line has the same author.
pub(super) fn person_content(parts: &[Part]) -> Vec<Value> {
    let label = parts.first().and_then(|p| p.content.first()).filter(|b| is_label(b)).cloned();
    let mut content = Vec::new();
    for (i, part) in parts.iter().enumerate() {
        let mut blocks = part.content.as_slice();
        if i > 0 {
            if label.is_some() && blocks.first() == label.as_ref() {
                blocks = blocks.get(1..).unwrap_or_default();
            }
            content.push(json!({"type": "text", "text": "\n\n"}));
        }
        content.extend(blocks.iter().cloned());
    }
    content
}

/// Whether `block` is the shared-chat label a person's steer opens with (`author::agent_label`).
fn is_label(block: &Value) -> bool {
    block.get("type").and_then(Value::as_str) == Some("text")
        && block
            .get("text")
            .and_then(Value::as_str)
            .is_some_and(|t| t.starts_with("[Message from "))
}

/// Whether `part` may join line `line`: both other sessions' messages, or both the same person's.
fn same_kind(line: &[Part], part: &Part) -> bool {
    line.first().is_some_and(|first| first.person == part.person)
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
    pub(super) async fn write_steer(
        &self,
        id: &Id,
        p: &Value,
        mut content: Vec<Value>,
    ) -> Outbound {
        let prompt_id = p.pointer("/_meta/promptId").and_then(Value::as_str).map(str::to_owned);
        let now = p.pointer("/_meta/steerNow").and_then(Value::as_bool) == Some(true);
        // Sent now (`_meta.steerNow`): the current step stops, so it reads the line at once; the
        // turn runs on. Not while a foreground subagent runs (`interrupt_ends_work`).
        let stops_step = now && !self.interrupt_ends_work().await;
        if stops_step {
            content.push(json!({"type": "text", "text": STEP_STOPPED_NOTE}));
        }
        let from = p.pointer("/_meta/batch/from").and_then(Value::as_str);
        let from = from.filter(|f| !now && !f.trim().is_empty());
        let person = p.pointer("/_meta/batch/person").and_then(Value::as_str);
        let person = person.filter(|_| !now && from.is_none()).map(str::to_owned);
        let batched = from.is_some() || person.is_some();
        let bytes = part_bytes(&content);
        let from_name = from.unwrap_or("").to_owned();
        let part = Part { id: id.to_string(), prompt_id, from: from_name, person, content, bytes };
        let mut batches = self.batches.lock().await;
        let mut steers = self.steers.lock().await;
        // The turn ended since `outbound` looked (its result clears `in_turn` before it fails what
        // waits, under these locks): nothing would ever answer this steer, so the hub queues it.
        if !self.in_turn.load(Ordering::SeqCst) {
            let no_turn = RpcError::invalid_params(STEER_NO_TURN);
            return Outbound::Reply(Message::err(id.clone(), no_turn));
        }
        if batched {
            // One line is written again at a time: while one is, every batched message waits
            // with it, so the lines go to Claude Code in the order their messages came.
            if let Some((_, held)) = batches.rewrite.as_mut() {
                held.push(part);
                return Outbound::Lines(Vec::new());
            }
            let last = steers.back().map(|(uuid, _)| uuid.clone());
            // Joined only while the line stays under the cap; past it, a new line starts.
            // Only a line of the same kind (`same_kind`).
            let fits = |l: &String| {
                let line = batches.lines.get(l).filter(|line| same_kind(line, &part));
                let held = line.map(|p| p.iter().map(|p| p.bytes).sum::<usize>());
                held.is_some_and(|held| held + part.bytes <= BATCH_MAX_BYTES)
            };
            if let Some(last) = last.filter(|l| !batches.no_drop && fits(l)) {
                batches.rewrite = Some((last.clone(), vec![part]));
                return Outbound::Lines(vec![drop_request(&last)]);
            }
        }
        let parts = vec![part];
        let (uuid, line) = self.steer_line(&mut steers, &parts).await;
        if batched {
            batches.lines.insert(uuid, parts);
        }
        drop(steers);
        drop(batches);
        if stops_step {
            return Outbound::Lines(vec![line, self.step_interrupt(None)]);
        }
        Outbound::Lines(vec![line])
    }

    /// The line of `parts` (one steer as it was sent, or several sessions' messages), each
    /// waiting for its echo under the line's uuid and named by its promptId for a withdraw.
    pub(super) async fn steer_line(
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

    /// Whether `MUX_STEER_WITHDRAW` of `prompt_id` names a message in the line being written
    /// again (line `uuid`), or held for it: it is not taken back until that drop is answered.
    pub(super) fn rewriting(batches: &Batches, prompt_id: &str, uuid: Option<&str>) -> bool {
        batches.rewrite.as_ref().is_some_and(|(line, held)| {
            uuid == Some(line.as_str())
                || held.iter().any(|p| p.prompt_id.as_deref() == Some(prompt_id))
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
        // Never empty: a rewrite holds the message that asked for it. Lines past the cap split,
        // whole messages each, in order.
        let mut written = Vec::new();
        for parts in lines_of(parts) {
            let (new, line) = self.steer_line(&mut steers, &parts).await;
            batches.lines.insert(new, parts);
            written.push(line);
        }
        drop(steers);
        drop(batches);
        self.stdin_replies.lock().await.extend(written);
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
