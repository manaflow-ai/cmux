//! The OS sandbox every new agent chat starts under, from the cmux settings file, read at each
//! start. Two choices; their defaults are what acpmux did before them:
//!
//! - `agents.sandbox.mode`:
//!   - `permissionMode` (default): the sandbox follows the chat's permission mode. The Codex
//!     bridge's modes carry their own sandbox (`ask` and `agent`: workspace-write, `read-only`:
//!     read-only, `agent-full-access`: danger-full-access); Claude Code runs without its sandbox.
//!   - `workspaceWrite`: agents write only inside their workspace. Full-access modes are off, as
//!     with `sessions.allowFullAccess` off (`hub/start_mode.rs` `file_allows_full_access`), so a
//!     Codex chat never runs danger-full-access and every mode it may run has a workspace-write or
//!     read-only sandbox. Claude Code starts with its sandbox on and no unsandboxed fallback
//!     (`--settings {"sandbox":{"enabled":true,"allowUnsandboxedCommands":false}}`, merged into
//!     the launch's own inline `--settings`; `claude_settings`). Claude Code's sandbox covers its
//!     Bash tool; its file tools follow its permission rules.
//! - `agents.sandbox.network`:
//!   - `harness` (default): each harness's own. Codex's workspace-write sandbox has no network;
//!     Claude Code's sandbox asks per domain.
//!   - `allow`: Codex's workspace-write sandbox reaches the network
//!     (`-c sandbox_workspace_write.network_access=true` on the `codex app-server` launch, unless
//!     its command line or codex's config sets that key; `codex_args`). A mode the person switches
//!     to mid-chat goes through the bridge's own policy, which has no network. Claude Code's
//!     network rules stay its own.
//!
//! A remote-origin chat keeps its own sandbox (`hub/remote_sandbox.rs`): it gets neither. A value
//! that is not one of the choices counts as the default, with a warning. A file that does not
//! parse is the default too (`sessions.allowFullAccess` fails closed on its own).

use serde_json::{Map, Value, json};

/// The sandbox choice.
pub const MODE_SETTING: &str = "agents.sandbox.mode";
/// The network choice.
pub const NETWORK_SETTING: &str = "agents.sandbox.network";
/// The Codex config key `agents.sandbox.network` `allow` sets.
pub const CODEX_NETWORK_KEY: &str = "sandbox_workspace_write.network_access";

/// `agents.sandbox.mode`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Mode {
    #[default]
    PermissionMode,
    WorkspaceWrite,
}

/// `agents.sandbox.network`.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum Network {
    #[default]
    Harness,
    Allow,
}

/// Both settings as the file holds them now.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct Sandbox {
    pub mode: Mode,
    pub network: Network,
}

/// The string `key` holds in `doc`, if any; another type warns and counts as unset.
fn choice(doc: &Value, key: &str) -> Option<String> {
    match crate::user_settings::value(doc, key) {
        None | Some(Value::Null) => None,
        Some(Value::String(s)) => Some(s),
        Some(other) => {
            tracing::warn!(%other, "{key}: not a string; the default applies");
            None
        }
    }
}

impl Sandbox {
    /// Both settings from a parsed settings document.
    pub fn from_doc(doc: &Value) -> Self {
        let mode = match choice(doc, MODE_SETTING).as_deref() {
            None | Some("permissionMode") => Mode::PermissionMode,
            Some("workspaceWrite") => Mode::WorkspaceWrite,
            Some(other) => {
                tracing::warn!(
                    value = other,
                    "{MODE_SETTING}: unknown choice; permissionMode applies"
                );
                Mode::PermissionMode
            }
        };
        let network = match choice(doc, NETWORK_SETTING).as_deref() {
            None | Some("harness") => Network::Harness,
            Some("allow") => Network::Allow,
            Some(other) => {
                tracing::warn!(value = other, "{NETWORK_SETTING}: unknown choice; harness applies");
                Network::Harness
            }
        };
        Self { mode, network }
    }

    /// The settings as the file holds them now (read at each start, so a change applies to the
    /// next chat).
    pub fn current() -> Self {
        match crate::user_settings::read() {
            crate::user_settings::Settings::Parsed(doc) => Self::from_doc(&doc),
            crate::user_settings::Settings::Missing
            | crate::user_settings::Settings::Unreadable(_) => Self::default(),
        }
    }
}

/// The settings Claude Code's sandbox starts with under `workspaceWrite`, over `flag` (the
/// launch's own `--settings`): its `sandbox` object keeps every other key it set.
pub fn claude_settings(flag: Option<&Map<String, Value>>) -> String {
    let mut settings = flag.cloned().unwrap_or_default();
    let sandbox = settings.entry("sandbox").or_insert_with(|| json!({}));
    if !sandbox.is_object() {
        *sandbox = json!({});
    }
    if let Value::Object(sandbox) = sandbox {
        sandbox.insert("enabled".to_owned(), Value::Bool(true));
        sandbox.insert("allowUnsandboxedCommands".to_owned(), Value::Bool(false));
    }
    Value::Object(settings).to_string()
}

/// A Claude Code launch `argv` (program first) under `sandbox`: under `workspaceWrite`, its
/// `--settings` replaced by one at its end with the sandbox on (`claude_settings`). A launch
/// whose own `--settings` cannot be read as a JSON object is left alone, with a warning: Claude
/// would refuse the merged one the same way.
pub fn claude_argv(sandbox: Sandbox, argv: &mut Vec<String>, cwd: &std::path::Path) {
    if sandbox.mode != Mode::WorkspaceWrite {
        return;
    }
    let Some((program, args)) = argv.split_first() else { return };
    let flag = match crate::claude_cloud_auth::flag_settings(args, cwd) {
        Ok(flag) => flag,
        Err(error) => {
            tracing::warn!(%error, "{MODE_SETTING}: the launch's --settings does not read; Claude Code starts without its sandbox");
            return;
        }
    };
    let mut out = crate::claude_cloud_auth::settings_args(args).0;
    out.insert(0, program.clone());
    // Before a `--`: after it every word is positional.
    let at = out.iter().position(|w| w == "--").unwrap_or(out.len());
    out.splice(at..at, ["--settings".to_owned(), claude_settings(flag.as_ref())]);
    *argv = out;
}

/// A `codex app-server` launch's arguments (`launch`, after its program) under `sandbox`: under
/// network `allow`, `-c sandbox_workspace_write.network_access=true` first, unless `sets` (the
/// command line or codex's config already has the key).
pub fn codex_args(
    sandbox: Sandbox,
    mut launch: Vec<String>,
    sets: impl FnOnce() -> bool,
) -> Vec<String> {
    if sandbox.network == Network::Allow && !sets() {
        launch.splice(0..0, ["-c".to_owned(), format!("{CODEX_NETWORK_KEY}=true")]);
    }
    launch
}

#[cfg(test)]
mod tests {
    use super::*;

    fn words(w: &[&str]) -> Vec<String> {
        w.iter().map(|s| (*s).to_owned()).collect()
    }

    #[test]
    fn reads_both_choices_and_defaults_what_it_does_not_know() {
        let doc = json!({"agents": {"sandbox": {"mode": "workspaceWrite", "network": "allow"}}});
        assert_eq!(
            Sandbox::from_doc(&doc),
            Sandbox { mode: Mode::WorkspaceWrite, network: Network::Allow }
        );
        let flat =
            json!({"agents.sandbox.mode": "permissionMode", "agents.sandbox.network": "harness"});
        assert_eq!(Sandbox::from_doc(&flat), Sandbox::default());
        let odd = json!({"agents.sandbox.mode": "everything", "agents.sandbox.network": true});
        assert_eq!(Sandbox::from_doc(&odd), Sandbox::default());
        assert_eq!(Sandbox::from_doc(&json!({})), Sandbox::default());
    }

    #[test]
    fn workspace_write_turns_claude_codes_sandbox_on_over_its_own_settings() {
        let on = Sandbox { mode: Mode::WorkspaceWrite, network: Network::Harness };
        let cwd = std::env::temp_dir();
        let mut argv = words(&[
            "claude",
            "--settings",
            r#"{"env":{"A":"1"},"sandbox":{"excludedCommands":["git"],"enabled":false}}"#,
            "-p",
            "--",
            "--settings",
        ]);
        claude_argv(on, &mut argv, &cwd);
        assert_eq!(&argv[..2], ["claude", "-p"]);
        assert_eq!(argv[2], "--settings");
        let merged: Value = serde_json::from_str(&argv[3]).unwrap();
        assert_eq!(merged["env"]["A"], "1");
        assert_eq!(merged["sandbox"]["enabled"], true);
        assert_eq!(merged["sandbox"]["allowUnsandboxedCommands"], false);
        assert_eq!(merged["sandbox"]["excludedCommands"], json!(["git"]));
        assert_eq!(&argv[4..], ["--", "--settings"], "positional words stay");

        let mut plain = words(&["claude"]);
        claude_argv(Sandbox::default(), &mut plain, &cwd);
        assert_eq!(plain, ["claude"], "permissionMode adds nothing");

        let mut unreadable = words(&["claude", "--settings", "/nonexistent/settings.json"]);
        let before = unreadable.clone();
        claude_argv(on, &mut unreadable, &cwd);
        assert_eq!(unreadable, before);
    }

    #[test]
    fn network_allow_adds_codexs_key_unless_it_is_set() {
        let allow = Sandbox { mode: Mode::PermissionMode, network: Network::Allow };
        let launch = words(&["app-server"]);
        assert_eq!(
            codex_args(allow, launch.clone(), || false),
            ["-c", "sandbox_workspace_write.network_access=true", "app-server"]
        );
        assert_eq!(codex_args(allow, launch.clone(), || true), ["app-server"]);
        assert_eq!(codex_args(Sandbox::default(), launch, || false), ["app-server"]);
    }
}
