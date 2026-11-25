//! The Mac's relay publisher (RFD 0142 R2 and R9): seals the newest snapshot of a stream to each
//! paired phone's key and puts it on the relay, and appends each change after it as a sealed delta
//! on `<stream>/delta`, so a phone that opens or resumes while this Mac sleeps still gets content
//! (`cmux_mobile_link::relay_cache`, the Worker's `/v1/relay-cache/...`).
//!
//! Off unless [`RelayPublishConfig::enabled`] is set (default off). It adds a copy on the relay; the
//! link stays the source of truth and nothing here replaces it.
//!
//! One position counter per stream, shared by every viewer: the snapshot sits at the position of
//! the last delta it includes, and the next delta is the seq after it, so a phone that cold-opened
//! at `P` applies deltas from `P + 1` (`cmux_relay_snapshot::delta::apply`).
//!
//! The relay keeps at most 512 deltas per slot ([`cmux_relay_snapshot::delta::MAX_ENTRIES`]); a
//! stream that changes 20 times a second would wrap it in 26 s. [`Coalescer`] batches changes into
//! one delta per window so a minute away fits.

use std::collections::HashMap;
use std::sync::{Mutex, PoisonError};
use std::time::{Duration, Instant};

use cmux_mobile_link::relay_cache::{FIRST_SCREEN_BYTES, RelayCache, RelayCacheError, first_screen_stream};
use cmux_relay_snapshot::delta::delta_stream;
use cmux_relay_snapshot::{MAX_PLAINTEXT, Position, seal};
use p256::PublicKey;
use p256::ecdsa::SigningKey;

use crate::pairing::DeviceTrust;
use crate::push_keys::PushKeys;

/// Whether hostd publishes to the relay cache at all. Default off.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct RelayPublishConfig {
    pub enabled: bool,
}

/// One phone the Mac publishes for: its device id and the key its envelopes are sealed to.
#[derive(Debug, Clone)]
pub struct Viewer {
    pub device: String,
    pub key: PublicKey,
}

/// Every phone the Mac pairs now that gave it a push key (`PushKeys::for_paired`), with that key;
/// a key that does not parse is skipped.
pub fn viewers(push_keys: &PushKeys, trust: &DeviceTrust) -> Vec<Viewer> {
    push_keys
        .for_paired(trust)
        .into_iter()
        .filter_map(|(device, key)| Some(Viewer { device, key: crate::seal::public_key_hex(&key).ok()? }))
        .collect()
}

/// What one publish did: how many viewers got it, and the first refusal.
#[derive(Debug, Default)]
pub struct Published {
    pub position: Option<Position>,
    pub sent: usize,
    pub failed: usize,
    pub bytes: usize,
    pub first_error: Option<String>,
}

pub struct RelayPublisher {
    cache: RelayCache,
    key: SigningKey,
    epoch: u64,
    config: RelayPublishConfig,
    /// The last position published per stream.
    seqs: Mutex<HashMap<String, u64>>,
}

impl RelayPublisher {
    /// `cache` is this Mac's relay cache client (its device id is the source); `key` is the source
    /// identity key the phones pin; `epoch` starts a new history (a new hostd run, a re-key).
    pub fn new(cache: RelayCache, key: SigningKey, epoch: u64, config: RelayPublishConfig) -> Self {
        Self { cache, key, epoch, config, seqs: Mutex::new(HashMap::new()) }
    }

    pub fn source_key(&self) -> PublicKey {
        PublicKey::from(self.key.verifying_key())
    }

    /// Where `stream` stands: the position its next snapshot is published at.
    pub fn position(&self, stream: &str) -> Position {
        let seqs = self.seqs.lock().unwrap_or_else(PoisonError::into_inner);
        Position { epoch: self.epoch, seq: seqs.get(stream).copied().unwrap_or(0) }
    }

    /// Seals `state` (the stream's whole current state, at most [`MAX_PLAINTEXT`]) to each viewer
    /// at the stream's current position and puts it.
    pub async fn publish_snapshot(&self, viewers: &[Viewer], stream: &str, state: &[u8]) -> Published {
        if !self.config.enabled {
            return Published::default();
        }
        let position = self.position(stream);
        self.each(viewers, stream, position, state, false).await
    }

    /// Seals `screen` (what the phone's first screen of `stream` shows, at most
    /// [`FIRST_SCREEN_BYTES`]) at the stream's current position on [`first_screen_stream`] and puts
    /// it, so a cold open fills the screen in one round trip before the whole snapshot arrives.
    /// A `screen` over the bound is not put: the phone opens the whole snapshot as before.
    pub async fn publish_first_screen(&self, viewers: &[Viewer], stream: &str, screen: &[u8]) -> Published {
        if !self.config.enabled {
            return Published::default();
        }
        if screen.len() > FIRST_SCREEN_BYTES {
            return Published {
                failed: viewers.len(),
                first_error: Some(format!(
                    "first screen is {} bytes, over {FIRST_SCREEN_BYTES}",
                    screen.len()
                )),
                ..Published::default()
            };
        }
        let position = self.position(stream);
        self.each(viewers, &first_screen_stream(stream), position, screen, false).await
    }

    /// Seals `change` as the next delta of `stream` to each viewer and appends it.
    pub async fn publish_delta(&self, viewers: &[Viewer], stream: &str, change: &[u8]) -> Published {
        if !self.config.enabled {
            return Published::default();
        }
        let position = {
            let mut seqs = self.seqs.lock().unwrap_or_else(PoisonError::into_inner);
            let seq = seqs.entry(stream.to_owned()).or_insert(0);
            *seq += 1;
            Position { epoch: self.epoch, seq: *seq }
        };
        self.each(viewers, stream, position, change, true).await
    }

    async fn each(
        &self,
        viewers: &[Viewer],
        stream: &str,
        position: Position,
        plaintext: &[u8],
        delta: bool,
    ) -> Published {
        let mut published = Published { position: Some(position), ..Published::default() };
        let sealed_on = if delta { delta_stream(stream) } else { stream.to_owned() };
        for viewer in viewers {
            let envelope = match seal(&self.key, &viewer.key, &sealed_on, position, plaintext) {
                Ok(envelope) => envelope,
                Err(error) => {
                    published.failed += 1;
                    published.first_error.get_or_insert_with(|| error.to_string());
                    continue;
                }
            };
            published.bytes += envelope.len();
            let sent = if delta {
                self.cache.append_delta(&viewer.device, stream, envelope).await
            } else {
                self.cache.put_snapshot(&viewer.device, stream, envelope).await
            };
            match sent {
                Ok(()) => published.sent += 1,
                Err(error) => {
                    published.failed += 1;
                    published.first_error.get_or_insert_with(|| describe(&error));
                }
            }
        }
        published
    }
}

fn describe(error: &RelayCacheError) -> String {
    error.to_string()
}

/// Batches a stream's changes into one delta per `window` (or sooner when the batch nears
/// [`MAX_PLAINTEXT`]), so a busy stream stays within the relay's delta bound. Each change is framed
/// as a 4-byte big-endian length and its bytes; [`Coalescer::split`] undoes it.
#[derive(Debug)]
pub struct Coalescer {
    window: Duration,
    started: Option<Instant>,
    pending: Vec<u8>,
}

impl Coalescer {
    pub fn new(window: Duration) -> Self {
        Self { window, started: None, pending: Vec::new() }
    }

    /// Adds `change`; returns a batch to publish when the window has passed or the next change
    /// would not fit. A change over the bound on its own is returned by itself (the seal refuses
    /// it, and the phone gets it from the Mac).
    pub fn push(&mut self, change: &[u8], now: Instant) -> Option<Vec<u8>> {
        let framed = 4 + change.len();
        let mut out = None;
        if !self.pending.is_empty() && self.pending.len() + framed > MAX_PLAINTEXT {
            out = self.take();
        }
        self.started.get_or_insert(now);
        self.pending.extend_from_slice(&(change.len() as u32).to_be_bytes());
        self.pending.extend_from_slice(change);
        if out.is_none() && self.started.is_some_and(|t| now.duration_since(t) >= self.window) {
            out = self.take();
        }
        out
    }

    /// The batch so far, if any (a flush before sleep).
    pub fn take(&mut self) -> Option<Vec<u8>> {
        self.started = None;
        (!self.pending.is_empty()).then(|| std::mem::take(&mut self.pending))
    }

    /// The changes in one batch, in order; `None` for a batch that is not framed.
    pub fn split(batch: &[u8]) -> Option<Vec<&[u8]>> {
        let mut out = Vec::new();
        let mut rest = batch;
        while !rest.is_empty() {
            let len = u32::from_be_bytes(rest.get(..4)?.try_into().ok()?) as usize;
            out.push(rest.get(4..4 + len)?);
            rest = &rest[4 + len..];
        }
        Some(out)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_coalescer_batches_by_window_and_size() {
        let start = Instant::now();
        let mut c = Coalescer::new(Duration::from_millis(250));
        assert!(c.push(b"a", start).is_none());
        assert!(c.push(b"bb", start + Duration::from_millis(100)).is_none());
        let batch = c.push(b"ccc", start + Duration::from_millis(260)).unwrap();
        assert_eq!(Coalescer::split(&batch).unwrap(), [&b"a"[..], b"bb", b"ccc"]);
        assert!(c.take().is_none());
        let big = vec![7u8; MAX_PLAINTEXT / 2];
        assert!(c.push(&big, start).is_none());
        let first = c.push(&big, start).unwrap();
        assert_eq!(Coalescer::split(&first).unwrap().len(), 1, "the second would not fit");
        assert_eq!(Coalescer::split(&c.take().unwrap()).unwrap().len(), 1);
    }

    #[test]
    fn a_batch_that_is_not_framed_does_not_split() {
        assert!(Coalescer::split(&[0, 0, 0, 9, 1]).is_none());
    }
}
