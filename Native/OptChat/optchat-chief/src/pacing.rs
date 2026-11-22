//! G11 (brains/DESIGN-cmux-lawrence.md): the cloud owner refuses an agent
//! message within its gap of the previous one (`agent_rate`, 2 s) and limits
//! agent turns without a human. The outbox therefore coalesces messages it has
//! not tried yet into one send, waits out the gap before the next agent
//! message, and retries an `agent_rate` refusal with a growing backoff under the
//! same key (the owner dedupes by key), never dropping it.

use std::time::Duration;

use cmux_conversation::{Op, Part};

use crate::state::OutboxEntry;

/// The longest wait between two tries of one refused message.
pub const MAX_BACKOFF: Duration = Duration::from_secs(60);

/// Merges each run of untried `message.send` entries of one conversation into
/// the first: its key, the texts joined by a blank line. An entry already tried
/// keeps its content (a retry under its key must send the same text), and an
/// entry with a reply target or a non-text part is never merged.
pub fn coalesce(entries: &mut Vec<OutboxEntry>) {
    let mut i = 0;
    while i + 1 < entries.len() {
        let mergeable = !entries[i].attempted
            && !entries[i + 1].attempted
            && entries[i].conversation == entries[i + 1].conversation
            && plain_text(&entries[i].op).is_some()
            && plain_text(&entries[i + 1].op).is_some();
        if !mergeable {
            i += 1;
            continue;
        }
        let next = entries.remove(i + 1);
        let tail = plain_text(&next.op).unwrap_or_default();
        if let Op::MessageSend { parts, .. } = &mut entries[i].op
            && let Some(Part::Text { text, .. }) = parts.first_mut()
        {
            text.push_str("\n\n");
            text.push_str(&tail);
        }
    }
}

/// The text of a one-part, plain-text `message.send` without a reply target.
fn plain_text(op: &Op) -> Option<String> {
    match op {
        Op::MessageSend {
            parts,
            reply_to: None,
            ..
        } => match parts.as_slice() {
            [Part::Text { text, runs: None }] => Some(text.clone()),
            _ => None,
        },
        _ => None,
    }
}

/// Milliseconds to wait before the next agent message, or None when the gap
/// since the last one (`last_ms`, epoch ms) has passed.
pub fn gap_wait(last_ms: Option<u64>, gap_ms: u64, now_ms: u64) -> Option<u64> {
    let due = last_ms?.saturating_add(gap_ms);
    (now_ms < due).then(|| due - now_ms)
}

/// The wait before try `attempt` (1-based) of an `agent_rate` refusal: the gap,
/// doubling, at most [`MAX_BACKOFF`].
pub fn backoff(gap: Duration, attempt: u32) -> Duration {
    let factor = 1u32
        .checked_shl(attempt.saturating_sub(1))
        .unwrap_or(u32::MAX);
    gap.checked_mul(factor)
        .unwrap_or(MAX_BACKOFF)
        .min(MAX_BACKOFF)
}
