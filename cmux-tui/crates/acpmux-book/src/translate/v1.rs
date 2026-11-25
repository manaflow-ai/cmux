//! v1 event semantics seeded from `acpmux/src/rows/fold.rs`.
use super::{
    BodyField, Error, MAX_KEY_BYTES, OwnedRow, State,
    input::{self, Meta, Output},
    kinds,
};
use crate::row::RowKind;
use serde::Deserialize;
use serde_json::value::RawValue;
use std::borrow::Cow;

#[derive(Deserialize)]
struct Event<'a> {
    seq: u64,
    at: u64,
    #[serde(borrow)]
    dir: Cow<'a, str>,
    #[serde(borrow)]
    kind: Cow<'a, str>,
    #[serde(borrow)]
    msg: &'a RawValue,
}
#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct Message<'a> {
    #[serde(borrow)]
    text: Option<&'a RawValue>,
    #[serde(borrow)]
    images: Option<&'a RawValue>,
    #[serde(borrow)]
    turn_id: Cow<'a, str>,
    #[serde(borrow)]
    prompt_id: Cow<'a, str>,
    steer: bool,
    #[serde(rename = "_meta", borrow)]
    meta: Meta<'a>,
    #[serde(borrow)]
    status: Cow<'a, str>,
    #[serde(borrow)]
    old_message_id: Cow<'a, str>,
    #[serde(borrow)]
    method: Cow<'a, str>,
    #[serde(borrow)]
    params: Option<Params<'a>>,
    #[serde(borrow)]
    held: Option<&'a RawValue>,
    #[serde(rename = "promptIds", borrow)]
    prompt_ids: Option<&'a RawValue>,
    #[serde(borrow)]
    order: Option<&'a RawValue>,
    next: bool,
}
#[derive(Deserialize, Default)]
#[serde(default)]
struct Params<'a> {
    #[serde(rename = "_meta", borrow)]
    meta: Meta<'a>,
    #[serde(borrow)]
    update: Option<&'a RawValue>,
}
#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct Update<'a> {
    #[serde(borrow)]
    session_update: Cow<'a, str>,
    #[serde(borrow)]
    subagent_session_id: Cow<'a, str>,
    #[serde(borrow)]
    message_id: Cow<'a, str>,
    #[serde(borrow)]
    tool_call_id: Cow<'a, str>,
    #[serde(borrow)]
    content: Option<&'a RawValue>,
    #[serde(borrow)]
    title: Option<&'a RawValue>,
    #[serde(borrow)]
    kind: Cow<'a, str>,
    #[serde(borrow)]
    status: Cow<'a, str>,
    #[serde(borrow)]
    state: Cow<'a, str>,
    #[serde(borrow)]
    entries: Option<&'a RawValue>,
    #[serde(borrow)]
    raw_input: Option<&'a RawValue>,
    #[serde(rename = "_meta", borrow)]
    meta: Meta<'a>,
}
pub(super) fn line(
    state: &mut State,
    place: u64,
    span: u64,
    bytes: &[u8],
    out: &mut Output<'_>,
) -> Result<(), Error> {
    let rec: Event<'_> = input::parse(bytes)?;
    if rec.seq <= state.last_v1_seq && state.last_v1_seq != 0 {
        return Ok(());
    }
    let msg: Message<'_> = input::value(rec.msg)?;
    state.at = rec.at / 1000;
    state.at_ms = rec.at;
    if rec.dir == "mux" {
        let line = Line { seq: rec.seq, raw: rec.msg, place, span };
        mux(state, &rec.kind, &msg, line, out)?;
    } else if rec.dir == "in"
        && !rec.kind.ends_with(".replay")
        && msg.method == "session/update"
        && let Some(params) = msg.params
    {
        if params.meta.acpmux.subagent.is_some() {
            return Ok(());
        }
        if let Some(raw) = params.update {
            let update: Update<'_> = input::value(raw)?;
            if update.meta.acpmux.subagent.is_none() {
                agent(state, &params.meta, &update, &rec.kind, out)?;
            }
        }
    }
    state.last_v1_seq = rec.seq;
    Ok(())
}

pub(super) fn validate(bytes: &[u8]) -> Result<(), Error> {
    let rec: Event<'_> = input::parse(bytes)?;
    super::bounded(&rec.dir)?;
    super::bounded(&rec.kind)?;
    let msg: Message<'_> = input::value(rec.msg)?;
    super::bounded(&msg.method)?;
    super::bounded(&msg.turn_id)?;
    super::bounded(&msg.prompt_id)?;
    super::bounded(&msg.old_message_id)?;
    if let Some(params) = msg.params {
        super::bounded(&params.meta.acpmux.segment)?;
        super::bounded(&params.meta.acpmux.recipient)?;
        if let Some(raw) = params.update {
            let update: Update<'_> = input::value(raw)?;
            super::bounded(&update.session_update)?;
            super::bounded(&update.meta.acpmux.segment)?;
            if let Some(raw) = update.content {
                input::content(raw, 0, &mut |_| Ok(()))?;
            }
            if let Some(raw) = update.title {
                let _: &RawValue = raw;
            }
            if let Some(raw) = update.raw_input {
                let _: &RawValue = raw;
            }
            super::bounded(&update.message_id)?;
            super::bounded(&update.tool_call_id)?;
            super::bounded(&update.subagent_session_id)?;
        }
    }
    Ok(())
}
/// Where a mux record is: its v1 seq, its `msg` as written, and its place in raw.
#[derive(Clone, Copy)]
struct Line<'a> {
    seq: u64,
    raw: &'a RawValue,
    place: u64,
    span: u64,
}
fn mux(
    state: &mut State,
    kind: &str,
    msg: &Message<'_>,
    line: Line<'_>,
    out: &mut Output<'_>,
) -> Result<(), Error> {
    let Line { place, span, .. } = line;
    match kind {
        "retracted" | "removed" | "steer_withdrawn" => {
            // A prompt sent now that an older writer withdraws takes its turn's `continued` back.
            state.withdrawn(&msg.prompt_id, out);
            state.queue_remove(&msg.prompt_id, out);
            state.settle_prompt(super::prompt_hash(&msg.prompt_id), true, out);
        }
        "queued" => {
            let text_len = msg.text.map(input::decoded_len).transpose()?.unwrap_or(0);
            state.queue_add(&msg.prompt_id, state.at_ms, false, place, span, text_len, out);
            // An inbox digest's record holds the queue's order with it in it.
            state.queue_order(msg.order, out);
        }
        "queue_order" => {
            if msg.next {
                state.interrupt(&msg.prompt_id);
                state.queue_release(&msg.prompt_id, out);
            }
            state.queue_order(msg.order, out);
        }
        "queue_paused" => state.queue_set_held(msg.held, true, out)?,
        "queue_resumed" => {
            if let Some(ids) = msg.prompt_ids {
                state.queue_set_held(Some(ids), false, out)?;
            } else {
                state.queue_set_all_held(false, out);
            }
        }
        "dequeued" => state.queue_remove(&msg.prompt_id, out),
        "queue_removed" | "queue_declined" | "prompt_refused" => {
            state.withdrawn(&msg.prompt_id, out);
            state.queue_remove(&msg.prompt_id, out);
        }
        "steer_read" => state.steer_read(&msg.prompt_id, out)?,
        "user_message" => {
            let notice = matches!(
                msg.meta.provenance.kind.as_ref(),
                "inbox_notice" | "task_notification" | "notice"
            );
            // Who sent it and how: the record's keys the message itself does not read.
            let said: super::user::Said<'_> =
                serde_json::from_str(line.raw.get()).unwrap_or_default();
            state.prompt(
                super::PromptEvent {
                    key: &msg.turn_id,
                    prompt_key: &msg.prompt_id,
                    steer: msg.steer,
                    notice,
                    body: msg.text,
                    images: msg.images,
                    sender: super::user::sender(&said, &msg.prompt_id),
                    inline_parts: said.inline_parts,
                    pasted: said.pasted,
                    place,
                    span,
                },
                out,
            )?;
        }
        "permission_request" => state.ask_permission(&ask(line.raw), out)?,
        "secret_request" => state.ask_secret(&ask(line.raw), false, out)?,
        "elevation_request" => state.ask_secret(&ask(line.raw), true, out)?,
        "permission_decision" => state.decide_permission(&ask(line.raw), out),
        "permission_auto" => state.decide_auto(&ask(line.raw), out),
        "secret_decision" | "elevation_decision" => state.decide_secret(&ask(line.raw), out),
        "sender_claim" => {
            if let Some((prompt, from)) = super::user::sent_from(line.raw) {
                state.claim(&prompt, from, out);
            }
        }
        "turn_started" if state.turn_key.is_empty() => {
            super::bounded(&msg.turn_id)?;
            state.turn_key = msg.turn_id.to_string();
        }
        "turn_result" => {
            if !msg.turn_id.is_empty()
                && !state.turn_key.is_empty()
                && msg.turn_id != state.turn_key
            {
                return Ok(());
            }
            let mut end = state.row(RowKind::Notice, out)?;
            end.field("notice", "turn_result");
            // A fork names the result by its v1 seq while fork is a v1 request.
            end.fields.insert("forkable".into(), "true".into());
            end.fields.insert("seq".into(), line.seq.to_string());
            state.copy(&mut end, kinds::TURN_END, line.raw);
            turn_result(state, &mut end, line.raw, &msg.status, &msg.prompt_id)?;
            state.end_turn(end, &msg.status, out);
        }
        "message_superseded" => state.supersede(&msg.old_message_id, out),
        _ if super::cards::record(
            state,
            kind,
            super::cards::At { raw: line.raw, line: super::RawLine { place, span } },
            out,
        )? => {}
        _ => match kinds::find(kinds::MUX, kind).map(|known| known.draw) {
            Some(kinds::Draw::Row(spec)) => {
                let mut row = state.drawn(&spec, line.raw, out)?;
                row.open = false;
                out.row(&row);
                match kind {
                    "stopped" | "exited" => state.end_session(out),
                    "stopping" => state.stop(),
                    _ => {}
                }
            }
            Some(_) => {}
            None => state.unknown(kind),
        },
    }
    Ok(())
}
/// An ask's record, read leniently: a key of another type reads as none.
fn ask(raw: &RawValue) -> super::asks::AskRecord<'_> {
    serde_json::from_str(raw.get()).unwrap_or_default()
}
/// The turn-end notice's fields computed from its result, as the view's turn summary reads
/// them (direct.ts, `turnSummary`): the split of its tokens, its checkpoints, its error, and the
/// auto-resume attempt it was. One pass over the record's keys.
fn turn_result(
    state: &mut State,
    end: &mut OwnedRow,
    raw: &RawValue,
    status: &str,
    prompt: &str,
) -> Result<(), Error> {
    let mut tokens = super::Tokens::default();
    let mut output = None;
    let mut fresh = false;
    let (mut named, mut from, mut to, mut reason) = (false, None, None, None);
    let mut error_text = None;
    let mut error = None;
    input::entries(raw, |key, value| {
        let n = || input::count(Some(value)).unwrap_or(0);
        match key {
            "outputTokens" => output = input::count(Some(value)),
            "inputTokens" => tokens.input = n(),
            "cacheReadTokens" => tokens.cache_read = n(),
            "cacheWriteTokens" => tokens.cache_write = n(),
            "contextTokens" => tokens.context = n(),
            "modelCalls" => tokens.calls = n(),
            "inputExcludesCache" => fresh |= value.get() == "true",
            // An older record names no mark: a Claude model's input was fresh-only too.
            "model" => {
                fresh |= input::text(value).is_ok_and(|model| {
                    let model = model.to_ascii_lowercase();
                    ["claude", "opus", "sonnet", "haiku"].iter().any(|name| model.contains(name))
                });
            }
            "checkpointId" => (named, from) = (true, Some(value)),
            "endCheckpointId" => to = Some(value),
            "checkpointError" => reason = Some(value),
            "errorText" if value.get() != "null" => error_text = Some(value),
            "error" => error = Some(value),
            _ => {}
        }
    })?;
    if let Some(output) = output {
        tokens.output = output;
        if !fresh {
            // The input counted the cache's reads and writes: take them out, at no less than none.
            tokens.input =
                tokens.input.saturating_sub(tokens.cache_read.saturating_add(tokens.cache_write));
        }
        if let Some(split) = tokens.json() {
            end.fields.insert("tokens".into(), split);
        }
    }
    // Only a record that names the starting checkpoint has any; `from` is null when the hub took none.
    if named {
        let quote = |text: &str, cap: usize| {
            serde_json::to_string(super::cut(text, cap)).map_err(|_| Error::InvalidJson)
        };
        let mut value = String::from(r#"{"from":"#);
        match text(from) {
            Some(id) => value.push_str(&quote(&id, 256)?),
            None => value.push_str("null"),
        }
        if let Some(to) = text(to) {
            value.push_str(r#","to":"#);
            value.push_str(&quote(&to, 256)?);
        }
        if let Some(reason) = text(reason) {
            value.push_str(r#","reason":"#);
            value.push_str(&quote(&reason, MAX_KEY_BYTES)?);
        }
        value.push('}');
        end.fields.insert("checkpoint".into(), value);
    }
    // An agent that could not start ends its turn with `error` and no `errorText`.
    let error = text(error_text).or_else(|| if status == "failed" { text(error) } else { None });
    if let Some(error) = error
        && end.field_capped("error", &error, MAX_ERROR_BYTES)
    {
        state.cut_fields = state.cut_fields.saturating_add(1);
    }
    // The auto-resume attempt `n` of a prompt `P` is the prompt `P~resume-n`.
    if let Some(attempt) = prompt.rsplit_once("~resume-").and_then(|(_, n)| n.parse::<u64>().ok()) {
        end.fields.insert("retry".into(), attempt.to_string());
    }
    Ok(())
}
const MAX_ERROR_BYTES: usize = 4 * 1024;
/// A non-empty string value, or none.
fn text(raw: Option<&RawValue>) -> Option<Cow<'_, str>> {
    raw.and_then(|raw| input::text(raw).ok()).filter(|text| !text.is_empty())
}
fn agent(
    state: &mut State,
    params: &Meta<'_>,
    u: &Update<'_>,
    fallback: &str,
    out: &mut Output<'_>,
) -> Result<(), Error> {
    let kind = if u.session_update.is_empty() { fallback } else { &u.session_update };
    match kind {
        "subagent_progress" => state.sub(&u.subagent_session_id, &u.status, out)?,
        "agent_message_chunk" | "agent_thought_chunk" => {
            let key = if !u.meta.acpmux.segment.is_empty() {
                &u.meta.acpmux.segment
            } else if !params.acpmux.segment.is_empty() {
                &params.acpmux.segment
            } else {
                &u.message_id
            };
            if let Some(raw) = u.content {
                input::content(raw, 0, &mut |text| {
                    state.text(text, key, &u.message_id, kind == "agent_thought_chunk", out)
                })?;
            }
        }
        "tool_call" | "tool_call_update" => {
            let fallback = format!("@{}", state.last_v1_seq);
            let key: &str =
                if u.tool_call_id.is_empty() { &fallback } else { u.tool_call_id.as_ref() };
            let mut metadata = Vec::new();
            for (k, v) in [
                ("kind", u.kind.as_ref()),
                ("status", u.status.as_ref()),
                ("tool", u.meta.claude.tool.as_ref()),
                ("recipient", params.acpmux.recipient.as_ref()),
            ] {
                if !v.is_empty() {
                    metadata.push((k, v));
                }
            }
            let mut parts = Vec::new();
            if let Some(raw) = u.title {
                parts.push((BodyField::Title, false, raw));
            }
            if let Some(raw) = u.raw_input {
                parts.push((BodyField::Input, false, raw));
            }
            if let Some(raw) = u.content.filter(|r| r.get() != "null") {
                parts.push((BodyField::Content, false, raw));
            }
            if let Some(raw) = u.meta.terminal_output.data {
                parts.push((BodyField::Text, true, raw));
            }
            state.tool(
                key,
                &metadata,
                &parts,
                matches!(u.status.as_ref(), "completed" | "failed"),
                kind == "tool_call",
                out,
            )?;
        }
        "plan" => {
            state.close_text(out);
            if let Some(raw) = u.entries {
                let mut row = if let Some(row) = state.plan.take() {
                    row
                } else {
                    state.row(RowKind::Plan, out)?
                };
                row.fields.insert("hidden".into(), (raw.get() == "[]").to_string());
                out.row(&row);
                out.body(row.id, BodyField::Entries, false, raw);
                state.plan = Some(row);
            }
        }
        "compaction" => {
            let mut row = if let Some(row) = state.compaction.take() {
                row
            } else {
                state.row(RowKind::Notice, out)?
            };
            if row.field("notice", "compaction") {
                state.cut_fields = state.cut_fields.saturating_add(1);
            }
            let status = if !u.state.is_empty() {
                u.state.as_ref()
            } else if !u.status.is_empty() {
                u.status.as_ref()
            } else {
                "running"
            };
            if row.field("status", status) {
                state.cut_fields = state.cut_fields.saturating_add(1);
            }
            row.open = status == "running";
            out.row(&row);
            if row.open {
                state.compaction = Some(row);
            }
        }
        _ => {
            if kinds::find(kinds::UPDATES, kind).is_none() {
                state.unknown(kind);
            }
        }
    }
    Ok(())
}
