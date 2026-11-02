//! What of the user's own Claude Code setup a Chief turn keeps: the hooks
//! and skills the user names in cmux.json, nothing else.
//!
//! A turn loads no user setting source (`host::TURN_SETTING_SOURCES`) and
//! its project settings turned every hook off, so the Chief's own Bash ran
//! without the user's guard hooks (a reserved-host guard, a local-build
//! guard) and its prompts never reached the user's prompt log. Copying every
//! user hook would bring hooks that add context to each prompt (a notes
//! search on every prompt) or work at each stop, so a turn keeps only:
//!
//! - `chief.turnHooks`: words; a user hook (`<Claude home>/settings.json`)
//!   whose command holds one of them is copied into the turn folder's
//!   project settings under its event and matcher, and hooks turn on. None
//!   named: hooks stay off, as before.
//! - `chief.turnSkills`: skill folder names under `<Claude home>/skills`;
//!   each is linked into the turn folder's `.claude/skills`, the project
//!   skills a turn loads with the `Skill` tool. Claude Code's bundled skills
//!   stay off (`disableBundledSkills`), so only these are listed.
//!
//! Both are read when the host writes the turn folder (host start).

use std::path::Path;

use serde_json::{Value, json};

/// The cmux.json key of the hook words.
pub const HOOKS_KEY: &str = "chief.turnHooks";
/// The cmux.json key of the skill names.
pub const SKILLS_KEY: &str = "chief.turnSkills";

/// The non-empty strings of an array at `key` in the user's settings document.
fn named(doc: Option<&Value>, key: &str) -> Vec<String> {
    match doc.and_then(|d| crate::agent_memory::settings::value(d, key)) {
        Some(Value::Array(items)) => items
            .iter()
            .filter_map(|v| v.as_str().map(str::trim))
            .filter(|s| !s.is_empty())
            .map(str::to_owned)
            .collect(),
        _ => Vec::new(),
    }
}

/// The user's settings document (cmux.json), against `$HOME`.
fn document() -> Option<Value> {
    let home = std::env::var_os("HOME")?;
    crate::agent_memory::settings::document(Path::new(&home))
}

/// The hooks of `user_settings` whose command holds one of `words`, in
/// Claude Code's `hooks` shape (event, then matcher groups); None when none.
pub fn select_hooks(user_settings: &Value, words: &[String]) -> Option<Value> {
    if words.is_empty() {
        return None;
    }
    let events = user_settings.get("hooks")?.as_object()?;
    let mut out = serde_json::Map::new();
    for (event, groups) in events {
        let Some(groups) = groups.as_array() else {
            continue;
        };
        let mut kept_groups = Vec::new();
        for group in groups {
            let Some(hooks) = group.get("hooks").and_then(Value::as_array) else {
                continue;
            };
            let kept: Vec<Value> = hooks
                .iter()
                .filter(|h| {
                    h.get("command")
                        .and_then(Value::as_str)
                        .is_some_and(|c| words.iter().any(|w| c.contains(w.as_str())))
                })
                .cloned()
                .collect();
            if kept.is_empty() {
                continue;
            }
            let mut group = group.clone();
            group["hooks"] = Value::Array(kept);
            kept_groups.push(group);
        }
        if !kept_groups.is_empty() {
            out.insert(event.clone(), Value::Array(kept_groups));
        }
    }
    (!out.is_empty()).then_some(Value::Object(out))
}

/// Puts the named hooks into a turn's project `settings` (hooks on only
/// when some were named and found) and keeps bundled skills off.
pub fn apply_to_settings(settings: &mut Value, claude_home: &Path, doc: Option<&Value>) {
    settings["disableBundledSkills"] = json!(true);
    let words = named(doc, HOOKS_KEY);
    let user = std::fs::read(claude_home.join("settings.json"))
        .ok()
        .and_then(|b| serde_json::from_slice::<Value>(&b).ok());
    if let Some(hooks) = user.as_ref().and_then(|u| select_hooks(u, &words)) {
        settings["hooks"] = hooks;
        settings["disableAllHooks"] = json!(false);
    }
}

/// Makes `skills_dir` hold a link to each named skill of `claude_home`
/// that exists, and no other link into `<claude_home>/skills`. Anything
/// else there (a real folder, another link) is left alone.
pub fn sync_skills(skills_dir: &Path, claude_home: &Path, doc: Option<&Value>) {
    let source = claude_home.join("skills");
    let want: Vec<String> = named(doc, SKILLS_KEY)
        .into_iter()
        .filter(|n| !n.contains('/') && n != "." && n != "..")
        .filter(|n| source.join(n).join("SKILL.md").is_file())
        .collect();
    if let Ok(entries) = std::fs::read_dir(skills_dir) {
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(target) = std::fs::read_link(&path) else {
                continue;
            };
            let name = entry.file_name().to_string_lossy().into_owned();
            let ours = target.parent() == Some(source.as_path());
            if ours && (!want.contains(&name) || target != source.join(&name)) {
                let _ = std::fs::remove_file(&path);
            }
        }
    }
    if want.is_empty() {
        return;
    }
    if std::fs::create_dir_all(skills_dir).is_err() {
        return;
    }
    for name in want {
        let link = skills_dir.join(&name);
        if std::fs::symlink_metadata(&link).is_ok() {
            continue;
        }
        let _ = std::os::unix::fs::symlink(source.join(&name), &link);
    }
}

/// Both, for the turn folder `session`: its settings value and its skills.
pub fn apply(settings: &mut Value, session: &Path) {
    let doc = document();
    let claude_home = crate::compactor::user_claude_home();
    apply_to_settings(settings, &claude_home, doc.as_ref());
    sync_skills(
        &session.join(".claude").join("skills"),
        &claude_home,
        doc.as_ref(),
    );
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_hooks_holding_a_named_word_are_kept() {
        let user = json!({"hooks": {
            "PreToolUse": [{"matcher": "Bash", "hooks": [
                {"type": "command", "command": "guard.sh"},
                {"type": "command", "command": "noisy.sh"}
            ]}],
            "Stop": [{"hooks": [{"type": "command", "command": "noisy.sh"}]}]
        }});
        assert_eq!(
            select_hooks(&user, &["guard".to_owned()]),
            Some(json!({"PreToolUse": [{"matcher": "Bash", "hooks": [
                {"type": "command", "command": "guard.sh"}
            ]}]}))
        );
        assert_eq!(select_hooks(&user, &[]), None);
        assert_eq!(select_hooks(&user, &["absent".to_owned()]), None);
    }
}
