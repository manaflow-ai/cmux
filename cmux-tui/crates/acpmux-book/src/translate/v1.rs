//! v1 event semantics seeded from `acpmux/src/rows/fold.rs`.
use super::{
    BodyField, Error, State,
    input::{self, Meta, Output},
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
    error: Option<&'a RawValue>,
    #[serde(borrow)]
    reason: Option<&'a RawValue>,
    #[serde(borrow)]
    detail: Option<&'a RawValue>,
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
pub(super) fn line(state: &mut State, bytes: &[u8], out: &mut Output<'_>) -> Result<(), Error> {
    let rec: Event<'_> = input::parse(bytes)?;
    if rec.seq <= state.last_v1_seq && state.last_v1_seq != 0 {
        return Ok(());
    }
    let msg: Message<'_> = input::value(rec.msg)?;
    state.at = rec.at / 1000;
    state.at_ms = rec.at;
    if rec.dir == "mux" {
        mux(state, &rec.kind, &msg, out)?;
    } else if rec.dir == "in" && !rec.kind.ends_with(".replay") && msg.method == "session/update" {
        if let Some(params) = msg.params {
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
    }
    state.last_v1_seq = rec.seq;
    Ok(())
}

pub(super) fn validate(bytes: &[u8]) -> Result<(), Error> {
    let rec: Event<'_> = input::parse(bytes)?;
    super::bounded(&rec.dir)?;
    super::bounded(&rec.kind)?;
    let msg: Message<'_> = input::value(rec.msg)?;
    super::bounded(&msg.status)?;
    super::bounded(&msg.method)?;
    super::bounded(&msg.turn_id)?;
    super::bounded(&msg.prompt_id)?;
    super::bounded(&msg.old_message_id)?;
    if let Some(params) = msg.params {
        if let Some(raw) = params.update {
            let update: Update<'_> = input::value(raw)?;
            super::bounded(&update.session_update)?;
            super::bounded(&update.kind)?;
            super::bounded(&update.status)?;
            super::bounded(&update.state)?;
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
fn mux(
    state: &mut State,
    kind: &str,
    msg: &Message<'_>,
    out: &mut Output<'_>,
) -> Result<(), Error> {
    match kind {
        "retracted" | "removed" => {
            state.settle_prompt(super::prompt_hash(&msg.prompt_id), true, out)
        }
        "queued" => state.reserve_prompt(&msg.prompt_id, msg.text, out)?,
        "steer_read" => state.steer_read(&msg.prompt_id, out)?,
        "user_message" => {
            let notice = matches!(
                msg.meta.provenance.kind.as_ref(),
                "inbox_notice" | "task_notification" | "notice"
            );
            state.prompt(
                super::PromptEvent {
                    key: &msg.turn_id,
                    prompt_key: &msg.prompt_id,
                    steer: msg.steer,
                    notice,
                    body: msg.text,
                    images: msg.images,
                },
                out,
            )?;
        }
        "turn_started" => {
            if state.turn_key.is_empty() {
                super::bounded(&msg.turn_id)?;
                state.turn_key = msg.turn_id.to_string()
            }
        }
        "turn_result" => {
            if !msg.turn_id.is_empty()
                && !state.turn_key.is_empty()
                && msg.turn_id != state.turn_key
            {
                return Ok(());
            }
            let mut end = state.row(RowKind::Notice, out)?;
            end.open = false;
            end.field("notice", "turn_result")?;
            end.fields.insert("forkable".into(), "true".into());
            if !msg.status.is_empty() {
                end.field("status", &msg.status)?;
            }
            out.row(&end);
            if !msg.status.is_empty() {
                if let Some(group) = &mut state.group {
                    group.field("status", &msg.status)?;
                }
            }
            state.finish(out);
        }
        "message_superseded" => state.supersede(&msg.old_message_id, out),
        "failover" | "forked" | "fork_start_failed" | "host_notice" | "policy_unenforced"
        | "recap" | "stopping" | "stopped" | "exited" => {
            let mut row = state.row(RowKind::Notice, out)?;
            row.field("notice", kind)?;
            out.row(&row);
            if let Some(raw) = msg.text.or(msg.error).or(msg.reason).or(msg.detail) {
                out.body(row.id, BodyField::Content, false, raw)?;
            }
            row.open = false;
            out.row(&row);
            if matches!(kind, "stopped" | "exited") {
                state.end_session(out);
            }
        }
        _ => {}
    }
    Ok(())
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
                out.body(row.id, BodyField::Entries, false, raw)?;
                state.plan = Some(row);
            }
        }
        "compaction" => {
            let mut row = if let Some(row) = state.compaction.take() {
                row
            } else {
                state.row(RowKind::Notice, out)?
            };
            row.field("notice", "compaction")?;
            let status = if !u.state.is_empty() {
                u.state.as_ref()
            } else if !u.status.is_empty() {
                u.status.as_ref()
            } else {
                "running"
            };
            row.field("status", status)?;
            row.open = status == "running";
            out.row(&row);
            if row.open {
                state.compaction = Some(row);
            }
        }
        _ => {}
    }
    Ok(())
}
