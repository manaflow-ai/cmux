//! Optional cmux-platform artifact and agent-memory synchronization.
//!
//! This module is deliberately inert unless `config.artifacts_sync.enabled` is
//! true. It owns no credentials: callers pass the short-lived cmux access
//! token already held by acpmux's mesh client.

use std::{
    collections::BTreeMap,
    env, fs, io,
    path::{Path, PathBuf},
    sync::Arc,
};

use anyhow::{Context, Result, anyhow};
use base64::{Engine as _, engine::general_purpose::STANDARD as BASE64};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tracing::debug;

use crate::artifacts_fs::Dir;
use crate::config::ArtifactsSyncConfig;

const MAX_PUSH_BYTES: usize = 64 * 1024 * 1024;
const BLOB_THRESHOLD: usize = 8 * 1024 * 1024;
/// A server that stops answering fails the pass instead of holding the sync loop forever. The read
/// timeout is per read, so a large blob that keeps moving is never cut off.
const CONNECT_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(15);
const READ_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);

/// What this machine last synced for one path: the digest of its bytes and the commit that wrote
/// them, when known.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
pub struct Synced {
    pub sha256: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub commit: Option<String>,
}

/// Kept on disk (`persist_at`), so a restart neither sends every file again nor takes a file
/// deleted while the daemon was down for one to restore.
#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SyncState {
    #[serde(default)]
    pub head_sha: Option<String>,
    #[serde(default)]
    pub synced: BTreeMap<String, Synced>,
    /// Last content synced for each path, the merge base after a CAS conflict. Memory only: after
    /// a restart a conflict merges against an empty base, which keeps both sides with markers.
    #[serde(skip)]
    pub base: BTreeMap<String, Vec<u8>>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct SyncReport {
    pub uploaded: usize,
    pub deleted: usize,
    pub pulled: usize,
    pub skipped: usize,
    pub conflicts: usize,
}

/// One change of a save, in the platform's `ArtifactChange` shape (camelCase).
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct Change {
    path: String,
    op: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    content_base64: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    blob_sha256: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    content_type: Option<String>,
}

#[derive(Debug, Serialize)]
struct SaveRequest {
    #[serde(rename = "expectedHeadSha")]
    expected_head_sha: Option<String>,
    branch: &'static str,
    message: String,
    trailers: Trailers,
    changes: Vec<Change>,
}

#[derive(Debug, Serialize, Default, Clone)]
pub struct Trailers {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub session: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub machine: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub harness: Option<String>,
}

#[derive(Debug, Deserialize)]
struct RepoResponse {
    #[serde(rename = "headSha")]
    head_sha: Option<String>,
}

#[derive(Debug, Deserialize)]
struct SaveResponse {
    #[serde(rename = "headSha")]
    head_sha: String,
    #[serde(default)]
    commit: Option<SaveCommit>,
}

#[derive(Debug, Deserialize)]
struct SaveCommit {
    sha: String,
}

impl SaveResponse {
    fn commit_sha(&self) -> Option<String> {
        self.commit.as_ref().map(|commit| commit.sha.clone())
    }
}

#[derive(Debug, Deserialize)]
struct ConflictResponse {
    #[serde(rename = "currentHeadSha")]
    current_head_sha: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ListResponse {
    #[serde(rename = "headSha")]
    head_sha: Option<String>,
    items: Vec<ListItem>,
    #[serde(default)]
    cursor: Option<String>,
}

#[derive(Debug, Deserialize)]
struct ListItem {
    path: String,
    /// Set on a saved artifact's folder (`artifacts/<id>`), which lists as one item, not a file.
    #[serde(default)]
    id: Option<String>,
    /// The commit that last wrote the path.
    #[serde(default)]
    commit: Option<String>,
}

/// A listing reads at most this many pages of `LIST_PAGE` items per pass.
const LIST_PAGE: usize = 100;
const LIST_PAGES: usize = 1_000;

#[derive(Debug, Deserialize)]
struct BlobResponse {
    sha256: String,
    size: usize,
}

#[derive(Debug, Clone)]
pub struct ArtifactsSync {
    config: ArtifactsSyncConfig,
    token: Option<Arc<str>>,
    client: Client,
    state: SyncState,
    roots: Vec<SyncRoot>,
    state_path: Option<PathBuf>,
    /// The state as last written to `state_path`, so an unchanged pass writes nothing.
    saved_state: Vec<u8>,
}

#[derive(Debug, Clone)]
struct SyncRoot {
    local: PathBuf,
    remote_prefix: String,
    /// The folder `local` is under (home). Every folder from below it down to `local` must be a
    /// real one.
    anchor: PathBuf,
}

impl SyncRoot {
    /// The root, opened for one pass. A root reached through a symlink, at itself or any folder
    /// above it below the anchor (`~/.claude/projects/work -> /elsewhere`), is not synced: its
    /// files live somewhere else. Every read and write of the pass goes through the opened folder
    /// (`artifacts_fs.rs`), so a folder swapped for a symlink after this check leads nowhere.
    fn open(&self) -> Option<Dir> {
        let relative = self.local.strip_prefix(&self.anchor).ok()?;
        Dir::open(&self.anchor, relative).ok().flatten()
    }

    #[cfg(test)]
    fn usable(&self) -> bool {
        self.open().is_some()
    }
}

#[path = "artifacts_client.rs"]
mod client;
pub use client::ArtifactsClient;

/// Run the opt-in daemon synchronizer until the daemon shuts down.
///
/// Each pass is bounded by `sync_once`/`pull_once`; the interval and the
/// shutdown notification are both owned by this task, so cancellation drops
/// the timer and no task survives daemon shutdown.
pub async fn run_background(hub: Arc<crate::hub::Hub>) {
    let config = hub.config.read().await.clone();
    if !config.artifacts_sync.enabled {
        return;
    }
    let Some(relay) = config.mesh_relay.as_ref() else {
        tracing::warn!("artifacts sync enabled without meshRelay credentials");
        return;
    };
    let relay = match crate::mesh_http::HttpHub::new(relay) {
        Ok(relay) => relay,
        Err(error) => {
            tracing::warn!("artifacts sync mesh auth unavailable: {error}");
            return;
        }
    };
    // No token is taken here: an access token expires, so each tick asks the mesh for the one it
    // holds (refreshed near expiry), and for a new one after the server refused the last.
    let Some(mut sync) = (match ArtifactsSync::new(config.artifacts_sync.clone(), None) {
        Ok(sync) => sync,
        Err(error) => {
            tracing::warn!("artifacts sync configuration invalid: {error}");
            return;
        }
    }) else {
        return;
    };
    sync.persist_at(crate::config::home().join("artifacts-sync-state.json"));
    let trailers = Trailers { machine: env::var("HOSTNAME").ok(), ..Default::default() };
    let period =
        std::time::Duration::from_millis(config.artifacts_sync.poll_interval_ms.max(1_000));
    let mut interval = tokio::time::interval(period);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let relay = &relay;
    let mut fresh = false;
    loop {
        tokio::select! {
            _ = hub.shutdown.notified() => break,
            _ = interval.tick() => {}
        }
        let token = |fresh| async move {
            relay
                .token(fresh)
                .await
                .map(|token| token.as_str().to_owned())
                .map_err(|error| anyhow!("mesh auth: {error}"))
        };
        // Shutdown also ends a pass in flight: a server that keeps trickling bytes never holds
        // the task past the daemon. A cancelled pass loses nothing; each file write is whole.
        tokio::select! {
            _ = hub.shutdown.notified() => break,
            next = sync_tick(&mut sync, token, fresh, &trailers) => fresh = next,
        }
    }
    tracing::debug!("artifacts sync stopped with daemon shutdown");
}

/// One sync pass with a current token. Returns whether the next tick needs a new token: the
/// server refused this one (401), or none could be had.
async fn sync_tick<F, Fut>(
    sync: &mut ArtifactsSync,
    token: F,
    fresh: bool,
    trailers: &Trailers,
) -> bool
where
    F: FnOnce(bool) -> Fut,
    Fut: std::future::Future<Output = Result<String>>,
{
    match token(fresh).await {
        Ok(token) => sync.set_token(token),
        Err(error) => {
            tracing::warn!("artifacts sync token unavailable: {error:#}");
            return true;
        }
    }
    let mut refused = false;
    if let Err(error) = sync.sync_once(trailers.clone()).await {
        refused |= unauthorized(&error);
        tracing::warn!("artifacts sync upload failed: {error:#}");
    }
    if let Err(error) = sync.pull_once().await {
        refused |= unauthorized(&error);
        tracing::warn!("artifacts sync pull failed: {error:#}");
    }
    if let Err(error) = sync.save_state() {
        tracing::warn!("artifacts sync state not saved: {error:#}");
    }
    refused
}

impl ArtifactsSync {
    /// Construct a sync client. Returns `None` for the safe, disabled default.
    pub fn new(config: ArtifactsSyncConfig, access_token: Option<String>) -> Result<Option<Self>> {
        if !config.enabled {
            return Ok(None);
        }
        let base = config.base_url.trim();
        if base.is_empty() {
            return Err(anyhow!("artifacts sync is enabled without baseUrl"));
        }
        Ok(Some(Self {
            config,
            token: access_token.map(Arc::from),
            client: http_client()?,
            state: SyncState::default(),
            roots: discover_roots(),
            state_path: None,
            saved_state: Vec::new(),
        }))
    }

    /// Keep the synced state in `path` across restarts, starting from what it holds. A state that
    /// can't be read starts over: every file then counts as unsynced, which sends or keeps it and
    /// never replaces it.
    pub fn persist_at(&mut self, path: PathBuf) {
        match fs::read(&path) {
            Ok(bytes) => match serde_json::from_slice::<SyncState>(&bytes) {
                Ok(state) => {
                    self.state = state;
                    self.saved_state = bytes;
                }
                Err(error) => {
                    tracing::warn!("artifacts sync state unreadable, starting over: {error}")
                }
            },
            Err(error) if error.kind() == io::ErrorKind::NotFound => {}
            Err(error) => tracing::warn!("artifacts sync state unreadable, starting over: {error}"),
        }
        self.state_path = Some(path);
    }

    /// Write the state when it changed, whole (a temporary file renamed over it).
    fn save_state(&mut self) -> Result<()> {
        let Some(path) = &self.state_path else { return Ok(()) };
        let bytes = serde_json::to_vec(&self.state)?;
        if bytes == self.saved_state {
            return Ok(());
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let temporary = path.with_extension("json.tmp");
        fs::write(&temporary, &bytes)?;
        fs::rename(&temporary, path)?;
        self.saved_state = bytes;
        Ok(())
    }

    fn mark(&mut self, path: String, bytes: Vec<u8>, commit: Option<String>) {
        self.state.synced.insert(path.clone(), Synced { sha256: sha256(&bytes), commit });
        self.state.base.insert(path, bytes);
    }

    fn forget(&mut self, path: &str) {
        self.state.synced.remove(path);
        self.state.base.remove(path);
    }

    fn synced_digest(&self, path: &str) -> Option<&str> {
        self.state.synced.get(path).map(|synced| synced.sha256.as_str())
    }

    pub fn enabled(&self) -> bool {
        self.config.enabled
    }
    /// Replace the bearer for the next pass; the daemon's loop sets it on every tick.
    pub fn set_token(&mut self, token: String) {
        self.token = Some(Arc::from(token));
    }
    pub fn state(&self) -> &SyncState {
        &self.state
    }
    pub fn state_mut(&mut self) -> &mut SyncState {
        &mut self.state
    }

    /// One bounded pass over local files. Callers may schedule this with their
    /// own cancellation token; this method never starts a polling loop.
    pub async fn sync_once(&mut self, trailers: Trailers) -> Result<SyncReport> {
        if !self.config.enabled {
            return Ok(SyncReport::default());
        }
        if self.token.is_none() {
            return Err(anyhow!("artifacts sync access token unavailable"));
        }
        let mut report = SyncReport::default();
        let mut batch = Vec::new();
        let mut batch_bytes = 0usize;
        let mut deleted = Vec::new();
        // A copy: pushing a full batch mid-walk borrows `self` mutably.
        for root in self.roots.clone() {
            let Some(dir) = root.open() else { continue };
            let files = dir.read_tree()?;
            let mut present = std::collections::BTreeSet::new();
            for (path, bytes) in files {
                let remote =
                    format!("{}{}", root.remote_prefix, path.to_string_lossy().replace('\\', "/"));
                present.insert(remote.clone());
                if should_skip(&remote, &bytes) {
                    report.skipped += 1;
                    debug!(path = %remote, "artifacts sync skipped secret-looking file");
                    continue;
                }
                if self.synced_digest(&remote) == Some(sha256(&bytes).as_str()) {
                    continue; // already synced; a pass sends only what changed
                }
                let estimated = bytes.len().saturating_mul(4).div_ceil(3) + remote.len() + 256;
                if !batch.is_empty() && batch_bytes.saturating_add(estimated) > MAX_PUSH_BYTES {
                    report.uploaded +=
                        self.push_batch(std::mem::take(&mut batch), &trailers).await?;
                    batch_bytes = 0;
                }
                batch_bytes = batch_bytes.saturating_add(estimated);
                batch.push((remote, bytes));
            }
            // A file this machine synced that is gone from its (still present) root was deleted
            // here, and the server deletes it too.
            deleted.extend(
                self.state
                    .synced
                    .keys()
                    .filter(|path| {
                        path.starts_with(&root.remote_prefix) && !present.contains(*path)
                    })
                    .filter(|path| {
                        path.strip_prefix(&root.remote_prefix)
                            .is_some_and(|relative| dir.missing(Path::new(relative)))
                    })
                    .cloned()
                    .collect::<Vec<_>>(),
            );
        }
        if !batch.is_empty() {
            report.uploaded += self.push_batch(batch, &trailers).await?;
        }
        if !deleted.is_empty() {
            report.deleted += self.push_deletes(deleted, &trailers).await?;
        }
        Ok(report)
    }

    /// Delete on the server the files deleted here. A conflict fails the pass; its pull reads
    /// the new head, and a file changed remotely since comes back instead of being deleted.
    async fn push_deletes(&mut self, paths: Vec<String>, trailers: &Trailers) -> Result<usize> {
        let token = self
            .token
            .as_ref()
            .map(|token| token.to_string())
            .ok_or_else(|| anyhow!("artifacts sync access token unavailable"))?;
        let request = SaveRequest {
            expected_head_sha: self.state.head_sha.clone(),
            branch: "main",
            message: "Sync local deletions".into(),
            trailers: trailers.clone(),
            changes: paths
                .iter()
                .map(|path| Change {
                    path: path.clone(),
                    op: "delete",
                    content_base64: None,
                    blob_sha256: None,
                    content_type: None,
                })
                .collect(),
        };
        let response = self
            .client
            .post(self.url("/v1/artifacts/save"))
            .bearer_auth(&token)
            .json(&request)
            .send()
            .await?;
        ensure_success(response.status(), "artifact delete")?;
        let saved: SaveResponse = response.json().await.context("decode delete response")?;
        self.state.head_sha = Some(saved.head_sha);
        for path in &paths {
            self.forget(path);
        }
        Ok(paths.len())
    }

    async fn push_batch(
        &mut self,
        files: Vec<(String, Vec<u8>)>,
        trailers: &Trailers,
    ) -> Result<usize> {
        let token = self
            .token
            .as_ref()
            .map(|token| token.to_string())
            .ok_or_else(|| anyhow!("artifacts sync access token unavailable"))?;
        let changes = self.make_changes(&files, &token).await?;
        let request = SaveRequest {
            expected_head_sha: self.state.head_sha.clone(),
            branch: "main",
            message: "Sync local artifacts and memories".into(),
            trailers: trailers.clone(),
            changes,
        };
        let response = self
            .client
            .post(self.url("/v1/artifacts/save"))
            .bearer_auth(&token)
            .json(&request)
            .send()
            .await?;
        if response.status() != StatusCode::CONFLICT {
            ensure_success(response.status(), "artifact save")?;
            let saved: SaveResponse = response.json().await.context("decode save response")?;
            let commit = saved.commit_sha();
            self.state.head_sha = Some(saved.head_sha);
            for (path, bytes) in files {
                self.mark(path, bytes, commit.clone());
            }
            return Ok(request.changes.len());
        }

        // The server's ref CAS rejected our old head. Read each remote file and resolve it
        // against the last synced base, then retry once at the new head. Nothing counts as
        // synced and no local file changes until that retry is saved: a failed retry leaves
        // every local edit to be sent again by the next pass.
        let conflict: ConflictResponse =
            response.json().await.unwrap_or(ConflictResponse { current_head_sha: None });
        let current_head = conflict.current_head_sha.or_else(|| self.state.head_sha.clone());
        let mut resolved = Vec::new();
        // (remote path, bytes, sent by the retry) that become synced once the retry is saved.
        let mut synced = Vec::new();
        // (remote path, bytes this pass read, bytes to write) for the local copies.
        let mut writes = Vec::new();
        for (path, local) in files {
            // A failed read fails the pass: read as empty, it would merge to an empty file.
            let remote = self.remote_file(&path, &token).await?;
            let base = self.state.base.get(&path).map(Vec::as_slice).unwrap_or(&[]);
            if path.to_ascii_lowercase().ends_with(".md")
                && let Some(remote) = remote.as_deref()
            {
                let merged = merge_markdown(base, &local, remote);
                resolved.push(self.change_for(path.clone(), merged.clone(), &token).await?);
                writes.push((path.clone(), Some(local), merged.clone()));
                synced.push((path, merged, true));
            } else {
                match remote {
                    Some(remote) if remote == local => synced.push((path, local, false)),
                    // Changed on both sides: ours goes beside it as a conflict copy, and the
                    // original takes the remote bytes as its synced version, so the next pass
                    // does not send ours over theirs.
                    Some(remote) => {
                        let sibling = conflict_sibling(&path);
                        resolved
                            .push(self.change_for(sibling.clone(), local.clone(), &token).await?);
                        writes.push((sibling.clone(), None, local.clone()));
                        writes.push((path.clone(), Some(local.clone()), remote.clone()));
                        synced.push((sibling, local, true));
                        synced.push((path, remote, false));
                    }
                    // Gone remotely: ours is the only version.
                    None => {
                        resolved.push(self.change_for(path.clone(), local.clone(), &token).await?);
                        synced.push((path, local, true));
                    }
                }
            }
        }
        let (head, commit) = if resolved.is_empty() {
            (current_head, None)
        } else {
            let retry = SaveRequest {
                expected_head_sha: current_head,
                branch: "main",
                message: "Resolve concurrent artifact sync".into(),
                trailers: trailers.clone(),
                changes: resolved,
            };
            let response = self
                .client
                .post(self.url("/v1/artifacts/save"))
                .bearer_auth(&token)
                .json(&retry)
                .send()
                .await?;
            ensure_success(response.status(), "artifact conflict resolution save")?;
            let saved: SaveResponse =
                response.json().await.context("decode conflict save response")?;
            (Some(saved.head_sha.clone()), saved.commit_sha())
        };
        self.state.head_sha = head;
        let count = synced.len();
        for (path, bytes, sent) in synced {
            // A file the retry did not write keeps its commit unknown; the next pull reads it
            // once and records it.
            self.mark(path, bytes, if sent { commit.clone() } else { None });
        }
        for (path, read, bytes) in writes {
            if let Some((dir, relative)) = self.locate(&path) {
                // A file edited again since this pass read it keeps that edit for the next pass.
                let read = read.as_deref().map(sha256);
                replace_if_unchanged(&dir, &relative, read.as_deref(), &bytes)?;
            }
        }
        Ok(count)
    }

    async fn make_changes(&self, files: &[(String, Vec<u8>)], token: &str) -> Result<Vec<Change>> {
        let mut changes = Vec::with_capacity(files.len());
        for (path, bytes) in files {
            changes.push(self.change_for(path.clone(), bytes.clone(), token).await?);
        }
        Ok(changes)
    }

    async fn change_for(&self, path: String, bytes: Vec<u8>, token: &str) -> Result<Change> {
        let (content_base64, blob_sha256) = if bytes.len() > BLOB_THRESHOLD {
            let response = self
                .client
                .post(self.url("/v1/artifacts/blobs"))
                .bearer_auth(token)
                .body(bytes.clone())
                .send()
                .await?;
            ensure_success(response.status(), "blob upload")?;
            let blob: BlobResponse = response.json().await.context("decode blob response")?;
            if blob.size != bytes.len() {
                return Err(anyhow!("blob response size mismatch"));
            }
            (None, Some(blob.sha256))
        } else {
            (Some(BASE64.encode(&bytes)), None)
        };
        Ok(Change {
            path: path.clone(),
            op: "put",
            content_base64,
            blob_sha256,
            content_type: content_type(&path),
        })
    }

    /// A remote file's bytes, or `None` when the server has no such file.
    async fn remote_file(&self, path: &str, token: &str) -> Result<Option<Vec<u8>>> {
        let response = self
            .client
            .get(with_query(&self.url("/v1/artifacts/file"), &[("path", path), ("ref", "main")])?)
            .bearer_auth(token)
            .send()
            .await?;
        if response.status() == StatusCode::NOT_FOUND {
            return Ok(None);
        }
        ensure_success(response.status(), "artifact conflict file read")?;
        Ok(Some(response.bytes().await?.to_vec()))
    }

    /// Pull the listed files into their local roots. A file whose commit is the one this machine
    /// last synced is not read again. Remote deletions are not applied here: the listing shows a
    /// saved artifact's folder as one item, so a file it does not name may still exist.
    pub async fn pull_once(&mut self) -> Result<SyncReport> {
        if !self.config.enabled {
            return Ok(SyncReport::default());
        }
        let token = self
            .token
            .as_deref()
            .map(str::to_owned)
            .ok_or_else(|| anyhow!("artifacts sync access token unavailable"))?;
        let (head, items) = self.list_all(&token).await?;
        self.state.head_sha = head.or_else(|| self.state.head_sha.clone());
        let mut report = SyncReport::default();
        for item in items {
            if item.id.is_some() {
                continue; // a saved artifact's folder, not a file
            }
            let Some((dir, relative)) = self.locate(&item.path) else { continue };
            let synced = self.state.synced.get(&item.path);
            if item.commit.is_some()
                && synced.and_then(|synced| synced.commit.as_ref()) == item.commit.as_ref()
            {
                // Unchanged remotely: a local edit or delete is the upload's to send.
                continue;
            }
            let Some(bytes) = self.remote_file(&item.path, &token).await? else { continue };
            if should_skip(&item.path, &bytes) {
                report.skipped += 1;
                continue;
            }
            // Only over what this machine last synced, or a missing file: a local edit the server
            // hasn't taken yet stays, and the next pass sends it. A file deleted here but changed
            // remotely since comes back: the remote edit wins over the delete.
            let expected = self.synced_digest(&item.path).map(str::to_owned);
            if !replace_if_unchanged(&dir, &relative, expected.as_deref(), &bytes)? {
                report.conflicts += 1;
                continue;
            }
            self.mark(item.path, bytes, item.commit);
            report.pulled += 1;
        }
        Ok(report)
    }

    /// Every listed item at one head, page by page. A head that moves between pages fails the
    /// pass, so a pull never mixes two versions; the next pass lists again.
    async fn list_all(&self, token: &str) -> Result<(Option<String>, Vec<ListItem>)> {
        let mut items = Vec::new();
        let mut head = None;
        let mut cursor: Option<String> = None;
        let limit = LIST_PAGE.to_string();
        for page in 0..LIST_PAGES {
            let mut query = vec![("limit", limit.as_str())];
            if let Some(cursor) = cursor.as_deref() {
                query.push(("cursor", cursor));
            }
            let response = self
                .client
                .get(with_query(&self.url("/v1/artifacts"), &query)?)
                .bearer_auth(token)
                .send()
                .await?;
            ensure_success(response.status(), "artifact list")?;
            let listed: ListResponse = response.json().await.context("decode artifact list")?;
            if page > 0 && listed.head_sha != head {
                return Err(anyhow!("artifacts changed while listing; listing again next pass"));
            }
            head = listed.head_sha;
            items.extend(listed.items);
            match listed.cursor {
                Some(next) if Some(&next) != cursor.as_ref() => cursor = Some(next),
                _ => return Ok((head, items)),
            }
        }
        Err(anyhow!("artifact list longer than {} items", LIST_PAGE * LIST_PAGES))
    }

    /// The opened root and the path in it for a remote path, only when it stays inside: a listed
    /// path is the server's text, and `..`, an absolute path or a backslash must never reach
    /// outside the memory and artifact folders. A symlink below the root is refused where it is
    /// used (`artifacts_fs.rs`).
    fn locate(&self, remote: &str) -> Option<(Dir, PathBuf)> {
        self.roots.iter().find_map(|root| {
            let relative = remote.strip_prefix(&root.remote_prefix)?;
            let inside = !relative.is_empty()
                && !relative.contains(['\\', '\0'])
                && Path::new(relative)
                    .components()
                    .all(|part| matches!(part, std::path::Component::Normal(_)));
            if !inside {
                return None;
            }
            Some((root.open()?, PathBuf::from(relative)))
        })
    }

    #[cfg(test)]
    fn local_for_remote(&self, remote: &str) -> Option<PathBuf> {
        let root = self.roots.iter().find(|root| remote.starts_with(&root.remote_prefix))?;
        self.locate(remote).map(|(_, relative)| root.local.join(relative))
    }
    fn url(&self, path: &str) -> String {
        format!("{}{}", self.config.base_url.trim_end_matches('/'), path)
    }
}

#[derive(Debug)]
struct HttpStatusError {
    operation: String,
    status: StatusCode,
}

impl std::fmt::Display for HttpStatusError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{} returned HTTP {}", self.operation, self.status)
    }
}

impl std::error::Error for HttpStatusError {}

/// reqwest is built without a rustls provider; install the workspace's ring one (as the mesh
/// client does) so a client built before the mesh's never panics.
fn http_client() -> Result<Client> {
    let _ = rustls::crypto::ring::default_provider().install_default();
    Ok(Client::builder().connect_timeout(CONNECT_TIMEOUT).read_timeout(READ_TIMEOUT).build()?)
}

/// The query string encoded by `url` (reqwest's own `query` needs a feature this workspace leaves off).
fn with_query(url: &str, pairs: &[(&str, &str)]) -> Result<reqwest::Url> {
    reqwest::Url::parse_with_params(url, pairs).context("artifacts URL")
}

fn ensure_success(status: StatusCode, operation: &str) -> Result<()> {
    if status.is_success() {
        Ok(())
    } else {
        Err(HttpStatusError { operation: operation.into(), status }.into())
    }
}

/// The server refused the bearer: the next pass takes a new token instead of the held one.
fn unauthorized(error: &anyhow::Error) -> bool {
    error.chain().any(|cause| {
        cause
            .downcast_ref::<HttpStatusError>()
            .is_some_and(|e| e.status == StatusCode::UNAUTHORIZED)
    })
}

fn discover_roots() -> Vec<SyncRoot> {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    let mut roots = Vec::new();
    let claude = home.join(".claude/projects");
    if claude.is_dir()
        && let Ok(entries) = fs::read_dir(&claude)
    {
        for entry in entries.flatten() {
            let scope = entry.file_name().to_string_lossy().into_owned();
            roots.push(SyncRoot {
                local: entry.path().join("memory"),
                remote_prefix: format!("memory/claude/{scope}/"),
                anchor: home.clone(),
            });
        }
    }
    for (local, remote_prefix) in
        [(".codex/memories", "memory/codex/"), (".cmux/artifacts", "artifacts/")]
    {
        roots.push(SyncRoot {
            local: home.join(local),
            remote_prefix: remote_prefix.into(),
            anchor: home.clone(),
        });
    }
    // Checked every pass (`usable`), so a folder made a symlink later is left out from then on.
    roots
}

/// Write `bytes` to `relative` in `dir` only when nothing is there, the file still has the digest
/// `expected`, or it already holds `bytes`. Returns whether it now holds `bytes`; anything else
/// (a local edit, or something that is not a plain file) is kept.
fn replace_if_unchanged(
    dir: &Dir,
    relative: &Path,
    expected: Option<&str>,
    bytes: &[u8],
) -> io::Result<bool> {
    if !dir.missing(relative) {
        match dir.read(relative)? {
            Some(current) if current == bytes => return Ok(true),
            Some(current) if expected == Some(sha256(&current).as_str()) => {}
            _ => return Ok(false),
        }
    }
    dir.write(relative, bytes)?;
    Ok(true)
}

fn conflict_sibling(path: &str) -> String {
    // One plain name part: a HOSTNAME with `/` or `..` never adds a folder to the path.
    let machine: String = env::var("HOSTNAME")
        .unwrap_or_default()
        .chars()
        .map(|c| if c.is_ascii_alphanumeric() || c == '-' { c } else { '_' })
        .take(64)
        .collect();
    let machine = if machine.is_empty() { "machine".to_owned() } else { machine };
    // Milliseconds, so two conflicts on one file in the same second keep both copies.
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis());
    let path = Path::new(path);
    let stem = path.file_stem().and_then(|v| v.to_str()).unwrap_or("artifact");
    let ext =
        path.extension().and_then(|v| v.to_str()).map(|e| format!(".{e}")).unwrap_or_default();
    let parent = path.parent().map(|p| p.to_string_lossy()).unwrap_or_default();
    let name = format!("{stem}.conflict-{machine}-{stamp}{ext}");
    if parent.is_empty() { name } else { format!("{parent}/{name}") }
}

fn content_type(path: &str) -> Option<String> {
    Some(
        match Path::new(path).extension().and_then(|e| e.to_str()).unwrap_or("") {
            "md" => "text/markdown",
            "json" => "application/json",
            "html" => "text/html",
            "txt" => "text/plain",
            _ => "application/octet-stream",
        }
        .into(),
    )
}

/// Refuse both sensitive names and files whose content resembles a credential.
pub fn should_skip(path: &str, bytes: &[u8]) -> bool {
    let lower = path.to_ascii_lowercase();
    let name = Path::new(&lower).file_name().and_then(|n| n.to_str()).unwrap_or("");
    if name.starts_with(".env")
        || name.starts_with("id_")
        || name.contains("credentials")
        || name.ends_with(".pem")
        || name.ends_with(".key")
    {
        return true;
    }
    let text = String::from_utf8_lossy(bytes);
    // The daemon's secret scanner (gitleaks' rules and cmux's own) finds keys and tokens by
    // shape; a credential-named key with a value (`password: x`, `apiKey = "…"`) is caught here
    // whatever the value looks like. A false hit only leaves a file unsynced.
    !crate::secret_scan::find(&text).is_empty()
        || CREDENTIAL_ASSIGNMENT.as_ref().is_none_or(|pattern| pattern.is_match(&text))
        || {
            let lower = text.to_ascii_lowercase();
            [
                "private key-----",
                "api_key=",
                "api-key:",
                "access_token=",
                "password=",
                "aws_secret_access_key",
                "secret_key",
            ]
            .iter()
            .any(|needle| lower.contains(needle))
        }
}

/// `None` only if the pattern failed to build, and then every file is skipped (the safe side).
static CREDENTIAL_ASSIGNMENT: std::sync::LazyLock<Option<regex::Regex>> = std::sync::LazyLock::new(
    || {
        regex::Regex::new(
        r#"(?i)(?:password|passwd|pwd|secret|client[_-]?secret|api[_-]?key|access[_-]?key|access[_-]?token|auth[_-]?token|refresh[_-]?token|bearer[_-]?token|private[_-]?key|secret[_-]?key)["']?\s*[:=]\s*["']?[^\s"',;]+"#,
    )
    .ok()
    },
);

/// A line-oriented 3-way merge. Non-overlapping changes are retained; an
/// overlapping edit is represented with standard conflict markers for review.
pub fn merge_markdown(base: &[u8], local: &[u8], remote: &[u8]) -> Vec<u8> {
    if local == base {
        return remote.to_vec();
    }
    if remote == base || local == remote {
        return local.to_vec();
    }
    let b_text = String::from_utf8_lossy(base);
    let l_text = String::from_utf8_lossy(local);
    let r_text = String::from_utf8_lossy(remote);
    let b = b_text.lines().collect::<Vec<_>>();
    let l = l_text.lines().collect::<Vec<_>>();
    let r = r_text.lines().collect::<Vec<_>>();
    let mut out = String::new();
    for i in 0..b.len().max(l.len()).max(r.len()) {
        let (base, ours, theirs) = (
            b.get(i).copied().unwrap_or(""),
            l.get(i).copied().unwrap_or(""),
            r.get(i).copied().unwrap_or(""),
        );
        let chosen = if ours == theirs {
            ours.to_owned()
        } else if ours == base {
            theirs.to_owned()
        } else if theirs == base {
            ours.to_owned()
        } else {
            format!("<<<<<<< local\n{ours}\n=======\n{theirs}\n>>>>>>> remote")
        };
        out.push_str(&chosen);
        out.push('\n');
    }
    out.into_bytes()
}

pub fn sha256(bytes: &[u8]) -> String {
    let mut digest = Sha256::new();
    digest.update(bytes);
    format!("{:x}", digest.finalize())
}

#[cfg(test)]
#[path = "artifacts_sync_tests.rs"]
mod tests;
