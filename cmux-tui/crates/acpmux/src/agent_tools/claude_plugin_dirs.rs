//! Which Claude Code plugin folders are cmux-tui's: the one rule for acpmux
//! and cmux-tui (which depends on acpmux).
//!
//! A cmux-tui pane names its build's Claude Code plugin in
//! `CLAUDE_CODE_PLUGIN_DIRS` (cmux-tui `claude_plugin.rs`), whose hooks report
//! to that pane. A daemon started in such a pane inherits the variable; its
//! agents run in no pane, so `agent/command.rs` takes the plugin out of the
//! agent's list and keeps every other folder. cmux-tui uses the same rule to
//! replace another build's plugin in a pane and to drop its own plugin where
//! the shim's `--settings` carry the hooks.

use std::ffi::{OsStr, OsString};
use std::io::Read as _;
use std::path::Path;

/// The variable Claude Code reads plugin folders from (`:`-separated,
/// absolute paths only).
pub const CLAUDE_PLUGIN_DIRS_ENV: &str = "CLAUDE_CODE_PLUGIN_DIRS";
/// The name in a cmux-tui plugin's manifest.
pub const PLUGIN_NAME: &str = "cmux-tui";
/// The folder a cmux-tui build writes its plugin into, inside its build
/// folder (`<data>/cmux-tui/builds/<build>/claude-plugin`).
pub const PLUGIN_FOLDER: &str = "claude-plugin";
/// A plugin's manifest, inside its folder.
pub const MANIFEST: &str = ".claude-plugin/plugin.json";
/// Manifests are small; a larger file is not read.
const MAX_MANIFEST_BYTES: u64 = 1024 * 1024;

/// `value` (a `CLAUDE_CODE_PLUGIN_DIRS` list) without cmux-tui plugin
/// folders or empty entries; `None` when no folder is left.
pub fn without_cmux_tui_plugins(value: &OsStr) -> Option<OsString> {
    let kept: Vec<_> = std::env::split_paths(value)
        .filter(|folder| !folder.as_os_str().is_empty() && !is_cmux_tui_plugin(folder))
        .collect();
    if kept.is_empty() {
        return None;
    }
    std::env::join_paths(kept).ok()
}

/// Whether `folder` is a cmux-tui plugin: a build's plugin folder
/// (`…/cmux-tui/builds/<build>/claude-plugin`, which holds for a build
/// deleted since), or a folder whose manifest names it `cmux-tui`.
pub fn is_cmux_tui_plugin(folder: &Path) -> bool {
    let builds = folder.parent().and_then(Path::parent);
    let named = |path: Option<&Path>, name: &str| {
        path.and_then(Path::file_name).is_some_and(|file| file == name)
    };
    if named(Some(folder), PLUGIN_FOLDER)
        && named(builds, "builds")
        && named(builds.and_then(Path::parent), "cmux-tui")
    {
        return true;
    }
    let mut data = Vec::new();
    let read = std::fs::File::open(folder.join(MANIFEST))
        .and_then(|file| file.take(MAX_MANIFEST_BYTES).read_to_end(&mut data));
    read.is_ok()
        && serde_json::from_slice::<serde_json::Value>(&data).is_ok_and(|manifest| {
            manifest.get("name").and_then(serde_json::Value::as_str) == Some(PLUGIN_NAME)
        })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn any_launcher_agent_env_drops_cmux_tui_claude_plugins_and_keeps_the_rest() {
        let root = tempfile::tempdir().unwrap();
        // A build's plugin folder, deleted with its build: found by its place.
        let build = root.path().join("data/cmux-tui/builds/0123abcd/claude-plugin");
        // A cmux-tui plugin somewhere else: found by its manifest.
        let named = root.path().join("elsewhere");
        std::fs::create_dir_all(named.join(".claude-plugin")).unwrap();
        std::fs::write(named.join(MANIFEST), r#"{"name": "cmux-tui"}"#).unwrap();
        // The person's own plugins stay, one of them in a folder of the same name.
        let mine = root.path().join("tools/claude-plugin");
        let other = root.path().join("other");
        std::fs::create_dir_all(other.join(".claude-plugin")).unwrap();
        std::fs::write(other.join(MANIFEST), r#"{"name": "my-plugin"}"#).unwrap();
        let value = std::env::join_paths([&build, &mine, &named, &other]).unwrap();
        let kept = without_cmux_tui_plugins(&value).unwrap();
        assert_eq!(std::env::split_paths(&kept).collect::<Vec<_>>(), [mine, other]);
        let only_cmux = std::env::join_paths([&build, &named]).unwrap();
        assert_eq!(without_cmux_tui_plugins(&only_cmux), None);
    }
}
