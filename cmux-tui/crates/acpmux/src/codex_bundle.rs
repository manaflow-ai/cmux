//! The opt-in bundled Codex app-server (Labs `labs.bundledCodexAppServer`, off
//! by default; plans/next-ux/ux-harness-health.md, "Optional bundled Codex
//! app-server design").
//!
//! Off, nothing here runs and a Codex chat starts the installed `codex` as
//! before. On, a chat whose profile runs plain `codex app-server` starts the
//! app-server cmux ships instead, when the bundle is whole: its manifest
//! (`manifest.json` in the app-owned bundle folder) names the binary inside
//! that folder, its version, its sha256 and the protocol it speaks; the file's
//! hash matches, `--version` prints that version and the protocol is one this
//! acpmux speaks. Anything else falls back to the installed CLI and says why
//! on the harness health row (`Health`). A profile that names its own program
//! (an absolute path, a renamed build) or listens on anything but stdio is
//! never taken over.
//!
//! The hash and version check run once per binary: a passed check is kept by
//! (path, size, modified time), so each new chat pays a `stat`, not a hash.

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashMap;
use std::io::Read;
use std::path::{Component, Path, PathBuf};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::SystemTime;

/// The Labs switch.
pub const SETTING: &str = "labs.bundledCodexAppServer";
/// The manifest's file name in the bundle folder.
pub const MANIFEST: &str = "manifest.json";
/// The app-server protocol versions this acpmux's translator speaks.
pub const PROTOCOLS: &[u32] = &[2];
/// Overrides the bundle folder (tests, the bench, a dev build's own bundle).
pub const DIR_ENV: &str = "ACPMUX_CODEX_BUNDLE_DIR";

/// The pinned bundle, as `manifest.json` describes it.
#[derive(Deserialize, Serialize, Clone, Debug, PartialEq, Eq)]
pub struct Manifest {
    pub version: String,
    /// The binary, relative to the bundle folder.
    pub path: String,
    /// Lowercase hex sha256 of the binary.
    pub sha256: String,
    /// The app-server protocol version the binary speaks.
    pub protocol: u32,
}

/// Which app-server a Codex chat starts.
#[derive(Serialize, Deserialize, Clone, Copy, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum Source {
    Bundled,
    Installed,
}

/// What the harness health row says about the bundle while the switch is on.
#[derive(Serialize, Deserialize, Clone, Debug, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct Health {
    pub source: Source,
    /// The bundle's version, when its manifest could be read.
    pub bundled_version: Option<String>,
    /// The protocol the bundle speaks, when its manifest could be read.
    pub protocol: Option<u32>,
    /// Why the installed CLI runs instead (missing bundle, hash mismatch...).
    pub fallback: Option<String>,
}

/// The result of resolving one launch.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolution {
    /// The switch is off: nothing changes and the health row says nothing.
    Off,
    /// Start the installed CLI; `why` is shown on the health row.
    Installed { why: String, manifest: Option<Manifest> },
    /// Start this binary in place of the profile's `codex`.
    Bundled { program: PathBuf, manifest: Manifest },
}

impl Resolution {
    /// The health row's view; None while the switch is off.
    pub fn health(&self) -> Option<Health> {
        match self {
            Self::Off => None,
            Self::Installed { why, manifest } => Some(Health {
                source: Source::Installed,
                bundled_version: manifest.as_ref().map(|m| m.version.clone()),
                protocol: manifest.as_ref().map(|m| m.protocol),
                fallback: Some(why.clone()),
            }),
            Self::Bundled { manifest, .. } => Some(Health {
                source: Source::Bundled,
                bundled_version: Some(manifest.version.clone()),
                protocol: Some(manifest.protocol),
                fallback: None,
            }),
        }
    }
}

/// Whether the person turned the switch on in the settings file. Read at each
/// use, so the next new chat follows a change.
pub fn enabled_in_settings() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => {
            crate::user_settings::value(&doc, SETTING).and_then(|v| v.as_bool()) == Some(true)
        }
        _ => false,
    }
}

/// The app-owned bundle folder: `ACPMUX_CODEX_BUNDLE_DIR`, else
/// `<data dir>/<NEXT_DIR>/codex-app-server` (`Application Support/cmux-next/...`
/// on macOS, [`cmux_config::NEXT_DIR`]).
pub fn bundle_dir() -> Option<PathBuf> {
    if let Some(dir) = std::env::var_os(DIR_ENV).filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(dir));
    }
    dirs::data_dir().map(|d| d.join(cmux_config::NEXT_DIR).join("codex-app-server"))
}

/// The launch for `argv` as the settings and the bundle folder say now.
pub fn resolve_now(argv: &[String]) -> Resolution {
    let on = enabled_in_settings();
    resolve(on, bundle_dir().as_deref(), argv)
}

/// The launch for `argv`: `on` is the switch, `dir` the bundle folder.
pub fn resolve(on: bool, dir: Option<&Path>, argv: &[String]) -> Resolution {
    if !on {
        return Resolution::Off;
    }
    let installed = |why: &str, manifest: Option<Manifest>| Resolution::Installed {
        why: why.to_owned(),
        manifest,
    };
    if let Some(why) = keeps_its_own(argv) {
        return installed(why, None);
    }
    let Some(dir) = dir else { return installed("no bundle folder on this machine", None) };
    let manifest = match read_manifest(dir) {
        Ok(m) => m,
        Err(why) => return installed(&why, None),
    };
    if !PROTOCOLS.contains(&manifest.protocol) {
        let why =
            format!("bundle speaks protocol {}; this cmux speaks {PROTOCOLS:?}", manifest.protocol);
        return installed(&why, Some(manifest));
    }
    let Some(program) = inside(dir, &manifest.path) else {
        return installed("bundle path leaves its folder", Some(manifest));
    };
    match verify(&program, &manifest) {
        Ok(()) => Resolution::Bundled { program, manifest },
        Err(why) => installed(&why, Some(manifest)),
    }
}

/// Why a profile keeps its own app-server: it names a program of its own, or
/// its app-server listens elsewhere than stdio (an existing external server).
fn keeps_its_own(argv: &[String]) -> Option<&'static str> {
    let program = argv.first()?;
    if program != "codex" {
        return Some("the profile names its own codex");
    }
    let listens_elsewhere = argv
        .windows(2)
        .any(|w| matches!(w, [flag, value] if flag == "--listen" && value != "stdio://"))
        || argv.iter().any(|a| a.strip_prefix("--listen=").is_some_and(|v| v != "stdio://"));
    listens_elsewhere.then_some("the profile's app-server listens elsewhere")
}

fn read_manifest(dir: &Path) -> Result<Manifest, String> {
    let path = dir.join(MANIFEST);
    let body = match std::fs::read(&path) {
        Ok(body) => body,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            return Err("no bundle installed".into());
        }
        Err(e) => return Err(format!("bundle manifest unreadable: {e}")),
    };
    serde_json::from_slice(&body).map_err(|e| format!("bundle manifest invalid: {e}"))
}

/// `rel` under `dir`, refusing an absolute path or `..`.
fn inside(dir: &Path, rel: &str) -> Option<PathBuf> {
    let rel = Path::new(rel);
    rel.components().all(|c| matches!(c, Component::Normal(_))).then(|| dir.join(rel))
}

/// What a passed check is kept by: the file as it was when it passed.
#[derive(Clone, PartialEq, Eq, Hash)]
struct Stamp {
    path: PathBuf,
    len: u64,
    modified: Option<SystemTime>,
    sha256: String,
    version: String,
}

fn passed() -> &'static Mutex<HashMap<PathBuf, Stamp>> {
    static PASSED: OnceLock<Mutex<HashMap<PathBuf, Stamp>>> = OnceLock::new();
    PASSED.get_or_init(Default::default)
}

/// The binary's hash and `--version` match the manifest. A passed check is
/// reused while the file's size and modified time stay the same.
fn verify(program: &Path, manifest: &Manifest) -> Result<(), String> {
    let meta = std::fs::metadata(program).map_err(|e| format!("bundle binary missing: {e}"))?;
    let stamp = Stamp {
        path: program.to_owned(),
        len: meta.len(),
        modified: meta.modified().ok(),
        sha256: manifest.sha256.to_ascii_lowercase(),
        version: manifest.version.clone(),
    };
    let cache = passed();
    if cache.lock().unwrap_or_else(PoisonError::into_inner).get(program) == Some(&stamp) {
        return Ok(());
    }
    let actual = sha256_file(program).map_err(|e| format!("bundle binary unreadable: {e}"))?;
    if actual != stamp.sha256 {
        return Err("bundle binary does not match its manifest's sha256".into());
    }
    handshake(program, &manifest.version)?;
    cache.lock().unwrap_or_else(PoisonError::into_inner).insert(program.to_owned(), stamp);
    Ok(())
}

/// The binary answers `--version` with the manifest's version.
fn handshake(program: &Path, version: &str) -> Result<(), String> {
    let path = program.to_str().ok_or("bundle path is not UTF-8")?;
    let printed = crate::harness_health::probe::installed_version(path)?;
    (printed == version)
        .then_some(())
        .ok_or_else(|| format!("bundle prints version {printed}; its manifest says {version}"))
}

/// Lowercase hex sha256 of a file.
pub fn sha256_file(path: &Path) -> std::io::Result<String> {
    let mut file = std::fs::File::open(path)?;
    let mut hash = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    loop {
        let n = file.read(&mut buf)?;
        if n == 0 {
            break;
        }
        hash.update(buf.get(..n).unwrap_or_default());
    }
    Ok(format!("{:x}", hash.finalize()))
}

/// The command line a `codex app-server` profile starts with: None (its own
/// argv) while the switch is off or the bundle falls back. The check runs off
/// the async workers: a cold one hashes the binary.
pub async fn launch_for(argv: &[String]) -> Option<(String, Vec<String>)> {
    if !enabled_in_settings() {
        return None;
    }
    let owned = argv.to_vec();
    let dir = bundle_dir();
    let resolution =
        tokio::task::spawn_blocking(move || resolve(true, dir.as_deref(), &owned)).await.ok()?;
    match resolution {
        Resolution::Bundled { program, manifest } => {
            tracing::info!(version = %manifest.version, "codex: bundled app-server");
            Some(command_line(&program, argv))
        }
        Resolution::Installed { why, .. } => {
            tracing::info!(%why, "codex: installed app-server");
            None
        }
        Resolution::Off => None,
    }
}

/// The profile's command line with the bundled program in place of `codex`,
/// as `ChildAgent::spawn_with`'s `command_line`.
pub fn command_line(program: &Path, argv: &[String]) -> (String, Vec<String>) {
    (program.to_string_lossy().into_owned(), argv.iter().skip(1).cloned().collect())
}

#[cfg(test)]
#[path = "codex_bundle_tests.rs"]
mod tests;
