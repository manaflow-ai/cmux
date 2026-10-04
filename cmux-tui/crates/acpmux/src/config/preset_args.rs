//! A preset's `args` and `systemPrompt`.
//!
//! `args` are extra words appended to the harness command line. Each entry
//! is one argv word handed to the process as it is (no shell, so quoting,
//! globs and `$(…)` stay literal and an empty string is a real empty
//! argument). They are an allowlist: on a Claude stdio command line only
//! `--tools ""` (no tools), `--strict-mcp-config` (no MCP servers, as no
//! `--mcp-config` may be given) and `--no-session-persistence`; on any other
//! harness none. Every other word is refused, `=` forms and short aliases
//! included, so a preset can only take capabilities away, never widen the
//! permission policy or reach outside the session.
//!
//! `systemPrompt` is text, not a path: acpmux writes it into its own preset
//! directory (`<state>/presets/<name>/system.md`, read-only, never the
//! session's cwd, which the agent can write), records its sha256 in the
//! preset, checks the file against that hash at every session start and
//! passes `--system-prompt-file` itself (Claude stdio harnesses only).

use std::io;
use std::path::{Path, PathBuf};

use serde_json::Value;

use super::HarnessKind;

/// The Claude Code flags a preset may pass.
const CLAUDE_ALLOWED: [&str; 3] = ["--tools", "--strict-mcp-config", "--no-session-persistence"];

/// The system prompt file's name in a preset's directory.
pub const SYSTEM_PROMPT_FILE: &str = "system.md";

/// `args` from a JSON value: a list of strings, each a valid argv word.
pub fn parse_preset_args(value: &Value) -> Result<Vec<String>, String> {
    let list = value.as_array().ok_or("args must be a list of strings (one argv word each)")?;
    let args = list
        .iter()
        .map(|v| v.as_str().map(str::to_owned))
        .collect::<Option<Vec<_>>>()
        .ok_or("args must be a list of strings (one argv word each)")?;
    Ok(args)
}

/// Whether `args` may be appended to a `kind` harness command line.
pub fn check_preset_args(kind: HarnessKind, args: &[String]) -> Result<(), String> {
    if let Some(arg) = args.iter().find(|a| a.contains('\0')) {
        return Err(format!("args: {arg:?} contains a NUL byte"));
    }
    if args.is_empty() {
        return Ok(());
    }
    if kind != HarnessKind::ClaudeStdio {
        return Err(
            "args: only Claude Code harnesses take preset args; this harness takes none".to_owned()
        );
    }
    let mut words = args.iter();
    while let Some(arg) = words.next() {
        match arg.as_str() {
            "--tools" => match words.next().map(String::as_str) {
                Some("") => {}
                _ => {
                    return Err(
                        "args: --tools takes only an empty value (\"\": no tools)".to_owned()
                    );
                }
            },
            "--strict-mcp-config" | "--no-session-persistence" => {}
            other => {
                return Err(format!(
                    "args: {other:?} is not allowed; a preset may pass only {} (\"--tools\" with an empty value); set systemPrompt for a system prompt file",
                    CLAUDE_ALLOWED.join(", ")
                ));
            }
        }
    }
    Ok(())
}

/// A preset name that can name a directory: ASCII letters, digits, `-`,
/// `_` and `.`, not starting with `.`, at most 128 bytes.
pub fn check_preset_dir_name(name: &str) -> Result<(), String> {
    let plain = !name.is_empty()
        && name.len() <= 128
        && !name.starts_with('.')
        && name.bytes().all(|b| b.is_ascii_alphanumeric() || b"-_.".contains(&b));
    if plain {
        Ok(())
    } else {
        Err(format!(
            "preset name {name:?} cannot carry a systemPrompt: use ASCII letters, digits, '-', '_' and '.', not starting with '.'"
        ))
    }
}

/// The directory of preset `name` under the daemon's `presets` directory.
pub fn preset_dir(presets: &Path, name: &str) -> PathBuf {
    presets.join(name)
}

/// Writes `text` as preset `name`'s system prompt file (directory 0700, file
/// 0400, replaced atomically); returns the file's sha256.
pub fn write_system_prompt(presets: &Path, name: &str, text: &str) -> io::Result<String> {
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt, PermissionsExt};
    let dir = preset_dir(presets, name);
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(&dir)?;
    std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    let tmp = dir.join(format!(".{SYSTEM_PROMPT_FILE}.{}", uuid::Uuid::now_v7()));
    let written = (|| {
        let mut file =
            std::fs::OpenOptions::new().write(true).create_new(true).mode(0o400).open(&tmp)?;
        file.write_all(text.as_bytes())?;
        file.sync_all()?;
        std::fs::rename(&tmp, dir.join(SYSTEM_PROMPT_FILE))
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written?;
    Ok(crate::sha256::sha256_hex(text.as_bytes()))
}

/// Removes preset `name`'s directory (its system prompt file).
pub fn remove_preset_dir(presets: &Path, name: &str) -> io::Result<()> {
    if check_preset_dir_name(name).is_err() {
        return Ok(());
    }
    match std::fs::remove_dir_all(preset_dir(presets, name)) {
        Err(e) if e.kind() != io::ErrorKind::NotFound => Err(e),
        _ => Ok(()),
    }
}

/// The system prompt file of preset `name`, by its real path, when its
/// bytes still hash to `sha256` (the hash recorded when the preset was set).
pub fn checked_system_prompt(presets: &Path, name: &str, sha256: &str) -> Result<PathBuf, String> {
    check_preset_dir_name(name)?;
    let file = preset_dir(presets, name).join(SYSTEM_PROMPT_FILE);
    let bytes = std::fs::read(&file)
        .map_err(|e| format!("the system prompt file of preset {name:?} cannot be read ({e}); set the preset's systemPrompt again"))?;
    let got = crate::sha256::sha256_hex(&bytes);
    if got != sha256 {
        return Err(format!(
            "the system prompt file of preset {name:?} changed since the preset was set (sha256 {got}, recorded {sha256}); no session starts with it until the preset is set again"
        ));
    }
    std::fs::canonicalize(&file).map_err(|e| format!("system prompt file of preset {name:?}: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claude(args: &[&str]) -> Result<(), String> {
        check_preset_args(
            HarnessKind::ClaudeStdio,
            &args.iter().map(|a| (*a).to_owned()).collect::<Vec<_>>(),
        )
    }

    #[test]
    fn the_allowlisted_words_pass() {
        assert_eq!(claude(&[]), Ok(()));
        assert_eq!(
            claude(&["--tools", "", "--strict-mcp-config", "--no-session-persistence"]),
            Ok(())
        );
        assert_eq!(claude(&["--no-session-persistence"]), Ok(()));
    }

    /// One test per refused form: unknown flags, `=` forms, short aliases,
    /// and every flag that can weaken permissions or reach outside the cwd.
    macro_rules! refused {
        ($($name:ident: [$($word:expr),* $(,)?];)*) => {$(
            #[test]
            fn $name() {
                let words = [$($word),*];
                let err = claude(&words).expect_err(&format!("{words:?} must be refused"));
                assert!(err.starts_with("args: "), "{words:?}: {err}");
            }
        )*};
    }

    refused! {
        refuses_an_unknown_flag: ["--verbose"];
        refuses_a_bare_word: ["hello"];
        refuses_tools_with_a_value: ["--tools", "Bash"];
        refuses_tools_without_a_value: ["--tools"];
        refuses_tools_equals_empty: ["--tools="];
        refuses_tools_equals_value: ["--tools=Bash"];
        refuses_strict_mcp_config_equals: ["--strict-mcp-config=true"];
        refuses_strict_mcp_config_with_mcp_config: ["--strict-mcp-config", "--mcp-config", "/x.json"];
        refuses_no_session_persistence_equals: ["--no-session-persistence=1"];
        refuses_system_prompt_file: ["--system-prompt-file", "/abs/system.md"];
        refuses_system_prompt_file_equals: ["--system-prompt-file=/abs/system.md"];
        refuses_dangerously_skip_permissions: ["--dangerously-skip-permissions"];
        refuses_allow_dangerously_skip_permissions: ["--allow-dangerously-skip-permissions"];
        refuses_permission_mode: ["--permission-mode", "bypassPermissions"];
        refuses_permission_mode_equals: ["--permission-mode=bypassPermissions"];
        refuses_settings: ["--settings", "{}"];
        refuses_settings_equals: ["--settings={}"];
        refuses_setting_sources: ["--setting-sources", ""];
        refuses_setting_sources_equals: ["--setting-sources="];
        refuses_mcp_config: ["--mcp-config", "/x.json"];
        refuses_mcp_config_equals: ["--mcp-config=/x.json"];
        refuses_allowed_tools: ["--allowedTools", "Bash"];
        refuses_allowed_tools_equals: ["--allowedTools=Bash"];
        refuses_allowed_tools_kebab: ["--allowed-tools", "Bash"];
        refuses_disallowed_tools: ["--disallowedTools", "Bash"];
        refuses_disallowed_tools_kebab: ["--disallowed-tools", "Bash"];
        refuses_add_dir: ["--add-dir", "/"];
        refuses_add_dir_equals: ["--add-dir=/"];
        refuses_append_system_prompt: ["--append-system-prompt", "x"];
        refuses_append_system_prompt_equals: ["--append-system-prompt=x"];
        refuses_system_prompt: ["--system-prompt", "x"];
        refuses_system_prompt_equals: ["--system-prompt=x"];
        refuses_plugin_dir: ["--plugin-dir", "/p"];
        refuses_plugin_dir_equals: ["--plugin-dir=/p"];
        refuses_agents: ["--agents", "{}"];
        refuses_agents_equals: ["--agents={}"];
        refuses_resume: ["--resume", "x"];
        refuses_short_resume: ["-r", "x"];
        refuses_short_continue: ["-c"];
        refuses_short_print: ["-p"];
        refuses_short_debug: ["-d"];
        refuses_model: ["--model", "opus"];
        refuses_session_id_equals: ["--session-id=x"];
        refuses_input_format: ["--input-format", "text"];
        refuses_an_allowed_flag_after_a_refused_one: ["--no-session-persistence", "--add-dir", "/"];
    }

    #[test]
    fn a_non_claude_harness_takes_no_args() {
        let err = check_preset_args(HarnessKind::Acp, &["--no-session-persistence".to_owned()])
            .expect_err("an ACP harness takes no preset args");
        assert!(err.starts_with("args: "), "{err}");
        assert_eq!(check_preset_args(HarnessKind::Acp, &[]), Ok(()));
    }

    #[test]
    fn a_nul_byte_is_refused() {
        assert!(claude(&["--tools", "\0"]).is_err());
    }
}
