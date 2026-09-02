//! Opt-in manifest catalog updates for the userland detector.
//!
//! Network access is never part of daemon startup. The `update` command must
//! be invoked explicitly, and every response is bounded, validated, and
//! committed with an atomic rename before the scanner can read it.
//!
//! The catalog and manifest format are derived from herdrdev/herdr's
//! `src/detect/manifest_update.rs` at commit
//! `7b675f42af35508eab66ac42fe1598628597a893` (Apache-2.0). The updater is a
//! manaflow implementation with stricter URL, size, version, and cache rules.

use std::collections::{BTreeMap, BTreeSet};
use std::fs;
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

use crate::manifest::{MAX_MANIFEST_BYTES, compile_manifest_source, read_bounded_utf8_file};

pub const DEFAULT_CATALOG_URL: &str = "https://herdr.dev/agent-detection/index.toml";
pub const CATALOG_URL_ENV: &str = "CMUX_AGENT_MANIFEST_CATALOG_URL";
pub const CACHE_DIR_ENV: &str = "CMUX_AGENT_MANIFEST_CACHE_DIR";
const MAX_FETCH_BYTES: usize = 256 * 1024;
const MAX_CATALOG_AGENTS: usize = 256;
const MAX_CATALOG_PATH_BYTES: usize = 512;
const MAX_CATALOG_URL_BYTES: usize = 2 * 1024;
const STATUS_FILE_NAME: &str = ".cmux-agent-detection-status.toml";
const LEGACY_STATUS_FILE_NAME: &str = "status.toml";

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestUpdateSummary {
    pub catalog_url: String,
    pub cache_dir: PathBuf,
    pub checked: Vec<String>,
    pub updated: Vec<String>,
    pub current: Vec<String>,
    pub failed: Vec<ManifestUpdateFailure>,
    pub status: ManifestUpdateStatus,
}

/// Durable diagnostics for the last explicit catalog check. This mirrors
/// herdr's useful status surface while keeping the state in the plugin cache,
/// never in the daemon registry.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManifestUpdateStatus {
    pub last_check_unix: Option<u64>,
    pub last_result: Option<String>,
    #[serde(default)]
    pub agents: BTreeMap<String, ManifestAgentStatus>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ManifestAgentStatus {
    pub cached_version: Option<String>,
    pub attempted_version: Option<String>,
    pub last_checked_unix: Option<u64>,
    pub last_result: String,
    pub last_error: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ManifestUpdateFailure {
    pub id: String,
    pub error: String,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestCatalog {
    schema_version: u32,
    #[serde(default)]
    agents: Vec<ManifestCatalogAgent>,
}

#[derive(Debug, Deserialize)]
#[serde(deny_unknown_fields)]
struct ManifestCatalogAgent {
    id: String,
    path: String,
}

struct ValidatedCatalogAgent {
    entry: ManifestCatalogAgent,
    manifest_url: String,
}

/// Fetch and validate a catalog and its manifests. This function does not
/// mutate the cache until each individual manifest has passed validation.
pub fn update_catalog(url: &str, cache_dir: &Path) -> Result<ManifestUpdateSummary, String> {
    let check_time = now_unix();
    let mut status = load_status(cache_dir);
    status.last_check_unix = Some(check_time);
    let catalog = match fetch_text(url).and_then(|content| parse_catalog(&content)) {
        Ok(catalog) => catalog,
        Err(error) => {
            status.last_result = Some(format!("failed: {error}"));
            let _ = save_status(cache_dir, &status);
            return Err(error);
        }
    };
    let base = match base_url(url) {
        Ok(base) => base,
        Err(error) => {
            status.last_result = Some(format!("failed: {error}"));
            let _ = save_status(cache_dir, &status);
            return Err(error);
        }
    };
    // Validate the complete catalog shape before fetching or writing any
    // manifest. A malformed entry must not leave a half-applied update.
    let entries = match validate_catalog_entries(catalog, &base) {
        Ok(entries) => entries,
        Err(error) => {
            status.last_result = Some(format!("failed: {error}"));
            let _ = save_status(cache_dir, &status);
            return Err(error);
        }
    };
    let checked = entries.iter().map(|entry| entry.entry.id.clone()).collect::<Vec<_>>();
    let mut updated = Vec::new();
    let mut current = Vec::new();
    let mut failed = Vec::new();
    status.last_result = Some("checked".into());
    for validated in entries {
        let entry = validated.entry;
        let manifest_url = validated.manifest_url;
        let result = (|| -> Result<(String, crate::manifest::CompiledManifest), String> {
            let content = fetch_text(&manifest_url)
                .map_err(|error| format!("fetch {manifest_url}: {error}"))?;
            let compiled = compile_manifest_source(&content)
                .map_err(|error| format!("manifest {} is invalid: {error}", entry.id))?;
            if compiled.id() != entry.id {
                return Err(format!(
                    "catalog id {:?} does not match manifest id {:?}",
                    entry.id,
                    compiled.id()
                ));
            }
            if compiled.version().is_none() {
                return Err(format!("manifest {} has no version", entry.id));
            }
            Ok((content, compiled))
        })();
        let (content, compiled) = match result {
            Ok(value) => value,
            Err(error) => {
                failed.push(ManifestUpdateFailure { id: entry.id.clone(), error: error.clone() });
                status.agents.insert(
                    entry.id.clone(),
                    ManifestAgentStatus {
                        cached_version: cached_version(cache_dir, &entry.id),
                        attempted_version: None,
                        last_checked_unix: Some(check_time),
                        last_result: "failed".into(),
                        last_error: Some(error),
                    },
                );
                continue;
            }
        };
        let version = compiled.version().cloned().expect("validated manifest version");
        let version_text = version.to_string();
        let path = cache_dir.join(format!("{}.toml", entry.id));
        match read_bounded_utf8_file(&path, MAX_MANIFEST_BYTES) {
            Ok(existing) => {
                let existing_manifest = match compile_manifest_source(&existing) {
                    Ok(manifest) => manifest,
                    Err(error) => {
                        let error = format!("cached manifest {} is invalid: {error}", entry.id);
                        failed.push(ManifestUpdateFailure {
                            id: entry.id.clone(),
                            error: error.clone(),
                        });
                        status.agents.insert(
                            entry.id.clone(),
                            ManifestAgentStatus {
                                cached_version: None,
                                attempted_version: Some(version_text.clone()),
                                last_checked_unix: Some(check_time),
                                last_result: "failed".into(),
                                last_error: Some(error),
                            },
                        );
                        continue;
                    }
                };
                if let Some(existing_version) = existing_manifest.version()
                    && version < existing_version.clone()
                {
                    let error = format!(
                        "manifest {} regressed from {} to {}",
                        entry.id, existing_version, version
                    );
                    failed
                        .push(ManifestUpdateFailure { id: entry.id.clone(), error: error.clone() });
                    status.agents.insert(
                        entry.id.clone(),
                        ManifestAgentStatus {
                            cached_version: Some(existing_version.to_string()),
                            attempted_version: Some(version_text.clone()),
                            last_checked_unix: Some(check_time),
                            last_result: "failed".into(),
                            last_error: Some(error),
                        },
                    );
                    continue;
                }
                if existing_manifest.version().is_some_and(|current| current == &version) {
                    if existing != content {
                        let error =
                            format!("manifest {} changed content without a version bump", entry.id);
                        failed.push(ManifestUpdateFailure {
                            id: entry.id.clone(),
                            error: error.clone(),
                        });
                        status.agents.insert(
                            entry.id.clone(),
                            ManifestAgentStatus {
                                cached_version: Some(version_text.clone()),
                                attempted_version: Some(version_text.clone()),
                                last_checked_unix: Some(check_time),
                                last_result: "failed".into(),
                                last_error: Some(error),
                            },
                        );
                        continue;
                    }
                    current.push(entry.id.clone());
                    status.agents.insert(
                        entry.id.clone(),
                        ManifestAgentStatus {
                            cached_version: Some(version_text.clone()),
                            attempted_version: Some(version_text.clone()),
                            last_checked_unix: Some(check_time),
                            last_result: "current".into(),
                            last_error: None,
                        },
                    );
                    continue;
                }
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
            Err(error) => {
                let error = format!("read cached manifest {}: {error}", entry.id);
                failed.push(ManifestUpdateFailure { id: entry.id.clone(), error: error.clone() });
                status.agents.insert(
                    entry.id.clone(),
                    ManifestAgentStatus {
                        cached_version: cached_version(cache_dir, &entry.id),
                        attempted_version: Some(version_text.clone()),
                        last_checked_unix: Some(check_time),
                        last_result: "failed".into(),
                        last_error: Some(error),
                    },
                );
                continue;
            }
        }
        if let Err(error) = atomic_write(&path, content.as_bytes()) {
            failed.push(ManifestUpdateFailure { id: entry.id.clone(), error: error.clone() });
            status.agents.insert(
                entry.id.clone(),
                ManifestAgentStatus {
                    cached_version: cached_version(cache_dir, &entry.id),
                    attempted_version: Some(version_text.clone()),
                    last_checked_unix: Some(check_time),
                    last_result: "failed".into(),
                    last_error: Some(error),
                },
            );
            continue;
        }
        updated.push(entry.id.clone());
        status.agents.insert(
            entry.id.clone(),
            ManifestAgentStatus {
                cached_version: Some(version_text.clone()),
                attempted_version: Some(version_text),
                last_checked_unix: Some(check_time),
                last_result: "updated".into(),
                last_error: None,
            },
        );
    }
    status.last_result = Some(if failed.is_empty() {
        "ok".into()
    } else {
        format!("partial_failure:{}", failed.len())
    });
    save_status(cache_dir, &status)?;
    Ok(ManifestUpdateSummary {
        catalog_url: url.to_string(),
        cache_dir: cache_dir.to_path_buf(),
        checked,
        updated,
        current,
        failed,
        status,
    })
}

pub fn environment_catalog_url() -> String {
    std::env::var(CATALOG_URL_ENV)
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| DEFAULT_CATALOG_URL.to_string())
}

pub fn environment_cache_dir() -> PathBuf {
    if let Some(path) = std::env::var_os(CACHE_DIR_ENV).map(PathBuf::from)
        && !path.as_os_str().is_empty()
    {
        return path;
    }
    if let Some(path) = std::env::var_os("XDG_CACHE_HOME").map(PathBuf::from) {
        return path.join("cmux").join("agent-detection");
    }
    if let Some(home) = std::env::var_os("HOME").map(PathBuf::from) {
        let cache_root = if cfg!(target_os = "macos") {
            home.join("Library").join("Caches")
        } else if cfg!(windows) {
            std::env::var_os("LOCALAPPDATA")
                .map(PathBuf::from)
                .unwrap_or_else(|| home.join("AppData").join("Local"))
        } else {
            home.join(".cache")
        };
        return cache_root.join("cmux").join("agent-detection");
    }
    PathBuf::from(".cmux-agent-detection-cache")
}

pub fn status_path(cache_dir: &Path) -> PathBuf {
    cache_dir.join(STATUS_FILE_NAME)
}

pub fn load_status(cache_dir: &Path) -> ManifestUpdateStatus {
    let path = status_path(cache_dir);
    match read_status_file(&path, true) {
        Ok(Some(status)) => status,
        Ok(None) => {
            // Read the old location only when the new namespaced file does
            // not exist. This preserves existing diagnostics while allowing
            // `status.toml` to become a normal agent manifest.
            let legacy = cache_dir.join(LEGACY_STATUS_FILE_NAME);
            read_status_file(&legacy, false).ok().flatten().unwrap_or_default()
        }
        Err(()) => ManifestUpdateStatus::default(),
    }
}

fn read_status_file(path: &Path, report_invalid: bool) -> Result<Option<ManifestUpdateStatus>, ()> {
    let content = match read_bounded_utf8_file(path, MAX_FETCH_BYTES) {
        Ok(content) => content,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            eprintln!(
                "cmux-agent-screen-detection: ignoring unreadable status {}: {error}",
                path.display()
            );
            return Err(());
        }
    };
    match toml::from_str(&content) {
        Ok(status) => Ok(Some(status)),
        Err(error) => {
            if report_invalid {
                eprintln!(
                    "cmux-agent-screen-detection: ignoring invalid status {}: {error}",
                    path.display()
                );
            }
            Err(())
        }
    }
}

/// Return whether a path is owned by the updater rather than a manifest.
/// `status.toml` is treated as metadata only when it contains a valid legacy
/// status document, so an agent named `status` remains loadable.
pub(crate) fn is_status_file(path: &Path) -> bool {
    let Some(name) = path.file_name().and_then(|name| name.to_str()) else {
        return false;
    };
    if name == STATUS_FILE_NAME {
        return true;
    }
    if name != LEGACY_STATUS_FILE_NAME {
        return false;
    }
    read_bounded_utf8_file(path, MAX_FETCH_BYTES)
        .ok()
        .and_then(|content| toml::from_str::<ManifestUpdateStatus>(&content).ok())
        .is_some()
}

fn save_status(cache_dir: &Path, status: &ManifestUpdateStatus) -> Result<(), String> {
    let content = toml::to_string_pretty(status)
        .map_err(|error| format!("encode manifest update status: {error}"))?;
    atomic_write(&status_path(cache_dir), content.as_bytes())
}

fn cached_version(cache_dir: &Path, id: &str) -> Option<String> {
    let content =
        read_bounded_utf8_file(&cache_dir.join(format!("{id}.toml")), MAX_MANIFEST_BYTES).ok()?;
    compile_manifest_source(&content)
        .ok()
        .and_then(|manifest| manifest.version().map(ToString::to_string))
}

fn now_unix() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_secs()
}

pub fn default_override_dir() -> Option<PathBuf> {
    if let Some(path) = std::env::var_os("CMUX_AGENT_MANIFEST_DIR").map(PathBuf::from)
        && !path.as_os_str().is_empty()
    {
        return Some(path);
    }
    let path = std::env::var_os("XDG_CONFIG_HOME")
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("HOME").map(|home| PathBuf::from(home).join(".config")))?
        .join("cmux")
        .join("agent-detection");
    path.exists().then_some(path)
}

fn parse_catalog(content: &str) -> Result<Vec<ManifestCatalogAgent>, String> {
    let catalog: ManifestCatalog =
        toml::from_str(content).map_err(|error| format!("invalid catalog TOML: {error}"))?;
    if catalog.schema_version != 1 {
        return Err(format!("unsupported catalog schema_version {}", catalog.schema_version));
    }
    Ok(catalog.agents)
}

fn validate_catalog_entries(
    catalog: Vec<ManifestCatalogAgent>,
    base: &str,
) -> Result<Vec<ValidatedCatalogAgent>, String> {
    if catalog.len() > MAX_CATALOG_AGENTS {
        return Err(format!(
            "catalog contains {} agents, max is {MAX_CATALOG_AGENTS}",
            catalog.len()
        ));
    }
    let mut seen = BTreeSet::new();
    let mut entries = Vec::with_capacity(catalog.len());
    for entry in catalog {
        validate_agent_id(&entry.id)?;
        if entry.path.len() > MAX_CATALOG_PATH_BYTES {
            return Err(format!(
                "manifest path for {} exceeds the {MAX_CATALOG_PATH_BYTES}-byte limit",
                entry.id
            ));
        }
        if !seen.insert(entry.id.clone()) {
            return Err(format!("catalog contains duplicate agent {:?}", entry.id));
        }
        let manifest_url = join_url(base, &entry.path)?;
        entries.push(ValidatedCatalogAgent { entry, manifest_url });
    }
    Ok(entries)
}

fn validate_agent_id(id: &str) -> Result<(), String> {
    if id.is_empty()
        || id.len() > 64
        || !id.as_bytes().first().is_some_and(|byte| byte.is_ascii_alphanumeric())
        || !id.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_' || byte == b'-'
        })
    {
        return Err(format!("invalid catalog agent id {id:?}"));
    }
    Ok(())
}

fn base_url(url: &str) -> Result<String, String> {
    validate_catalog_url(url)?;
    let prefix_len = "https://".len();
    let rest = &url[prefix_len..];
    let Some(_) = rest.find('/') else {
        return Ok(url.to_string());
    };
    let Some(last_slash) = url.rfind('/') else {
        return Ok(url.to_string());
    };
    Ok(url[..last_slash].to_string())
}

fn join_url(base: &str, path: &str) -> Result<String, String> {
    if path.trim().is_empty()
        || path.len() > MAX_CATALOG_PATH_BYTES
        || path.contains("://")
        || path.starts_with('/')
        || path.contains('\\')
        || path.contains('?')
        || path.contains('#')
        || path.bytes().any(|byte| byte == 0 || byte.is_ascii_control())
        || path.split('/').any(|part| part == "..")
    {
        return Err(format!("unsafe manifest path {path:?}"));
    }
    Ok(format!("{}/{}", base.trim_end_matches('/'), path))
}

fn fetch_text(url: &str) -> Result<String, String> {
    validate_catalog_url(url)?;
    let max_bytes = MAX_FETCH_BYTES.to_string();
    let mut child = Command::new("curl")
        .args([
            "-sfL",
            "--proto",
            "=https",
            "--proto-redir",
            "=https",
            "--retry",
            "2",
            "--connect-timeout",
            "5",
            "--max-time",
            "15",
            "--max-filesize",
            &max_bytes,
            url,
        ])
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("curl failed: {error}"))?;
    let mut bytes = Vec::new();
    let read_result = {
        let Some(stdout) = child.stdout.as_mut() else {
            let _ = child.kill();
            let _ = child.wait();
            return Err("curl stdout was not captured".into());
        };
        stdout.take((MAX_FETCH_BYTES + 1) as u64).read_to_end(&mut bytes)
    };
    if let Err(error) = read_result {
        // Reap curl on every read failure. Returning while it still owns the
        // pipe can leak a child and leave a network process behind the plugin.
        let _ = child.kill();
        let _ = child.wait();
        return Err(format!("read curl response: {error}"));
    }
    if bytes.len() > MAX_FETCH_BYTES {
        // Stop curl before waiting. Without this, a server that omits
        // Content-Length can keep writing into a full pipe while the parent
        // waits forever for the child to exit.
        let _ = child.kill();
    }
    let status = child.wait().map_err(|error| format!("wait for curl: {error}"))?;
    if bytes.len() > MAX_FETCH_BYTES {
        return Err(format!("response exceeded {MAX_FETCH_BYTES} bytes"));
    }
    if !status.success() {
        return Err(format!("curl exited with {status}"));
    }
    String::from_utf8(bytes).map_err(|error| format!("response was not UTF-8: {error}"))
}

fn validate_catalog_url(url: &str) -> Result<(), String> {
    let trimmed = url.trim();
    if url != trimmed
        || url.len() > MAX_CATALOG_URL_BYTES
        || !trimmed.starts_with("https://")
        || trimmed.contains('?')
        || trimmed.contains('#')
        || trimmed
            .bytes()
            .any(|byte| byte == 0 || byte.is_ascii_control() || byte.is_ascii_whitespace())
    {
        return Err("manifest catalog URL must be an HTTPS URL without credentials".into());
    }
    let rest = &trimmed["https://".len()..];
    let authority_end = rest.find('/').unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    validate_https_authority(authority)?;
    Ok(())
}

/// Validate the small HTTPS URL surface accepted by the updater. A strict
/// authority parser avoids handing credentials, malformed ports, or shell
/// metacharacters to curl. IPv6 literals are intentionally not accepted until
/// the updater has a URL parser with equivalent bounds and tests.
fn validate_https_authority(authority: &str) -> Result<(), String> {
    if authority.is_empty() || authority.len() > 255 || authority.contains('@') {
        return Err("manifest catalog URL must include a valid host".into());
    }
    if authority.bytes().filter(|byte| *byte == b':').count() > 1 {
        return Err("manifest catalog URL must include a valid host".into());
    }
    let (host, _port) = if let Some((host, port)) = authority.rsplit_once(':') {
        if port.is_empty() || !port.bytes().all(|byte| byte.is_ascii_digit()) {
            return Err("manifest catalog URL must include a valid host".into());
        }
        let port = port
            .parse::<u16>()
            .ok()
            .filter(|port| *port != 0)
            .ok_or_else(|| "manifest catalog URL must include a valid host".to_string())?;
        (host, Some(port))
    } else {
        (authority, None)
    };
    if host.is_empty() {
        return Err("manifest catalog URL must include a valid host".into());
    }
    for label in host.split('.') {
        if label.is_empty()
            || label.starts_with('-')
            || label.ends_with('-')
            || !label.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        {
            return Err("manifest catalog URL must include a valid host".into());
        }
    }
    Ok(())
}

fn atomic_write(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path.parent().ok_or_else(|| format!("path {} has no parent", path.display()))?;
    fs::create_dir_all(parent).map_err(|error| format!("create {}: {error}", parent.display()))?;
    let tmp = parent.join(format!(
        ".{}.{}-{}.tmp",
        path.file_name().and_then(|name| name.to_str()).unwrap_or("manifest"),
        std::process::id(),
        now_nanos()
    ));
    let result = (|| {
        // Do not follow or overwrite a pre-existing temporary symlink. The
        // cache may live in a shared user directory, so the write itself must
        // be race-safe even though the final rename is atomic.
        let mut file = fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&tmp)
            .map_err(|error| error.to_string())?;
        file.write_all(bytes).map_err(|error| error.to_string())?;
        file.sync_all().map_err(|error| error.to_string())?;
        fs::rename(&tmp, path).map_err(|error| error.to_string())?;
        // A durable file rename also needs its parent directory flushed. The
        // rename already committed the new content, so a directory-sync error
        // is a durability warning, not an update failure that callers could
        // safely roll back.
        if let Err(error) = fs::File::open(parent).and_then(|directory| directory.sync_all()) {
            eprintln!(
                "cmux-agent-screen-detection: committed {}, but could not flush its parent directory: {error}",
                path.display()
            );
        }
        Ok::<(), String>(())
    })();
    if result.is_err() {
        let _ = fs::remove_file(&tmp);
    }
    result
}

fn now_nanos() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap_or_default().as_nanos()
}

pub fn summary_json(summary: &ManifestUpdateSummary) -> serde_json::Value {
    serde_json::json!({
        "catalog_url": summary.catalog_url,
        "cache_dir": summary.cache_dir,
        "checked": summary.checked,
        "updated": summary.updated,
        "current": summary.current,
        "failed": summary.failed.iter().map(|failure| serde_json::json!({
            "id": failure.id,
            "error": failure.error,
        })).collect::<Vec<_>>(),
        "status": summary.status,
    })
}

pub fn status_json(cache_dir: &Path) -> serde_json::Value {
    serde_json::to_value(load_status(cache_dir)).unwrap_or_else(|_| serde_json::json!({}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn catalog_paths_reject_traversal_and_absolute_urls() {
        assert!(join_url("https://example.test/catalog", "codex.toml").is_ok());
        assert!(join_url("https://example.test/catalog", "../codex.toml").is_err());
        assert!(join_url("https://example.test/catalog", "/codex.toml").is_err());
        assert!(join_url("https://example.test/catalog", "https://evil.test/x").is_err());
    }

    #[test]
    fn catalog_urls_require_a_bounded_https_authority() {
        assert!(validate_catalog_url("https://example.test/catalog/index.toml").is_ok());
        assert!(validate_catalog_url("https://example.test:443/catalog/index.toml").is_ok());
        assert!(validate_catalog_url("https://127.0.0.1/catalog/index.toml").is_ok());
        for invalid in [
            "http://example.test/catalog/index.toml",
            "https://",
            "https:///catalog/index.toml",
            "https://user@example.test/catalog/index.toml",
            "https://example..test/catalog/index.toml",
            "https://-example.test/catalog/index.toml",
            "https://example-.test/catalog/index.toml",
            "https://example.test:0/catalog/index.toml",
            "https://example.test:65536/catalog/index.toml",
            "https://[::1]/catalog/index.toml",
            " https://example.test/catalog/index.toml",
            "https://example.test/catalog/index.toml?token=1",
            "https://example.test/catalog/index.toml#fragment",
            "https://example.test\\catalog\\index.toml",
        ] {
            assert!(validate_catalog_url(invalid).is_err(), "{invalid:?}");
        }
    }

    #[test]
    fn catalog_ids_are_bounded_and_normalized() {
        assert!(validate_agent_id("codex").is_ok());
        assert!(validate_agent_id("screen_detector").is_ok());
        assert!(validate_agent_id("screen-detector").is_ok());
        assert!(validate_agent_id("status").is_ok());
        assert!(validate_agent_id("bad id").is_err());
        assert!(validate_agent_id("A").is_err());
        assert!(validate_agent_id("-codex").is_err());
    }

    #[test]
    fn catalog_shape_is_validated_before_network_fetches() {
        let duplicate = vec![
            ManifestCatalogAgent { id: "codex".into(), path: "codex.toml".into() },
            ManifestCatalogAgent { id: "codex".into(), path: "other.toml".into() },
        ];
        assert!(validate_catalog_entries(duplicate, "https://example.test/catalog").is_err());

        let unsafe_path =
            vec![ManifestCatalogAgent { id: "codex".into(), path: "../codex.toml".into() }];
        assert!(validate_catalog_entries(unsafe_path, "https://example.test/catalog").is_err());

        let valid = vec![ManifestCatalogAgent { id: "codex".into(), path: "codex.toml".into() }];
        let entries = validate_catalog_entries(valid, "https://example.test/catalog").unwrap();
        assert_eq!(entries[0].manifest_url, "https://example.test/catalog/codex.toml");

        let too_long_path = vec![ManifestCatalogAgent {
            id: "codex".into(),
            path: "x".repeat(MAX_CATALOG_PATH_BYTES + 1),
        }];
        assert!(validate_catalog_entries(too_long_path, "https://example.test/catalog").is_err());

        let too_many = (0..=MAX_CATALOG_AGENTS)
            .map(|index| ManifestCatalogAgent {
                id: format!("agent-{index}"),
                path: format!("agent-{index}.toml"),
            })
            .collect();
        assert!(validate_catalog_entries(too_many, "https://example.test/catalog").is_err());
    }

    #[cfg(unix)]
    #[test]
    fn catalog_updates_hold_an_exclusive_cache_lock() {
        let directory = std::env::temp_dir().join(format!(
            "cmux-agent-update-lock-{}-{}",
            std::process::id(),
            now_nanos()
        ));
        let first = UpdateLock::acquire(&directory).expect("first updater acquires the lock");
        assert!(
            UpdateLock::acquire(&directory).is_err(),
            "a second updater must not race the first cache transaction"
        );
        drop(first);
        assert!(UpdateLock::acquire(&directory).is_ok(), "the lock must release on drop");
        let _ = std::fs::remove_dir_all(directory);
    }
}
