//! Records in the folders view, independent of the writer's table.

use crate::{MAX_FIELD_BYTES, RowKey};
use serde::{Deserialize, Serialize};
use std::io;
use std::sync::Arc;

/// A folder's stable identity. The folder itself is bounded to 1,024 bytes by
/// the index record contract; origins use the ordinary 256-byte row-key bound.
#[derive(Clone, Debug, Eq, Hash, Ord, PartialEq, PartialOrd, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderKey {
    pub origin: Arc<str>,
    pub folder: Arc<str>,
}

impl FolderKey {
    pub fn new(origin: impl Into<Arc<str>>, folder: impl Into<Arc<str>>) -> Self {
        Self { origin: origin.into(), folder: folder.into() }
    }

    pub fn validate(&self) -> io::Result<()> {
        if self.origin.len() > MAX_FIELD_BYTES {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "folder origin exceeds 256 bytes",
            ));
        }
        if self.folder.len() > MAX_FOLDER_BYTES {
            return Err(io::Error::new(io::ErrorKind::InvalidInput, "folder exceeds 1024 bytes"));
        }
        Ok(())
    }
}

pub const MAX_FOLDER_BYTES: usize = 1024;

/// One row in the folders view.
#[derive(Clone, Debug, Eq, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FolderRow {
    pub origin: Arc<str>,
    pub folder: Arc<str>,
    pub newest: RowKey,
    pub at: u64,
    pub count: u32,
}

impl FolderRow {
    pub fn key(&self) -> FolderKey {
        FolderKey::new(self.origin.clone(), self.folder.clone())
    }

    pub fn encoded_len(&self) -> usize {
        serde_json::to_vec(self).map_or(0, |bytes| bytes.len())
    }
}
