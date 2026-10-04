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
