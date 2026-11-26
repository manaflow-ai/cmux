//! The `bundle` service's wire pieces, shared by the Mac (hostd) and the phone (the FFI): a file moved
//! as sealed, content-defined chunks ([`cmux_bundle`], RFD 0142 R7), so a re-sent or re-opened file
//! costs one round trip and its manifest, not its bytes (PROTOCOL.md "bundle").
//!
//! A channel is a byte stream (a write is split into frames of at most 256 KiB), so every message of
//! the service is `[u32 BE length][bytes]`. A message that starts with `{` is JSON (the key, a reply,
//! a refusal); any other is a [`cmux_bundle::sync`] message (offer, want, chunks). An empty message
//! ends a `get`'s chunks.

use std::path::Path;

use bytes::{Buf, Bytes, BytesMut};

use crate::link::ChannelReceiver;
use crate::{ChannelEvent, CloseInfo};

pub use cmux_bundle;

/// The largest message either end takes: a full manifest (65 536 entries of 36 bytes) fits, and a
/// chunks message ([`cmux_bundle::sync::BATCH_BYTES`]) with room to spare. A longer length prefix is
/// refused before anything is read into memory.
pub const MAX_MESSAGE: usize = 4 << 20;

/// The largest file the service moves (it is assembled in memory on each end); a larger one goes the
/// old way (`upload`, `file`).
pub const MAX_BUNDLE_BYTES: u64 = 256 << 20;

/// The Mac's chunk store's cap; past it the oldest chunks go ([`evict`]).
pub const HOST_STORE_CAP: u64 = 2 << 30;

/// The phone's chunk store's cap per Mac (the app's Caches folder, which iOS may also purge).
pub const PHONE_STORE_CAP: u64 = 512 << 20;

/// One message with its length prefix.
pub fn frame(msg: &[u8]) -> Bytes {
    let mut out = Vec::with_capacity(4 + msg.len());
    out.extend_from_slice(&(msg.len() as u32).to_be_bytes());
    out.extend_from_slice(msg);
    Bytes::from(out)
}

/// The key message: `{"v":1,"key":"<64 hex>"}`, the secret the pair's bundle keys derive from
/// ([`cmux_bundle::PairKey::derive`]).
pub fn key_message(secret: &[u8; 32]) -> Vec<u8> {
    serde_json::json!({"v": 1, "key": cmux_bundle::hex(secret)}).to_string().into_bytes()
}

/// The secret a key message carries; `None` for anything else.
pub fn parse_key_message(msg: &[u8]) -> Option<[u8; 32]> {
    let value: serde_json::Value = serde_json::from_slice(msg).ok()?;
    if value.get("v")?.as_u64()? != 1 {
        return None;
    }
    cmux_bundle::unhex(value.get("key")?.as_str()?).ok()
}

/// What [`MessageReader::next`] read.
#[derive(Debug)]
pub enum Read {
    /// One whole message.
    Message(Vec<u8>),
    /// The channel closed (with a whole number of messages read).
    Closed(CloseInfo),
}

/// Why [`MessageReader::next`] stopped.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum ReadError {
    #[error("a bundle message of {0} bytes is over the limit")]
    TooLarge(usize),
    #[error("the channel closed inside a bundle message")]
    Truncated,
}

/// Reads length-prefixed messages off a channel.
pub struct MessageReader {
    receiver: ChannelReceiver,
    buffer: BytesMut,
    /// Payload bytes read off the channel so far (length prefixes included).
    pub received: u64,
}

impl MessageReader {
    pub fn new(receiver: ChannelReceiver) -> Self {
        Self { receiver, buffer: BytesMut::new(), received: 0 }
    }

    /// The next message, or the channel's close.
    pub async fn next(&mut self) -> Result<Read, ReadError> {
        loop {
            if self.buffer.len() >= 4 {
                let len = u32::from_be_bytes([self.buffer[0], self.buffer[1], self.buffer[2], self.buffer[3]])
                    as usize;
                if len > MAX_MESSAGE {
                    return Err(ReadError::TooLarge(len));
                }
                if self.buffer.len() >= 4 + len {
                    self.buffer.advance(4);
                    return Ok(Read::Message(self.buffer.split_to(len).to_vec()));
                }
            }
            match self.receiver.recv().await {
                Some(ChannelEvent::Data(bytes)) => {
                    self.received += bytes.len() as u64;
                    self.buffer.extend_from_slice(&bytes);
                }
                Some(ChannelEvent::Closed(info)) if self.buffer.is_empty() => return Ok(Read::Closed(info)),
                None if self.buffer.is_empty() => {
                    return Ok(Read::Closed(CloseInfo { code: "closed".into(), reason: String::new() }));
                }
                _ => return Err(ReadError::Truncated),
            }
        }
    }
}

/// Removes the oldest (by modification time) chunk files of a [`cmux_bundle::store::DirStore`] at
/// `root` until the rest hold at most `cap` bytes. Errors are ignored: a chunk that could not be
/// removed is tried again next time, and a missing chunk is only asked for again.
pub fn evict(root: &Path, cap: u64) {
    let mut files = Vec::new();
    let mut total = 0u64;
    let Ok(shards) = std::fs::read_dir(root) else { return };
    for shard in shards.flatten() {
        let Ok(entries) = std::fs::read_dir(shard.path()) else { continue };
        for entry in entries.flatten() {
            let Ok(meta) = entry.metadata() else { continue };
            if !meta.is_file() {
                continue;
            }
            total += meta.len();
            let mtime = meta.modified().unwrap_or(std::time::SystemTime::UNIX_EPOCH);
            files.push((mtime, meta.len(), entry.path()));
        }
    }
    if total <= cap {
        return;
    }
    files.sort_by_key(|(mtime, _, _)| *mtime);
    for (_, len, path) in files {
        if total <= cap {
            break;
        }
        if std::fs::remove_file(&path).is_ok() {
            total -= len;
        }
    }
}

/// Marks the chunks a bundle used as recently used, so [`evict`] keeps them over idle ones.
pub fn touch(root: &Path, ids: impl IntoIterator<Item = cmux_bundle::ChunkId>) {
    let now = std::time::SystemTime::now();
    for id in ids {
        let name = cmux_bundle::hex(&id);
        let path = root.join(&name[..2]).join(&name);
        if let Ok(file) = std::fs::File::options().write(true).open(&path) {
            let _ = file.set_modified(now);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn key_messages_round_trip() {
        let secret = [7u8; 32];
        assert_eq!(parse_key_message(&key_message(&secret)), Some(secret));
        assert_eq!(parse_key_message(b"{\"v\":2,\"key\":\"00\"}"), None);
        assert_eq!(parse_key_message(b"{\"path\":\"/x\"}"), None);
    }

    #[test]
    fn eviction_drops_the_oldest_until_under_the_cap() {
        let dir = tempfile_dir();
        let mut store = cmux_bundle::store::DirStore::new(&dir);
        use cmux_bundle::store::Store;
        let ids: Vec<[u8; 32]> = (0..4u8).map(|i| [i; 32]).collect();
        for (i, id) in ids.iter().enumerate() {
            store.put(id, &[0u8; 1000]).unwrap();
            let name = cmux_bundle::hex(id);
            let file = std::fs::File::options().write(true).open(dir.join(&name[..2]).join(&name)).unwrap();
            file.set_modified(
                std::time::SystemTime::UNIX_EPOCH + std::time::Duration::from_secs(i as u64 * 10),
            )
            .unwrap();
        }
        evict(&dir, 2500);
        assert!(!store.has(&ids[0]) && !store.has(&ids[1]));
        assert!(store.has(&ids[2]) && store.has(&ids[3]));
        std::fs::remove_dir_all(&dir).ok();
    }

    fn tempfile_dir() -> std::path::PathBuf {
        let dir = std::env::temp_dir().join(format!("cmux-bundle-evict-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }
}
