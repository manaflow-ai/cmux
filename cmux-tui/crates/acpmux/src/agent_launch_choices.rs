//! Choices cmux passes to the Claude Code and Codex chats it starts (`hub/spawn.rs`), read from
//! the cmux settings file at each start, so a change applies to the next chat start:
//!
//! - `agents.claudeOutputStyle`: Claude Code's `outputStyle` setting (`default`, `Explanatory`,
//!   `Learning`, or a custom style's name).
//! - `agents.codexPersonality`: Codex's `personality` config (`none`, `friendly`, `pragmatic`).
//! - `agents.commitAttribution`: `strip` gives Claude Code `attribution` with empty `commit` and
//!   `pr` strings, so its commits and pull requests carry no co-author line or "Generated with"
//!   footer. Codex has no config for its attribution (codex 0.171: the trailer follows the
//!   ChatGPT workspace's policy), so the setting applies to Claude Code only.
//!
//! - `agents.harnessMagic.outputCaps.enabled` (off unless `true`; RFD 0147,
//!   `harness_limits::OUTPUT_CAPS_SETTING`): Claude Code's `bashOutputMaxChars` at
//!   `harness_limits::OUTPUT_CAPS_BASH_CHARS`, unless Claude Code's own user settings name it.
//!
//! Each setting's default, `agent`, passes nothing: the agent's own settings decide, as before.
//! A chosen value reaches Claude Code in its launch's one `--settings` (Claude Code honors only
//! the last one, so it is merged into the launch's own, `claude_cloud_auth::flag_settings`) and
//! Codex as `-c personality="…"`. A launch whose command line already sets the key keeps its own
//! value; a Claude Code `--settings` that does not read is left alone. A remote-origin chat (a
//! peer's) gets nothing: its chain refuses a `--settings` of the profile's
//! (`hub/remote_sandbox.rs`).

use serde_json::{Map, Value};
use std::path::Path;

/// Claude Code's output style.
pub const OUTPUT_STYLE_SETTING: &str = "agents.claudeOutputStyle";
/// Codex's personality.
pub const PERSONALITY_SETTING: &str = "agents.codexPersonality";
/// Co-author line on commits and pull requests.
pub const ATTRIBUTION_SETTING: &str = "agents.commitAttribution";

/// Every setting's default: the agent's own setting decides.
pub const AGENT_OWN: &str = "agent";

/// The Codex personalities codex accepts (`unknown variant` otherwise, codex 0.171).
pub const CODEX_PERSONALITIES: [&str; 3] = ["none", "friendly", "pragmatic"];

/// What the settings file chooses for the next chat start.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct LaunchChoices {
    /// Claude Code's `outputStyle`, or None for its own.
    pub output_style: Option<String>,
    /// Codex's `personality`, or None for its own.
    pub personality: Option<String>,
    /// Whether Claude Code's attribution is stripped.
    pub strip_attribution: bool,
    /// Claude Code's `bashOutputMaxChars` (RFD 0147's output caps), or None for its own.
    pub bash_output_max_chars: Option<u64>,
}

impl LaunchChoices {
    /// The choices in `get` (a setting's string value). An unset, empty or `agent` value, or a
    /// personality codex would refuse, is the agent's own.
    pub fn parse(get: impl Fn(&str) -> Option<String>) -> Self {
        let chosen = |key: &str| {
            get(key).map(|v| v.trim().to_owned()).filter(|v| !v.is_empty() && v != AGENT_OWN)
        };
        Self {
            output_style: chosen(OUTPUT_STYLE_SETTING),
            personality: chosen(PERSONALITY_SETTING)
                .filter(|p| CODEX_PERSONALITIES.contains(&p.as_str())),
            strip_attribution: chosen(ATTRIBUTION_SETTING).as_deref() == Some("strip"),
            bash_output_max_chars: None,
        }
    }

    /// The choices as the settings file holds them now. No file, or one that does not parse,
    /// chooses nothing.
    pub fn current() -> Self {
        let mut choices = match crate::user_settings::read() {
            crate::user_settings::Settings::Parsed(doc) => Self::parse(|key| {
                crate::user_settings::value(&doc, key).and_then(|v| v.as_str().map(str::to_owned))
            }),
            crate::user_settings::Settings::Missing
            | crate::user_settings::Settings::Unreadable(_) => Self::default(),
        };
        if crate::harness_limits::output_caps() {
            choices.bash_output_max_chars = output_caps_bash(&claude_user_settings());
        }
        choices
    }

    /// The Claude Code settings these choices add: `outputStyle` and `attribution`.
    pub fn claude_settings(&self) -> Map<String, Value> {
        let mut settings = Map::new();
        if let Some(style) = &self.output_style {
            settings.insert("outputStyle".into(), Value::String(style.clone()));
        }
        if self.strip_attribution {
            settings.insert("attribution".into(), serde_json::json!({"commit": "", "pr": ""}));
        }
        if let Some(chars) = self.bash_output_max_chars {
            settings.insert(crate::harness_limits::OUTPUT_CAPS_BASH_SETTING.into(), chars.into());
        }
        settings
    }
}

/// The Bash cap the output caps give a launch whose Claude Code user settings are `user`
/// (`None` when they name their own: a `--settings` value would replace it).
pub fn output_caps_bash(user: &Option<Value>) -> Option<u64> {
    let own = user
        .as_ref()
        .is_some_and(|u| u.get(crate::harness_limits::OUTPUT_CAPS_BASH_SETTING).is_some());
    (!own).then_some(crate::harness_limits::OUTPUT_CAPS_BASH_CHARS)
}

/// Claude Code's user settings (`$CLAUDE_CONFIG_DIR/settings.json`, else
/// `~/.claude/settings.json`), when they read as JSON.
fn claude_user_settings() -> Option<Value> {
    let dir = std::env::var_os("CLAUDE_CONFIG_DIR")
        .filter(|d| !d.is_empty())
        .map(std::path::PathBuf::from)
        .or_else(|| dirs::home_dir().map(|h| h.join(".claude")))?;
    serde_json::from_slice(&std::fs::read(dir.join("settings.json")).ok()?).ok()
}

/// Puts `choices`' Claude Code settings in `argv` (a Claude Code launch, its program first):
/// merged into its last `--settings` (inline JSON or a file relative to `cwd`), which becomes one
/// inline `--settings` before any `--`, else a new one. A key the launch's settings already
/// name stays theirs (for attribution, `attribution` or the older `includeCoAuthoredBy`); a
/// `--settings` that does not read leaves `argv` alone.
pub fn apply_claude(argv: &mut Vec<String>, cwd: &Path, choices: &LaunchChoices) {
    let wanted = choices.claude_settings();
    if wanted.is_empty() {
        return;
    }
    let Some((program, args)) = argv.split_first() else { return };
    let Ok(flag) = crate::claude_cloud_auth::flag_settings(args, cwd) else { return };
    let mut settings = flag.unwrap_or_default();
    let mut added = false;
    for (key, value) in wanted {
        let own = settings.contains_key(&key)
            || (key == "attribution" && settings.contains_key("includeCoAuthoredBy"));
        if !own {
            settings.insert(key, value);
            added = true;
        }
    }
    if !added {
        return;
    }
    let mut rest = crate::claude_cloud_auth::without_settings(args);
    let at = rest.iter().position(|a| a == "--").unwrap_or(rest.len());
    rest.splice(at..at, ["--settings".to_owned(), Value::Object(settings).to_string()]);
    rest.insert(0, program.clone());
    *argv = rest;
}

/// Puts `choices`' Codex personality in `argv` (a `codex app-server` launch) as
/// `-c personality="…"`, unless its command line sets `personality` already.
/// `harness_limits::codex_args` moves it before the subcommand.
pub fn apply_codex(argv: &mut Vec<String>, choices: &LaunchChoices) {
    let Some(personality) = &choices.personality else { return };
    if crate::harness_limits::sets_codex_key(argv.get(1..).unwrap_or(&[]), "personality") {
        return;
    }
    argv.push("-c".into());
    argv.push(format!("personality={}", toml::Value::String(personality.clone())));
}

#[cfg(test)]
#[path = "agent_launch_choices_tests.rs"]
mod tests;
