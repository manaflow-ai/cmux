//! ChatGPT subscription records live in the login Keychain on macOS. The
//! owner-only files in `<acpmux home>/chatgpt/` carry the account metadata and
//! Keychain references. Other platforms retain their owner-only JSON records.

use std::path::Path;

use serde::{Deserialize, Serialize};

use super::CODEX_CLIENT_ID;
use crate::subscription_store::{Error, Store};

#[cfg(test)]
pub(crate) fn dir(home: &Path) -> std::path::PathBuf {
    store(home).directory()
}

fn store(home: &Path) -> Store<'_> {
    Store::new(home, "chatgpt")
}

/// One signed-in account. Not `Debug`: its tokens must never reach a log line.
#[derive(Clone, Default, PartialEq, Serialize, Deserialize)]
pub(crate) struct Record {
    pub client_id: String,
    pub sub: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub email: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub plan: Option<String>,
    #[serde(default)]
    pub access_token: String,
    #[serde(default)]
    pub refresh_token: String,
    #[serde(default)]
    pub id_token: String,
    /// Unix seconds when `access_token` expires.
    #[serde(default)]
    pub expires_at: i64,
    #[serde(default)]
    pub scopes: Vec<String>,
}

impl std::fmt::Debug for Record {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Record")
            .field("client_id", &self.client_id)
            .field("sub", &self.sub)
            .field("signed_in", &self.signed_in())
            .field("expires_at", &self.expires_at)
            .field("scopes", &self.scopes)
            .finish_non_exhaustive()
    }
}

impl Record {
    /// Signed in with Codex's client and still holding a refresh token.
    pub fn signed_in(&self) -> bool {
        self.client_id == CODEX_CLIENT_ID && !self.refresh_token.is_empty()
    }

    /// Signed out in place: the tokens go, the identity stays (a later sign-in of the same
    /// account finds this record and its route).
    pub fn clear_tokens(&mut self) {
        self.access_token.clear();
        self.refresh_token.clear();
        self.id_token.clear();
        self.expires_at = 0;
    }
}

/// Writes `bytes` to `path` owner-only and atomically.
pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write as _;
    let parent = path.parent().ok_or_else(|| std::io::Error::other("no parent folder"))?;
    crate::home_fs::private_dir(parent)?;
    let mut tmp = tempfile::NamedTempFile::new_in(parent)?;
    // NamedTempFile is created 0600 on Unix; the explicit call also covers Windows' access list.
    crate::router_socket::owner_only(tmp.path());
    tmp.write_all(bytes)?;
    tmp.as_file().sync_all()?;
    tmp.persist(path).map_err(|e| e.error)?;
    Ok(())
}

pub(crate) fn read(home: &Path, id: &str) -> Result<Option<Record>, Error> {
    store(home).read(id)
}

pub(crate) fn write(home: &Path, id: &str, record: &Record) -> Result<(), Error> {
    store(home).write(id, record)
}

pub(crate) fn delete(home: &Path, id: &str) -> Result<(), Error> {
    store(home).delete(id)
}

#[derive(Deserialize)]
pub(crate) struct Metadata {
    pub client_id: String,
    pub sub: String,
    pub email: Option<String>,
    pub plan: Option<String>,
    signed_in: bool,
}

impl Metadata {
    pub(crate) fn signed_in(&self) -> bool {
        self.client_id == CODEX_CLIENT_ID && self.signed_in
    }
}

pub(crate) fn migrate_all(home: &Path) {
    store(home).migrate_all::<Record>();
}

pub(crate) fn available(home: &Path, id: &str) -> Result<bool, Error> {
    store(home).available::<Record>(id)
}

pub(crate) fn metadata(home: &Path, id: &str) -> Option<Metadata> {
    serde_json::from_value(store(home).metadata(id)?).ok()
}

/// Every account by its route id, sorted. Listing never asks the Keychain for tokens.
pub(crate) fn all(home: &Path) -> Vec<(String, Metadata)> {
    let Ok(entries) = std::fs::read_dir(store(home).directory()) else { return Vec::new() };
    let mut out: Vec<_> = entries
        .filter_map(|entry| {
            let path = entry.ok()?.path();
            let id = path.file_stem()?.to_str()?;
            if path.extension()? != "json" {
                return None;
            }
            metadata(home, id).map(|record| (id.to_owned(), record))
        })
        .collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}
