//! Owner-only external Codex access-token handoff.
//!
//! The native app may refresh this file on an owner VM.  It contains only a
//! short-lived access token; the refresh token and Codex auth cache stay on the
//! user's machine.  A missing file means the normal Codex login path is used.

use anyhow::{Result, anyhow, ensure};
use serde_json::Value;
use std::fs::OpenOptions;
use std::io::Read;
use std::os::unix::{fs::MetadataExt, fs::OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};

const MAX_BYTES: u64 = 8 * 1024;
const MIN_LIFETIME_S: u64 = 60;

#[derive(Clone)]
pub struct AccessFile {
    pub access_token: String,
    pub account_id: String,
    pub expires_at: u64,
    pub modified: std::time::SystemTime,
}

pub fn path() -> Option<PathBuf> {
    std::env::var_os("CMUX_CODEX_BROKER_ACCESS").map(PathBuf::from).or_else(|| {
        std::env::var_os("HOME")
            .map(|home| PathBuf::from(home).join(".config/cmux/codex-broker/access.json"))
    })
}

/// Read an installed handoff. Missing is intentionally distinct from invalid:
/// the former preserves existing login behavior, while the latter fails closed.
pub fn read() -> Result<Option<AccessFile>> {
    let Some(path) = path() else { return Ok(None) };
    read_at(&path, Path::new("/etc/cmux/vm-kind"))
}

/// Read a broker file with an explicit owner marker. Tests use a temporary
/// marker rather than mutating the process environment or relying on /etc.
pub fn read_at(path: &Path, owner_marker: &Path) -> Result<Option<AccessFile>> {
    match std::fs::symlink_metadata(path) {
        Ok(metadata) => {
            ensure!(!metadata.file_type().is_symlink(), "Codex broker path is a symlink")
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(error) => return Err(error.into()),
    }
    validate_owner_marker(owner_marker)?;
    let file = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)?;
    let metadata = file.metadata()?;
    // SAFETY: getuid has no preconditions.
    ensure!(
        metadata.is_file() && metadata.uid() == unsafe { libc::getuid() },
        "Codex broker file owner mismatch"
    );
    ensure!(metadata.mode() & 0o077 == 0, "Codex broker file is not private");
    ensure!(metadata.len() <= MAX_BYTES, "Codex broker file is too large");
    let modified = metadata.modified().unwrap_or(SystemTime::UNIX_EPOCH);
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(MAX_BYTES + 1).read_to_end(&mut bytes)?;
    ensure!(bytes.len() as u64 <= MAX_BYTES, "Codex broker file is too large");
    let value: Value =
        serde_json::from_slice(&bytes).map_err(|_| anyhow!("Codex broker file is invalid"))?;
    ensure!(
        value["schema"] == 1 && value["bridge"] == "codex-external-access-v1",
        "Codex broker file version is unsupported"
    );
    let access_token = value["accessToken"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| anyhow!("Codex access token missing"))?
        .to_owned();
    let account_id = value["chatgptAccountId"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| anyhow!("Codex account id missing"))?
        .to_owned();
    let expires_at =
        value["expiresAt"].as_u64().ok_or_else(|| anyhow!("Codex access expiry missing"))?;
    let now = SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs();
    ensure!(expires_at > now + MIN_LIFETIME_S, "Codex access token is expired");
    Ok(Some(AccessFile { access_token, account_id, expires_at, modified }))
}

pub fn changed_since(modified: SystemTime) -> bool {
    let Some(path) = path() else { return false };
    std::fs::metadata(path).and_then(|m| m.modified()).map_or(true, |m| m != modified)
}

fn validate_owner_marker(path: &Path) -> Result<()> {
    let metadata = std::fs::symlink_metadata(path)
        .map_err(|_| anyhow!("Codex broker requires an owner VM"))?;
    ensure!(metadata.is_file(), "Codex broker owner marker is not a file");
    if path == Path::new("/etc/cmux/vm-kind") {
        ensure!(metadata.uid() == 0, "Codex broker owner marker is not root-owned");
        ensure!(
            matches!(
                std::fs::symlink_metadata("/srv/team"),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound
            ),
            "Codex broker is unavailable on a shared VM"
        );
    }
    let kind =
        std::fs::read_to_string(path).map_err(|_| anyhow!("Codex broker requires an owner VM"))?;
    ensure!(kind.trim() == "owner", "Codex broker requires an owner VM");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt;

    #[test]
    fn missing_file_is_disabled() {
        let dir =
            std::env::temp_dir().join(format!("cmux-codex-broker-test-{}", uuid::Uuid::now_v7()));
        let file = dir.join("missing.json");
        let marker = dir.join("vm-kind");
        std::fs::create_dir_all(&dir).unwrap();
        std::fs::write(&marker, "shared\n").unwrap();
        assert!(read_at(&file, &marker).unwrap().is_none());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn file_shape_requires_private_owner_marker() {
        let dir =
            std::env::temp_dir().join(format!("cmux-codex-broker-test-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("access.json");
        let marker = dir.join("vm-kind");
        std::fs::write(&marker, "owner\n").unwrap();
        std::fs::write(&file, r#"{"schema":1,"bridge":"codex-external-access-v1","accessToken":"a","chatgptAccountId":"acct","expiresAt":4102444800}"#).unwrap();
        std::fs::set_permissions(&file, std::fs::Permissions::from_mode(0o644)).unwrap();
        assert!(read_at(&file, &marker).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}
