//! Directory input is resolved against the selected session, never the TUI process cwd
//! (its pure parts: `acpmux::directory_input`).
use super::*;
pub use acpmux::directory_input::*;
use std::path::{Path, PathBuf};

impl App {
    pub(super) fn current_directory(&self) -> String {
        self.draft()
            .map(|d| d.cwd.clone())
            .or_else(|| {
                self.selected_session()
                    .and_then(|s| s.get("cwd").and_then(Value::as_str).map(str::to_owned))
            })
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| {
                std::env::current_dir().unwrap_or_default().to_string_lossy().into_owned()
            })
    }
    pub(super) fn remote_directory(&self) -> bool {
        self.draft().and_then(|d| d.peer.as_ref()).is_some()
            || self.selected_session().and_then(|s| s.get("peer").and_then(Value::as_str)).is_some()
    }
    pub(super) fn resolve_directory(&self, path: &str) -> Result<PathBuf> {
        // Unquote first: `cd '~/x'` must not expand the local home remotely.
        if self.remote_directory() && unquote(path).starts_with('~') {
            anyhow::bail!("Use an absolute path on the remote host");
        }
        // `cd -` goes back within this draft, never to another session's path.
        resolve(
            Path::new(&self.current_directory()),
            path,
            &dirs::home_dir().unwrap_or_default(),
            self.draft().and_then(|d| d.previous_cwd.as_deref()),
        )
    }
}
