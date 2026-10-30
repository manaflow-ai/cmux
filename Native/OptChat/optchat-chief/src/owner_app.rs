//! The app the Chief's host serves, as a level (cp/quit-chief-idle,
//! 2026-10-27: a Cmd-Q left the Chief's host, its acpmux and its owner
//! daemon running, about 300 MB with nothing to do; principled audit
//! lagQuitHelpers, 2026-10-29: one shared owner-liveness for every helper).
//!
//! The app that starts a host (Home's `HomeBrainHost`, or the owner daemon's
//! Chief brain supervisor for a Chief that is not the default) names itself
//! in `OPTCHAT_OWNER_APP_PID`. `cmux-owner-liveness` follows it through one
//! kernel handle (a pidfd on Linux, a kqueue `NOTE_EXIT` registration on
//! macOS; no polling), and after its exit the newer app that reused the
//! running host and wrote `<Chief home>/state/owner-app.pid` ([`pid_file`]).
//! The brain reads that level at every input and timer, and the follow
//! thread sends [`crate::brain::Input::OwnerChanged`] when it changes
//! (`brain/owner_exit.rs`).
//!
//! A host no app named (`cmux chief`, the always-on brain's LaunchAgent, a
//! VM Chief) follows nothing and runs as before.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use cmux_owner_liveness::{OwnerApp, OwnerLiveness, Watch};

use crate::cli::env;

/// The variable the app names itself in.
pub const OWNER_APP_PID_ENV: &str = "OPTCHAT_OWNER_APP_PID";

/// `<Chief home>/state/owner-app.pid`: the app that last opened this Chief
/// home's Home (`CMUX_CHIEF_HOME`, else the host's own home).
pub fn pid_file(mux_home: &Path) -> PathBuf {
    env("CMUX_CHIEF_HOME")
        .map_or_else(|| mux_home.to_path_buf(), PathBuf::from)
        .join("state/owner-app.pid")
}

/// The app this host was started for, from its environment.
pub fn from_env() -> OwnerApp {
    OwnerApp::parse(env(OWNER_APP_PID_ENV).as_deref())
}

/// Follows `app` (then the newer apps `file` names); `changed` runs on the
/// follow thread at each change. None for an unnamed app; else the
/// liveness and how it follows the app.
pub fn follow(
    app: OwnerApp,
    file: PathBuf,
    changed: impl Fn() + Send + Sync + 'static,
) -> Option<(Arc<OwnerLiveness>, Watch)> {
    if !app.is_named() {
        return None;
    }
    let liveness = OwnerLiveness::new(Some(file));
    liveness.observe(changed);
    let watch = liveness.follow(app);
    Some((liveness, watch))
}
