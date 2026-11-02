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
    /// The Chief's conversation owner socket (the `chief` service):
    /// `CMUX_MOBILE_CHIEF_SOCKET`, else `<tui_socket_dir>/<CMUX_MOBILE_CHIEF_SESSION>.sock`,
    /// else the session of `~/.cmux/chief/<CMUX_NEXT_CHIEF_ACCOUNT or default>`
    /// (`ChiefHome` in the Mac app). None turns the service off.
    pub chief_socket: Option<PathBuf>,
    /// The `browser` service: who starts browser hosts, and the running ones.
    pub browser: crate::browser::BrowserConfig,
    /// The `surface` service: who starts simulator surface sources, and the running hosts.
    pub surface: crate::surface::SurfaceConfig,
}

impl ServiceConfig {
    /// The app's own daemon socket: `default_socket`, else `<tui_socket_dir>/<default_session>.sock`.
    pub fn daemon_socket(&self) -> PathBuf {
        self.default_socket
            .clone()
            .unwrap_or_else(|| self.tui_socket_dir.join(format!("{}.sock", self.default_session)))
    }
}

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
    /// The computer this build runs on (`gethostuuid`), never sent raw: see
    /// [`machine_id`]. None when the OS gives none (Linux, a sandbox, tests).
    pub host_uuid: Option<HostUuid>,
    /// `CMUX_MOBILE_MACHINE_ID`: a machine id to send as is (tests, the rig).
    pub machine_id_override: Option<String>,
    /// Where other builds keep their state folders ([`sibling_device_ids`]).
    pub app_support: PathBuf,
    /// This build's state folder: its `machine-id` marker goes there.
    pub state_dir: PathBuf,
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

/// The host UUID. Its `Debug` is redacted: the hardware id is never logged.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct HostUuid(pub [u8; 16]);

impl std::fmt::Debug for HostUuid {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("HostUuid(<redacted>)")
    }
}

/// A machine id as the backend takes it (32 lowercase hex digits), or None.
pub fn normalize_machine_id(value: &str) -> Option<String> {
    let id = value.trim().to_ascii_lowercase();
    (id.len() == 32 && id.bytes().all(|b| b.is_ascii_hexdigit())).then_some(id)
}

/// The file in a build's state folder that says which machine id that build
/// registered: a sibling whose marker names another machine (its folder came
/// from another Mac, through Migration Assistant or a restore) is not this
/// Mac's build.
pub const MACHINE_MARKER: &str = "machine-id";

/// The salt of [`machine_id`]: names the purpose, so the value matches nothing else derived from the host UUID.
const MACHINE_ID_KEY: &[u8] = b"cmux-mobile machine-id v1";

/// The machine id a Mac registers (PROTOCOL.md "Devices"): the same for every
/// cmux build on one computer and one account, so the phone lists the computer
/// once, and different on any other computer whatever its name. HMAC-SHA256 of
/// the owner and the host UUID under a cmux key, first 16 bytes in hex: the
/// hardware id never leaves the Mac, and two accounts on one Mac get unrelated
/// ids (the backend compares them within one owner only).
pub fn machine_id(owner: &str, host_uuid: &[u8; 16]) -> String {
    let key = ring::hmac::Key::new(ring::hmac::HMAC_SHA256, MACHINE_ID_KEY);
    let mut message = Vec::with_capacity(owner.len() + 17);
    message.extend_from_slice(owner.as_bytes());
    message.push(0);
    message.extend_from_slice(host_uuid);
    let tag = ring::hmac::sign(&key, &message);
    tag.as_ref()[..16].iter().map(|b| format!("{b:02x}")).collect()
}

/// This computer's host UUID (the IOPlatformUUID every build reads alike).
#[cfg(target_os = "macos")]
pub fn host_uuid() -> Option<HostUuid> {
    let mut id = [0u8; 16];
    let wait = libc::timespec { tv_sec: 1, tv_nsec: 0 };
    // SAFETY: `id` is the 16-byte uuid_t gethostuuid fills; `wait` outlives the call.
    let ok = unsafe { libc::gethostuuid(id.as_mut_ptr(), &raw const wait) } == 0;
    (ok && id != [0u8; 16]).then_some(HostUuid(id))
}

#[cfg(not(target_os = "macos"))]
pub fn host_uuid() -> Option<HostUuid> {
    None
}

/// At most this many sibling ids per registration (the backend's limit).
pub const MAX_SIBLINGS: usize = 16;

/// The device ids other cmux builds on this Mac registered, read from their
/// state folders in `app_support` (`<bundle id>/cmux-mobile-host/device-id`,
/// the pre-rename `<bundle id>/cnx-host/device-id`, and a standalone host's
/// `cmux-mobile-host/device-id`), without `own`. The backend gives each the
/// registering Mac's machine id when it is the same owner's Mac and has none
/// yet: the record a deleted build left behind is then listed as that
/// computer's, instead of as another Mac. A folder whose [`MACHINE_MARKER`]
/// names another machine id came from another Mac and is skipped (a folder
/// without one is a build from before machine ids). Unreadable folders are
/// skipped.
pub fn sibling_device_ids(app_support: &Path, own: &str, machine_id: &str) -> Vec<String> {
    let mut folders = vec![app_support.join("cmux-mobile-host")];
    if let Ok(entries) = std::fs::read_dir(app_support) {
        let mut bundles: Vec<PathBuf> = entries.flatten().map(|e| e.path()).collect();
        bundles.sort();
        for bundle in bundles {
            folders.push(bundle.join("cmux-mobile-host"));
            folders.push(bundle.join("cnx-host"));
        }
    }
    let mut ids: Vec<String> = Vec::new();
    for folder in folders {
        if let Ok(marker) = std::fs::read_to_string(folder.join(MACHINE_MARKER))
            && normalize_machine_id(&marker).is_some_and(|m| m != machine_id)
        {
            continue;
        }
        let Ok(text) = std::fs::read_to_string(folder.join("device-id")) else { continue };
        let Ok(id) = uuid::Uuid::parse_str(text.trim()) else { continue };
        let id = id.to_string();
        if !id.eq_ignore_ascii_case(own) && !ids.contains(&id) {
            ids.push(id);
        }
        if ids.len() == MAX_SIBLINGS {
            break;
        }
    }
    ids
}

/// The other builds a registration names: [`sibling_device_ids`], or none
/// when the machine id is an override. An override (a hidden test rig) says
/// this build is its own computer; claiming this Mac's folders as its
/// siblings would make the backend give its id to every same-owner record
/// that has none yet (old builds, other rigs) and fold them into it for good.
pub fn registration_siblings(app_support: &Path, own: &str, machine_id: &str, overridden: bool) -> Vec<String> {
    if overridden {
        return Vec::new();
    }
    sibling_device_ids(app_support, own, machine_id)
}

/// [`HostConfig::machine`] on the fields it reads: the machine id to register
/// (`id`, nil when the host has none), whether it is an override, this
/// build's state folder (its marker) and the folders its siblings live in.
pub fn registration_machine(
    id: Option<String>,
    overridden: bool,
    state_dir: &Path,
    app_support: &Path,
    device_id: &str,
) -> (Option<String>, Vec<String>) {
    let Some(id) = id else {
        tracing::info!("no machine id on this host: the phone lists this build as its own Mac");
        return (None, Vec::new());
    };
    let marker = state_dir.join(MACHINE_MARKER);
    // An override (tests, the rig) is not this computer's id: never written as its marker.
    if !overridden
        && std::fs::read_to_string(&marker).ok().as_deref() != Some(id.as_str())
        && let Err(error) = std::fs::create_dir_all(state_dir).and_then(|()| std::fs::write(&marker, &id))
    {
        tracing::warn!("could not write the machine marker: {error}");
    }
    let siblings = registration_siblings(app_support, device_id, &id, overridden);
    (Some(id), siblings)
}

/// `~/Library/Application Support` (`CMUX_MOBILE_APP_SUPPORT_DIR` in tests).
pub fn app_support_dir() -> PathBuf {
    env("CMUX_MOBILE_APP_SUPPORT_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| home().join("Library/Application Support"))
}

impl HostConfig {
    /// The machine id to register for `owner`: the override, else derived from the host UUID.
    pub fn machine_id(&self, owner: &str) -> Option<String> {
        self.machine_id_override.clone().or_else(|| self.host_uuid.map(|uuid| machine_id(owner, &uuid.0)))
    }

    /// What a registration sends besides the device: the machine id and the
    /// other builds' device ids, after writing this build's marker. Nothing
    /// without a machine id (logged once per registration).
    pub fn machine(&self, owner: &str) -> (Option<String>, Vec<String>) {
        registration_machine(
            self.machine_id(owner),
            self.machine_id_override.is_some(),
            &self.state_dir,
            &self.app_support,
            &self.device_id,
        )
    }

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
                project_id: env("CMUX_MOBILE_STACK_PROJECT_ID")
                    .unwrap_or_else(|| DEFAULT_STACK_PROJECT.into()),
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
            .with_push_keys(std::sync::Arc::new(crate::push_keys::PushKeys::load(
                default_state_dir().join("push-keys.json"),
            )))
            .with_spent_replies(std::sync::Arc::new(crate::mailbox::SpentReplies::load(
                default_state_dir().join("mailbox-spent.json"),
            )))
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
        // Supervised: the app has a surface source (`CMUX_MOBILE_SURFACE_HOSTS=1`): its
        // phone tabs' simulators when SimulatorKit loads (an app that cannot says
        // `CMUX_MOBILE_SURFACE_SIMULATORS=0`; an older app sets neither then), and Cloud desktops.
        let surface = match &supplied {
            Some(supplied) if env("CMUX_MOBILE_SURFACE_HOSTS").as_deref() == Some("1") => {
                let config = crate::surface::SurfaceConfig::new(Some(supplied.surface.launcher()), max_tabs);
                if env("CMUX_MOBILE_SURFACE_SIMULATORS").as_deref() == Some("0") {
                    config.without_simulators()
                } else {
                    config
                }
            }
            _ => crate::surface::SurfaceConfig::default(),
        };
        let file_roots = env("CMUX_MOBILE_FILE_ROOTS")
            .map(|roots| roots.split(':').filter(|r| !r.is_empty()).map(PathBuf::from).collect())
            .unwrap_or_default();
        Ok(Self {
            base_url,
            team_id,
            device_id,
            device_name: env("CMUX_MOBILE_DEVICE_NAME").unwrap_or_else(hostname),
            host_uuid: host_uuid(),
            machine_id_override: env("CMUX_MOBILE_MACHINE_ID").and_then(|value| {
                let id = normalize_machine_id(&value);
                if id.is_none() {
                    tracing::warn!("CMUX_MOBILE_MACHINE_ID is not 32 hex digits; using this host's own");
                }
                id
            }),
            app_support: app_support_dir(),
            state_dir: default_state_dir(),
            tokens,
            owner_user_id: env("CMUX_MOBILE_OWNER_USER_ID"),
            include_loopback: env("CMUX_MOBILE_INCLUDE_LOOPBACK").is_some_and(|v| v == "1"),
            exclude_cgnat: env("CMUX_MOBILE_EXCLUDE_CGNAT").is_some_and(|v| v == "1"),
            services: ServiceConfig {
                chief_socket: Some(chief_socket(
                    &env("CMUX_MOBILE_TUI_SOCKET_DIR")
                        .map(PathBuf::from)
                        .unwrap_or_else(default_tui_socket_dir),
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
                browser,
                surface,
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
