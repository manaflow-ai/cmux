//! `_acpmux/customize_run`: the Try it on, Keep, Revert and Go buttons of a wrap-up card
//! (`wrap_up` actions of the form `{label, run}`, `acpmux_mcp_wrap_up.rs`). The page never names a
//! command: it sends one of four typed requests, which this turns into the argv of
//! `cmux customize try TARGET [--minutes N]`, `cmux customize keep`, `cmux customize revert` or
//! `cmux customize go pr:N` (the PR tried on is merge-ready at the head the person saw), run
//! without a shell. Leo, 2026-11-25: "have that one click merge ready, or like one click readiness
//! to merge, like the go button for that to happen". Every field is checked against a short allowlist first, so a call cannot
//! carry a flag or a second command. Leo, 2026-11-24: "A MOTHERFUCKING THING AT TURN END OF A WAY
//! TO TRY ON THE CUSTOMIZATION. FUCKING BOOM. AND A WAY TO SAVE IT OR SHARE IT."

use serde_json::{Value, json};
use std::time::Duration;

/// The longest a customize command may run (a `pr:N` try waits for a download).
const LIMIT: Duration = Duration::from_secs(180);
/// The longest a try-on may last, in minutes.
pub(crate) const MAX_MINUTES: u64 = 240;

/// Whether `target` names code or a profile `cmux customize try` takes: `pr:N`, `branch:B`,
/// `sha:S`, `dir:PATH`, or a profile NAME. Never a flag, never a control character.
pub(crate) fn valid_target(target: &str) -> bool {
    if target.is_empty() || target.len() > 400 || target.starts_with('-') {
        return false;
    }
    if target.chars().any(char::is_control) {
        return false;
    }
    let word = |s: &str, ok: fn(char) -> bool| !s.is_empty() && s.chars().all(ok);
    match target.split_once(':') {
        Some(("pr", n)) => word(n, |c| c.is_ascii_digit()),
        Some(("sha", s)) => word(s, |c| c.is_ascii_hexdigit()) && (7..=40).contains(&s.len()),
        Some(("branch", b)) => {
            word(b, |c| c.is_ascii_alphanumeric() || "._/-".contains(c)) && !b.starts_with('-')
        }
        Some(("dir", p)) => !p.is_empty() && !p.starts_with('-'),
        Some(_) => false,
        None => {
            word(target, |c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
        }
    }
}

/// The argv after `cmux` for the typed request `run`, or why it is refused.
pub(crate) fn argv(run: &Value) -> Result<Vec<String>, String> {
    let verb = run.get("customize").and_then(Value::as_str).unwrap_or_default();
    let mut out = vec!["customize".to_owned(), verb.to_owned()];
    match verb {
        "keep" | "revert" => {}
        "go" => {
            let target = run.get("target").and_then(Value::as_str).unwrap_or_default();
            match target.split_once(':') {
                Some(("pr", n)) if valid_target(target) && n.len() <= 9 => {
                    out.push(target.to_owned())
                }
                _ => return Err("go takes the PR tried on: pr:N".into()),
            }
        }
        "try" => {
            let target = run.get("target").and_then(Value::as_str).unwrap_or_default();
            if !valid_target(target) {
                return Err(
                    "target must be pr:N, branch:B, sha:S, dir:PATH or a profile name".into()
                );
            }
            out.push(target.to_owned());
            if let Some(minutes) = run.get("minutes").filter(|v| !v.is_null()) {
                let minutes = minutes
                    .as_u64()
                    .filter(|m| (1..=MAX_MINUTES).contains(m))
                    .ok_or_else(|| format!("minutes is a whole number from 1 to {MAX_MINUTES}"))?;
                out.extend(["--minutes".to_owned(), minutes.to_string()]);
            }
        }
        _ => return Err("customize is try, keep, revert or go".into()),
    }
    Ok(out)
}

/// Runs the typed request `params.run`: `{ok, output}`, `ok` false with the command's own words
/// when it failed.
pub(crate) async fn run(params: &Value) -> Result<Value, String> {
    let args = argv(params.get("run").unwrap_or(&Value::Null))?;
    let binary =
        std::env::var_os("CMUX_BIN").filter(|v| !v.is_empty()).unwrap_or_else(|| "cmux".into());
    let mut command = tokio::process::Command::new(binary);
    command.kill_on_drop(true).args(&args).stdin(std::process::Stdio::null());
    if let Some(socket) = std::env::var_os("CMUX_SOCKET_PATH").filter(|v| !v.is_empty()) {
        command.env("CMUX_SOCKET_PATH", socket);
    }
    let output = tokio::time::timeout(LIMIT, command.output())
        .await
        .map_err(|_| "customize took too long".to_owned())?
        .map_err(|e| format!("cmux customize did not start: {e}"))?;
    let text =
        |bytes: &[u8]| String::from_utf8_lossy(bytes).trim().chars().take(4000).collect::<String>();
    let said = if output.status.success() { text(&output.stdout) } else { text(&output.stderr) };
    Ok(json!({"ok": output.status.success(), "output": said}))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_three_typed_requests_become_argv() {
        assert_eq!(
            argv(&json!({"customize": "try", "target": "pr:51234", "minutes": 15})).unwrap(),
            ["customize", "try", "pr:51234", "--minutes", "15"]
        );
        assert_eq!(
            argv(&json!({"customize": "try", "target": "darker"})).unwrap(),
            ["customize", "try", "darker"]
        );
        assert_eq!(argv(&json!({"customize": "keep"})).unwrap(), ["customize", "keep"]);
        assert_eq!(argv(&json!({"customize": "revert"})).unwrap(), ["customize", "revert"]);
        assert_eq!(
            argv(&json!({"customize": "go", "target": "pr:57001"})).unwrap(),
            ["customize", "go", "pr:57001"]
        );
    }

    #[test]
    fn anything_else_is_refused() {
        for bad in [
            json!({}),
            json!({"customize": "apply"}),
            json!({"customize": "try"}),
            json!({"customize": "try", "target": "--help"}),
            json!({"customize": "try", "target": "pr:x"}),
            json!({"customize": "try", "target": "sha:zz"}),
            json!({"customize": "try", "target": "dir:--x"}),
            json!({"customize": "try", "target": "a b"}),
            json!({"customize": "try", "target": "x;rm", "minutes": 5}),
            json!({"customize": "try", "target": "pr:1", "minutes": 0}),
            json!({"customize": "try", "target": "pr:1", "minutes": 241}),
            json!({"customize": "try", "target": "pr:1", "minutes": "5"}),
            json!({"customize": "go"}),
            json!({"customize": "go", "target": "branch:x"}),
            json!({"customize": "go", "target": "darker"}),
            json!({"customize": "go", "target": "pr:"}),
        ] {
            assert!(argv(&bad).is_err(), "{bad}");
        }
        assert!(valid_target("branch:lane/live-artifacts-chat") && valid_target("dir:/tmp/my dir"));
    }
}
