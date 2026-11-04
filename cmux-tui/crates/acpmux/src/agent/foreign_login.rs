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
//!
//! Every path that starts a harness's own program goes through here: an
//! agent (`agent/command.rs`), a fork of a terminal's chat (`chat_fork.rs`),
//! a model list (`live_models`) and a sign-in check (`harness_health/probe.rs`).

use crate::config::{HarnessKind, HarnessProfile};
use tokio::process::Command;

/// The families of harnesses that are one model agent each. Any other
/// family (`chief`, `unii`, a test's `fake`) is left as it was.
/// The discovered ACP agents (`config/discover.rs`) are all here, Muse
/// (`muse-acp`, family from its name) included.
const LEAF_FAMILIES: [&str; 12] = [
    "claude", "codex", "opencode", "gemini", "pi", "omp", "prime", "grok", "cursor", "hermes",
    "deepseek", "muse",
];

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

/// The agent `profile` runs, from its kind and command line first, never
/// its `family` label alone: `{"argv": ["codex-acp"], "family": "mine"}` is
/// Codex, and a Claude Code kind is Claude. A launcher whose program does not
/// name its agent (Cursor's `agent`, `sr`) counts by its profile name
/// (`claude-sr` is Claude). `None` for a host that starts harnesses itself (the
/// Chief brain `chief acp`, `uniichat-agent`), whatever it is called, and for
/// a profile that is not one agent.
pub(crate) fn leaf_family(name: &str, profile: &HarnessProfile) -> Option<String> {
    if profile.kind == HarnessKind::ClaudeStdio {
        return Some("claude".into());
    }
    if is_host(&profile.argv) {
        return None;
    }
    if let Some(family) = argv_family(&profile.argv) {
        return Some(family);
    }
    canonical(name)
}

/// The leaf family a profile name or family label names: itself, or its
/// first word (`claude-sr` is Claude, `opencode-v2` OpenCode).
fn canonical(label: &str) -> Option<String> {
    let lower = label.to_lowercase();
    let head = lower.split(['-', '_', '.']).next().unwrap_or_default();
    [lower.as_str(), head].into_iter().find(|f| LEAF_FAMILIES.contains(f)).map(str::to_owned)
}

/// The agent a command runs (an `auth.check` such as `claude auth status`),
/// else the canonical family of its `label` (`opencode-v2` is OpenCode).
/// `None` for a host's command or a label that names no agent.
pub(crate) fn command_family(argv: &[String], label: &str) -> Option<String> {
    if is_host(argv) {
        return None;
    }
    if let Some(family) = argv_family(argv) {
        return Some(family);
    }
    canonical(label)
}

/// A command line that starts acpmux harnesses under itself, in the exact
/// shape acpmux gives it: the Chief brain (`<cli> chief acp`,
/// `config/discover.rs`) or uniichat (`<acpmux argv> uniichat-agent`).
fn is_host(argv: &[String]) -> bool {
    matches!(argv, [_, chief, acp, ..] if chief == "chief" && acp == "acp")
        || argv.len() > 1 && argv.last().is_some_and(|a| a == "uniichat-agent")
}

/// The leaf agent a command line runs, by exact program name: its executable
/// (`/usr/bin/claude`), or what a package runner or interpreter starts
/// (`npx -y @agentclientprotocol/claude-agent-acp@0.99`, `node
/// .../claude-agent-acp/dist/index.js`). No substring of an argument counts.
fn argv_family(argv: &[String]) -> Option<String> {
    let (program, rest) = argv.split_first()?;
    let by_name = |name: &str| {
        EXECUTABLES.iter().find(|(exe, _)| *exe == name).map(|(_, family)| family.to_string())
    };
    if let Some(family) = by_name(&program_name(program)) {
        return Some(family);
    }
    if !RUNNERS.contains(&program_name(program).as_str()) {
        return None;
    }
    // The first non-option argument is what the runner starts: a package
    // (`@scope/name@version`) or a script path, one of whose folders names it.
    let target = rest.iter().find(|a| !a.starts_with('-'))?;
    let package = target.rsplit('/').next().unwrap_or(target);
    let package = package.split('@').find(|p| !p.is_empty()).unwrap_or(package);
    by_name(&package.to_lowercase()).or_else(|| {
        std::path::Path::new(target)
            .components()
            .filter_map(|c| c.as_os_str().to_str().map(str::to_lowercase))
            .find_map(|c| by_name(&c))
    })
}

/// A program's own name: its file name, lower case, without a Windows or
/// script extension.
fn program_name(program: &str) -> String {
    let name = std::path::Path::new(program)
        .file_name()
        .map(|f| f.to_string_lossy().to_lowercase())
        .unwrap_or_default();
    [".exe", ".cmd", ".js", ".mjs"]
        .iter()
        .find_map(|ext| name.strip_suffix(ext).map(str::to_owned))
        .unwrap_or(name)
}

/// Programs that start another program named by their arguments.
const RUNNERS: [&str; 7] = ["npx", "bunx", "pnpx", "node", "bun", "uvx", "env"];

/// The executables of leaf agents and their families: `derive_family`'s and
/// the launchers discovery finds (`config/discover.rs`).
const EXECUTABLES: [(&str, &str); 19] = [
    ("codex", "codex"),
    ("codex-acp", "codex"),
    ("claude", "claude"),
    ("claude-agent-acp", "claude"),
    ("claude-code-acp", "claude"),
    ("gemini", "gemini"),
    ("opencode", "opencode"),
    ("opencode2", "opencode"),
    ("dsh", "deepseek"),
    ("pi", "pi"),
    ("pi-acp", "pi"),
    ("omp", "omp"),
    ("prime-agent", "prime"),
    ("grok", "grok"),
    ("cursor-agent", "cursor"),
    ("hermes", "hermes"),
    ("muse", "muse"),
    ("muse-acp", "muse"),
    ("deepseek", "deepseek"),
];

/// Every other family's login removed through `remove`, for an agent of
/// `family` started outside [`scrub`]'s profile path (a sign-in probe, a
/// model list). Nothing for a family that is not one agent.
pub(crate) fn remove_foreign_for(family: &str, mut remove: impl FnMut(&str)) {
    if LEAF_FAMILIES.contains(&family) {
        foreign_login_keys(family).for_each(&mut remove);
    }
}

/// Remove every other family's login from `cmd`, whatever set it so far
/// (the daemon's own env, the login shell, machine env), for the agent
/// `profile` runs. Call before the profile's own env is applied.
pub(crate) fn scrub(cmd: &mut Command, name: &str, profile: &HarnessProfile) {
    let Some(family) = leaf_family(name, profile) else { return };
    remove_foreign_for(&family, |key| {
        cmd.env_remove(key);
    });
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
    fn a_probe_or_model_list_of_one_agent_loses_the_other_logins_and_a_host_keeps_them() {
        let removed = |family: &str| {
            let mut keys = Vec::new();
            remove_foreign_for(family, |key| keys.push(key.to_owned()));
            keys
        };
        assert!(removed("codex").contains(&"CLAUDE_CODE_OAUTH_TOKEN".to_owned()));
        assert!(removed("claude").contains(&"CODEX_HOME".to_owned()));
        assert!(removed("chief").is_empty());
    }

    #[test]
    fn a_sign_in_check_counts_by_the_agent_it_runs_or_its_canonical_label() {
        let argv = |words: &[&str]| words.iter().map(|w| w.to_string()).collect::<Vec<_>>();
        assert_eq!(
            command_family(&argv(&["claude", "auth", "status"]), "mine").as_deref(),
            Some("claude")
        );
        assert_eq!(
            command_family(&argv(&["/opt/x", "auth"]), "opencode-v2").as_deref(),
            Some("opencode")
        );
        assert_eq!(command_family(&argv(&["cmux", "chief", "status"]), "codex"), None);
        assert_eq!(command_family(&argv(&["/opt/x"]), "custom"), None);
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
        // Muse through its ACP adapter, as discovery makes it (family `muse`).
        assert_eq!(
            leaf_family("muse", &profile("/opt/bin/muse-acp", Some("muse"))).as_deref(),
            Some("muse")
        );
        // A launcher `derive_family` does not know, under a made-up label.
        let mut cursor = profile("/opt/bin/cursor-agent", Some("custom"));
        cursor.argv.push("acp".into());
        assert_eq!(leaf_family("custom", &cursor).as_deref(), Some("cursor"));
        // The program names the agent before any other word does.
        let mut claude = profile("/usr/bin/claude", None);
        claude.argv.extend(["--add-dir".into(), "/src/codex".into()]);
        assert_eq!(leaf_family("mine", &claude).as_deref(), Some("claude"));
        // Only exact program names count, never a substring of an argument.
        let mut prompt = profile("/opt/tools/mytool", None);
        prompt.argv.extend(["--prompt".into(), "/home/claude/codex".into()]);
        assert_eq!(leaf_family("mytool", &prompt), None);
        let mut npx = profile("npx", None);
        npx.argv.extend(["-y".into(), "@agentclientprotocol/claude-agent-acp@0.99.1".into()]);
        assert_eq!(leaf_family("mine", &npx).as_deref(), Some("claude"));
        let mut node = profile("/usr/bin/node", None);
        node.argv.push("/opt/lib/node_modules/@zed/claude-agent-acp/dist/index.js".into());
        assert_eq!(leaf_family("mine", &node).as_deref(), Some("claude"));
        // An ordinary `chief` argument does not make a command a host.
        let mut chiefarg = profile("/usr/bin/codex", None);
        chiefarg.argv.extend(["exec".into(), "chief".into()]);
        assert_eq!(leaf_family("mine", &chiefarg).as_deref(), Some("codex"));
        // A host is never one agent, whatever its name says.
        let mut host = profile("/usr/local/bin/cmux", None);
        host.argv.extend(["chief".into(), "acp".into()]);
        assert_eq!(leaf_family("codex-host", &host), None);
        // A launcher that does not name its agent counts by the profile's name.
        assert_eq!(
            leaf_family("deepseek", &profile("/opt/bin/dsh", None)).as_deref(),
            Some("deepseek")
        );
        let mut chief = profile("cmux-tui", Some("chief"));
        chief.argv = vec!["cmux-tui".into(), "chief".into(), "acp".into()];
        assert_eq!(leaf_family("chief", &chief), None);
        let mut stdio = profile("anything", Some("router"));
        stdio.kind = HarnessKind::ClaudeStdio;
        assert_eq!(leaf_family("router", &stdio).as_deref(), Some("claude"));
    }
}
