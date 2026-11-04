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
    // Codex's own API-key sign-in (`agent_login.rs` `MODEL_PLANE_ENV`).
    LoginEnv { key: "CODEX_API_KEY", family: "codex", shared_with_others: false },
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
/// ([`argv_family`]), and only when that names none, its profile name's
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
    match argv_family(argv) {
        Ok(Some(family)) => Runs::Agent(family),
        // The command names no agent: its name or label may (`opencode-v2`).
        Ok(None) => canonical(label).map_or(Runs::Unknown, Runs::Agent),
        // A runner whose program cannot be told: no name or label decides.
        Err(Ambiguous) => Runs::Unknown,
    }
}

/// The leaf family `profile` runs, when it runs exactly one known agent.
#[cfg(test)]
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
/// brain, `<cli> chief acp` where `<cli>` is this very binary or the
/// `cmux-tui` beside it, as discovery makes it (`config/discover.rs`
/// `add_chief`). A `cmux` elsewhere on PATH (another app's CLI, a planted
/// file) is no host; nor is uniichat (`uniichat-agent` is a network agent and
/// starts no harness).
fn is_host(argv: &[String]) -> bool {
    let [program, chief, acp, ..] = argv else { return false };
    chief == "chief" && acp == "acp" && is_own_binary(std::path::Path::new(program))
}

/// Whether `program` is this binary, or the `cmux-tui` beside it, after
/// links are resolved.
/// The installed path counts, as `SelfCommand` names it: after an update
/// replaced the file, Linux's `current_exe` ends in ` (deleted)`.
fn is_own_binary(program: &std::path::Path) -> bool {
    let Ok(this) = crate::self_command::SelfCommand::current().map(|s| s.exe) else {
        return false;
    };
    let beside = this.parent().map(|dir| dir.join("cmux-tui"));
    let same = |a: &std::path::Path, b: &std::path::Path| {
        a == b || matches!((a.canonicalize(), b.canonicalize()), (Ok(a), Ok(b)) if a == b)
    };
    same(program, &this) || beside.is_some_and(|beside| same(program, &beside))
}

/// The leaf family a command line names by exact program name: its
/// executable (`/usr/bin/claude`), or, when that is a runner (`npx`, `node`,
/// `env`, `bun`, ...), the program the runner starts: its first word after
/// `K=V` assignments (`env` only) and the flags known to stand alone (`-y`).
/// That word names the agent by its executable, its package
/// (`@agentclientprotocol/claude-agent-acp@0.99`) or, for a script, a folder
/// of its path when `node` or `bun` runs it (`.../claude-agent-acp/dist/index.js`). Any other option before
/// it (one that may take a value: `--require x.js`, `--chdir /tmp/codex-acp`),
/// or a runner with no program, is [`Ambiguous`]: no guess, and no label decides. No substring counts.
fn argv_family(argv: &[String]) -> Result<Option<String>, Ambiguous> {
    let by_name = |name: &str| {
        EXECUTABLES.iter().find(|(exe, _)| *exe == name).map(|(_, family)| family.to_string())
    };
    let Some((program, rest)) = argv.split_first() else { return Ok(None) };
    let runner = program_name(program);
    if let Some(family) = by_name(&runner) {
        return Ok(Some(family));
    }
    if !RUNNERS.contains(&runner.as_str()) {
        return Ok(None);
    }
    let mut words = rest.iter();
    let target = loop {
        let Some(word) = words.next() else { return Err(Ambiguous) };
        if STANDALONE_FLAGS.contains(&word.as_str()) || runner == "bun" && word == "x" {
            continue;
        }
        if word.starts_with('-') {
            return Err(Ambiguous);
        }
        if word.contains('=') {
            if runner == "env" {
                continue;
            }
            return Err(Ambiguous);
        }
        break word;
    };
    let package = target.rsplit('/').next().unwrap_or(target);
    let package = package.split('@').find(|p| !p.is_empty()).unwrap_or(package);
    let script_runner = matches!(runner.as_str(), "node" | "bun");
    let family = by_name(&program_name(package)).or_else(|| {
        // Only a script names its agent by a folder (`.../claude-agent-acp/dist/index.js`).
        if !script_runner {
            return None;
        }
        std::path::Path::new(target)
            .components()
            .filter_map(|c| c.as_os_str().to_str().map(str::to_lowercase))
            .find_map(|c| by_name(&c))
    });
    Ok(family)
}

/// A runner command whose program cannot be told from its words.
#[derive(Debug)]
struct Ambiguous;

/// Runner flags that take no value, so the next word may be the program.
const STANDALONE_FLAGS: [&str; 6] = ["-y", "--yes", "-q", "--quiet", "--bun", "--"];

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
        let claude = removed(Runs::Agent("claude".into()));
        assert!(claude.contains(&"CODEX_HOME".to_owned()));
        assert!(claude.contains(&"CODEX_API_KEY".to_owned()));
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
        let this = std::env::current_exe().unwrap().to_string_lossy().into_owned();
        assert_eq!(classify_command(&argv(&["claude", "auth", "status"]), "mine"), agent("claude"));
        assert_eq!(classify_command(&argv(&["/opt/x", "auth"]), "opencode-v2"), agent("opencode"));
        // The host is this very binary running `chief acp`, nothing named like it.
        assert_eq!(classify_command(&argv(&[&this, "chief", "acp"]), "codex"), Runs::Host);
        assert_eq!(classify_command(&argv(&["cmux", "chief", "acp"]), "x"), Runs::Unknown);
        // uniichat is a network agent, no host: it keeps no other harness's sign-in.
        assert_eq!(
            classify_command(&argv(&["/App/bin/cmux", "acp", "uniichat-agent"]), "unii"),
            Runs::Unknown
        );
        assert_eq!(classify_command(&argv(&["cmux-helper", "chief", "acp"]), "x"), Runs::Unknown);
        // An assignment's value or an option's value is no program.
        assert_eq!(
            classify_command(&argv(&["env", "FOO=/tmp/codex-acp", "/bin/tool"]), "x"),
            Runs::Unknown
        );
        assert_eq!(
            classify_command(&argv(&["node", "--require", "/x/codex-acp", "/bin/tool"]), "x"),
            Runs::Unknown
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
            &["npx", "-y", "codex-acp", "--then", "claude"],
            &["bun", "x", "codex-acp"],
        ] {
            assert_eq!(classify_command(&argv(words), "custom"), agent("codex"), "{words:?}");
        }
        // Any other runner option may take a value: the command is unknown.
        for words in [
            &["env", "--chdir", "/tmp/codex-acp", "/bin/tool"][..],
            &["env", "-C", "/tmp/codex-acp", "/bin/tool"],
            &["npx", "--package=claude-agent-acp", "codex-acp"],
            &["node", "--require", "loader.js", "codex-acp"],
            &["node", "FOO=1", "codex-acp"],
            &["npx"],
        ] {
            assert_eq!(classify_command(&argv(words), "custom"), Runs::Unknown, "{words:?}");
            // Nor does a name or label decide for it.
            assert_eq!(classify_command(&argv(words), "codex"), Runs::Unknown, "{words:?}");
        }
        // A runner's program in a folder named like an agent is not that agent.
        assert_eq!(
            classify_command(&argv(&["env", "/tmp/codex-acp/bin/tool"]), "x"),
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
        let this = std::env::current_exe().unwrap().to_string_lossy().into_owned();
        let mut host = profile(&this, None);
        host.argv.extend(["chief".into(), "acp".into()]);
        assert_eq!(leaf_family("codex-host", &host), None);
        // Another program's `chief acp` is no host: it counts by its name.
        let mut other = profile("/usr/local/bin/cmux", None);
        other.argv.extend(["chief".into(), "acp".into()]);
        assert_eq!(leaf_family("codex-host", &other).as_deref(), Some("codex"));
        // A launcher that does not name its agent counts by the profile's name.
        assert_eq!(
            leaf_family("deepseek", &profile("/opt/bin/dsh", None)).as_deref(),
            Some("deepseek")
        );
        let mut chief = profile(&this, Some("chief"));
        chief.argv = vec![this.clone(), "chief".into(), "acp".into()];
        assert_eq!(leaf_family("chief", &chief), None);
        let mut stdio = profile("anything", Some("router"));
        stdio.kind = HarnessKind::ClaudeStdio;
        assert_eq!(leaf_family("router", &stdio).as_deref(), Some("claude"));
    }
}
