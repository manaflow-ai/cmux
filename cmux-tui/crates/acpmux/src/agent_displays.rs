//! One X display per cmux workspace for computer use (cx-ncc.5). On a Linux
//! cloud machine every agent's `cmux-cua mcp` would otherwise drive the one
//! shared default display, so agents of two workspaces would click into each
//! other's windows. The machine image runs this daemon with
//! [`MODE_ENV`]`=`[`PER_WORKSPACE`]; then:
//!
//! - A session's workspace is the typed `_meta.acpmux.workspaceId` of its
//!   `session/new`, else its session env's `CMUX_WORKSPACE_ID` (a request
//!   naming two different ones is refused, `workspace.mismatch`); a fork
//!   keeps its parent's unless it names another either way. It is recorded
//!   in the session meta, so a restart or respawn keeps it. The env never
//!   sets [`DISPLAY_ENV`] (not an allowed session env key).
//! - Each workspace gets a display number from [`BASE`] up, allocated once
//!   and kept in `<ACPMUX_HOME>/agent-displays/displays.json` (0600 in a 0700
//!   folder, written under a file lock), so it is stable across sessions
//!   and restarts.
//! - The session's `cmux-cua` server gets [`DISPLAY_ENV`]`=:N`; the proxy's
//!   daemon runs each call on that display. Nothing else sees it.
//! - Fail closed: a session without a workspace id, or one whose display
//!   cannot be allocated, gets no computer use server at all, so it can
//!   never drive the shared display.
//!
//! The workspace reaches `agent_tools.rs` as [`WORKSPACE_KEY`] in the spawn
//! profile's env (set by [`mark`]); `agent/command.rs` removes it before the
//! harness starts, so no agent process carries it. With the mode off (any
//! other value or unset) nothing here runs.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use anyhow::{Context, Result, bail};
use serde_json::{Value, json};

/// This daemon's env that turns per-workspace displays on.
pub const MODE_ENV: &str = "CMUX_AGENT_DISPLAYS";
/// The [`MODE_ENV`] value that turns them on.
pub const PER_WORKSPACE: &str = "per-workspace";
/// The `cmux-cua mcp` env naming the display its calls run on (`:N`).
pub const DISPLAY_ENV: &str = "CMUX_CUA_DISPLAY";
/// The private spawn-profile env key carrying the session's workspace to
/// `agent_tools.rs`; never in an agent's env.
pub const WORKSPACE_KEY: &str = "ACPMUX_AGENT_WORKSPACE";
/// The first display number a workspace gets (well above `:0` and the
/// low numbers a desktop or Xvfb run by hand takes).
pub const BASE: u32 = 100;
/// Most workspaces one machine allocates.
pub const MAX_DISPLAYS: usize = 1024;

/// Whether this daemon runs with per-workspace displays.
pub fn per_workspace() -> bool {
    std::env::var(MODE_ENV).is_ok_and(|v| v == PER_WORKSPACE)
}

/// The allocation folder under `home` (`<ACPMUX_HOME>/agent-displays`).
pub fn dir(home: &Path) -> PathBuf {
    home.join("agent-displays")
}

/// Put the session's workspace into its spawn profile `env` as
/// [`WORKSPACE_KEY`], only in per-workspace mode. A value a preset or
/// profile set there is never kept.
pub fn mark(env: &mut BTreeMap<String, String>, workspace: Option<&str>) {
    env.remove(WORKSPACE_KEY);
    if let (true, Some(ws)) = (per_workspace(), workspace) {
        env.insert(WORKSPACE_KEY.to_owned(), ws.to_owned());
    }
}

/// The display number of `workspace`, allocating the lowest free one from
/// [`BASE`] the first time. Ids compare lowercased.
pub fn display_for(dir: &Path, workspace: &str) -> Result<u32> {
    let workspace = workspace.to_ascii_lowercase();
    // Check before creating `agent-displays`: a removed home must never be
    // recreated by the allocation path before its atomic write notices the
    // lost-home fence.
    crate::config::refuse_lost_home(dir)?;
    private_dir(dir)?;
    let lock_path = dir.join("lock");
    let lock = open_private(&lock_path)
        .with_context(|| format!("open the display lock {}", lock_path.display()))?;
    lock.lock().with_context(|| format!("lock {}", lock_path.display()))?;
    let file = dir.join("displays.json");
    let mut displays: BTreeMap<String, u32> = match std::fs::read(&file) {
        Ok(bytes) => {
            let doc: Value = serde_json::from_slice(&bytes)
                .with_context(|| format!("read {}", file.display()))?;
            serde_json::from_value(doc.get("displays").cloned().unwrap_or(json!({})))
                .with_context(|| format!("read {}", file.display()))?
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => BTreeMap::new(),
        Err(e) => return Err(e).with_context(|| format!("read {}", file.display())),
    };
    if let Some(n) = displays.get(&workspace) {
        return Ok(*n);
    }
    if displays.len() >= MAX_DISPLAYS {
        bail!("{MAX_DISPLAYS} workspaces already have a display");
    }
    let taken: std::collections::BTreeSet<u32> = displays.values().copied().collect();
    let n = (BASE..).find(|n| !taken.contains(n)).unwrap_or(BASE);
    displays.insert(workspace, n);
    let doc = json!({"version": 1, "displays": displays});
    crate::agent_tools::write_private(&file, doc.to_string().as_bytes())?;
    // The lock goes with `lock` when it drops.
    Ok(n)
}

#[cfg(unix)]
fn private_dir(dir: &Path) -> Result<()> {
    use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
    std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))?;
    Ok(())
}
#[cfg(windows)]
fn private_dir(dir: &Path) -> Result<()> {
    crate::owner_only::create_dir_all(dir)?;
    crate::owner_only::restrict(dir)?;
    Ok(())
}

#[cfg(unix)]
fn open_private(path: &Path) -> std::io::Result<std::fs::File> {
    use std::os::unix::fs::OpenOptionsExt;
    std::fs::OpenOptions::new()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .mode(0o600)
        .open(path)
}
#[cfg(windows)]
fn open_private(path: &Path) -> std::io::Result<std::fs::File> {
    std::fs::OpenOptions::new().read(true).write(true).create(true).truncate(false).open(path)
}
