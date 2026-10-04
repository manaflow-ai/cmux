//! A preset's `args`: extra words appended to the harness command line.
//!
//! Each entry is one argv word handed to the process as it is (no shell, so
//! quoting, globs and `$(…)` stay literal and an empty string is a real empty
//! argument). On a Claude stdio command line acpmux already passes the flags
//! that carry its protocol and its session state; a preset that sets one of
//! them again would break the session, so those are refused.

use serde_json::Value;

use super::HarnessKind;

/// Claude Code flags acpmux sets itself (`claude_stdio::spawn_plan`), plus
/// the ones that would resume another conversation or bypass the
/// permission policy.
const CLAUDE_OWNED: [&str; 18] = [
    "-p",
    "--print",
    "--input-format",
    "--output-format",
    "--include-partial-messages",
    "--permission-prompt-tool",
    "--permission-mode",
    "--dangerously-skip-permissions",
    "--allow-dangerously-skip-permissions",
    "-r",
    "--resume",
    "-c",
    "--continue",
    "--fork-session",
    "--session-id",
    "--model",
    "--effort",
    "--replay-user-messages",
];

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
    for arg in args {
        if arg.contains('\0') {
            return Err(format!("args: {arg:?} contains a NUL byte"));
        }
        if kind == HarnessKind::ClaudeStdio {
            let flag = arg.split_once('=').map_or(arg.as_str(), |(f, _)| f);
            if CLAUDE_OWNED.contains(&flag) {
                return Err(format!(
                    "args: acpmux sets {flag} on a Claude command line itself; a preset may not"
                ));
            }
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn claude(args: &[&str]) -> Result<(), String> {
        check_preset_args(HarnessKind::ClaudeStdio, &args.iter().map(|a| (*a).to_owned()).collect::<Vec<_>>())
    }

    #[test]
    fn the_allowlisted_words_pass() {
        assert_eq!(claude(&[]), Ok(()));
        assert_eq!(claude(&["--tools", "", "--strict-mcp-config", "--no-session-persistence"]), Ok(()));
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
