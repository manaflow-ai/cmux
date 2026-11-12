//! Claude transcript JSONL, parsed one borrowed record/block at a time.
use super::{
    BodyField, Error, State,
    input::{self, Block, Output},
};
use crate::row::RowKind;
use serde::Deserialize;
use serde_json::value::RawValue;
use std::borrow::Cow;
#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct Record<'a> {
    #[serde(rename = "type", borrow)]
    kind: Cow<'a, str>,
    #[serde(borrow)]
    timestamp: Cow<'a, str>,
    #[serde(borrow)]
    uuid: Cow<'a, str>,
    is_sidechain: bool,
    is_meta: bool,
    is_compact_summary: bool,
    #[serde(borrow)]
    message: Option<Message<'a>>,
    #[serde(borrow)]
    origin: Origin<'a>,
}
#[derive(Deserialize, Default)]
#[serde(default)]
struct Origin<'a> {
    #[serde(borrow)]
    kind: Cow<'a, str>,
}
#[derive(Deserialize, Default)]
#[serde(default)]
struct Message<'a> {
    #[serde(borrow)]
    id: Cow<'a, str>,
    #[serde(borrow)]
    content: Option<&'a RawValue>,
    #[serde(borrow)]
    stop_reason: Option<Cow<'a, str>>,
}
pub(super) fn line(state: &mut State, bytes: &[u8], out: &mut Output<'_>) -> Result<(), Error> {
    let rec: Record<'_> = input::parse(bytes)?;
    if rec.kind.is_empty() {
        return Err(Error::InvalidRecord("Claude type"));
    }
    if rec.is_sidechain || rec.is_meta || rec.is_compact_summary {
        return Ok(());
    }
    if let Some(at) = timestamp(&rec.timestamp) {
        state.at = at;
        state.at_ms = at.saturating_mul(1000);
    }
    if rec.kind == "result" {
        state.finish(out);
        return Ok(());
    }
    let Some(message) = rec.message else { return Ok(()) };
    let Some(body) = message.content else { return Ok(()) };
    match rec.kind.as_ref() {
        "user" => {
            let mut results = false;
            if body.get().starts_with('[') {
                input::each(body, |raw| {
                    let block: Block<'_> = input::value(raw)?;
                    if block.kind == "tool_result" {
                        results = true;
                    }
                    Ok(())
                })?;
            }
            if results {
                input::each(body, |raw| {
                    let block: Block<'_> = input::value(raw)?;
                    if block.kind == "tool_result" && !block.tool_use_id.is_empty() {
                        let parts = block.content.map(|raw| (BodyField::Content, false, raw));
                        state.tool(
                            &block.tool_use_id,
                            &[("status", if block.is_error { "failed" } else { "completed" })],
                            parts.as_slice(),
                            true,
                            false,
                            out,
                        )?;
                    }
                    Ok(())
                })?;
            } else {
                if body.get().starts_with('"') {
                    let text = input::text(body)?;
                    let start = text.trim_start();
                    if start.is_empty()
                        || ["<command-", "<local-command-", "<bash-", "[Request interrupted"]
                            .iter()
                            .any(|p| start.starts_with(p))
                    {
                        return Ok(());
                    }
                }
                let notice = !rec.origin.kind.is_empty() && rec.origin.kind != "human";
                state.prompt(
                    super::PromptEvent {
                        key: &rec.uuid,
                        prompt_key: "",
                        steer: false,
                        notice,
                        body: Some(body),
                        images: None,
                    },
                    out,
                )?;
            }
        }
        "assistant" => {
            if body.get().starts_with('"') {
                state.text(&input::text(body)?, &message.id, &message.id, false, out)?;
            } else {
                input::each(body, |raw| {
                    let block: Block<'_> = input::value(raw)?;
                    match block.kind.as_ref() {
                        "text" | "thinking" => {
                            let thinking = block.kind == "thinking";
                            if let Some(raw) = if thinking { block.thinking } else { block.text } {
                                state.text(
                                    &input::text(raw)?,
                                    &message.id,
                                    &message.id,
                                    thinking,
                                    out,
                                )?;
                            }
                        }
                        "tool_use" if !block.id.is_empty() => {
                            let parts = block.input.map(|raw| (BodyField::Input, false, raw));
                            state.tool(
                                &block.id,
                                &[("tool", &block.name), ("status", "running")],
                                parts.as_slice(),
                                false,
                                true,
                                out,
                            )?;
                        }
                        "image" => {
                            let mut row = state.row(RowKind::Image, out)?;
                            out.row(&row);
                            if let Some(raw) = block.source {
                                out.body(row.id, BodyField::Source, false, raw)?;
                            }
                            row.open = false;
                            out.row(&row);
                        }
                        _ => {}
                    }
                    Ok(())
                })?;
            }
            if matches!(message.stop_reason.as_deref(), Some("end_turn" | "stop_sequence")) {
                state.finish(out);
            }
        }
        _ => {}
    }
    Ok(())
}

pub(super) fn validate(bytes: &[u8]) -> Result<(), Error> {
    let rec: Record<'_> = input::parse(bytes)?;
    super::bounded(&rec.uuid)?;
    if let Some(message) = rec.message {
        super::bounded(&message.id)?;
        if let Some(body) = message.content {
            if body.get().starts_with('[') {
                input::each(body, |raw| {
                    let block: Block<'_> = input::value(raw)?;
                    if let Some(raw) = block.text.or(block.thinking) {
                        let _ = input::text(raw)?;
                    }
                    if let Some(raw) = block.input {
                        let _: &RawValue = raw;
                    }
                    if let Some(raw) = block.content {
                        input::content(raw, 0, &mut |_| Ok(()))?;
                    }
                    super::bounded(&block.id)?;
                    super::bounded(&block.name)?;
                    super::bounded(&block.tool_use_id)
                })?;
            } else if body.get().starts_with('"') {
                let _ = input::text(body)?;
            }
        }
    }
    Ok(())
}

/// RFC3339 seconds, independent of local timezone. Missing timestamps inherit checkpoint `at`.
fn timestamp(s: &str) -> Option<u64> {
    let n = |r: std::ops::Range<usize>| s.get(r)?.parse::<i64>().ok();
    let y = n(0..4)?;
    let m = n(5..7)?;
    let d = n(8..10)?;
    let h = n(11..13)?;
    let min = n(14..16)?;
    let sec = n(17..19)?;
    if s.get(4..5)? != "-"
        || s.get(7..8)? != "-"
        || !matches!(s.get(10..11)?, "T" | "t")
        || s.get(13..14)? != ":"
        || s.get(16..17)? != ":"
        || !(1..=12).contains(&m)
        || !(1..=31).contains(&d)
        || !(0..=23).contains(&h)
        || !(0..=59).contains(&min)
        || !(0..=59).contains(&sec)
    {
        return None;
    }
    let y = y.checked_sub(i64::from(m <= 2))?;
    let era = y.div_euclid(400);
    let yo = y.checked_sub(era.checked_mul(400)?)?;
    let mp = m.checked_add(if m > 2 { -3 } else { 9 })?;
    let doy = (153i64.checked_mul(mp)?.checked_add(2)? / 5).checked_add(d)?.checked_sub(1)?;
    let doe = yo.checked_mul(365)?.checked_add(yo / 4)?.checked_sub(yo / 100)?.checked_add(doy)?;
    let days = era.checked_mul(146097)?.checked_add(doe)?.checked_sub(719468)?;
    let tail = s.get(19..)?;
    let zone = if let Some(frac) = tail.strip_prefix('.') {
        let pos = frac.find(|c: char| !c.is_ascii_digit())?;
        if pos == 0 {
            return None;
        }
        frac.get(pos..)?
    } else {
        tail
    };
    let offset = if matches!(zone, "Z" | "z") {
        0
    } else {
        if zone.len() != 6 || zone.get(3..4)? != ":" {
            return None;
        }
        let zh = zone.get(1..3)?.parse::<i64>().ok()?;
        let zm = zone.get(4..6)?.parse::<i64>().ok()?;
        if zh > 23 || zm > 59 {
            return None;
        }
        let v = zh.checked_mul(3600)?.checked_add(zm.checked_mul(60)?)?;
        match zone.get(..1)? {
            "+" => v,
            "-" => v.checked_neg()?,
            _ => return None,
        }
    };
    u64::try_from(
        days.checked_mul(86400)?
            .checked_add(h.checked_mul(3600)?)?
            .checked_add(min.checked_mul(60)?)?
            .checked_add(sec)?
            .checked_sub(offset)?,
    )
    .ok()
}
