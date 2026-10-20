//! cmux-mobile-host configuration, read from the environment (README.md lists
//! every variable).

use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};

use crate::auth::{DEFAULT_STACK_API, DEFAULT_STACK_PROJECT, TokenSource};
use crate::control::{AcpmuxEndpoint, Supplied};

/// Where the `acpmux` service connects.
#[derive(Debug, Clone)]
pub enum AcpmuxTarget {
    /// Read `websocket.listen` and `websocket.token` from
    /// `<home>/config.json` at every open (the port can move).
    Home(PathBuf),
    /// A fixed URL and token (tests).
    Fixed { url: String, token: Option<String> },
    /// The endpoint the supervising app reports over stdin (`control`).
    Supplied(tokio::sync::watch::Receiver<AcpmuxEndpoint>),
}

/// What the link services may reach.
#[derive(Debug, Clone)]
pub struct ServiceConfig {
    /// `$TMPDIR/cmux-tui-<uid>`: the cmux-tui session sockets.
    pub tui_socket_dir: PathBuf,
    pub default_session: String,
    /// The default session's socket when it is not `<dir>/<session>.sock`
    /// (`CMUX_MOBILE_TUI_SOCKET`: the app's own daemon socket). A phone that names
    /// a session still gets `<dir>/<session>.sock`.
    pub default_socket: Option<PathBuf>,
    /// Workspace roots the `file` service may read below. Empty denies all.
    pub file_roots: Vec<PathBuf>,
    pub acpmux: AcpmuxTarget,
    /// Supervised: only phones the Mac approved are served (`pairing.rs`).
    /// None (unsupervised): every admitted link is served.
    pub pairing: Option<crate::pairing::Pairing>,
    /// `CMUX_MOBILE_AGENT_TAB_HOST`: the `agent_session.host` this Mac's app records
    /// on its own agent tabs (`install:<id>`). Unset: no agent tabs from a phone.
    pub agent_tab_host: Option<String>,
    /// `CMUX_MOBILE_UPLOADS_DIR` (default `<state>/uploads`): where the `upload`
    /// service writes a file that has no workspace folder, one folder per
    /// link session.
    pub uploads_dir: PathBuf,
    /// `CMUX_MOBILE_UPLOAD_MAX_BYTES`: the largest file one `upload` accepts.
    pub upload_max_bytes: u64,
    /// The Chief's conversation owner socket (the `chief` service):
    /// `CMUX_MOBILE_CHIEF_SOCKET`, else `<tui_socket_dir>/<CMUX_MOBILE_CHIEF_SESSION>.sock`,
    /// else the session of `~/.cmux/chief/<CMUX_NEXT_CHIEF_ACCOUNT or default>`
    /// (`ChiefHome` in the Mac app). None turns the service off.
    pub chief_socket: Option<PathBuf>,
    /// The `browser` service: who starts browser hosts, and the running ones.
    pub browser: crate::browser::BrowserConfig,
}

/// The default `upload` size cap: 100 MiB.
pub const DEFAULT_UPLOAD_MAX_BYTES: u64 = 100 * 1024 * 1024;
/// `ChiefHome.sessionName`: `cmux-chief-` and the FNV-1a 32 hash of the
/// home's path, so hostd finds the owner every Mac build shares.
pub fn chief_session_name(root: &Path) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in root.to_string_lossy().as_bytes() {
        hash ^= u32::from(*byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("cmux-chief-{hash:08x}")
}

/// The Chief owner socket from the environment (see [`ServiceConfig::chief_socket`]).
pub fn chief_socket(tui_socket_dir: &Path) -> PathBuf {
    if let Some(socket) = env("CMUX_MOBILE_CHIEF_SOCKET") {
        return PathBuf::from(socket);
    }
    let session = env("CMUX_MOBILE_CHIEF_SESSION").unwrap_or_else(|| {
        let account = env("CMUX_NEXT_CHIEF_ACCOUNT").unwrap_or_else(|| "default".into());
        chief_session_name(&home().join(".cmux/chief").join(account))
    });
    tui_socket_dir.join(format!("{session}.sock"))
}

#[derive(Debug, Clone)]
pub struct HostConfig {
    pub base_url: String,
    pub team_id: String,
    pub device_id: String,
    pub device_name: String,
    pub tokens: TokenSource,
    /// The Stack user whose phones may dial; defaults to the token's `sub`.
    pub owner_user_id: Option<String>,
    pub include_loopback: bool,
    /// Never offer or use 100.64.0.0/10 (Tailscale) addresses.
    pub exclude_cgnat: bool,
    pub services: ServiceConfig,
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().map(|v| v.trim().to_owned()).filter(|v| !v.is_empty())
}

fn env_or_file(name: &str) -> Result<Option<String>> {
    if let Some(value) = env(name) {
        return Ok(Some(value));
    }
    if let Some(path) = env(&format!("{name}_FILE")) {
        let text = std::fs::read_to_string(&path).with_context(|| format!("reading {name}_FILE {path}"))?;
        return Ok(Some(text.trim().to_owned()).filter(|v| !v.is_empty()));
    }
    Ok(None)
}

pub fn default_tui_socket_dir() -> PathBuf {
    let tmp = std::env::var_os("TMPDIR").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("/tmp"));
    // SAFETY: getuid has no preconditions and cannot fail.
    let uid = unsafe { libc::getuid() };
    tmp.join(format!("cmux-tui-{uid}"))
}

fn home() -> PathBuf {
    std::env::var_os("HOME").map(PathBuf::from).unwrap_or_else(|| PathBuf::from("."))
}

pub fn default_state_dir() -> PathBuf {
    env("CMUX_MOBILE_STATE_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join("Library/Application Support/cmux-mobile-host"))
}

fn hostname() -> String {
    let mut buffer = [0u8; 256];
    // SAFETY: the buffer is valid for its length; gethostname NUL-terminates
    // on success when the name fits.
    let ok = unsafe { libc::gethostname(buffer.as_mut_ptr().cast(), buffer.len()) } == 0;
    let end = buffer.iter().position(|&b| b == 0).unwrap_or(0);
    if ok && end > 0 { String::from_utf8_lossy(&buffer[..end]).into_owned() } else { "Mac".into() }
}

/// A persistent device id: a UUID stored in `<state>/device-id`.
pub fn persistent_device_id(state_dir: &Path) -> Result<String> {
    let path = state_dir.join("device-id");
    if let Ok(text) = std::fs::read_to_string(&path)
        && let Ok(id) = uuid::Uuid::parse_str(text.trim())
    {
        return Ok(id.to_string());
    }
    std::fs::create_dir_all(state_dir).with_context(|| format!("creating {}", state_dir.display()))?;
    let id = uuid::Uuid::new_v4().to_string();
    std::fs::write(&path, &id).with_context(|| format!("writing {}", path.display()))?;
    Ok(id)
}

impl HostConfig {
    /// Reads the environment. `supplied` (supervised mode) replaces the token
    /// variables and the acpmux lookup with what the app sends over stdin.
    pub fn from_env(supplied: Option<Supplied>) -> Result<Self> {
        let base_url = env("CMUX_MOBILE_BASE_URL").context("CMUX_MOBILE_BASE_URL is required")?;
        let team_id = env("CMUX_MOBILE_TEAM_ID").context("CMUX_MOBILE_TEAM_ID is required")?;
        let tokens = if let Some(supplied) = &supplied {
            TokenSource::Supplied(supplied.token.clone())
        } else if let Some(refresh_token) = env_or_file("CMUX_MOBILE_REFRESH_TOKEN")? {
            TokenSource::Refresh {
                refresh_token,
                project_id: env("CMUX_MOBILE_STACK_PROJECT_ID").unwrap_or_else(|| DEFAULT_STACK_PROJECT.into()),
                publishable_key: env("CMUX_MOBILE_STACK_PUBLISHABLE_KEY"),
                api: env("CMUX_MOBILE_STACK_API").unwrap_or_else(|| DEFAULT_STACK_API.into()),
            }
        } else if let Some(token) = env_or_file("CMUX_MOBILE_ACCESS_TOKEN")? {
            TokenSource::Access(token)
        } else {
            bail!("set CMUX_MOBILE_REFRESH_TOKEN(_FILE) or CMUX_MOBILE_ACCESS_TOKEN(_FILE)");
        };
        let device_id = match env("CMUX_MOBILE_DEVICE_ID") {
            Some(id) => id,
            None => persistent_device_id(&default_state_dir())?,
        };
        let acpmux = match (env("CMUX_MOBILE_ACPMUX_URL"), &supplied) {
            (Some(url), _) => AcpmuxTarget::Fixed { url, token: env("CMUX_MOBILE_ACPMUX_TOKEN") },
            (None, Some(supplied)) => AcpmuxTarget::Supplied(supplied.acpmux.clone()),
            (None, None) => AcpmuxTarget::Home(
                env("ACPMUX_HOME").map(PathBuf::from).unwrap_or_else(|| home().join(".acpmux")),
            ),
        };
        let pairing = supplied.as_ref().map(|supplied| {
            crate::pairing::Pairing::new(
                device_id.clone(),
                supplied.devices.clone(),
                std::sync::Arc::new(|event| crate::control::emit(&event)),
            )
            .with_identity(supplied.identity.clone())
        });
        let max_tabs = env("CMUX_MOBILE_RB_MAX_TABS").and_then(|v| v.parse().ok()).unwrap_or(4);
        let browser = match (&supplied, env("CMUX_MOBILE_RB_HOST")) {
            // Supervised: the app starts its own bundled browser host, when this
            // build has one (`CMUX_MOBILE_BROWSER_HOSTS=1`; Release builds ship none yet).
            (Some(supplied), _) if env("CMUX_MOBILE_BROWSER_HOSTS").as_deref() == Some("1") => {
                crate::browser::BrowserConfig::new(Some(supplied.browser.launcher()), max_tabs)
            }
            (Some(_), _) => crate::browser::BrowserConfig::new(None, max_tabs),
            (None, Some(exe)) => crate::browser::BrowserConfig::process(
                PathBuf::from(exe),
                env("CMUX_MOBILE_RB_CACHE_DIR")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| default_state_dir().join("browser")),
                max_tabs,
            ),
            (None, None) => crate::browser::BrowserConfig::default(),
        };
        let file_roots = env("CMUX_MOBILE_FILE_ROOTS")
            .map(|roots| roots.split(':').filter(|r| !r.is_empty()).map(PathBuf::from).collect())
            .unwrap_or_default();
        Ok(Self {
            base_url,
            team_id,
            device_id,
            device_name: env("CMUX_MOBILE_DEVICE_NAME").unwrap_or_else(hostname),
            tokens,
            owner_user_id: env("CMUX_MOBILE_OWNER_USER_ID"),
            include_loopback: env("CMUX_MOBILE_INCLUDE_LOOPBACK").is_some_and(|v| v == "1"),
            exclude_cgnat: env("CMUX_MOBILE_EXCLUDE_CGNAT").is_some_and(|v| v == "1"),
            services: ServiceConfig {
                chief_socket: Some(chief_socket(
                    &env("CMUX_MOBILE_TUI_SOCKET_DIR").map(PathBuf::from).unwrap_or_else(default_tui_socket_dir),
                )),
                tui_socket_dir: env("CMUX_MOBILE_TUI_SOCKET_DIR")
                    .map(PathBuf::from)
                    .unwrap_or_else(default_tui_socket_dir),
                default_session: env("CMUX_MOBILE_TUI_SESSION").unwrap_or_else(|| "main".into()),
                default_socket: env("CMUX_MOBILE_TUI_SOCKET").map(PathBuf::from),
                file_roots,
                acpmux,
                pairing,
                agent_tab_host: env("CMUX_MOBILE_AGENT_TAB_HOST"),
                uploads_dir: env("CMUX_MOBILE_UPLOADS_DIR")
                    .map(PathBuf::from)
                    .unwrap_or_else(|| default_state_dir().join("uploads")),
                upload_max_bytes: env("CMUX_MOBILE_UPLOAD_MAX_BYTES")
                    .and_then(|v| v.parse().ok())
                    .unwrap_or(DEFAULT_UPLOAD_MAX_BYTES),
                browser,
            },
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The Mac app's `ChiefHome.sessionName` for the same home.
    #[test]
    fn chief_session_matches_the_mac_app() {
        assert_eq!(chief_session_name(Path::new("/Users/me/.cmux/chief/default")), "cmux-chief-2fcbc999");
    }
}
