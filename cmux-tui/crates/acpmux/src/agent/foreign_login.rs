//! Each harness's own login variables, and their removal from every other
//! harness's environment.
//!
//! An agent inherits the daemon's environment. A daemon started with one
//! harness's login in its env (`CLAUDE_CODE_OAUTH_TOKEN` for Claude Code)
//! handed it to every agent it started, Codex included, and Codex writes its
//! whole shell environment to `~/.codex/shell_snapshots`: the Claude login
//! ended up on disk in a file Claude Code never reads (machine-vault-e2e,
//! 2026-11-04). A harness gets only its own family's login from the daemon,
//! the login shell or machine env; a profile, preset or session value
//! (applied after this removal) still passes on purpose. That includes a
//! name delivered in machine secrets or added to `loginEnvAllow`: another
//! harness's login never reaches an agent through those either (a delivered
//! `OPENAI_API_KEY` no longer reaches Claude Code's Bash); put it in the
//! profile's env to give it on purpose.
//!
//! Only a harness that is one model agent is scrubbed ([`LEAF_FAMILIES`]).
//! A profile that runs acpmux or cmux itself and starts harnesses under it
//! (the Chief brain, `chief acp`) passes every login on to them on purpose
//! (`cli/chief/launch.rs` `brain_env_allowed`), so it keeps them.

use crate::config::{HarnessKind, HarnessProfile};
use tokio::process::Command;

/// The families of harnesses that are one model agent each. Any other
/// family (`chief`, `unii`, a test's `fake`) is left as it was.
const LEAF_FAMILIES: [&str; 7] = ["claude", "codex", "opencode", "gemini", "pi", "omp", "prime"];

/// A login variable and the harness family it belongs to. Every key of the
/// pool's credential fingerprint (`hub/pool/auth.rs` `AUTH_ENV`) that is one
/// harness's login is here (`XDG_DATA_HOME` is not one harness's).
///
/// `shared_with_others`: the key is a provider API key that a multi-provider
/// harness (OpenCode, pi, Gemini, ...) may use as its own login, so only the
/// other single-login families (Claude Code, Codex) lose it. A harness's own
/// sign-in (an OAuth token, a config or home folder) is removed from every
/// other family.
pub(crate) const LOGIN_ENV_OWNERS: &[LoginEnv] = &[
    LoginEnv { key: "CLAUDE_CODE_OAUTH_TOKEN", family: "claude", shared_with_others: false },
    LoginEnv { key: "CLAUDE_CONFIG_DIR", family: "claude", shared_with_others: false },
    LoginEnv { key: "ANTHROPIC_API_KEY", family: "claude", shared_with_others: true },
    LoginEnv { key: "ANTHROPIC_AUTH_TOKEN", family: "claude", shared_with_others: true },
    LoginEnv { key: "OPENAI_API_KEY", family: "codex", shared_with_others: true },
    LoginEnv { key: "CODEX_HOME", family: "codex", shared_with_others: false },
    LoginEnv { key: "OPENCODE_CONFIG", family: "opencode", shared_with_others: false },
];

/// The families whose login is exactly their own keys above.
const SINGLE_LOGIN_FAMILIES: [&str; 2] = ["claude", "codex"];

#[derive(Debug, Clone, Copy)]
pub(crate) struct LoginEnv {
    pub(crate) key: &'static str,
    pub(crate) family: &'static str,
    pub(crate) shared_with_others: bool,
}

/// The login keys a harness of `family` must not inherit.
pub(crate) fn foreign_login_keys(family: &str) -> impl Iterator<Item = &'static str> + '_ {
    LOGIN_ENV_OWNERS
        .iter()
        .filter(move |login| {
            login.family != family
                && (!login.shared_with_others || SINGLE_LOGIN_FAMILIES.contains(&family))
        })
        .map(|login| login.key)
}

/// The agent `profile` runs, from its kind and command line, never its
/// `family` label: `{"argv": ["codex-acp"], "family": "mine"}` is Codex. A
/// Claude Code kind is Claude. `None` for a profile that is not one agent.
pub(crate) fn leaf_family(name: &str, profile: &HarnessProfile) -> Option<String> {
    if profile.kind == HarnessKind::ClaudeStdio {
        return Some("claude".into());
    }
    let unnamed = HarnessProfile { family: None, ..profile.clone() };
    let family = crate::config::derive_family(name, &unnamed);
    LEAF_FAMILIES.contains(&family.as_str()).then_some(family)
}

/// Remove every other family's login from `cmd`, whatever set it so far
/// (the daemon's own env, the login shell, machine env), for the agent
/// `profile` runs. Call before the profile's own env is applied.
pub(crate) fn scrub(cmd: &mut Command, name: &str, profile: &HarnessProfile) {
    let Some(family) = leaf_family(name, profile) else { return };
    for key in foreign_login_keys(&family) {
        cmd.env_remove(key);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn claude_and_codex_lose_each_others_login() {
        let codex: Vec<_> = foreign_login_keys("codex").collect();
        for key in ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR", "ANTHROPIC_API_KEY"] {
            assert!(codex.contains(&key), "{key} reaches Codex");
        }
        assert!(!codex.contains(&"OPENAI_API_KEY") && !codex.contains(&"CODEX_HOME"));
        let claude: Vec<_> = foreign_login_keys("claude").collect();
        for key in ["OPENAI_API_KEY", "CODEX_HOME", "OPENCODE_CONFIG"] {
            assert!(claude.contains(&key), "{key} reaches Claude Code");
        }
        assert!(!claude.contains(&"CLAUDE_CODE_OAUTH_TOKEN"));
    }

    #[test]
    fn a_multi_provider_harness_keeps_provider_keys_but_not_other_sign_ins() {
        let opencode: Vec<_> = foreign_login_keys("opencode").collect();
        assert!(opencode.contains(&"CLAUDE_CODE_OAUTH_TOKEN") && opencode.contains(&"CODEX_HOME"));
        assert!(!opencode.contains(&"ANTHROPIC_API_KEY") && !opencode.contains(&"OPENAI_API_KEY"));
        assert!(!opencode.contains(&"OPENCODE_CONFIG"));
    }

    #[test]
    fn the_family_comes_from_what_runs_and_a_host_is_left_alone() {
        let profile = |argv: &str, family: Option<&str>| {
            let mut p: HarnessProfile =
                serde_json::from_value(serde_json::json!({"argv": [argv]})).unwrap();
            p.family = family.map(str::to_string);
            p
        };
        assert_eq!(
            leaf_family("mine", &profile("codex-acp", Some("mine"))).as_deref(),
            Some("codex")
        );
        assert_eq!(
            leaf_family("claude-xyz", &profile("claude-acp", Some("claude-xyz"))).as_deref(),
            Some("claude")
        );
        let mut chief = profile("cmux-tui", Some("chief"));
        chief.argv = vec!["cmux-tui".into(), "chief".into(), "acp".into()];
        assert_eq!(leaf_family("chief", &chief), None);
        let mut stdio = profile("anything", Some("router"));
        stdio.kind = HarnessKind::ClaudeStdio;
        assert_eq!(leaf_family("router", &stdio).as_deref(), Some("claude"));
    }
}
