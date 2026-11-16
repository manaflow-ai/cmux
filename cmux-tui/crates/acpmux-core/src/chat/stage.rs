//! Stateful tap composition shared by v1 and the chat actor.
//!
//! The writer is deliberately outside this module. `before` prepares the one record and
//! caller-side steps, the caller appends that record, then `after` commits repeat state and
//! returns post-write steps. No step performs I/O or invokes a hub.

use super::record::{Context, Entry, Record};

/// Read-only values supplied by the caller for one harness entry.
#[derive(Clone, Copy, Debug, Default)]
pub struct Call {
    /// A live update may be reduced by the repeat filter; replayed updates are always retained.
    pub eligible_update: bool,
}

/// A caller-side action that must retain v1's ordering around the record write.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// The entry was acknowledged but had no record after filtering.
    Touch,
}

/// The data returned before the writer runs.
pub struct Before {
    pub steps: Vec<Step>,
    /// The record to append, if any. Its repeat hashes are committed only by `after`.
    pub record: Option<Record>,
}

/// Data returned after the writer reports whether the record reached durable storage.
pub struct After {
    pub steps: Vec<Step>,
}

/// Build the record and pre-write steps. The caller owns append/ack and all hub effects.
pub fn before(entry: Entry<'_>, context: &mut Context, call: Call) -> Before {
    let mut record = super::record::record_of(entry, context);
    let mut steps = Vec::new();
    if let Some(candidate) = record.as_mut()
        && !candidate.trim_live_update(context, call.eligible_update)
    {
        record = None;
    }
    if record.is_none() {
        steps.push(Step::Touch);
    }
    Before { steps, record }
}

/// Commit state only after the caller's append succeeds.
pub fn after(mut before: Before, context: &mut Context, logged: bool) -> After {
    if logged {
        if let Some(record) = before.record.take() {
            record.note_logged(context);
        }
    }
    After { steps: Vec::new() }
}
