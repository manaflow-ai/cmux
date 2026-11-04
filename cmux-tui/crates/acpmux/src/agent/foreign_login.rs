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
//! Which agent a profile runs comes from its kind and its command line by
//! exact program names ([`classify`]). A host that starts harnesses under it
//! (only the Chief brain, `<cli> chief acp`) passes every login on
//! to them on purpose (`cli/chief/launch.rs` `brain_env_allowed`), so it keeps
//! them. A command line that names no known agent, or more than one, loses
//! every harness's own sign-in and keeps only the provider API keys: the safe
//! side; its profile's env can still give it a login on purpose.
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

/// What a harness's command line runs, for the scrub.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Runs {
    /// One agent of this leaf family: every other family's login goes.
    Agent(String),
    /// A host that starts harnesses itself: it keeps every login.
    Host,
    /// No known agent, or more than one: every family's own sign-in goes.
    Unknown,
}

impl Runs {
    /// The family whose login is kept, for [`foreign_login_keys`]: none for
    /// an unknown command (`""` keeps only the provider API keys).
    fn kept(&self) -> Option<&str> {
        match self {
            Self::Agent(family) => Some(family),
            Self::Host => None,
            Self::Unknown => Some(""),
        }
    }
}

/// What `profile` (named `name`) runs: a Claude Code kind is Claude; a host's
/// exact shape is a host; else the agents its command line names exactly
/// ([`argv_families`]), and only when that names none, its profile name's
/// first word (`claude-sr` running `sr` is Claude, `cursor` running `agent`
/// is Cursor). The `family` label never decides.
pub(crate) fn classify(name: &str, profile: &HarnessProfile) -> Runs {
    if profile.kind == HarnessKind::ClaudeStdio {
        return Runs::Agent("claude".into());
    }
    classify_command(&profile.argv, name)
}

/// [`classify`] for a bare command (a sign-in check such as `claude auth
/// status`) and the name or label it belongs to.
pub(crate) fn classify_command(argv: &[String], label: &str) -> Runs {
    if is_host(argv) {
        return Runs::Host;
    }
    let found = argv_families(argv);
    match found.as_slice() {
        [one] => Runs::Agent(one.clone()),
        [] => canonical(label).map_or(Runs::Unknown, Runs::Agent),
        _ => Runs::Unknown,
    }
}

/// The leaf family `profile` runs, when it runs exactly one known agent.
pub(crate) fn leaf_family(name: &str, profile: &HarnessProfile) -> Option<String> {
    match classify(name, profile) {
        Runs::Agent(family) => Some(family),
        Runs::Host | Runs::Unknown => None,
    }
}

/// The leaf family a profile name or family label names: itself, or its
/// first word (`claude-sr` is Claude, `opencode-v2` OpenCode).
fn canonical(label: &str) -> Option<String> {
    let lower = label.to_lowercase();
    let head = lower.split(['-', '_', '.']).next().unwrap_or_default();
    [lower.as_str(), head].into_iter().find(|f| LEAF_FAMILIES.contains(f)).map(str::to_owned)
}

/// A command line that starts acpmux harnesses under itself: the Chief
/// brain, exactly `<cmux-tui|cmux|acpmux> chief acp` as discovery makes it
/// (`config/discover.rs` `add_chief`). Nothing else keeps every login: not
/// uniichat (`uniichat-agent` is a network agent and starts no harness), not
/// a wrapper whose name merely starts with `cmux-`.
fn is_host(argv: &[String]) -> bool {
    matches!(argv, [program, chief, acp, ..]
        if HOST_PROGRAMS.contains(&program_name(program).as_str()) && chief == "chief" && acp == "acp")
}

/// acpmux's own multicall binary names.
const HOST_PROGRAMS: [&str; 3] = ["cmux-tui", "cmux", "acpmux"];

/// The distinct leaf families a command line names by exact program name:
/// its executable (`/usr/bin/claude`), and when that is a runner (`npx`,
/// `node`, `env`, `bun`, ...), any later word that is an agent's executable,
/// package (`@agentclientprotocol/claude-agent-acp@0.99`) or a folder of a
/// script path (`.../claude-agent-acp/dist/index.js`). No substring counts.
fn argv_families(argv: &[String]) -> Vec<String> {
    let by_name = |name: &str| {
        EXECUTABLES.iter().find(|(exe, _)| *exe == name).map(|(_, family)| family.to_string())
    };
    let Some((program, rest)) = argv.split_first() else { return Vec::new() };
    if let Some(family) = by_name(&program_name(program)) {
        return vec![family];
    }
    if !RUNNERS.contains(&program_name(program).as_str()) {
        return Vec::new();
    }
    let mut found: Vec<String> = Vec::new();
    // Only words that can be what the runner starts: no option (`-y`,
    // `--require`), no option's value (`--require loader.js`), no `K=V`
    // assignment (`env FOO=/tmp/codex-acp tool`).
    let mut skip_value = false;
    for word in rest {
        if std::mem::take(&mut skip_value) {
            continue;
        }
        if word.starts_with('-') {
            skip_value = !word.contains('=') && OPTIONS_WITH_VALUE.contains(&word.as_str());
            continue;
        }
        if word.contains('=') {
            continue;
        }
        let package = word.rsplit('/').next().unwrap_or(word);
        let package = package.split('@').find(|p| !p.is_empty()).unwrap_or(package);
        let hit = by_name(&program_name(package)).or_else(|| {
            std::path::Path::new(word)
                .components()
                .filter_map(|c| c.as_os_str().to_str().map(str::to_lowercase))
                .find_map(|c| by_name(&c))
        });
        if let Some(family) = hit.filter(|f| !found.contains(f)) {
            found.push(family);
        }
    }
    found
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

/// Runner options whose next word is their value, never the program.
const OPTIONS_WITH_VALUE: [&str; 8] =
    ["--require", "-r", "--import", "--loader", "--experimental-loader", "-p", "--package", "-C"];

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

/// Every login `runs` must not inherit, removed through `remove`, for an
/// agent started outside [`scrub`]'s profile path (a sign-in check, a model
/// list).
pub(crate) fn remove_foreign(runs: &Runs, mut remove: impl FnMut(&str)) {
    if let Some(kept) = runs.kept() {
        foreign_login_keys(kept).for_each(&mut remove);
    }
}

/// Remove every login the agent `profile` runs must not inherit from `cmd`,
/// whatever set it so far (the daemon's own env, the login shell, machine
/// env). Call before the profile's own env is applied.
pub(crate) fn scrub(cmd: &mut Command, name: &str, profile: &HarnessProfile) {
    remove_foreign(&classify(name, profile), |key| {
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
    fn an_agent_loses_the_other_logins_an_unknown_command_every_sign_in_and_a_host_none() {
        let removed = |runs: Runs| {
            let mut keys = Vec::new();
            remove_foreign(&runs, |key| keys.push(key.to_owned()));
            keys
        };
        let codex = removed(Runs::Agent("codex".into()));
        assert!(codex.contains(&"CLAUDE_CODE_OAUTH_TOKEN".to_owned()));
        assert!(removed(Runs::Agent("claude".into())).contains(&"CODEX_HOME".to_owned()));
        assert!(removed(Runs::Host).is_empty());
        let unknown = removed(Runs::Unknown);
        for key in ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "OPENCODE_CONFIG"]
        {
            assert!(unknown.contains(&key.to_owned()), "{key} reaches an unknown agent");
        }
        assert!(!unknown.contains(&"OPENAI_API_KEY".to_owned()));
    }

    #[test]
    fn a_command_counts_by_the_one_agent_it_names_exactly() {
        let argv = |words: &[&str]| words.iter().map(|w| w.to_string()).collect::<Vec<_>>();
        let agent = |f: &str| Runs::Agent(f.into());
        assert_eq!(classify_command(&argv(&["claude", "auth", "status"]), "mine"), agent("claude"));
        assert_eq!(classify_command(&argv(&["/opt/x", "auth"]), "opencode-v2"), agent("opencode"));
        assert_eq!(classify_command(&argv(&["cmux", "chief", "acp"]), "codex"), Runs::Host);
        assert_eq!(
            classify_command(&argv(&["/App/bin/cmux", "acp", "uniichat-agent"]), "unii"),
            Runs::Host
        );
        // The host words after another program are no host.
        assert_eq!(
            classify_command(&argv(&["codex", "exec", "uniichat-agent"]), "x"),
            agent("codex")
        );
        assert_eq!(classify_command(&argv(&["/opt/x", "chief", "acp"]), "x"), Runs::Unknown);
        assert_eq!(classify_command(&argv(&["/opt/x"]), "custom"), Runs::Unknown);
        // A runner's agent, wherever it stands among the runner's arguments.
        for words in [
            &["env", "CLAUDE_CONFIG_DIR=/tmp", "codex-acp"][..],
            &["node", "--require", "loader.js", "codex-acp"],
            &["bun", "x", "codex-acp"],
        ] {
            assert_eq!(classify_command(&argv(words), "custom"), agent("codex"), "{words:?}");
        }
        // Two agents named: neither is trusted, every sign-in goes.
        assert_eq!(
            classify_command(&argv(&["npx", "codex-acp", "--then", "claude"]), "mine"),
            Runs::Unknown
        );
        // `chief` as an ordinary argument is no host.
        assert_eq!(
            classify_command(&argv(&["/usr/bin/codex", "exec", "chief"]), "x"),
            agent("codex")
        );
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
