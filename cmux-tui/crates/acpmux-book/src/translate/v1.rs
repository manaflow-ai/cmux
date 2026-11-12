//! v1 event semantics seeded from `acpmux/src/rows/fold.rs`.
use super::{Change, Error, State, content, json::Json, quoted};
use crate::row::RowKind;
use std::collections::BTreeMap;

pub(super) fn line(state: &mut State, rec: Json<'_>, out: &mut Vec<Change>) -> Result<(), Error> {
    let seq = rec.get("seq").and_then(Json::number).ok_or(Error::InvalidRecord("v1 seq"))?;
    let at = rec.get("at").and_then(Json::number).ok_or(Error::InvalidRecord("v1 at"))?;
    let dir = rec.text("dir").ok_or(Error::InvalidRecord("v1 dir"))?;
    let kind = rec.text("kind").ok_or(Error::InvalidRecord("v1 kind"))?;
    let msg = rec.get("msg").ok_or(Error::InvalidRecord("v1 msg"))?;
    if seq <= state.last_v1_seq && state.last_v1_seq != 0 {
        return Ok(());
    }
    state.last_v1_seq = seq;
    state.at = at / 1000;
    if dir == "mux" {
        mux(state, &kind, msg, out);
    } else if dir == "in"
        && !kind.ends_with(".replay")
        && msg.text("method").as_deref() == Some("session/update")
    {
        if let Some(params) = msg.get("params") {
            if params.path(&["_meta", "acpmux", "subagent"]).is_some() {
                return Ok(());
            }
            if let Some(update) = params.get("update") {
                agent(state, params, update, &kind, out);
            }
        }
    }
    Ok(())
}
fn mux(state: &mut State, kind: &str, msg: Json<'_>, out: &mut Vec<Change>) {
    match kind {
        "user_message" => {
            let steer = msg.get("steer").is_some_and(Json::yes);
            let notice =
                msg.path(&["_meta", "provenance", "kind"]).and_then(Json::string).is_some_and(
                    |k| matches!(k.as_ref(), "inbox_notice" | "task_notification" | "notice"),
                );
            state.prompt(
                msg.text("text").unwrap_or_default().into_owned(),
                msg.text("turnId").unwrap_or_default().into_owned(),
                steer,
                notice,
                out,
            );
        }
        "turn_started" => {
            // Notice turns and steers cannot steal the person's active turn.
            if state.turn_key.is_empty() {
                state.turn_key = msg.text("turnId").unwrap_or_default().into_owned();
            }
        }
        "turn_result" => {
            let key = msg.text("turnId").unwrap_or_default();
            if !key.is_empty() && !state.turn_key.is_empty() && key != state.turn_key {
                return;
            }
            let mut end = state.row(RowKind::Notice, false, String::new());
            end.field("notice", "turn_result");
            end.fields.insert("forkable".into(), "true".into());
            if let Some(status) = msg.text("status") {
                end.field("status", &status);
            }
            state.finish(out);
            out.push(Change::Row(end));
        }
        "message_superseded" => {
            // An in-flight replacement can be marked without reading a settled row.
            if let Some(old) = msg.text("oldMessageId") {
                if let Some(stream) = &mut state.reply {
                    if stream.row.fields.get("messageId").is_some_and(|v| {
                        Json::parse(v.as_bytes()).and_then(Json::string).as_deref()
                            == Some(old.as_ref())
                    }) {
                        stream.row.fields.insert("hidden".into(), "true".into());
                        State::close_stream(&mut state.reply, out);
                    }
                }
            }
        }
        "failover" | "forked" | "fork_start_failed" | "host_notice" | "policy_unenforced"
        | "recap" | "stopping" | "stopped" | "exited" => {
            state.close_text(out);
            let text = ["text", "error", "reason", "detail"]
                .iter()
                .find_map(|k| msg.text(k))
                .unwrap_or_default()
                .into_owned();
            let mut row = state.row(RowKind::Notice, false, text);
            row.field("notice", kind);
            out.push(Change::Row(row));
        }
        _ => {}
    }
}
fn agent(
    state: &mut State,
    params: Json<'_>,
    update: Json<'_>,
    fallback: &str,
    out: &mut Vec<Change>,
) {
    let kind = update.text("sessionUpdate");
    let kind = kind.as_deref().unwrap_or(fallback);
    match kind {
        "usage_update"
        | "available_commands_update"
        | "current_mode_update"
        | "config_option_update"
        | "session_info_update"
        | "prompt_suggestion"
        | "compaction_summary" => return,
        "agent_message_chunk" | "agent_thought_chunk" => {
            let message = update.text("messageId").unwrap_or_default();
            let segment = update
                .path(&["_meta", "acpmux", "segment"])
                .or_else(|| params.path(&["_meta", "acpmux", "segment"]))
                .and_then(Json::string);
            let key = segment.as_deref().unwrap_or(&message).to_owned();
            let thinking = kind == "agent_thought_chunk";
            state.text(content(update.get("content")), key, thinking, out);
            if !thinking && !message.is_empty() {
                if let Some(reply) = &mut state.reply {
                    reply.row.field("messageId", &message);
                }
            }
        }
        "tool_call" | "tool_call_update" => {
            let key = update
                .text("toolCallId")
                .map(|s| s.into_owned())
                .unwrap_or_else(|| format!("@{}", state.last_v1_seq));
            let mut fields = BTreeMap::new();
            for key in ["title", "kind", "status"] {
                if let Some(v) = update.get(key) {
                    fields.insert(key.into(), v.compact());
                }
            }
            if let Some(v) = update.path(&["_meta", "claude", "tool"]) {
                fields.insert("tool".into(), v.compact());
            }
            let ended = matches!(update.text("status").as_deref(), Some("completed" | "failed"));
            let text = update.get("content").filter(|v| !v.null()).map(|v| content(Some(v)));
            let delta = update
                .path(&["_meta", "terminal_output", "data"])
                .and_then(Json::string)
                .map(|s| s.into_owned());
            state.tool(key, fields, text, delta, ended, out);
        }
        "plan" => {
            state.close_text(out);
            let Some(entries) = update.get("entries") else {
                return;
            };
            let empty = entries.items().is_some_and(|mut i| i.next().is_none());
            if state.plan.is_none() && empty {
                return;
            }
            let mut row =
                state.plan.take().unwrap_or_else(|| state.row(RowKind::Plan, true, String::new()));
            row.fields.insert("entries".into(), entries.compact());
            row.fields.insert("hidden".into(), empty.to_string());
            out.push(Change::Row(row.clone()));
            state.plan = Some(row);
        }
        "compaction" => {
            state.close_text(out);
            let mut row = state
                .compaction
                .take()
                .unwrap_or_else(|| state.row(RowKind::Notice, true, String::new()));
            row.field("notice", "compaction");
            let status = update
                .text("state")
                .or_else(|| update.text("status"))
                .unwrap_or_else(|| "running".into());
            row.field("status", &status);
            row.open = status == "running";
            if row.open {
                state.compaction = Some(row.clone());
            }
            out.push(Change::Row(row));
        }
        _ => {}
    }
}

pub(super) fn field(fields: &mut BTreeMap<String, String>, key: &str, value: &str) {
    let mut s = String::new();
    quoted(&mut s, value);
    fields.insert(key.into(), s);
}
