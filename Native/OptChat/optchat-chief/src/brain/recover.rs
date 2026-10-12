//! Restart after a host that stopped during a turn. The pending turn says,
//! per batch of logged items, where the batch starts in the log and whether
//! every item reached it; the log's length tells how many did when the save
//! after the appends was lost. Each logged item's bookkeeping is finished
//! (cursor for a human message, `Reported` for a child's report), so nothing
//! is logged twice; items that never reached the log are caught up again.
//! A cut turn whose human messages reached the log runs again as a resume
//! turn on `RESUMED` (E23, the reference client's Server.ts `resume`), so
//! each message is answered once.

use optchat_host::OptChat;

use crate::state::{ChildStatus, HostState, Item, Resume};
use crate::turn::Orphan;

/// The note a resume turn runs on (the reference client's words). It is
/// logged as `user`; the cut turn's messages are in the log before it.
pub(super) const RESUMED: &str = "The server restarted, cutting the turn; nothing was lost: go on.";

/// The resume turn's new messages: the note, then the cut requests' full
/// text in order (the reference client re-queues them into the next call's
/// new messages), before any newer message. Only the note is logged.
pub(super) fn resume_prompt(cut: &[String]) -> String {
    if cut.is_empty() {
        return RESUMED.to_owned();
    }
    format!(
        "{RESUMED} These are the cut turn's requests, in order: finish them first, then any newer message.\n\n{}",
        cut.join("\n\n")
    )
}

/// Finishes the pending turn's bookkeeping in `state` and clears it.
/// Returns the names of acpmux turn sessions to remove whose id was never
/// saved; a session whose id is known becomes an orphan instead, so what it
/// did after the last fold still reaches the log (section 7).
pub(super) fn recover(chat: &OptChat, state: &mut HostState, acpmux: bool) -> Vec<String> {
    let Some(turn) = state.turn.take() else {
        return Vec::new();
    };
    let messages = chat.status().messages;
    let opening = turn.opening();
    let mut batches: Vec<(u64, Vec<Item>, bool)> = Vec::new();
    match turn.first_id {
        // Once the key is set, every opening item is logged.
        Some(first) => batches.push((first, opening, !turn.key.is_empty())),
        // A pre-`first_id` host: it set the key only after logging.
        None => batches.push((0, opening, true)),
    }
    for batch in &turn.mid {
        batches.push((batch.at, batch.items.clone(), batch.done));
    }
    let mut human = false;
    let mut remote = false;
    // The cut messages' full text, in log order (the resume turn's).
    let mut cut: Vec<String> = Vec::new();
    for (k, (at, items, done)) in batches.iter().enumerate() {
        // A pre-`first_id` host's opening batch has no known log position.
        let positioned = k > 0 || turn.first_id.is_some();
        let logged = if *done {
            items.len()
        } else {
            (messages.saturating_sub(*at) as usize).min(items.len())
        };
        for (j, item) in items[..logged].iter().enumerate() {
            // A logged resume note is a cut turn's too: it resumes again.
            human |= item.resume;
            remote |= item.remote;
            cut.extend(item.cut.iter().cloned());
            if item.seq.is_some()
                && positioned
                && let Some((_, text)) = chat.message(at + j as u64)
            {
                cut.push(text);
            }
            // A logged image keeps its description pending until the note is
            // written (the save after the describe may have been lost).
            for image in &item.images {
                if !state.undescribed.contains(image) {
                    state.undescribed.push(image.clone());
                }
            }
            match (item.seq, &item.conversation) {
                (Some(seq), Some(side)) => {
                    human = true;
                    let id = item.id.as_deref().unwrap_or("");
                    state.side.entry(side.clone()).or_default().handled(seq, id);
                }
                (Some(seq), None) => {
                    human = true;
                    state.logged_seq = state.logged_seq.max(seq);
                }
                _ => {}
            }
            if let Some(spawn) = &item.spawn {
                state.spawn_logged(spawn);
            }
            if let Some(child) = &item.child
                && let Some(record) = state.children.get_mut(&child.session_id)
            {
                record.status = ChildStatus::Reported;
                record.floor = child.floor;
            }
        }
    }
    // Messages in the log stay there and are not logged again (section 7);
    // the turn runs again on the resume note and answers them once.
    if human && let Some(conversation) = turn.conversation.as_deref() {
        let side =
            (state.conversation.as_deref() != Some(conversation)).then(|| conversation.to_owned());
        match state.resumes.iter_mut().find(|r| r.conversation == side) {
            Some(r) => {
                r.remote |= remote;
                r.messages.extend(cut);
            }
            None => state.resumes.push(Resume {
                conversation: side,
                remote,
                messages: cut,
            }),
        }
    }
    if !acpmux {
        return Vec::new();
    }
    // A session the brain never heard of: its fold position, written when
    // the turn created it, names it (one turn runs at a time, and a turn's
    // position is dropped when it ends).
    let session_id = turn.session_id.clone().or_else(|| {
        let rows = chat.state_prefix(crate::state::FOLD_PREFIX).ok()?;
        let mut unclaimed = rows.into_iter().filter_map(|(k, _)| {
            let id = k.strip_prefix(crate::state::FOLD_PREFIX)?.to_owned();
            (!state.orphans.iter().any(|o| o.session == id)).then_some(id)
        });
        let first = unclaimed.next()?;
        unclaimed.next().is_none().then_some(first)
    });
    match session_id {
        Some(session) => {
            // The fold position commits with the folded entries, so it is
            // never behind the log; the pending turn's copy can be.
            let after = turn.after.max(crate::state::folded(chat, &session));
            state.orphans.push(Orphan { session, after });
            Vec::new()
        }
        None => vec![turn.session],
    }
}
