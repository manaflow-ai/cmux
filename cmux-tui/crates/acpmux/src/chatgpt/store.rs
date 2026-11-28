//! ChatGPT subscription records are owner-only JSON files. New macOS grants
//! live in the login Keychain, with a metadata index in place of the record.

use std::path::Path;

use serde::{Deserialize, Serialize};

use super::CODEX_CLIENT_ID;
use crate::subscription_store::{Error, Grants, Store};

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
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub workspace: Option<String>,
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
        self.workspace = self.workspace();
        self.access_token.clear();
        self.refresh_token.clear();
        self.id_token.clear();
        self.expires_at = 0;
    }

    pub(super) fn workspace(&self) -> Option<String> {
        crate::agent_credentials::token_account(&self.access_token)
            .or_else(|| crate::agent_credentials::token_account(&self.id_token))
            .or_else(|| self.workspace.clone())
    }
}

/// Writes `bytes` to `path` owner-only and atomically.
pub(crate) fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    let parent = path.parent().ok_or_else(|| std::io::Error::other("no parent folder"))?;
    crate::home_fs::private_dir(parent)?;
    // 0600 from creation (an owner-only access list on Windows), synced, under one copy name per
    // process (`home_fs::write_durable`), not a random one per write.
    crate::home_fs::write_durable(path, bytes)
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

pub(super) fn disconnect_grants(home: &Path, id: &str) -> Result<Grants<Record>, Error> {
    store(home).grants(id)
}

pub(super) fn delete_disconnected_grants(
    home: &Path,
    id: &str,
    grants: &Grants<Record>,
) -> Result<(), Error> {
    store(home).delete_grants(id, grants)
}

#[derive(Deserialize)]
pub(crate) struct Metadata {
    pub client_id: String,
    pub sub: String,
    pub email: Option<String>,
    pub plan: Option<String>,
    pub workspace: Option<String>,
    signed_in: bool,
}

impl Metadata {
    pub(crate) fn signed_in(&self) -> bool {
        self.client_id == CODEX_CLIENT_ID && self.signed_in
    }
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
