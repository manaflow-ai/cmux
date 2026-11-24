//! A Codex launch on a machine where Codex has no way in at all: refused at spawn, with the host,
//! the harness and the fix, instead of a chat that starts and then fails every turn.
//!
//! Lane VMs have no cmux Cloud marker and no join, so neither `codex_cloud_auth.rs` nor
//! `joined_model_plane.rs` looks at them. Codex sessions were started on lane VMs that had no
//! Codex login, and each one failed only at its first turn (hq#21792 event 12, the 2026-11-23 API
//! overload incident). Leo: "all events need to be investigated and fixed".
//!
//! [`no_way_in`] is the cheap part: no sign-in file or key (`Inputs::own_login`), no Mac broker
//! access file, no `OPENAI_API_KEY` or `OPENAI_BASE_URL`, and no model provider other than the
//! built-in `openai` in the argv or `config.toml` (a lane VM's `subrouter` provider needs no
//! `codex login`). Only then does [`says_not_logged_in`] ask the launch's own program
//! (`codex login status`), which also sees a keyring sign-in. Only its plain "Not logged in"
//! refuses; a timeout, an error or any other answer lets the launch start as before.

use std::collections::BTreeMap;
use std::path::Path;
use std::time::Duration;

use crate::codex_cloud_auth::{Inputs, PLACEHOLDER_KEY};

/// How long `codex login status` may take before the launch goes ahead unchecked.
const STATUS_TIMEOUT: Duration = Duration::from_secs(5);

/// Whether nothing in the launch's env, argv or Codex home gives it a way to a model.
pub(crate) fn no_way_in(inputs: &Inputs<'_>, argv: &[String]) -> bool {
    if inputs.own_login() || inputs.broker {
        return false;
    }
    if (inputs.var)("OPENAI_API_KEY").is_some_and(|k| k != PLACEHOLDER_KEY)
        || (inputs.var)("OPENAI_BASE_URL").is_some()
    {
        return false;
    }
    if argv.iter().any(|a| a.contains("model_provider") && !names_openai(a)) {
        return false;
    }
    !config_names_provider(&inputs.codex_home().join("config.toml"))
}

/// `model_provider=openai` in any quoting: the built-in provider, which needs `codex login`.
fn names_openai(arg: &str) -> bool {
    let Some((_, value)) = arg.split_once('=') else { return false };
    value.trim().trim_matches(|c| c == '"' || c == '\'') == "openai"
}

/// Whether `config.toml` sets a top-level `model_provider` other than `openai`.
fn config_names_provider(path: &Path) -> bool {
    let Ok(text) = std::fs::read_to_string(path) else { return false };
    for line in text.lines() {
        let line = line.trim();
        if line.starts_with('[') {
            return false;
        }
        if line.starts_with("model_provider") && line.contains('=') && !names_openai(line) {
            return true;
        }
    }
    false
}

/// Whether `program login status`, run with the launch's Codex home, answers "Not logged in".
pub(crate) async fn says_not_logged_in(program: &str, env: &BTreeMap<String, String>) -> bool {
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(["login", "status"])
        .envs(env)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);
    let Ok(Ok(out)) = tokio::time::timeout(STATUS_TIMEOUT, cmd.output()).await else {
        return false;
    };
    let text =
        format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    !out.status.success() && text.contains("Not logged in")
}

/// The refusal: the host, the harness and the fix.
pub(crate) fn refusal(host: &str, harness: &str) -> String {
    format!(
        "{} ({host}): `codex login status` says Not logged in, and the `{harness}` harness has no \
         API key or model provider set, so its turns cannot run. Run `codex login` on {host} (or \
         set CODEX_API_KEY there), or start the session on another harness (-m claude).",
        crate::codex_cloud_auth::NOT_SIGNED_IN
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_provider_other_than_openai_is_a_way_in() {
        assert!(names_openai("model_provider=\"openai\""));
        assert!(names_openai("model_provider = 'openai'"));
        assert!(!names_openai("model_provider=\"subrouter\""));
        let dir =
            std::env::temp_dir().join(format!("acpmux-codex-signed-out-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("config.toml");
        std::fs::write(&path, "model_provider = \"subrouter\"\n").unwrap();
        assert!(config_names_provider(&path));
        std::fs::write(&path, "model_provider = \"openai\"\n").unwrap();
        assert!(!config_names_provider(&path));
        std::fs::write(&path, "[profiles.x]\nmodel_provider = \"subrouter\"\n").unwrap();
        assert!(!config_names_provider(&path), "only the top level counts");
        let _ = std::fs::remove_dir_all(&dir);
    }
}
