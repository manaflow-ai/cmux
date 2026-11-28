//! Removes obsolete per-launch Copilot auth directories.

use std::path::Path;
use std::sync::Mutex;

pub(crate) const ROUTE_ENV: &str = "ACPMUX_COPILOT_ROUTE";
pub(crate) const ROUTE_HOME_ENV: &str = "ACPMUX_COPILOT_ROUTE_HOME";
const SCRATCH_PREFIX: &str = "copilot-";
static SCRATCH_WRITE: Mutex<()> = Mutex::new(());

/// Remove the legacy auth folder and this session's launch directories. Each launch has its
/// own directory, so an older host's exit cannot remove a replacement's credential.
pub(crate) fn remove_session(id: &str) {
    let _write = SCRATCH_WRITE.lock().unwrap_or_else(|e| e.into_inner());
    let base = super::session_tmp::per_user_base();
    let home = crate::config::home();
    if let Some(dir) = super::session_tmp::existing_session(&base, &home, id) {
        remove_from(&dir);
    }
}

pub(crate) fn remove_legacy_session(id: &str) {
    let base = super::session_tmp::per_user_base();
    let home = crate::config::home();
    if let Some(dir) = super::session_tmp::existing_session(&base, &home, id) {
        remove_legacy(&dir);
    }
}

pub(crate) fn remove_route(route: &str) {
    let _write = SCRATCH_WRITE.lock().unwrap_or_else(|e| e.into_inner());
    let base = super::session_tmp::per_user_base();
    let home = crate::config::home();
    let prefix = format!("{SCRATCH_PREFIX}{route}.");
    for dir in super::session_tmp::existing_sessions(&base, &home) {
        // Legacy copies have no route identity. Clear them conservatively, including ones
        // from before a route reorder or a chat's binding change.
        remove_legacy(&dir);
        for scratch in super::session_tmp::real_dirs_in(&dir, &|name| name.starts_with(&prefix)) {
            super::session_tmp::remove_dir(&scratch);
        }
    }
}

pub(crate) fn sweep_inactive(live: &std::collections::HashSet<String>) {
    let _write = SCRATCH_WRITE.lock().unwrap_or_else(|e| e.into_inner());
    let base = super::session_tmp::per_user_base();
    let home = crate::config::home();
    for dir in super::session_tmp::existing_sessions(&base, &home) {
        if let Some(id) = dir.file_name().and_then(|name| name.to_str())
            && !live.contains(id)
        {
            remove_from(&dir);
        }
    }
}

fn remove_from(dir: &Path) {
    remove_legacy(dir);
    for scratch in super::session_tmp::real_dirs_in(dir, &|name| name.starts_with(SCRATCH_PREFIX)) {
        super::session_tmp::remove_dir(&scratch);
    }
}

fn remove_legacy(dir: &Path) {
    super::session_tmp::remove_dir(&dir.join("opencode"));
}

pub(crate) fn remove_host_launch(home: &Path, id: &str, path: &Path) {
    // The host starts with a minimal environment, so its daemon may have chosen a different base.
    let Some(base) = path.ancestors().nth(4) else { return };
    let parent = super::session_tmp::existing_session(base, home, id);
    if parent.is_some()
        && parent.as_deref() == path.parent()
        && path
            .file_name()
            .and_then(|name| name.to_str())
            .is_some_and(|name| name.starts_with(SCRATCH_PREFIX))
    {
        super::session_tmp::remove_dir(path);
    }
}
