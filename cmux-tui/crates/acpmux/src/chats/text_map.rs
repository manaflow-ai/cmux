//! The chat text's saved copy, served in place (`text.rs`): a doc read back from it holds a range
//! of a read-only shared mapping of the file, not a heap copy of its text. The mapped pages are
//! the file's clean page cache, so the daemon's own footprint does not hold them, and the kernel
//! drops and reads them back as it needs (goal ram-baseline: about 15 MB on the bench's empty app).
//!
//! The file: `MAGIC` (8 bytes), the metadata's length (`u64` little-endian), the metadata as JSON
//! (every doc's key, stamp, messages and the range of its text), then every doc's text, one after
//! the other. A text is the doc's whole flattened text (valid UTF-8, checked when read back).
//!
//! The file is only ever replaced whole (a synced temporary copy renamed over it,
//! `home_fs::write_index_file`), never written in place or shortened, so a mapping of an older copy
//! keeps reading that copy's bytes until the last doc holding it is let go of.

use std::fs::File;
use std::io;
use std::sync::Arc;

use serde::{Deserialize, Serialize};

/// The first bytes of a saved copy: its kind and layout version.
pub(super) const MAGIC: &[u8; 8] = b"cmxtxt\x00\x02";
const HEADER: usize = 16;

/// A doc's text: its own, or (`mapped`) a range of a mapped saved copy, `own` then empty.
#[derive(Clone, Default)]
pub(super) struct Text {
    own: String,
    mapped: Option<Range>,
}

#[derive(Clone)]
struct Range {
    map: Arc<Map>,
    start: usize,
    len: usize,
}

impl Range {
    fn as_str(&self) -> &str {
        let bytes = self.map.bytes().get(self.start..self.start + self.len).unwrap_or_default();
        // SAFETY: a mapped range was checked to be inside the map and valid UTF-8 when it was
        // made (`Map::text`), and the map's bytes never change (`Map`).
        unsafe { std::str::from_utf8_unchecked(bytes) }
    }
}

impl Text {
    pub(super) fn as_str(&self) -> &str {
        self.mapped.as_ref().map_or(&self.own, Range::as_str)
    }

    /// The text to edit: a mapped text is copied into one of its own first.
    pub(super) fn to_mut(&mut self) -> &mut String {
        if let Some(range) = self.mapped.take() {
            self.own = range.as_str().to_owned();
        }
        &mut self.own
    }

    pub(super) fn is_mapped(&self) -> bool {
        self.mapped.is_some()
    }
}

impl std::ops::Deref for Text {
    type Target = str;
    fn deref(&self) -> &str {
        self.as_str()
    }
}

impl From<String> for Text {
    fn from(own: String) -> Self {
        Text { own, mapped: None }
    }
}

impl PartialEq for Text {
    fn eq(&self, other: &Self) -> bool {
        self.as_str() == other.as_str()
    }
}

impl Eq for Text {}

impl std::fmt::Debug for Text {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        std::fmt::Debug::fmt(self.as_str(), f)
    }
}

impl Serialize for Text {
    fn serialize<S: serde::Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        serializer.serialize_str(self.as_str())
    }
}

impl<'de> Deserialize<'de> for Text {
    fn deserialize<D: serde::Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        String::deserialize(deserializer).map(Text::from)
    }
}

/// A saved copy, mapped read-only (off Unix: read whole, the same lookups from the heap).
pub(super) struct Map {
    #[cfg(unix)]
    start: *mut libc::c_void,
    #[cfg(unix)]
    len: usize,
    #[cfg(not(unix))]
    bytes: Vec<u8>,
}

// SAFETY: the mapping is read-only memory this value owns; nothing about it is tied to a thread,
// and no one writes it, so shared reads from any thread are sound.
#[cfg(unix)]
unsafe impl Send for Map {}
#[cfg(unix)]
unsafe impl Sync for Map {}

impl Map {
    /// Maps all of `file` (`len` bytes, as its metadata read just before).
    #[cfg(unix)]
    pub(super) fn of(file: &File, len: u64) -> io::Result<Map> {
        use std::os::fd::AsRawFd;
        let len = usize::try_from(len).map_err(|_| io::Error::other("chat text: too large"))?;
        if len == 0 {
            return Ok(Map { start: std::ptr::null_mut(), len: 0 });
        }
        // SAFETY: a new read-only mapping at an address the kernel picks, of a descriptor `file`
        // owns for the whole call; no existing memory is touched.
        let start = unsafe {
            libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ,
                libc::MAP_SHARED,
                file.as_raw_fd(),
                0,
            )
        };
        if start == libc::MAP_FAILED {
            return Err(io::Error::last_os_error());
        }
        Ok(Map { start, len })
    }

    #[cfg(not(unix))]
    pub(super) fn of(file: &File, len: u64) -> io::Result<Map> {
        use std::io::Read as _;
        let mut bytes = Vec::with_capacity(usize::try_from(len).unwrap_or_default());
        (&*file).read_to_end(&mut bytes)?;
        Ok(Map { bytes })
    }

    pub(super) fn bytes(&self) -> &[u8] {
        #[cfg(unix)]
        {
            if self.len == 0 {
                return &[];
            }
            // SAFETY: `start..start+len` is the mapping `of` made, unmapped only on drop. The
            // file is only ever replaced by a rename, never written in place or shortened (the
            // module's doc), so every page stays backed and its bytes do not change.
            unsafe { std::slice::from_raw_parts(self.start.cast::<u8>(), self.len) }
        }
        #[cfg(not(unix))]
        {
            &self.bytes
        }
    }

    /// The text at `at..at+len` of the texts (which start after the metadata), when it is inside
    /// the map and valid UTF-8.
    pub(super) fn text(self: &Arc<Self>, texts: usize, at: u64, len: u32) -> Option<Text> {
        let start = texts.checked_add(usize::try_from(at).ok()?)?;
        let len = len as usize;
        let bytes = self.bytes().get(start..start.checked_add(len)?)?;
        std::str::from_utf8(bytes).ok()?;
        Some(Text { own: String::new(), mapped: Some(Range { map: self.clone(), start, len }) })
    }
}

#[cfg(unix)]
impl Drop for Map {
    fn drop(&mut self) {
        if self.len != 0 {
            // SAFETY: `start..start+len` is the mapping `of` made, unmapped only here.
            unsafe {
                libc::munmap(self.start, self.len);
            }
        }
    }
}

/// The bytes of a saved copy: `MAGIC`, the length of `meta`'s JSON, it, then `texts` in order.
pub(super) fn encode<'a>(
    meta: &impl Serialize,
    texts: impl Iterator<Item = &'a str>,
    text_bytes: usize,
) -> serde_json::Result<Vec<u8>> {
    let meta = serde_json::to_vec(meta)?;
    let mut bytes = Vec::with_capacity(HEADER + meta.len() + text_bytes);
    bytes.extend_from_slice(MAGIC);
    bytes.extend_from_slice(&(meta.len() as u64).to_le_bytes());
    bytes.extend_from_slice(&meta);
    for text in texts {
        bytes.extend_from_slice(text.as_bytes());
    }
    Ok(bytes)
}

/// Maps the saved copy `file` (at most `most` bytes), and reads its metadata: the map, the
/// metadata, and where its texts start. None: too large, or not a copy of this layout.
pub(super) fn open<M: for<'de> Deserialize<'de>>(
    file: &File,
    most: u64,
) -> Option<(Arc<Map>, M, usize)> {
    let len = file.metadata().ok()?.len();
    if len > most || len < HEADER as u64 {
        return None;
    }
    let map = Arc::new(Map::of(file, len).ok()?);
    let bytes = map.bytes();
    if bytes.get(..MAGIC.len())? != MAGIC {
        return None;
    }
    let meta_len = u64::from_le_bytes(bytes.get(MAGIC.len()..HEADER)?.try_into().ok()?);
    let texts = HEADER.checked_add(usize::try_from(meta_len).ok()?)?;
    let meta = serde_json::from_slice(bytes.get(HEADER..texts)?).ok()?;
    Some((map, meta, texts))
}
