//! The chat's log going to the Cloud: its records in order, `seq` from 1, as an export writes
//! them. It resumes after the store's last seq, and a gap answer says where to resume.

use std::sync::Arc;

use cmux_auto_session::AutoCloud;
use cmux_auto_session::cloud::{AutoCloudError, CloudResult};
use cmux_auto_session::consts::{EVENTS_MAX_BYTES, EVENTS_MAX_PER_APPEND};
use cmux_auto_session::wire::{ErrorCode, EventsAppend, Fence, SeqRecord};

use crate::hub::{Hub, Session};

/// The room an append's body keeps for its own fields, around its records.
const BODY_MARGIN: usize = 4096;

/// How often a gap answer moves the resume point before the upload gives up: the store
/// answers its last seq, so one is enough unless another writer appends meanwhile.
const GAP_TRIES: usize = 3;

/// Appends the records through the local high-water mark at entry, starting after `after`.
/// A running agent may append faster than the network can upload: chasing its moving tail
/// would keep the snapshot behind this upload from ever being published. Later records go
/// with the next copy. Answers the store's last seq.
pub(crate) async fn upload<C: AutoCloud>(
    hub: &Arc<Hub>,
    cloud: &C,
    session: &Arc<Session>,
    fence: &Fence,
    after: u64,
    through: u64,
) -> CloudResult<u64> {
    let mut after = after;
    let mut gaps = 0usize;
    while after < through {
        let (reader, chat) = (hub.clone(), session.clone());
        let from = after;
        let page = tokio::task::spawn_blocking(move || {
            let mut page = reader.auto_events(
                &chat,
                from,
                EVENTS_MAX_PER_APPEND,
                EVENTS_MAX_BYTES.saturating_sub(BODY_MARGIN),
            )?;
            page.retain(|(seq, _)| *seq <= through);
            // Masked here, off the turn's path, so a secret's plain text never leaves.
            page.iter_mut().for_each(|(_, record)| super::redact::redact(record));
            anyhow::Ok(page)
        })
        .await
        .map_err(|error| AutoCloudError::decoding(format!("reading the chat's log: {error}")))?
        .map_err(|error| AutoCloudError::decoding(format!("reading the chat's log: {error}")))?;
        let Some(last) = page.last().map(|(seq, _)| *seq) else { return Ok(after) };
        let events = page.into_iter().map(|(seq, record)| SeqRecord { seq, record }).collect();
        let request = EventsAppend { holder: fence.holder.clone(), epoch: fence.epoch, events };
        match cloud.append_events(&session.id, &request).await {
            // The store may be ahead of this page (a repeat of stored seqs is accepted).
            Ok(stored) => after = stored.max(last),
            Err(error) if error.code() == Some(ErrorCode::SeqGap) && gaps < GAP_TRIES => {
                let Some(stored) = error.last_seq() else { return Err(error) };
                gaps += 1;
                after = stored;
            }
            Err(error) => return Err(error),
        }
    }
    Ok(after)
}
