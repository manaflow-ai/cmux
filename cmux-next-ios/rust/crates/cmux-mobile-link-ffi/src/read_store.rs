//! The phone's own read-first store (`cmux_mobile_core::read_store`) for Swift: what a surface
//! last showed, per account, Mac and surface, so a cold launch draws it before the Mac answers
//! (Leo, 2026-11-22: "like im sure theres a hell of s lot more value in being able to read nigh
//! instantly as much as possible"). The Agent Chats list is its first surface.
//!
//! Swift only binds: it names the directory (Application Support, excluded from backups,
//! readable after first unlock), encodes its value and draws what comes back. The key, the
//! bounds, the atomic write and the eviction are the core's.

use std::sync::Arc;

use cmux_mobile_core::read_store as core;

/// One entry's key: the account (or team), the Mac and the surface (`agent_chats`).
#[derive(Debug, Clone, PartialEq, Eq, Hash, uniffi::Record)]
pub struct PhoneReadKey {
    pub scope: String,
    pub device: String,
    pub kind: String,
}

impl From<PhoneReadKey> for core::ReadKey {
    fn from(key: PhoneReadKey) -> Self {
        core::ReadKey::new(key.scope, key.device, key.kind)
    }
}

/// Why the store refused.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error, uniffi::Error)]
pub enum PhoneReadStoreError {
    #[error("value of {size} bytes is over the {limit} byte limit")]
    TooLarge { size: u64, limit: u64 },
    #[error("io: {message}")]
    Io { message: String },
}

impl From<core::ReadStoreError> for PhoneReadStoreError {
    fn from(error: core::ReadStoreError) -> Self {
        match error {
            core::ReadStoreError::TooLarge { size, limit } => {
                Self::TooLarge { size: size as u64, limit: limit as u64 }
            }
            core::ReadStoreError::Io(error) => error.into(),
        }
    }
}

impl From<std::io::Error> for PhoneReadStoreError {
    fn from(error: std::io::Error) -> Self {
        Self::Io { message: error.to_string() }
    }
}

/// The store on one directory. Safe to call from any thread; calls are plain file I/O, so the
/// app calls writes off the main thread.
#[derive(Debug, uniffi::Object)]
pub struct PhoneReadStore {
    inner: core::ReadStore,
}

#[uniffi::export]
impl PhoneReadStore {
    /// The store on `directory` (created if missing), keeping at most `max_entries` entries of
    /// at most `max_value_bytes` each.
    #[uniffi::constructor]
    pub fn open(
        directory: String,
        max_entries: u32,
        max_value_bytes: u32,
    ) -> Result<Arc<Self>, PhoneReadStoreError> {
        let limits = core::ReadStoreLimits {
            max_entries: max_entries.max(1) as usize,
            max_value_bytes: max_value_bytes as usize,
        };
        Ok(Arc::new(Self { inner: core::ReadStore::open(directory, limits)? }))
    }

    /// The value kept for `key`; nil when nothing (or nothing readable) is kept.
    pub fn get(&self, key: PhoneReadKey) -> Option<Vec<u8>> {
        self.inner.get(&key.into())
    }

    /// Keeps `value` for `key`, atomically; past the entry limit the oldest writes leave.
    pub fn put(&self, key: PhoneReadKey, value: Vec<u8>) -> Result<(), PhoneReadStoreError> {
        Ok(self.inner.put(&key.into(), &value)?)
    }

    /// Forgets `key`.
    pub fn remove(&self, key: PhoneReadKey) -> Result<(), PhoneReadStoreError> {
        Ok(self.inner.remove(&key.into())?)
    }

    /// Sign-out: every entry goes.
    pub fn remove_all(&self) -> Result<(), PhoneReadStoreError> {
        Ok(self.inner.remove_all()?)
    }

    /// Entries kept now.
    pub fn count(&self) -> u32 {
        u32::try_from(self.inner.len()).unwrap_or(u32::MAX)
    }
}
