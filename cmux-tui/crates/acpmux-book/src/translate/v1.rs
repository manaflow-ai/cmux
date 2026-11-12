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
    state.last_v1_seq = rec.seq;
    state.at = rec.at / 1000;
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
    Ok(())
}
fn mux(
    state: &mut State,
    kind: &str,
    msg: &Message<'_>,
    out: &mut Output<'_>,
) -> Result<(), Error> {
    match kind {
        "queued" => state.reserve_prompt(&msg.prompt_id, msg.text, out)?,
        "steer_read" => state.steer_read(&msg.prompt_id, out)?,
        "user_message" => {
            let notice = matches!(
                msg.meta.provenance.kind.as_ref(),
                "inbox_notice" | "task_notification" | "notice"
            );
            state.prompt(&msg.turn_id, &msg.prompt_id, msg.steer, notice, msg.text, out)?;
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
            state.finish(out);
            let mut end = state.row(RowKind::Notice)?;
            end.open = false;
            end.field("notice", "turn_result")?;
            end.fields.insert("forkable".into(), "true".into());
            if !msg.status.is_empty() {
                end.field("status", &msg.status)?;
            }
            out.row(&end);
        }
        "message_superseded" => {
            if state.reply.as_ref().is_some_and(|s| s.key == msg.old_message_id) {
                if let Some(s) = &mut state.reply {
                    s.row.fields.insert("hidden".into(), "true".into());
                }
                State::close_stream(&mut state.reply, out);
            }
        }
        "failover" | "forked" | "fork_start_failed" | "host_notice" | "policy_unenforced"
        | "recap" | "stopping" | "stopped" | "exited" => {
            let mut row = state.row(RowKind::Notice)?;
            row.field("notice", kind)?;
            out.row(&row);
            if let Some(raw) = msg.text.or(msg.error).or(msg.reason).or(msg.detail) {
                out.body(row.id, BodyField::Content, false, raw)?;
            }
            row.open = false;
            out.row(&row);
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
                    state.text(text, key, kind == "agent_thought_chunk", out)
                })?;
            }
        }
        "tool_call" | "tool_call_update" => {
            let fallback = format!("@{}", state.last_v1_seq);
            let key = if u.tool_call_id.is_empty() { &fallback } else { &u.tool_call_id };
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
                out,
            )?;
        }
        "plan" => {
            if let Some(raw) = u.entries {
                let mut row = if let Some(row) = state.plan.take() {
                    row
                } else {
                    state.row(RowKind::Plan)?
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
                state.row(RowKind::Notice)?
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
