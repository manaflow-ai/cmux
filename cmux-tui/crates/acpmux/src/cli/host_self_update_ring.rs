//! The signed config ring on the self-update tick (cmuxterm-hq
//! docs/rfd/0224-one-update-system.md, "Hot patches": flags first, so flipping a flag is the
//! default fix for a bad feature, with no new build).
//!
//! Every `host self-update` run reads `cmux-tui/rings/<ring>.json` on R2 (the ring is the update
//! channel's name), verifies it with `cmux_signed_envelope::config_ring::verify` against the
//! seq this host applied last, and keeps what it applied in `<home>/config-ring/<ring>.json`:
//! the seq, the file's times and its flags. A file not published yet (404), an unreadable one,
//! or one the verify refuses (a bad signature, expired, another ring, or a replayed older seq)
//! leaves the applied state as it was and never fails the update: the flags only ever move
//! forward to a newer signed file. [`applied`] is what the rest of acpmux reads.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use cmux_signed_envelope::Key;
use cmux_signed_envelope::config_ring::{self, FlagValue, MAX_RING_BYTES};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use super::{FILES, Fetch};

/// The applied state's schema.
pub(crate) const SCHEMA: &str = "acpmux-config-ring/v1";
/// The folder in the acpmux home that keeps one applied file per ring.
pub(crate) const DIR: &str = "config-ring";

/// Where CI publishes `ring`'s file.
pub(crate) fn ring_url(ring: &str) -> String {
    format!("{FILES}/rings/{ring}.json")
}

/// The applied file of `ring` in `home`.
pub(crate) fn applied_path(home: &Path, ring: &str) -> PathBuf {
    home.join(DIR).join(format!("{ring}.json"))
}

/// What a host applied of a ring.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Applied {
    pub(crate) schema: String,
    pub(crate) ring: String,
    pub(crate) seq: u64,
    pub(crate) issued_at: u64,
    pub(crate) expires_at: u64,
    pub(crate) applied_at: u64,
    pub(crate) flags: BTreeMap<String, Value>,
}

/// The ring `ring` as `home` applied it last; None before the first, or when the file is not
/// this schema's (then the next tick applies the published one again).
pub(crate) fn applied(home: &Path, ring: &str) -> Option<Applied> {
    let body = std::fs::read(applied_path(home, ring)).ok()?;
    let applied: Applied = serde_json::from_slice(&body).ok()?;
    (applied.schema == SCHEMA && applied.ring == ring).then_some(applied)
}

/// What one tick did.
#[derive(Clone, Debug, PartialEq)]
pub(crate) enum RingOutcome {
    /// A newer signed file: its seq and flag count, now applied.
    Applied { seq: u64, flags: usize },
    /// The file is the seq already applied.
    Unchanged { seq: u64 },
    /// No file at the URL (or not reachable): the applied state, if any, holds.
    NotRead(String),
    /// The file was read and refused; the applied state holds.
    Refused(String),
}

impl RingOutcome {
    pub(crate) fn json(&self, ring: &str) -> Value {
        match self {
            RingOutcome::Applied { seq, flags } => {
                json!({"ring": ring, "outcome": "applied", "seq": seq, "flags": flags})
            }
            RingOutcome::Unchanged { seq } => {
                json!({"ring": ring, "outcome": "unchanged", "seq": seq})
            }
            RingOutcome::NotRead(why) => {
                json!({"ring": ring, "outcome": "notRead", "message": why})
            }
            RingOutcome::Refused(why) => {
                json!({"ring": ring, "outcome": "refused", "message": why})
            }
        }
    }

    /// The line a plain run prints, only when something changed or was refused.
    pub(crate) fn line(&self, ring: &str) -> Option<String> {
        match self {
            RingOutcome::Applied { seq, flags } => {
                Some(format!("config ring {ring}: applied seq {seq} ({flags} flags)"))
            }
            RingOutcome::Refused(why) => Some(format!("config ring {ring}: refused: {why}")),
            RingOutcome::Unchanged { .. } | RingOutcome::NotRead(_) => None,
        }
    }
}

fn flag_json(value: &FlagValue) -> Value {
    match value {
        FlagValue::Bool(value) => json!(value),
        FlagValue::Number(value) => json!(value),
        FlagValue::String(value) => json!(value),
    }
}

/// Read, verify and keep `ring`'s file for `home` at `now` (unix seconds).
pub(super) async fn tick(
    home: &Path,
    fetch: &dyn Fetch,
    keys: &[Key],
    ring: &str,
    now: u64,
) -> RingOutcome {
    let last = applied(home, ring);
    let body = match fetch.get(&ring_url(ring), MAX_RING_BYTES).await {
        Ok(body) => body,
        Err(why) => return RingOutcome::NotRead(why),
    };
    let verified =
        match config_ring::verify(&body, keys, ring, now, last.as_ref().map(|last| last.seq)) {
            Ok(verified) => verified,
            Err(why) => return RingOutcome::Refused(why),
        };
    if last.as_ref().is_some_and(|last| last.seq == verified.seq) {
        return RingOutcome::Unchanged { seq: verified.seq };
    }
    let flags: BTreeMap<String, Value> =
        verified.flags.iter().map(|(name, value)| (name.clone(), flag_json(value))).collect();
    let count = flags.len();
    let state = Applied {
        schema: SCHEMA.to_owned(),
        ring: verified.ring,
        seq: verified.seq,
        issued_at: verified.issued_at,
        expires_at: verified.expires_at,
        applied_at: now,
        flags,
    };
    let path = applied_path(home, ring);
    let written = path
        .parent()
        .map_or(Ok(()), std::fs::create_dir_all)
        .map_err(|e| e.to_string())
        .and_then(|()| serde_json::to_vec_pretty(&state).map_err(|e| e.to_string()))
        .and_then(|body| crate::home_fs::write_durable(&path, &body).map_err(|e| e.to_string()));
    match written {
        Ok(()) => RingOutcome::Applied { seq: state.seq, flags: count },
        Err(why) => RingOutcome::Refused(format!("keeping {}: {why}", path.display())),
    }
}

#[cfg(test)]
#[path = "host_self_update_ring_tests.rs"]
mod tests;
