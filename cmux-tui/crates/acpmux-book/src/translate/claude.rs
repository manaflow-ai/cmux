//! Claude transcript JSONL: persisted message blocks, not a whole transcript parse.
use super::{Change, Error, State, content, json::Json, v1::field};
use crate::row::RowKind;
use std::collections::BTreeMap;

pub(super) fn line(state: &mut State, rec: Json<'_>, out: &mut Vec<Change>) -> Result<(), Error> {
    let kind = rec.text("type").ok_or(Error::InvalidRecord("Claude type"))?;
    if rec.get("isSidechain").is_some_and(Json::yes)
        || rec.get("isMeta").is_some_and(Json::yes)
        || rec.get("isCompactSummary").is_some_and(Json::yes)
    {
        return Ok(());
    }
    if let Some(at) = rec.text("timestamp").and_then(|s| timestamp(&s)) {
        state.at = at;
    }
    if kind == "result" {
        state.finish(out);
        return Ok(());
    }
    let Some(message) = rec.get("message") else {
        return Ok(());
    };
    let Some(body) = message.get("content") else {
        return Ok(());
    };
    match kind.as_ref() {
        "user" => {
            let results = body.items().is_some_and(|i| {
                i.into_iter().any(|v| v.text("type").as_deref() == Some("tool_result"))
            });
            if results {
                for block in body.items().into_iter().flatten() {
                    if block.text("type").as_deref() != Some("tool_result") {
                        continue;
                    }
                    let Some(key) = block.text("tool_use_id") else {
                        continue;
                    };
                    let mut fields = BTreeMap::new();
                    field(
                        &mut fields,
                        "status",
                        if block.get("is_error").is_some_and(Json::yes) {
                            "failed"
                        } else {
                            "completed"
                        },
                    );
                    state.tool(
                        key.into_owned(),
                        fields,
                        Some(content(block.get("content"))),
                        None,
                        true,
                        out,
                    );
                }
            } else {
                let text = content(Some(body));
                let start = text.trim_start();
                if text.is_empty()
                    || ["<command-", "<local-command-", "<bash-", "[Request interrupted"]
                        .iter()
                        .any(|p| start.starts_with(p))
                {
                    return Ok(());
                }
                let notice = rec
                    .path(&["origin", "kind"])
                    .and_then(Json::string)
                    .is_some_and(|s| s != "human");
                state.prompt(
                    text,
                    rec.text("uuid").unwrap_or_default().into_owned(),
                    false,
                    notice,
                    out,
                );
            }
        }
        "assistant" => {
            if let Some(text) = body.string() {
                state.text(
                    text.into_owned(),
                    message.text("id").unwrap_or_default().into_owned(),
                    false,
                    out,
                );
                State::close_stream(&mut state.reply, out);
            }
            for block in body.items().into_iter().flatten() {
                match block.text("type").as_deref() {
                    Some("text") | Some("thinking") => {
                        let thinking = block.text("type").as_deref() == Some("thinking");
                        let key = message.text("id").unwrap_or_default().into_owned();
                        state.text(content(Some(block)), key, thinking, out);
                        // A persisted content block is complete, unlike a v1 text delta.
                        if thinking {
                            State::close_stream(&mut state.thought, out);
                        } else {
                            State::close_stream(&mut state.reply, out);
                        }
                    }
                    Some("tool_use") => {
                        let Some(key) = block.text("id") else {
                            continue;
                        };
                        let mut fields = BTreeMap::new();
                        field(&mut fields, "tool", block.text("name").as_deref().unwrap_or(""));
                        field(&mut fields, "status", "running");
                        // Input is cold; the raw range retains access to it without a parsed copy.
                        state.tool(key.into_owned(), fields, None, None, false, out);
                    }
                    Some("image") => {
                        let mut row = state.row(RowKind::Image, false, String::new());
                        row.field("source", "raw");
                        out.push(Change::Row(row));
                    }
                    _ => {}
                }
            }
            if matches!(message.text("stop_reason").as_deref(), Some("end_turn" | "stop_sequence"))
            {
                state.finish(out);
            }
        }
        _ => {}
    }
    Ok(())
}

/// RFC3339 seconds, independent of local timezone. Missing timestamps inherit checkpoint `at`.
fn timestamp(s: &str) -> Option<u64> {
    let n = |r| s.get(r)?.parse::<i64>().ok();
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
