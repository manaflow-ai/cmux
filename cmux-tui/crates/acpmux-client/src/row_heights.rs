//! Bounded, width-specific row height measurements for the native chat host.
//!
//! The page is responsible for measuring CSS pixels. This cache keeps those
//! measurements next to the v2 client so a later page can seed its first
//! layout without measuring every row before paint.

use serde::{Deserialize, Serialize};
use std::collections::{HashMap, VecDeque};

/// Maximum number of remembered measurements per client handle.
pub const MAX_ENTRIES: usize = 8_192;
/// Maximum number of keys accepted in one read or write batch.
pub const MAX_BATCH: usize = 256;
const MAX_SID_BYTES: usize = 128;
const MAX_SIGNATURE_BYTES: usize = 512;
const MAX_HEIGHT: f32 = 1_000_000.0;

#[derive(Clone, Debug, Deserialize, Eq, Hash, PartialEq, Serialize)]
pub struct RowHeightKey {
    /// The edition supplied by the chat window that owns this row.
    pub edition: u32,
    pub id: u64,
    pub rev: u64,
    pub signature: String,
    /// CSS width in 1/64-pixel units. This preserves fractional layout widths
    /// without putting floating point values in a cache key.
    pub width: u32,
}

#[derive(Clone, Debug, Deserialize)]
pub struct RowHeightEntry {
    #[serde(flatten)]
    pub key: RowHeightKey,
    pub height: f32,
}

#[derive(Clone, Debug, Deserialize)]
pub struct ReadRequest {
    /// The chat sid, verified by the host before it reaches this cache.
    pub sid: String,
    pub rows: Vec<RowHeightKey>,
}

#[derive(Clone, Debug, Deserialize)]
pub struct WriteRequest {
    /// The chat sid, verified by the host before it reaches this cache.
    pub sid: String,
    pub entries: Vec<RowHeightEntry>,
}

#[derive(Clone, Debug, Serialize)]
pub struct RowHeightResult {
    #[serde(flatten)]
    pub key: RowHeightKey,
    pub height: Option<f32>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ReadResponse {
    pub rows: Vec<RowHeightResult>,
}

#[derive(Clone, Debug, Serialize)]
pub struct WriteResponse {
    pub stored: usize,
}

#[derive(Clone, Debug, Eq, Hash, PartialEq)]
struct CacheKey {
    sid: String,
    key: RowHeightKey,
}

/// A small FIFO cache. Measurements are cheap to replace and bounded memory
/// matters more than retaining a strict LRU ordering here.
#[derive(Debug, Default)]
pub struct RowHeightCache {
    entries: HashMap<CacheKey, f32>,
    order: VecDeque<CacheKey>,
}

impl RowHeightCache {
    pub fn read(&self, request: ReadRequest) -> Result<ReadResponse, ()> {
        validate_sid(&request.sid)?;
        if request.rows.len() > MAX_BATCH {
            return Err(());
        }
        for key in &request.rows {
            validate_key(key)?;
        }
        let rows = request
            .rows
            .into_iter()
            .map(|key| RowHeightResult {
                height: self
                    .entries
                    .get(&CacheKey { sid: request.sid.clone(), key: key.clone() })
                    .copied(),
                key,
            })
            .collect();
        Ok(ReadResponse { rows })
    }

    pub fn write(&mut self, request: WriteRequest) -> Result<WriteResponse, ()> {
        validate_sid(&request.sid)?;
        if request.entries.len() > MAX_BATCH {
            return Err(());
        }
        for entry in &request.entries {
            validate_key(&entry.key)?;
            if !entry.height.is_finite() || !(0.0..=MAX_HEIGHT).contains(&entry.height) {
                return Err(());
            }
        }
        let mut stored = 0;
        for entry in request.entries {
            let cache_key = CacheKey { sid: request.sid.clone(), key: entry.key };
            if let Some(height) = self.entries.get_mut(&cache_key) {
                *height = entry.height;
                stored += 1;
                continue;
            }
            self.order.push_back(cache_key.clone());
            self.entries.insert(cache_key, entry.height);
            stored += 1;
            while self.entries.len() > MAX_ENTRIES {
                let Some(oldest) = self.order.pop_front() else { break };
                self.entries.remove(&oldest);
            }
        }
        Ok(WriteResponse { stored })
    }

    #[cfg(test)]
    fn len(&self) -> usize {
        self.entries.len()
    }
}

fn validate_sid(sid: &str) -> Result<(), ()> {
    if sid.is_empty() || sid.len() > MAX_SID_BYTES {
        return Err(());
    }
    Ok(())
}

fn validate_key(key: &RowHeightKey) -> Result<(), ()> {
    if key.signature.len() > MAX_SIGNATURE_BYTES {
        return Err(());
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(id: u64, rev: u64, width: u32) -> RowHeightKey {
        RowHeightKey { edition: 3, id, rev, signature: "open".into(), width }
    }

    #[test]
    fn reads_exact_edition_revision_signature_and_width() {
        let mut cache = RowHeightCache::default();
        cache
            .write(WriteRequest {
                sid: "chat".into(),
                entries: vec![RowHeightEntry { key: key(7, 2, 800), height: 42.5 }],
            })
            .unwrap();
        let response = cache
            .read(ReadRequest {
                sid: "chat".into(),
                rows: vec![
                    key(7, 2, 800),
                    key(7, 1, 800),
                    key(7, 2, 801),
                    RowHeightKey { edition: 4, ..key(7, 2, 800) },
                ],
            })
            .unwrap();
        assert_eq!(response.rows[0].height, Some(42.5));
        assert_eq!(response.rows[1].height, None);
        assert_eq!(response.rows[2].height, None);
        assert_eq!(response.rows[3].height, None);
    }

    #[test]
    fn views_do_not_share_measurements() {
        let mut cache = RowHeightCache::default();
        cache
            .write(WriteRequest {
                sid: "chat".into(),
                entries: vec![RowHeightEntry { key: key(1, 1, 800), height: 10.0 }],
            })
            .unwrap();
        let response =
            cache.read(ReadRequest { sid: "sidebar".into(), rows: vec![key(1, 1, 800)] }).unwrap();
        assert_eq!(response.rows[0].height, None);
    }

    #[test]
    fn replacement_keeps_one_bounded_entry() {
        let mut cache = RowHeightCache::default();
        let key = key(1, 1, 800);
        cache
            .write(WriteRequest {
                sid: "chat".into(),
                entries: vec![RowHeightEntry { key: key.clone(), height: 10.0 }],
            })
            .unwrap();
        cache
            .write(WriteRequest {
                sid: "chat".into(),
                entries: vec![RowHeightEntry { key, height: 11.0 }],
            })
            .unwrap();
        assert_eq!(cache.len(), 1);
    }

    #[test]
    fn replacement_keeps_fifo_order() {
        let mut cache = RowHeightCache::default();
        let entries = (0..MAX_ENTRIES)
            .map(|id| RowHeightEntry { key: key(id as u64, 1, 800), height: id as f32 })
            .collect::<Vec<_>>();
        for chunk in entries.chunks(MAX_BATCH) {
            cache.write(WriteRequest { sid: "chat".into(), entries: chunk.to_vec() }).unwrap();
        }
        cache
            .write(WriteRequest {
                sid: "chat".into(),
                entries: vec![RowHeightEntry { key: key(0, 1, 800), height: 99.0 }],
            })
            .unwrap();
        cache
            .write(WriteRequest {
                sid: "chat".into(),
                entries: vec![RowHeightEntry { key: key(MAX_ENTRIES as u64, 1, 800), height: 1.0 }],
            })
            .unwrap();
        let response = cache
            .read(ReadRequest {
                sid: "chat".into(),
                rows: vec![key(0, 1, 800), key(1, 1, 800), key(MAX_ENTRIES as u64, 1, 800)],
            })
            .unwrap();
        assert_eq!(response.rows[0].height, None);
        assert_eq!(response.rows[1].height, Some(1.0));
        assert_eq!(response.rows[2].height, Some(1.0));
    }

    #[test]
    fn rejects_bad_batches_and_heights() {
        let mut cache = RowHeightCache::default();
        assert!(cache.read(ReadRequest { sid: String::new(), rows: vec![] }).is_err());
        assert!(
            cache
                .write(WriteRequest {
                    sid: "chat".into(),
                    entries: vec![RowHeightEntry { key: key(1, 1, 800), height: f32::NAN }],
                })
                .is_err()
        );
    }
}
