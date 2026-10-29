//! Optional cmux-platform artifact and agent-memory synchronization.
//!
//! This module is deliberately inert unless `config.artifacts_sync.enabled` is
//! true. It owns no credentials: callers pass the short-lived cmux access
//! token already held by acpmux's mesh client.

use std::{collections::BTreeMap, env, fs, io, path::{Path, PathBuf}, sync::Arc};

use anyhow::{anyhow, Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine as _};
use reqwest::{Client, StatusCode};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use tracing::debug;

use crate::config::{ArtifactsSyncConfig, Config};

const MAX_PUSH_BYTES: usize = 64 * 1024 * 1024;
const BLOB_THRESHOLD: usize = 8 * 1024 * 1024;

#[derive(Debug, Clone, Default, PartialEq)]
pub struct SyncState {
    pub head_sha: Option<String>,
    /// Last content sent for each path. This is the merge base after a CAS conflict.
    pub base: BTreeMap<String, Vec<u8>>,
}

#[derive(Debug, Clone, Default, PartialEq)]
pub struct SyncReport {
    pub uploaded: usize,
    pub pulled: usize,
    pub skipped: usize,
    pub conflicts: usize,
}

#[derive(Debug, Clone, Serialize)]
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
struct SaveResponse {
    #[serde(rename = "headSha")]
    head_sha: String,
    commit: String,
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
}

#[derive(Debug, Deserialize)]
struct ListItem {
    path: String,
}

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
}

#[derive(Debug, Clone)]
struct SyncRoot {
    local: PathBuf,
    remote_prefix: String,
}

/// HTTP client shared by the MCP artifact tools and the background synchronizer.
/// It never persists or returns the bearer token.
#[derive(Debug, Clone)]
pub struct ArtifactsClient {
    config: ArtifactsSyncConfig,
    token: Arc<str>,
    client: Client,
}

#[derive(Debug, Serialize)]
struct CreateArtifactRequest<'a> {
    title: &'a str,
    kind: &'a str,
    files: Vec<CreateArtifactFile>,
    trailers: Trailers,
    #[serde(rename = "expectedHeadSha")]
    expected_head_sha: Option<String>,
}

#[derive(Debug, Serialize)]
struct CreateArtifactFile {
    name: String,
    #[serde(rename = "contentBase64")]
    content_base64: String,
    #[serde(skip_serializing_if = "Option::is_none", rename = "contentType")]
    content_type: Option<String>,
}

impl ArtifactsClient {
    /// Build from the daemon config, taking the access token from the same
    /// process credential hand-off used by the mesh client. The token is never
    /// written to config or returned by this client.
    /// Build from the daemon config and the mesh's in-memory access-token
    /// provider. No token is read from disk or environment.
    pub async fn from_runtime_config(config: &Config) -> Result<Option<Self>> {
        if !config.artifacts_sync.enabled { return Ok(None); }
        let relay = config.mesh_relay.as_ref().ok_or_else(|| anyhow!("artifacts sync requires meshRelay credentials"))?;
        let hub = crate::mesh_http::HttpHub::new(relay).map_err(|error| anyhow!("mesh auth: {error}"))?;
        let token = hub.token(false).await.map_err(|error| anyhow!("mesh auth: {error}"))?;
        Self::from_parts(config.artifacts_sync.clone(), Some(token.as_ref().as_str().to_owned()))
    }

    pub fn from_parts(config: ArtifactsSyncConfig, access_token: Option<String>) -> Result<Option<Self>> {
        if !config.enabled { return Ok(None); }
        let token = access_token.ok_or_else(|| anyhow!("artifacts sync access token unavailable"))?;
        if config.base_url.trim().is_empty() { return Err(anyhow!("artifacts sync is enabled without baseUrl")); }
        Ok(Some(Self { config, token: Arc::from(token), client: Client::new() }))
    }

    pub fn enabled(&self) -> bool { self.config.enabled }

    pub async fn save_artifact(
        &self,
        title: &str,
        kind: &str,
        files: &[(String, Vec<u8>, Option<String>)],
        trailers: Trailers,
    ) -> Result<(String, String)> {
        let payload = CreateArtifactRequest {
            title,
            kind,
            files: files.iter().map(|(name, bytes, content_type)| CreateArtifactFile {
                name: name.clone(), content_base64: BASE64.encode(bytes), content_type: content_type.clone(),
            }).collect(),
            trailers,
            expected_head_sha: None,
        };
        let response = self.client.post(self.url("/v1/artifacts")).bearer_auth(self.token.as_ref()).json(&payload).send().await?;
        ensure_success(response.status(), "artifact create")?;
        let value: serde_json::Value = response.json().await.context("decode artifact create response")?;
        let id = value.get("id").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("artifact response missing id"))?.to_owned();
        let head = value.get("headSha").and_then(|v| v.as_str()).ok_or_else(|| anyhow!("artifact response missing headSha"))?.to_owned();
        Ok((id, head))
    }

    pub async fn list(&self, prefix: Option<&str>, kind: Option<&str>) -> Result<serde_json::Value> {
        let mut request = self.client.get(self.url("/v1/artifacts")).bearer_auth(self.token.as_ref());
        if let Some(prefix) = prefix { request = request.query(&[("prefix", prefix)]); }
        if let Some(kind) = kind { request = request.query(&[("kind", kind)]); }
        let response = request.send().await?;
        ensure_success(response.status(), "artifact list")?;
        Ok(response.json().await?)
    }

    pub async fn search(&self, query: &str, limit: usize) -> Result<serde_json::Value> {
        let limit_string = limit.to_string();
        let response = self.client.get(self.url("/v1/artifacts/search")).query(&[("q", query), ("limit", limit_string.as_str())]).bearer_auth(self.token.as_ref()).send().await?;
        ensure_success(response.status(), "artifact search")?;
        Ok(response.json().await?)
    }

    fn url(&self, path: &str) -> String { format!("{}{}", self.config.base_url.trim_end_matches('/'), path) }
}

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
    let token = match relay.token(false).await {
        Ok(token) => token.as_ref().as_str().to_owned(),
        Err(error) => {
            tracing::warn!("artifacts sync mesh auth unavailable: {error}");
            return;
        }
    };
    let Some(mut sync) = (match ArtifactsSync::new(config.artifacts_sync.clone(), Some(token)) {
        Ok(sync) => sync,
        Err(error) => {
            tracing::warn!("artifacts sync configuration invalid: {error}");
            return;
        }
    }) else {
        return;
    };
    let trailers = Trailers {
        machine: env::var("HOSTNAME").ok(),
        ..Default::default()
    };
    let period = std::time::Duration::from_millis(config.artifacts_sync.poll_interval_ms.max(1_000));
    let mut interval = tokio::time::interval(period);
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    loop {
        tokio::select! {
            _ = hub.shutdown.notified() => break,
            _ = interval.tick() => {
                if let Err(error) = sync.sync_once(trailers.clone()).await {
                    tracing::warn!("artifacts sync upload failed: {error:#}");
                }
                if let Err(error) = sync.pull_once().await {
                    tracing::warn!("artifacts sync pull failed: {error:#}");
                }
            }
        }
    }
    tracing::debug!("artifacts sync stopped with daemon shutdown");
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
            client: Client::builder().build()?,
            state: SyncState::default(),
            roots: discover_roots(),
        }))
    }

    pub fn enabled(&self) -> bool { self.config.enabled }
    pub fn state(&self) -> &SyncState { &self.state }
    pub fn state_mut(&mut self) -> &mut SyncState { &mut self.state }

    /// One bounded pass over local files. Callers may schedule this with their
    /// own cancellation token; this method never starts a polling loop.
    pub async fn sync_once(&mut self, trailers: Trailers) -> Result<SyncReport> {
        if !self.config.enabled { return Ok(SyncReport::default()); }
        let token = self.token.as_ref().map(|token| token.to_string()).ok_or_else(|| anyhow!("artifacts sync access token unavailable"))?;
        let mut report = SyncReport::default();
        let mut batch = Vec::new();
        let mut batch_bytes = 0usize;
        for root in &self.roots {
            if !root.local.exists() { continue; }
            let mut files = Vec::new();
            collect_files(&root.local, &root.local, &mut files)?;
            for (path, bytes) in files {
                let remote = format!("{}{}", root.remote_prefix, path.to_string_lossy().replace('\\', "/"));
                if should_skip(&remote, &bytes) {
                    report.skipped += 1;
                    debug!(path = %remote, "artifacts sync skipped secret-looking file");
                    continue;
                }
                let estimated = bytes.len().saturating_mul(4).div_ceil(3) + remote.len() + 256;
                if !batch.is_empty() && batch_bytes.saturating_add(estimated) > MAX_PUSH_BYTES {
                    report.uploaded += self.push_batch(std::mem::take(&mut batch), &trailers).await?;
                    batch_bytes = 0;
                }
                batch_bytes = batch_bytes.saturating_add(estimated);
                batch.push((remote, bytes));
            }
        }
        if !batch.is_empty() { report.uploaded += self.push_batch(batch, &trailers).await?; }
        Ok(report)
    }

    async fn push_batch(&mut self, files: Vec<(String, Vec<u8>)>, trailers: &Trailers) -> Result<usize> {
        let token = self.token.as_ref().map(|token| token.to_string()).ok_or_else(|| anyhow!("artifacts sync access token unavailable"))?;
        let changes = self.make_changes(&files, &token).await?;
        let request = SaveRequest {
            expected_head_sha: self.state.head_sha.clone(),
            branch: "main",
            message: "Sync local artifacts and memories".into(),
            trailers: trailers.clone(),
            changes,
        };
        let response = self.client.post(self.url("/v1/artifacts/save")).bearer_auth(&token).json(&request).send().await?;
        if response.status() != StatusCode::CONFLICT {
            ensure_success(response.status(), "artifact save")?;
            let saved: SaveResponse = response.json().await.context("decode save response")?;
            self.state.head_sha = Some(saved.head_sha);
            for (path, bytes) in files { self.state.base.insert(path, bytes); }
            return Ok(request.changes.len());
        }

        // The server's ref CAS rejected our old head. Read each remote file and
        // resolve it against the last synced base before retrying once at the new head.
        let conflict: ConflictResponse = response.json().await.unwrap_or(ConflictResponse { current_head_sha: None });
        let current_head = conflict.current_head_sha.or_else(|| self.state.head_sha.clone());
        let mut resolved = Vec::new();
        for (path, local) in files {
            let remote = self.remote_file(&path, &token).await.unwrap_or_default();
            let base = self.state.base.get(&path).map(Vec::as_slice).unwrap_or(&[]);
            if path.to_ascii_lowercase().ends_with(".md") {
                let merged = merge_markdown(base, &local, &remote);
                if let Some(destination) = self.local_for_remote(&path) {
                    if let Some(parent) = destination.parent() { fs::create_dir_all(parent)?; }
                    fs::write(destination, &merged)?;
                }
                self.state.base.insert(path.clone(), merged.clone());
                resolved.push(self.change_for(path, merged, &token).await?);
            } else {
                let sibling = conflict_sibling(&path);
                if let Some(destination) = self.local_for_remote(&sibling) {
                    if let Some(parent) = destination.parent() { fs::create_dir_all(parent)?; }
                    fs::write(destination, &local)?;
                }
                resolved.push(self.change_for(sibling, local, &token).await?);
            }
        }
        let retry = SaveRequest { expected_head_sha: current_head.clone(), branch: "main", message: "Resolve concurrent artifact sync".into(), trailers: trailers.clone(), changes: resolved };
        let response = self.client.post(self.url("/v1/artifacts/save")).bearer_auth(&token).json(&retry).send().await?;
        ensure_success(response.status(), "artifact conflict resolution save")?;
        let saved: SaveResponse = response.json().await.context("decode conflict save response")?;
        self.state.head_sha = Some(saved.head_sha);
        Ok(retry.changes.len())
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
            let response = self.client.post(self.url("/v1/artifacts/blobs")).bearer_auth(token).body(bytes.clone()).send().await?;
            ensure_success(response.status(), "blob upload")?;
            let blob: BlobResponse = response.json().await.context("decode blob response")?;
            if blob.size != bytes.len() { return Err(anyhow!("blob response size mismatch")); }
            (None, Some(blob.sha256))
        } else { (Some(BASE64.encode(&bytes)), None) };
        Ok(Change { path: path.clone(), op: "put", content_base64, blob_sha256, content_type: content_type(&path) })
    }

    async fn remote_file(&self, path: &str, token: &str) -> Result<Vec<u8>> {
        let response = self.client.get(self.url("/v1/artifacts/file")).query(&[("path", path), ("ref", "main")]).bearer_auth(token).send().await?;
        if response.status() == StatusCode::NOT_FOUND { return Ok(Vec::new()); }
        ensure_success(response.status(), "artifact conflict file read")?;
        Ok(response.bytes().await?.to_vec())
    }

    /// Pull the indexed paths and apply remote bytes to the corresponding local root.
    pub async fn pull_once(&mut self) -> Result<SyncReport> {
        if !self.config.enabled { return Ok(SyncReport::default()); }
        let token = self.token.as_deref().ok_or_else(|| anyhow!("artifacts sync access token unavailable"))?;
        let response = self.client.get(self.url("/v1/artifacts")).bearer_auth(token).send().await?;
        ensure_success(response.status(), "artifact list")?;
        let listed: ListResponse = response.json().await.context("decode artifact list")?;
        self.state.head_sha = listed.head_sha.or_else(|| self.state.head_sha.clone());
        let mut report = SyncReport::default();
        for item in listed.items {
            let Some(local) = self.local_for_remote(&item.path) else { continue };
            let response = self.client.get(self.url("/v1/artifacts/file")).query(&[("path", item.path.as_str()), ("ref", "main")]).bearer_auth(token).send().await?;
            if response.status() == StatusCode::NOT_FOUND { continue; }
            ensure_success(response.status(), "artifact file")?;
            let bytes = response.bytes().await?.to_vec();
            if should_skip(&item.path, &bytes) { report.skipped += 1; continue; }
            if let Some(parent) = local.parent() { fs::create_dir_all(parent)?; }
            fs::write(&local, &bytes)?;
            self.state.base.insert(item.path, bytes);
            report.pulled += 1;
        }
        Ok(report)
    }

    fn local_for_remote(&self, remote: &str) -> Option<PathBuf> {
        self.roots.iter().find_map(|root| remote.strip_prefix(&root.remote_prefix).map(|relative| root.local.join(relative)))
    }
    fn url(&self, path: &str) -> String { format!("{}{}", self.config.base_url.trim_end_matches('/'), path) }
}

fn ensure_success(status: StatusCode, operation: &str) -> Result<()> {
    if status.is_success() { Ok(()) } else { Err(anyhow!("{operation} returned HTTP {status}")) }
}

fn discover_roots() -> Vec<SyncRoot> {
    let home = dirs::home_dir().unwrap_or_else(|| PathBuf::from("."));
    let mut roots = Vec::new();
    let claude = home.join(".claude/projects");
    if claude.is_dir() {
        if let Ok(entries) = fs::read_dir(&claude) {
            for entry in entries.flatten().filter(|e| e.path().is_dir()) {
                let scope = entry.file_name().to_string_lossy().into_owned();
                roots.push(SyncRoot { local: entry.path().join("memory"), remote_prefix: format!("memory/claude/{scope}/") });
            }
        }
    }
    let codex = home.join(".codex/memories");
    roots.push(SyncRoot { local: codex, remote_prefix: "memory/codex/".into() });
    roots.push(SyncRoot { local: home.join(".cmux/artifacts"), remote_prefix: "artifacts/".into() });
    roots
}

fn collect_files(root: &Path, current: &Path, out: &mut Vec<(PathBuf, Vec<u8>)>) -> io::Result<()> {
    if !current.exists() { return Ok(()); }
    for entry in fs::read_dir(current)? {
        let entry = entry?;
        let path = entry.path();
        if path.is_dir() { collect_files(root, &path, out)?; }
        else if path.is_file() { out.push((path.strip_prefix(root).unwrap_or(&path).to_path_buf(), fs::read(path)?)); }
    }
    Ok(())
}

fn conflict_sibling(path: &str) -> String {
    let machine = env::var("HOSTNAME").unwrap_or_else(|_| "machine".into());
    let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_secs());
    let path = Path::new(path);
    let stem = path.file_stem().and_then(|v| v.to_str()).unwrap_or("artifact");
    let ext = path.extension().and_then(|v| v.to_str()).map(|e| format!(".{e}")).unwrap_or_default();
    let parent = path.parent().map(|p| p.to_string_lossy()).unwrap_or_default();
    let name = format!("{stem}.conflict-{machine}-{stamp}{ext}");
    if parent.is_empty() { name } else { format!("{parent}/{name}") }
}

fn content_type(path: &str) -> Option<String> {
    Some(match Path::new(path).extension().and_then(|e| e.to_str()).unwrap_or("") {
        "md" => "text/markdown", "json" => "application/json", "html" => "text/html", "txt" => "text/plain", _ => "application/octet-stream",
    }.into())
}

/// Refuse both sensitive names and files whose content resembles a credential.
pub fn should_skip(path: &str, bytes: &[u8]) -> bool {
    let lower = path.to_ascii_lowercase();
    let name = Path::new(&lower).file_name().and_then(|n| n.to_str()).unwrap_or("");
    if name.starts_with(".env") || name.starts_with("id_") || name.contains("credentials") || name.ends_with(".pem") || name.ends_with(".key") { return true; }
    let text = String::from_utf8_lossy(bytes).to_ascii_lowercase();
    ["begin rsa private key", "begin openssh private key", "begin private key", "api_key=", "api-key:", "access_token=", "password=", "aws_secret_access_key", "secret_key"].iter().any(|needle| text.contains(needle))
}

/// A line-oriented 3-way merge. Non-overlapping changes are retained; an
/// overlapping edit is represented with standard conflict markers for review.
pub fn merge_markdown(base: &[u8], local: &[u8], remote: &[u8]) -> Vec<u8> {
    if local == base { return remote.to_vec(); }
    if remote == base || local == remote { return local.to_vec(); }
    let b_text = String::from_utf8_lossy(base);
    let l_text = String::from_utf8_lossy(local);
    let r_text = String::from_utf8_lossy(remote);
    let b = b_text.lines().collect::<Vec<_>>();
    let l = l_text.lines().collect::<Vec<_>>();
    let r = r_text.lines().collect::<Vec<_>>();
    let mut out = String::new();
    for i in 0..b.len().max(l.len()).max(r.len()) {
        let (base, ours, theirs) = (b.get(i).copied().unwrap_or(""), l.get(i).copied().unwrap_or(""), r.get(i).copied().unwrap_or(""));
        let chosen = if ours == theirs { ours.to_owned() } else if ours == base { theirs.to_owned() } else if theirs == base { ours.to_owned() } else { format!("<<<<<<< local\n{ours}\n=======\n{theirs}\n>>>>>>> remote") };
        out.push_str(&chosen); out.push('\n');
    }
    out.into_bytes()
}

pub fn sha256(bytes: &[u8]) -> String {
    let mut digest = Sha256::new(); digest.update(bytes); format!("{:x}", digest.finalize())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn disabled_is_inert() {
        let config = ArtifactsSyncConfig::default();
        assert!(ArtifactsSync::new(config, Some("secret".into())).unwrap().is_none());
    }

    #[test]
    fn secret_paths_and_content_are_skipped() {
        assert!(should_skip("memory/claude/scope/.env", b"x"));
        assert!(should_skip("memory/claude/scope/server.pem", b"x"));
        assert!(should_skip("memory/claude/scope/notes.md", b"AWS_SECRET_ACCESS_KEY=abc"));
        assert!(!should_skip("memory/claude/scope/notes.md", b"safe notes"));
    }

    #[test]
    fn markdown_three_way_merge_keeps_non_overlapping_edits() {
        let merged = merge_markdown(b"one\ntwo\n", b"ONE\ntwo\n", b"one\nTWO\n");
        assert_eq!(String::from_utf8(merged).unwrap(), "ONE\nTWO\n");
    }

    #[test]
    fn markdown_conflict_is_explicit() {
        let merged = String::from_utf8(merge_markdown(b"one\n", b"local\n", b"remote\n")).unwrap();
        assert!(merged.contains("<<<<<<< local"));
        assert!(merged.contains(">>>>>>> remote"));
    }

    #[test]
    fn sha256_matches_contract_blob_hash() {
        assert_eq!(sha256(b"hello"), "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824");
    }

    #[test]
    fn config_round_trip_keeps_disabled_default_omitted() {
        let config = ArtifactsSyncConfig::default();
        assert_eq!(serde_json::to_value(&config).unwrap()["enabled"], json!(false));
    }
}
