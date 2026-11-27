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
fn gemini_and_muse_logins_stay_with_their_harness() {
    let claude: Vec<_> = foreign_login_keys("claude").collect();
    for key in ["GEMINI_API_KEY", "GEMINI_CLI_HOME", "META_API_KEY"] {
        assert!(claude.contains(&key), "{key} reaches Claude Code");
    }
    let opencode: Vec<_> = foreign_login_keys("opencode").collect();
    assert!(opencode.contains(&"META_API_KEY") && opencode.contains(&"GEMINI_CLI_HOME"));
    assert!(!opencode.contains(&"GEMINI_API_KEY"), "OpenCode loses a provider key");
    let gemini: Vec<_> = foreign_login_keys("gemini").collect();
    assert!(gemini.contains(&"META_API_KEY") && gemini.contains(&"CLAUDE_CODE_OAUTH_TOKEN"));
    assert!(!gemini.contains(&"GEMINI_API_KEY") && !gemini.contains(&"GEMINI_CLI_HOME"));
    let muse: Vec<_> = foreign_login_keys("muse").collect();
    assert!(muse.contains(&"GEMINI_CLI_HOME") && !muse.contains(&"META_API_KEY"));
}

/// The provider keys a multi-provider harness reads (`login_env::PROVIDER_KEYS`) reach only
/// those harnesses and the one family that signs in with each, whatever env set them (the
/// daemon's own, from a shell holding OPENROUTER_API_KEY): Claude Code, Codex and every other
/// agent lose them. An unknown command keeps them, as it keeps the shared provider keys.
#[test]
fn provider_keys_reach_only_multi_provider_harnesses_and_their_own_family() {
    let loses = |family: &str, key: &str| foreign_login_keys(family).any(|k| k == key);
    for family in ["claude", "codex", "gemini", "muse", "cursor", "grok", "deepseek"] {
        for key in ["OPENROUTER_API_KEY", "GROQ_API_KEY", "HF_TOKEN", "TOGETHER_API_KEY"] {
            assert!(loses(family, key), "{key} reaches {family}");
        }
    }
    for family in ["opencode", "pi", "omp", "prime", "hermes", ""] {
        for key in ["OPENROUTER_API_KEY", "GROQ_API_KEY", "XAI_API_KEY", "OPENAI_BASE_URL"] {
            assert!(!loses(family, key), "{family:?} loses {key}");
        }
    }
    // Each family keeps the ones it signs in with.
    assert!(!loses("claude", "ANTHROPIC_BASE_URL") && loses("claude", "OPENAI_BASE_URL"));
    assert!(!loses("codex", "OPENAI_BASE_URL") && loses("codex", "ANTHROPIC_BASE_URL"));
    assert!(!loses("gemini", "GOOGLE_API_KEY") && loses("claude", "GOOGLE_API_KEY"));
    assert!(!loses("grok", "XAI_API_KEY") && loses("claude", "XAI_API_KEY"));
    assert!(!loses("deepseek", "DEEPSEEK_API_KEY") && loses("codex", "DEEPSEEK_API_KEY"));
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
        remove_foreign(&runs, None, |key| keys.push(key.to_owned()));
        keys
    };
    let codex = removed(Runs::Agent("codex".into()));
    assert!(codex.contains(&"CLAUDE_CODE_OAUTH_TOKEN".to_owned()));
    let claude = removed(Runs::Agent("claude".into()));
    assert!(claude.contains(&"CODEX_HOME".to_owned()));
    assert!(claude.contains(&"CODEX_API_KEY".to_owned()));
    assert!(removed(Runs::Host).is_empty());
    let unknown = removed(Runs::Unknown);
    for key in ["CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR", "CODEX_HOME", "OPENCODE_CONFIG"] {
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
    // The claude-acp ACP adapter (`config/discover.rs`) is Claude Code under any profile name.
    assert_eq!(classify_command(&argv(&["/opt/bin/claude-acp"]), "mine"), agent("claude"));
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
    assert_eq!(classify_command(&argv(&["codex", "exec", "uniichat-agent"]), "x"), agent("codex"));
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
    assert_eq!(classify_command(&argv(&["env", "/tmp/codex-acp/bin/tool"]), "x"), Runs::Unknown);
    // `chief` as an ordinary argument is no host.
    assert_eq!(classify_command(&argv(&["/usr/bin/codex", "exec", "chief"]), "x"), agent("codex"));
}

#[test]
fn the_family_comes_from_what_runs_and_a_host_is_left_alone() {
    let profile = |argv: &str, family: Option<&str>| {
        let mut p: HarnessProfile =
            serde_json::from_value(serde_json::json!({"argv": [argv]})).unwrap();
        p.family = family.map(str::to_string);
        p
    };
    assert_eq!(leaf_family("mine", &profile("codex-acp", Some("mine"))).as_deref(), Some("codex"));
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
