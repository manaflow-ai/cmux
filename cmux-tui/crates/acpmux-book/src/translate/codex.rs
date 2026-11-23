//! Native Codex rollout JSONL, in both the legacy event and current response-item forms.
//!
//! Codex writes progress and environment records beside the conversation.  This translator keeps
//! only the person's typed prompt and the final assistant answer in the book vocabulary; the raw
//! line remains the provenance for every body it accepts.
use super::{
    Error, PromptEvent, State,
    input::{self, Output},
    user::Sender,
};
use crate::row::RowKind;
use serde::Deserialize;
use serde_json::value::RawValue;
use std::borrow::Cow;

#[derive(Deserialize, Default)]
#[serde(default)]
struct Record<'a> {
    #[serde(rename = "type", borrow)]
    kind: Cow<'a, str>,
    #[serde(borrow)]
    id: Cow<'a, str>,
    #[serde(borrow)]
    timestamp: Cow<'a, str>,
    #[serde(borrow)]
    payload: Option<Payload<'a>>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Payload<'a> {
    #[serde(rename = "type", borrow)]
    kind: Cow<'a, str>,
    #[serde(borrow)]
    id: Cow<'a, str>,
    #[serde(borrow)]
    message_id: Cow<'a, str>,
    #[serde(borrow)]
    turn_id: Cow<'a, str>,
    #[serde(borrow)]
    role: Cow<'a, str>,
    #[serde(borrow)]
    phase: Cow<'a, str>,
    #[serde(borrow)]
    message: Option<&'a RawValue>,
    #[serde(borrow)]
    content: Option<&'a RawValue>,
    #[serde(rename = "internal_chat_message_metadata_passthrough", borrow)]
    metadata: Metadata<'a>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Metadata<'a> {
    #[serde(borrow)]
    content_item_kinds: Option<Vec<Cow<'a, str>>>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct Item<'a> {
    #[serde(rename = "type", borrow)]
    kind: Cow<'a, str>,
    #[serde(borrow)]
    text: Option<&'a RawValue>,
}

const CONTEXT_PREFIXES: [&str; 4] = [
    "<environment_context>",
    "<user_instructions>",
    "# AGENTS.md instructions",
    "<user_shell_command>",
];

fn context_text(text: &str) -> bool {
    CONTEXT_PREFIXES.iter().any(|prefix| text.trim_start().starts_with(prefix))
}

/// Decode the text-bearing content items without retaining a JSON tree.
fn content_text(raw: &RawValue, filter_context: bool) -> Result<Option<String>, Error> {
    if !raw.get().starts_with('[') {
        return Ok(None);
    }
    let mut text = String::new();
    input::each(raw, |item| {
        let item: Item<'_> = input::value(item)?;
        let Some(raw) = item.text else { return Ok(()) };
        let value = input::text(raw)?;
        if value.is_empty() || (filter_context && context_text(&value)) {
            return Ok(());
        }
        if !text.is_empty() {
            text.push('\n');
        }
        text.push_str(&value);
        Ok(())
    })?;
    let text = text.trim();
    Ok((!text.is_empty()).then(|| text.to_owned()))
}

fn identity<'a>(record: &'a Record<'a>, payload: &'a Payload<'a>) -> &'a str {
    [payload.id.as_ref(), payload.message_id.as_ref(), record.id.as_ref()]
        .into_iter()
        .find(|id| !id.is_empty())
        .unwrap_or("codex")
}

fn turn_key<'a>(record: &'a Record<'a>, payload: &'a Payload<'a>) -> &'a str {
    [payload.turn_id.as_ref(), record.id.as_ref(), payload.id.as_ref()]
        .into_iter()
        .find(|id| !id.is_empty())
        .unwrap_or("codex")
}

fn finish(state: &mut State, status: &str, out: &mut Output<'_>) -> Result<(), Error> {
    if !state.in_turn() {
        state.finish(out);
        return Ok(());
    }
    let mut end = state.row(RowKind::Notice, out)?;
    end.field("notice", "turn_result");
    end.field("status", status);
    state.end_turn(end, status, out);
    Ok(())
}

fn prompt(
    state: &mut State,
    record: &Record<'_>,
    payload: &Payload<'_>,
    body: &RawValue,
    out: &mut Output<'_>,
) -> Result<(), Error> {
    let key = turn_key(record, payload);
    let prompt_key = identity(record, payload);
    state.prompt(
        PromptEvent {
            key,
            prompt_key,
            steer: false,
            notice: false,
            body: Some(body),
            images: None,
            sender: Sender::default(),
            inline_parts: None,
            pasted: None,
            place: 0,
            span: 0,
        },
        out,
    )
}

fn answer(
    state: &mut State,
    record: &Record<'_>,
    payload: &Payload<'_>,
    text: &str,
    out: &mut Output<'_>,
) -> Result<(), Error> {
    let key = identity(record, payload);
    state.text(text, key, key, false, out)
}

pub(super) fn line(state: &mut State, bytes: &[u8], out: &mut Output<'_>) -> Result<(), Error> {
    let record: Record<'_> = input::parse(bytes)?;
    let Some(payload) = record.payload.as_ref() else { return Ok(()) };
    state.at = super::timestamp(&record.timestamp).unwrap_or(state.at);
    state.at_ms = state.at.saturating_mul(1000);

    if record.kind == "event_msg" {
        match payload.kind.as_ref() {
            "user_message" => {
                let Some(body) = payload.message else { return Ok(()) };
                let text = input::text(body)?;
                if text.trim().is_empty() || context_text(&text) {
                    return Ok(());
                }
                prompt(state, &record, payload, body, out)?;
            }
            "agent_message" => {
                let Some(body) = payload.message else { return Ok(()) };
                let text = input::text(body)?;
                if !text.trim().is_empty() {
                    answer(state, &record, payload, text.trim(), out)?;
                }
            }
            "task_complete" | "turn_complete" => finish(state, "completed", out)?,
            _ => {}
        }
        return Ok(());
    }

    if record.kind != "response_item" || payload.kind != "message" {
        return Ok(());
    }
    let Some(content) = payload.content else { return Ok(()) };
    let Some(text) = content_text(content, payload.role == "user")? else { return Ok(()) };
    match payload.role.as_ref() {
        "user" => {
            let typed = payload
                .metadata
                .content_item_kinds
                .as_deref()
                .map(is_typed)
                .unwrap_or_else(|| !context_text(&text));
            if typed {
                prompt(state, &record, payload, content, out)?;
            }
        }
        "assistant" if payload.phase.is_empty() || payload.phase == "final_answer" => {
            answer(state, &record, payload, &text, out)?;
            finish(state, "completed", out)?;
        }
        _ => {}
    }
    Ok(())
}

fn is_typed(kinds: &[Cow<'_, str>]) -> bool {
    kinds.iter().any(|kind| kind == "user.text")
        && kinds.iter().all(|kind| kind.starts_with("user."))
}

pub(super) fn validate(bytes: &[u8]) -> Result<(), Error> {
    let record: Record<'_> = input::parse(bytes)?;
    if record.kind.is_empty() {
        return Err(Error::InvalidRecord("Codex type"));
    }
    super::bounded(&record.kind)?;
    super::bounded(&record.id)?;
    super::bounded(&record.timestamp)?;
    if let Some(payload) = record.payload {
        for value in [
            payload.kind.as_ref(),
            payload.id.as_ref(),
            payload.message_id.as_ref(),
            payload.turn_id.as_ref(),
            payload.role.as_ref(),
            payload.phase.as_ref(),
        ] {
            super::bounded(value)?;
        }
        if let Some(raw) = payload.message {
            let _ = input::text(raw)?;
        }
        if let Some(raw) = payload.content
            && raw.get().starts_with('[')
        {
            let _ = content_text(raw, false)?;
        }
    }
    Ok(())
}
