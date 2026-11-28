//! A permission answered after its tool settled. The usual lookup reads one indexed record.
//! A turn beyond the translator's retained call IDs searches backward within that prompt.
use super::{ActorState, ChatError, RawRange, RowKind, stream};
use acpmux_book::log::{Edge, RowRef};
use acpmux_book::row::{RowHead, approve_settled_tool};

pub(super) fn apply(
    state: &mut ActorState,
    call: &str,
    turn: Option<u64>,
    hint: Option<u64>,
    raw: RawRange,
) -> Result<bool, ChatError> {
    if let Some(reference) = hint.and_then(|id| state.log.row(id)) {
        let mut bytes = Vec::new();
        let mut ranges = Vec::new();
        state.log.fill(&[reference], &mut bytes, &mut ranges)?;
        if let Some(text) = ranges.first().and_then(|range| bytes.get(range.clone()))
            && approve(state, call, turn, &reference, text, raw)?
        {
            return Ok(true);
        }
    }
    let first = turn.unwrap_or(1);
    let mut edge = state.translate.last_row_id().saturating_add(1);
    while edge > first {
        let page = state.log.page(Edge::Before(edge), 64 * 1024)?;
        for (reference, range) in page.rows.iter().zip(&page.at).rev() {
            if reference.row_id < first {
                return Ok(false);
            }
            if let Some(text) = page.bytes.get(range.clone())
                && approve(state, call, turn, reference, text, raw)?
            {
                return Ok(true);
            }
        }
        if !page.has_before || page.lo >= edge {
            break;
        }
        edge = page.lo;
    }
    Ok(false)
}

fn approve(
    state: &mut ActorState,
    call: &str,
    turn: Option<u64>,
    reference: &RowRef,
    text: &[u8],
    raw: RawRange,
) -> Result<bool, ChatError> {
    let Some(head) = RowHead::parse(text).filter(|h| h.kind == RowKind::Tool && h.turn == turn)
    else {
        return Ok(false);
    };
    #[derive(serde::Deserialize)]
    #[serde(rename_all = "camelCase")]
    struct Facts {
        call_id: Option<String>,
        #[serde(default)]
        approved: bool,
    }
    // Decode just the object at body_at. Unrelated fields, including output, are skipped.
    let body_bytes = text.get(head.body_at..).ok_or(ChatError::Closed)?;
    let mut reader = serde_json::Deserializer::from_slice(body_bytes);
    let body: Facts =
        serde::Deserialize::deserialize(&mut reader).map_err(|_| ChatError::Closed)?;
    if body.call_id.as_deref() != Some(call) {
        return Ok(false);
    }
    if body.approved {
        return Ok(true);
    }
    if head.rev > 1 {
        if text.ends_with(b",\"approvedAfterSettle\":true}") {
            // Recovering a log ahead of its checkpoint accounts for this exact patch once.
            if state.replay_remaining > 0 && state.log.raw_range(reference)? == raw {
                state.replay_remaining = state.replay_remaining.saturating_sub(1);
            }
            return Ok(true);
        }
        return Ok(false);
    }
    let patched = approve_settled_tool(text, &head).ok_or(ChatError::Closed)?;
    state.source.sync_through(state.raw_place)?;
    let seq = state.log.patch(head.id, head.rev + 1, raw, &patched)?;
    stream::settled(state, "patch", seq, &patched, head.id);
    Ok(true)
}
