//! What Sign in with ChatGPT keeps on disk, under `<acpmux home>/chatgpt/` (owner-only files,
//! each written atomically: a temporary file in the same folder, then a rename):
//!
//! - `<route id>.json`: one signed-in ChatGPT account, keyed by (client id, `sub`): its tokens,
//!   their expiry and granted scopes. A record of another client (the token-sharing protocol's
//!   `oaiapp_...` registrations before cmux#45774) reads as signed out: sign in again. A token never leaves these files except through
//!   `_acpmux/connections/chatgpt.token`.

use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};

use super::CODEX_CLIENT_ID;

pub(crate) fn dir(home: &Path) -> PathBuf {
    home.join("chatgpt")
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

fn read_json<T: for<'de> Deserialize<'de>>(path: &Path) -> std::io::Result<Option<T>> {
    match std::fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(|e| std::io::Error::other(format!("{}: {e}", path.display()))),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}

fn record_path(home: &Path, id: &str) -> PathBuf {
    dir(home).join(format!("{id}.json"))
}

pub(crate) fn read(home: &Path, id: &str) -> std::io::Result<Option<Record>> {
    if !crate::routes::is_route_id(id) || id == "host" {
        return Ok(None);
    }
    read_json(&record_path(home, id))
}

pub(crate) fn write(home: &Path, id: &str, record: &Record) -> std::io::Result<()> {
    if !crate::routes::is_route_id(id) || id == "host" {
        return Err(std::io::Error::other("not a route id"));
    }
    write_atomic(&record_path(home, id), &serde_json::to_vec_pretty(record).unwrap_or_default())
}

pub(crate) fn delete(home: &Path, id: &str) -> std::io::Result<()> {
    match crate::home_fs::remove_file(record_path(home, id)) {
        Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// Every record by its route id, sorted.
pub(crate) fn all(home: &Path) -> Vec<(String, Record)> {
    let Ok(entries) = std::fs::read_dir(dir(home)) else { return Vec::new() };
    let mut out: Vec<(String, Record)> = entries
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.extension().is_some_and(|x| x == "json"))
        .filter_map(|p| {
            let id = p.file_stem()?.to_str()?.to_owned();
            if id == "host" || !crate::routes::is_route_id(&id) {
                return None;
            }
            read_json::<Record>(&p).ok().flatten().map(|r| (id, r))
        })
        .collect();
    out.sort_by(|a, b| a.0.cmp(&b.0));
    out
}
