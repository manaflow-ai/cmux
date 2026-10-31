//! `_acpmux/complete` without a real harness: the exact argv per recipe,
//! the small-model choice, the request limits, and the child's deadline and
//! output cap with plain shell commands.

use super::codex_config::{CodexUserConfig, config_path};
use super::model_pick::{self, ClaudeInputs, claude_model, newest_haiku, pick};
use super::places::Places;
use super::recipes::{self, Folders, Invocation, Recipe, invocation, recipe_for};
use super::run::{self, RunDir, RunError};
use super::*;
use crate::config::{HarnessKind, HarnessProfile};
use serde_json::json;
use std::collections::BTreeMap;
use std::path::Path;
use std::time::{Duration, Instant};

fn profile(kind: HarnessKind, argv: &[&str]) -> HarnessProfile {
    HarnessProfile {
        kind,
        argv: argv.iter().map(|a| (*a).to_owned()).collect(),
        env: BTreeMap::new(),
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    }
}

fn ids(list: &[&str]) -> Vec<String> {
    list.iter().map(|s| (*s).to_owned()).collect()
}

fn words(inv: &Invocation) -> Vec<&str> {
    inv.args.iter().map(String::as_str).collect()
}

const DIR: &str = "/tmp/acpmux-complete-x";
const CWD: &str = "/tmp/acpmux-oneshot/cwd";

/// The fixed empty cwd and this run's own folder.
fn folders() -> Folders<'static> {
    Folders { cwd: Path::new(CWD), run: Path::new(DIR) }
}

// ------------------------------------------------------------- recipes

#[test]
fn recipes_by_harness() {
    let claude = profile(HarnessKind::ClaudeStdio, &["/bin/claude"]);
    assert_eq!(recipe_for("claude", &claude), Ok(Recipe::Claude));
    let sr = profile(HarnessKind::ClaudeStdio, &["/bin/sr", "claude", "proxy"]);
    assert_eq!(recipe_for("claude-sr", &sr), Ok(Recipe::Claude));
    let cr = profile(HarnessKind::ClaudeStdio, &["/bin/coderouter", "main"]);
    assert_eq!(recipe_for("claude-cr", &cr), Ok(Recipe::Claude));
    let codex = profile(HarnessKind::Acp, &["/bin/codex-acp"]);
    assert_eq!(recipe_for("codex", &codex), Ok(Recipe::Codex));
    let opencode = profile(HarnessKind::Acp, &["/bin/opencode", "acp"]);
    assert_eq!(recipe_for("opencode", &opencode), Ok(Recipe::OpenCode));
    let pi = profile(HarnessKind::Acp, &["/bin/pi-acp"]);
    assert_eq!(recipe_for("pi", &pi), Ok(Recipe::Pi));
    let omp = profile(HarnessKind::Acp, &["/bin/omp", "acp"]);
    assert_eq!(recipe_for("omp", &omp), Ok(Recipe::Omp));
    let grok = profile(HarnessKind::Acp, &["/bin/grok", "agent", "stdio"]);
    assert_eq!(recipe_for("grok", &grok), Ok(Recipe::Grok));
}

#[test]
fn gemini_and_terminal_harnesses_are_unsupported() {
    let gemini = profile(HarnessKind::Acp, &["/bin/gemini", "--experimental-acp"]);
    let err = recipe_for("gemini", &gemini).unwrap_err();
    assert_eq!(err.reason(), "complete.unsupported_harness");
    let term = profile(HarnessKind::Terminal, &["/bin/aider"]);
    assert_eq!(recipe_for("aider", &term).unwrap_err().reason(), "complete.unsupported_harness");
    let other = profile(HarnessKind::Acp, &["/bin/cursor-agent", "acp"]);
    assert_eq!(recipe_for("cursor", &other).unwrap_err().reason(), "complete.unsupported_harness");
}

#[test]
fn claude_argv_keeps_the_profile_prefix() {
    let sr = profile(HarnessKind::ClaudeStdio, &["/bin/sr", "claude", "proxy"]);
    let none = |_: &str| -> Option<String> { None };
    let (program, prefix) = recipes::program(Recipe::Claude, &sr, &BTreeMap::new(), &none).unwrap();
    assert_eq!(program, "/bin/sr");
    let inv = invocation(Recipe::Claude, program, prefix, Some("claude-haiku-5-5"), folders());
    assert_eq!(
        words(&inv),
        [
            "claude",
            "proxy",
            "-p",
            "--output-format",
            "text",
            "--model",
            "claude-haiku-5-5",
            "--tools",
            "",
            "--disable-slash-commands",
            "--no-session-persistence",
            "--strict-mcp-config",
            "--mcp-config",
            r#"{"mcpServers":{}}"#,
            "--settings",
            r#"{"disableAllHooks":true}"#,
        ]
    );
    assert!(inv.stdin_prompt);
    assert_eq!(inv.prompt_file, None);
    assert_eq!(inv.output_file, None);
}

#[test]
fn claude_drops_every_profile_flag() {
    // A profile that pins its own MCP servers, permissions and output format:
    // none of it reaches the one-shot (--mcp-config adds servers, and
    // --tools "" does not remove MCP tools).
    let pinned = profile(
        HarnessKind::ClaudeStdio,
        &[
            "/bin/sr",
            "claude",
            "proxy",
            "--mcp-config",
            "x.json",
            "--dangerously-skip-permissions",
            "--output-format",
            "json",
        ],
    );
    let none = |_: &str| -> Option<String> { None };
    let (program, prefix) =
        recipes::program(Recipe::Claude, &pinned, &BTreeMap::new(), &none).unwrap();
    assert_eq!(
        (program.as_str(), prefix.clone()),
        ("/bin/sr", vec!["claude".to_owned(), "proxy".to_owned()])
    );
    let inv = invocation(Recipe::Claude, program, prefix, Some("haiku"), folders());
    let argv = words(&inv);
    for pinned in ["x.json", "--dangerously-skip-permissions", "json"] {
        assert!(!argv.contains(&pinned), "{pinned} leaked into {argv:?}");
    }
    assert_eq!(argv.iter().filter(|w| **w == "--mcp-config").count(), 1, "{argv:?}");
    let at = argv.iter().position(|w| *w == "--output-format").expect("--output-format");
    assert_eq!(argv[at + 1], "text");
    assert_eq!(argv.iter().filter(|w| **w == "--output-format").count(), 1, "{argv:?}");
}

#[test]
fn claude_with_an_empty_argv_runs_claude() {
    let empty = profile(HarnessKind::ClaudeStdio, &[]);
    let none = |_: &str| -> Option<String> { None };
    let (program, prefix) =
        recipes::program(Recipe::Claude, &empty, &BTreeMap::new(), &none).unwrap();
    assert_eq!((program.as_str(), prefix.len()), ("claude", 0));
}

#[test]
fn codex_argv_is_ephemeral_tool_less_and_low_effort() {
    let codex = profile(HarnessKind::Acp, &["/bin/codex-acp"]);
    let mut env = BTreeMap::new();
    env.insert("CODEX_PATH".to_owned(), "/opt/codex".to_owned());
    let none = |_: &str| -> Option<String> { None };
    let (program, prefix) = recipes::program(Recipe::Codex, &codex, &env, &none).unwrap();
    assert_eq!(program, "/opt/codex");
    let inv = invocation(Recipe::Codex, program, prefix, Some("gpt-6-luna"), folders());
    let last = format!("{DIR}/last-message.txt");
    assert_eq!(
        words(&inv),
        [
            "exec",
            "--ephemeral",
            "--skip-git-repo-check",
            "--ignore-user-config",
            "--ignore-rules",
            "--sandbox",
            "read-only",
            "-c",
            "default_tools_enabled=false",
            "-c",
            "tools={}",
            "-c",
            "mcp_servers={}",
            "-c",
            "web_search=\"disabled\"",
            "-c",
            "approval_policy=never",
            "-c",
            "shell_environment_policy.inherit=none",
            "-c",
            "model_reasoning_effort=low",
            "-m",
            "gpt-6-luna",
            "--output-last-message",
            last.as_str(),
            "-",
        ]
    );
    assert!(inv.stdin_prompt);
    assert_eq!(inv.output_file.as_deref(), Some(Path::new(&last)));
}

#[test]
fn codex_without_codex_path_uses_codex_on_path() {
    let codex = profile(HarnessKind::Acp, &["/bin/codex-acp"]);
    let which = |bin: &str| (bin == "codex").then(|| "/usr/local/bin/codex".to_owned());
    let (program, _) = recipes::program(Recipe::Codex, &codex, &BTreeMap::new(), &which).unwrap();
    assert_eq!(program, "/usr/local/bin/codex");
    let none = |_: &str| -> Option<String> { None };
    assert_eq!(recipes::program(Recipe::Codex, &codex, &BTreeMap::new(), &none), None);
}

#[test]
fn file_recipes_argv() {
    let dir = folders();
    let file = format!("{DIR}/prompt.txt");
    let opencode = invocation(Recipe::OpenCode, "/bin/opencode".into(), vec![], None, dir);
    assert_eq!(
        words(&opencode),
        [
            "run",
            "--pure",
            "--format",
            "default",
            "--dir",
            CWD,
            "--file",
            file.as_str(),
            recipes::FILE_INSTRUCTION
        ]
    );
    assert!(!opencode.stdin_prompt);
    assert_eq!(opencode.prompt_file.as_deref(), Some(Path::new(&file)));
    assert!(opencode.env_set.contains(&("OPENCODE_PURE".into(), "1".into())));
    assert!(opencode.env_remove.contains(&"OPENCODE_CONFIG".to_owned()));

    let pi = invocation(Recipe::Pi, "/bin/pi".into(), vec![], Some("gemini-3-flash"), dir);
    let at = format!("@{file}");
    assert_eq!(
        words(&pi),
        [
            "--print",
            "--no-tools",
            "--no-session",
            "--no-extensions",
            "--no-skills",
            "--no-prompt-templates",
            "--no-context-files",
            "--model",
            "gemini-3-flash",
            at.as_str(),
            recipes::FILE_INSTRUCTION
        ]
    );
    let omp = invocation(Recipe::Omp, "/bin/omp".into(), vec![], None, dir);
    assert_eq!(
        words(&omp),
        [
            "--print",
            "--no-tools",
            "--no-session",
            "--no-extensions",
            "--no-skills",
            "--no-rules",
            at.as_str(),
            recipes::FILE_INSTRUCTION
        ]
    );
    let grok = invocation(Recipe::Grok, "/bin/grok".into(), vec![], None, dir);
    assert_eq!(
        words(&grok),
        [
            "--prompt-file",
            file.as_str(),
            "--output-format",
            "plain",
            "--tools",
            "",
            "--disable-web-search",
            "--no-subagents",
            "--no-memory",
            "--verbatim"
        ]
    );
}

#[test]
fn pi_runs_the_pi_cli_not_its_acp_adapter() {
    let pi = profile(HarnessKind::Acp, &["/bin/pi-acp"]);
    let which = |bin: &str| (bin == "pi").then(|| "/usr/local/bin/pi".to_owned());
    let (program, prefix) = recipes::program(Recipe::Pi, &pi, &BTreeMap::new(), &which).unwrap();
    assert_eq!((program.as_str(), prefix.len()), ("/usr/local/bin/pi", 0));
    let grok = profile(HarnessKind::Acp, &["/bin/grok", "agent", "stdio"]);
    let none = |_: &str| -> Option<String> { None };
    let (program, prefix) = recipes::program(Recipe::Grok, &grok, &BTreeMap::new(), &none).unwrap();
    assert_eq!((program.as_str(), prefix.len()), ("/bin/grok", 0));
}

#[test]
fn codex_reapplies_the_users_model_provider_without_credentials() {
    let cfg =
        CodexUserConfig::parse(include_str!("../../tests/fixtures/codex-provider-config.toml"));
    assert_eq!(cfg.provider.as_deref(), Some("openrouter"));
    assert_eq!(cfg.model.as_deref(), Some("deepseek/deepseek-v4"));
    assert_eq!(
        cfg.overrides,
        [
            r#"model_provider="openrouter""#,
            r#"model_providers.openrouter.base_url="https://openrouter.ai/api/v1""#,
            r#"model_providers.openrouter.env_key="OPENROUTER_API_KEY""#,
            r#"model_providers.openrouter.name="OpenRouter""#,
            r#"model_providers.openrouter.query_params.api-version="2026-01""#,
            r#"model_providers.openrouter.request_max_retries=2"#,
            r#"model_providers.openrouter.wire_api="chat""#,
        ]
    );
    let joined = cfg.overrides.join("\n");
    for leaked in
        ["sk-or-secret", "secret-header", "mcp_servers", "approval_policy", "example.invalid"]
    {
        assert!(!joined.contains(leaked), "{leaked} leaked: {joined}");
    }

    let inv = invocation(Recipe::Codex, "/opt/codex".into(), vec![], None, folders())
        .with_codex_overrides(&cfg.overrides);
    let argv = words(&inv);
    assert_eq!(&argv[..3], ["exec", "-c", r#"model_provider="openrouter""#]);
    assert!(argv.contains(&"--ignore-user-config"));
}

#[test]
fn codex_default_config_adds_nothing() {
    for text in ["", "model = \"gpt-6\"\n", "model_provider = \"openai\"\n", "not toml ["] {
        let cfg = CodexUserConfig::parse(text);
        assert!(cfg.overrides.is_empty(), "{text:?}: {:?}", cfg.overrides);
    }
    // A provider id that is not a bare key is not passed on.
    let odd = CodexUserConfig::parse("model_provider = \"a b\"\n");
    assert!(odd.overrides.is_empty(), "{:?}", odd.overrides);
    assert_eq!(
        config_path(Some("/x/codex"), Some(Path::new("/home/u"))),
        Some(Path::new("/x/codex/config.toml").to_path_buf())
    );
    assert_eq!(
        config_path(None, Some(Path::new("/home/u"))),
        Some(Path::new("/home/u/.codex/config.toml").to_path_buf())
    );
}

#[test]
fn codex_model_comes_from_the_users_provider() {
    let cfg =
        CodexUserConfig::parse(include_str!("../../tests/fixtures/codex-provider-config.toml"));
    let offered = ids(&["gpt-6", "gpt-6-luna"]);
    let live = ids(&["deepseek/deepseek-v4", "qwen/qwen3-mini"]);
    // Their provider's own list, never OpenAI's catalog.
    assert_eq!(cfg.model_for(&offered, Some(live.as_slice())).as_deref(), Some("qwen/qwen3-mini"));
    // No small model there (or no list yet): their configured model.
    assert_eq!(cfg.model_for(&offered, None).as_deref(), Some("deepseek/deepseek-v4"));
    let big = ids(&["deepseek/deepseek-v4"]);
    assert_eq!(
        cfg.model_for(&offered, Some(big.as_slice())).as_deref(),
        Some("deepseek/deepseek-v4")
    );
    // OpenAI: the offered list.
    let openai = CodexUserConfig::parse("model = \"gpt-6\"\n");
    assert_eq!(openai.model_for(&offered, Some(live.as_slice())).as_deref(), Some("gpt-6-luna"));
    assert_eq!(openai.model_for(&ids(&["gpt-6"]), None).as_deref(), Some("gpt-6"));
    assert_eq!(CodexUserConfig::default().model_for(&ids(&["gpt-6"]), None), None);
}

// ---------------------------------------------------------- model pick

#[test]
fn claude_prefers_the_haiku_alias() {
    // The alias lets the user's own provider mapping (Bedrock, Vertex,
    // CodeRouter) pick the concrete model.
    let live = ids(&["default", "opus", "sonnet", "haiku", "claude-haiku-5-5"]);
    let with_live = ClaudeInputs { live: Some(live.as_slice()), ..Default::default() };
    assert_eq!(claude_model(&with_live), "haiku");
    // No live list yet: the alias, never a catalog id.
    assert_eq!(claude_model(&ClaudeInputs::default()), model_pick::CLAUDE_FALLBACK);
}

#[test]
fn claude_uses_a_concrete_haiku_only_when_the_alias_is_unavailable() {
    let live = ids(&[
        "default",
        "claude-opus-5-5",
        "claude-haiku-4-5-20251001",
        "claude-haiku-5-5",
        "claude-haiku-5-1",
    ]);
    let no_alias = ClaudeInputs { live: Some(live.as_slice()), ..Default::default() };
    assert_eq!(claude_model(&no_alias), "claude-haiku-5-5");
    // The alias listed but refused by the backend.
    let mut with_alias = live.clone();
    with_alias.push("haiku".to_owned());
    let refused = ids(&["haiku"]);
    let alias_refused =
        ClaudeInputs { live: Some(with_alias.as_slice()), refused: &refused, ..Default::default() };
    assert_eq!(claude_model(&alias_refused), "claude-haiku-5-5");
    // No concrete Haiku to fall back to: still the alias.
    let bare = ids(&["default", "opus"]);
    assert_eq!(
        claude_model(&ClaudeInputs { live: Some(bare.as_slice()), ..Default::default() }),
        "haiku"
    );
    assert_eq!(
        newest_haiku(&ids(&["claude-haiku-4-5-20250101", "claude-haiku-4-5-20251001"])).as_deref(),
        Some("claude-haiku-4-5-20251001")
    );
}

#[test]
fn claude_honors_small_fast_then_default_haiku() {
    let live = ids(&["claude-haiku-5-5"]);
    let small = ClaudeInputs {
        small_fast: Some(" us.anthropic.claude-haiku-4-5-v1:0 "),
        default_haiku: Some("us.anthropic.claude-haiku-4-5-v2:0"),
        live: Some(live.as_slice()),
        ..Default::default()
    };
    assert_eq!(claude_model(&small), "us.anthropic.claude-haiku-4-5-v1:0");
    // ANTHROPIC_DEFAULT_HAIKU_MODEL: the alias, which Claude Code maps.
    let mapped = ClaudeInputs {
        small_fast: Some("  "),
        default_haiku: Some("us.anthropic.claude-haiku-4-5-v2:0"),
        live: Some(live.as_slice()),
        ..Default::default()
    };
    assert_eq!(claude_model(&mapped), "haiku");
}

#[test]
fn codex_prefers_luna_then_mini_then_nano() {
    let all = ids(&["gpt-6", "gpt-6-nano", "gpt-6-mini", "gpt-6-luna", "gpt-6-codex"]);
    assert_eq!(pick(Recipe::Codex, &all).as_deref(), Some("gpt-6-luna"));
    let no_luna = ids(&["gpt-6", "gpt-6-nano", "gpt-6-mini"]);
    assert_eq!(pick(Recipe::Codex, &no_luna).as_deref(), Some("gpt-6-mini"));
    let nano = ids(&["gpt-6", "gpt-6-nano"]);
    assert_eq!(pick(Recipe::Codex, &nano).as_deref(), Some("gpt-6-nano"));
    assert_eq!(pick(Recipe::Codex, &ids(&["gpt-6"])), None);
}

#[test]
fn others_pick_the_cheapest_tier_and_gemini_is_not_mini() {
    let list = ids(&[
        "google/gemini-3-pro",
        "google/gemini-3-flash",
        "google/gemini-3-flash-lite",
        "anthropic/claude-haiku-5-5",
    ]);
    assert_eq!(pick(Recipe::OpenCode, &list).as_deref(), Some("google/gemini-3-flash-lite"));
    let no_lite =
        ids(&["google/gemini-3-pro", "anthropic/claude-haiku-5-5", "google/gemini-3-flash"]);
    assert_eq!(pick(Recipe::Pi, &no_lite).as_deref(), Some("google/gemini-3-flash"));
    // `gemini` holds `mini` mid-word: never a match.
    assert_eq!(pick(Recipe::Omp, &ids(&["google/gemini-3-pro"])), None);
    assert_eq!(
        pick(Recipe::Grok, &ids(&["grok-5", "grok-5-mini"])).as_deref(),
        Some("grok-5-mini")
    );
}

// ------------------------------------------------------------- request

#[test]
fn only_the_unix_socket_may_complete() {
    use crate::server::Origin;
    assert!(allowed(Origin::Local));
    for origin in [Origin::Web, Origin::LocalApp, Origin::Peer] {
        assert!(!allowed(origin), "{origin:?} may not run a completion");
    }
}

#[test]
fn request_defaults_and_limits() {
    let req = Request::parse(&json!({"prompt": "Name this"})).unwrap();
    assert_eq!(req.max_tokens, DEFAULT_MAX_TOKENS);
    assert_eq!(req.timeout, Duration::from_millis(u64::from(DEFAULT_TIMEOUT_MS)));
    assert_eq!((req.harness, req.model), (None, None));

    let at_limit = "a".repeat(MAX_PROMPT_BYTES);
    assert!(Request::parse(&json!({"prompt": at_limit})).is_ok());
    let over = "a".repeat(MAX_PROMPT_BYTES + 1);
    let err = Request::parse(&json!({"prompt": over})).unwrap_err();
    assert_eq!(err, CompleteError::PromptTooLarge { bytes: MAX_PROMPT_BYTES + 1 });
    let rpc: crate::rpc::RpcError = err.into();
    assert_eq!(rpc.data.unwrap()["reason"], "complete.prompt_too_large");
    // Bytes, not characters: 1366 three-byte characters are over.
    let wide = "語".repeat(1366);
    assert_eq!(
        Request::parse(&json!({"prompt": wide})).unwrap_err().reason(),
        "complete.prompt_too_large"
    );

    for bad in [
        json!({}),
        json!({"prompt": "  "}),
        json!({"prompt": "x", "maxTokens": 0}),
        json!({"prompt": "x", "maxTokens": 257}),
        json!({"prompt": "x", "timeoutMs": 60_001}),
        json!({"prompt": "x", "harness": 3}),
    ] {
        assert_eq!(Request::parse(&bad).unwrap_err().reason(), "complete.invalid_params", "{bad}");
    }
    // A model is an id: never a flag, whitespace or a control character.
    for bad in
        ["-x", "--dangerously-skip-permissions", "claude haiku", " haiku", "haiku\n", "a\u{7}b"]
    {
        let err = Request::parse(&json!({"prompt": "x", "model": bad})).unwrap_err();
        assert_eq!(err.reason(), "complete.invalid_params", "{bad:?}");
    }
    // `default` is no model: the small model is picked and reported.
    assert_eq!(Request::parse(&json!({"prompt": "x", "model": "default"})).unwrap().model, None);
    let full = Request::parse(
        &json!({"prompt": "x", "harness": "codex", "model": "gpt-6-luna", "maxTokens": 256, "timeoutMs": 60_000}),
    )
    .unwrap();
    assert_eq!(full.harness.as_deref(), Some("codex"));
    assert_eq!(full.model.as_deref(), Some("gpt-6-luna"));
    assert_eq!((full.max_tokens, full.timeout), (256, Duration::from_secs(60)));
}

#[test]
fn errors_carry_their_reason() {
    for (e, reason) in [
        (CompleteError::LocalOnly, "complete.local_only"),
        (CompleteError::UnknownHarness("x".into()), "complete.unknown_harness"),
        (CompleteError::SignedOut { harness: "x".into() }, "complete.signed_out"),
        (CompleteError::Timeout { harness: "x".into(), ms: 5 }, "complete.timeout"),
        (CompleteError::EmptyOutput { harness: "x".into() }, "complete.empty_output"),
    ] {
        let rpc: crate::rpc::RpcError = e.into();
        assert_eq!(rpc.data.unwrap()["reason"], reason);
    }
}

// --------------------------------------------------------------- finish

fn ran(stdout: &str, stderr: &str, success: bool) -> run::Output {
    run::Output {
        stdout: stdout.as_bytes().to_vec(),
        stderr: stderr.as_bytes().to_vec(),
        success,
        code: Some(if success { 0 } else { 1 }),
    }
}

#[test]
fn finish_trims_and_cuts_to_max_tokens() {
    let out = ran("  Fix Login Redirect Bug \n", "", true);
    assert_eq!(finish("claude", &out, &out.stdout, 16).unwrap(), "Fix Login Redirect Bug");
    let long = ran(&"word ".repeat(100), "", true);
    let text = finish("claude", &long, &long.stdout, 2).unwrap();
    assert!(text.len() <= 2 * BYTES_PER_TOKEN, "{text:?}");
}

#[test]
fn finish_tells_signed_out_empty_and_failed() {
    let out = ran("", "Invalid API key · Please run /login", false);
    assert_eq!(
        finish("claude", &out, &out.stdout, 16),
        Err(CompleteError::SignedOut { harness: "claude".into() })
    );
    let out = ran("", "Error: Not logged in", false);
    assert_eq!(finish("codex", &out, b"", 16).unwrap_err().reason(), "complete.signed_out");
    let out = ran(" \n", "", true);
    assert_eq!(
        finish("claude", &out, &out.stdout, 16).unwrap_err().reason(),
        "complete.empty_output"
    );
    let out = ran("", "model not found", false);
    assert_eq!(finish("claude", &out, &out.stdout, 16).unwrap_err().reason(), "complete.failed");
}

#[test]
fn sign_in_is_read_from_a_failed_runs_stderr_only() {
    // The model's own answer names logging in: never a sign-in failure.
    let out = ran("Login Page Redesign", "", true);
    assert_eq!(finish("claude", &out, &out.stdout, 16).unwrap(), "Login Page Redesign");
    let out = ran("Fix Login", "warning: please log in again soon", true);
    assert_eq!(finish("claude", &out, &out.stdout, 16).unwrap(), "Fix Login");
    // A failed run whose stdout (not stderr) mentions login is just failed.
    let out = ran("Sign in flow broken", "rate limited", false);
    assert_eq!(finish("claude", &out, &out.stdout, 16).unwrap_err().reason(), "complete.failed");
}

// ------------------------------------------------------------------ run

fn sh(script: &str) -> tokio::process::Command {
    let mut cmd = tokio::process::Command::new("/bin/sh");
    cmd.arg("-c").arg(script);
    cmd
}

#[tokio::test]
async fn run_feeds_stdin_and_reads_stdout() {
    let out =
        run::run(sh("tr a-z A-Z"), Some(&b"name this"[..]), Duration::from_secs(10)).await.unwrap();
    assert!(out.success);
    assert_eq!(out.stdout, b"NAME THIS");
}

#[cfg(unix)]
#[tokio::test]
async fn run_kills_the_whole_group_on_timeout() {
    let dir = RunDir::new().unwrap();
    let pid_file = dir.path().join("bg.pid");
    // A background sleep the CLI started, and the CLI itself waiting on it.
    let script = format!("sleep 30 & echo $! > '{}'; wait", pid_file.display());
    let started = Instant::now();
    let out = run::run(sh(&script), None, Duration::from_millis(300)).await;
    assert!(matches!(out, Err(RunError::Timeout)), "{out:?}");
    assert!(started.elapsed() < Duration::from_secs(5), "the timeout did not end the run");
    let pid: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    // The group's SIGKILL is delivered at once; the orphan is reaped by init.
    let gone = (0..50).any(|_| {
        std::thread::sleep(Duration::from_millis(20));
        // SAFETY: signal 0 only checks that the process exists.
        let alive = unsafe { libc::kill(pid, 0) };
        alive != 0
    });
    assert!(gone, "the background sleep {pid} outlived the timeout");
}

#[cfg(unix)]
#[tokio::test]
async fn a_finished_answer_is_not_held_by_a_grandchild() {
    let dir = RunDir::new().unwrap();
    let pid_file = dir.path().join("bg.pid");
    // The CLI answers and exits, but left a background process holding stdout.
    let script = format!("sleep 30 & echo $! > '{}'; echo answer", pid_file.display());
    let started = Instant::now();
    let out = run::run(sh(&script), None, Duration::from_secs(10)).await.expect("the answer");
    assert!(started.elapsed() < Duration::from_secs(5), "waited on the grandchild");
    assert!(out.success);
    assert_eq!(out.stdout, b"answer\n");
    // Its whole group is killed once the leader exited.
    let pid: i32 = std::fs::read_to_string(&pid_file).unwrap().trim().parse().unwrap();
    let gone = (0..50).any(|_| {
        std::thread::sleep(Duration::from_millis(20));
        // SAFETY: signal 0 only checks that the process exists.
        let alive = unsafe { libc::kill(pid, 0) };
        alive != 0
    });
    assert!(gone, "the background sleep {pid} outlived the run");
}

#[tokio::test]
async fn run_caps_stdout() {
    let out = run::run(sh("head -c 200000 /dev/zero"), None, Duration::from_secs(10)).await;
    let out = out.unwrap();
    assert_eq!(out.stdout.len(), OUTPUT_CAP);
}

#[test]
fn run_dir_is_fresh_private_and_removed() {
    let dir = RunDir::new().unwrap();
    let path = dir.path().to_path_buf();
    assert_eq!(std::fs::read_dir(&path).unwrap().count(), 0);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o700);
    }
    let file = path.join("prompt.txt");
    dir.write_private(&file, b"secret prompt").unwrap();
    assert_eq!(std::fs::read(&file).unwrap(), b"secret prompt");
    drop(dir);
    assert!(!path.exists());
}

#[test]
fn every_run_shares_one_fixed_empty_private_cwd() {
    let root = RunDir::new().unwrap();
    let places = Places::new(root.path().join("complete"));
    places.ensure().unwrap();
    places.ensure().unwrap();
    let (cwd, runs) = (places.cwd(), places.runs());
    assert_eq!(cwd, root.path().join("complete").join("cwd"));
    assert!(!runs.starts_with(&cwd), "run folders must not sit in the cwd");
    for dir in [&cwd, &runs] {
        assert!(dir.is_dir(), "{dir:?}");
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(std::fs::metadata(dir).unwrap().permissions().mode() & 0o777, 0o700);
        }
    }
    // A run's prompt and output go in its own folder under `runs`, never the cwd.
    let run = RunDir::new_in(&runs).unwrap();
    assert!(run.path().starts_with(&runs));
    assert_eq!(std::fs::read_dir(&cwd).unwrap().count(), 0);
    drop(run);
    // The acpmux home's own folder, unless it is a guarded one.
    assert_eq!(
        Places::root_in(Path::new("/opt/acpmux-home"), None),
        Path::new("/opt/acpmux-home/complete")
    );
}

#[test]
fn stale_run_folders_are_swept() {
    let root = RunDir::new().unwrap();
    let places = Places::new(root.path().join("complete"));
    places.ensure().unwrap();
    let runs = places.runs();
    let left = RunDir::new_in(&runs).unwrap().path().to_path_buf();
    // A crashed daemon left this one behind: Drop never ran.
    std::fs::create_dir(&left).unwrap();
    std::fs::write(left.join("prompt.txt"), b"x").unwrap();
    let other = runs.join("not-a-run");
    std::fs::create_dir(&other).unwrap();
    // Younger than the limit: kept (a run may be starting now).
    assert_eq!(places.sweep_stale_runs(Duration::from_secs(3600)), 0);
    assert!(left.exists());
    assert_eq!(places.sweep_stale_runs(Duration::ZERO), 1);
    assert!(!left.exists(), "the stale run folder stayed");
    assert!(other.exists(), "only run folders are swept");
    assert!(places.cwd().exists());
}

#[test]
fn finish_cleans_stderr_without_changing_raw_output() {
    for raw in [
        "\x1b[2m2026-10-25T01:44:57Z\x1b[0m \x1b[31mERROR\x1b[0m \x1b[2mcodex_models_manager::manager: failed to refresh available models: request timed out\x1b[0m\n\x1b[0m",
        "\x1b]8;;https://example.com\x1b\\codex_models_manager::manager: failed to refresh available models: request timed out\x1b]8;;\x1b\\",
        "codex_models_manager::manager: failed to refresh available models: request timed out\x1b",
    ] {
        let out = ran("", raw, false);
        assert_eq!(
            finish("codex", &out, b"", 16),
            Err(CompleteError::Failed {
                harness: "codex".into(),
                detail: "exit status 1: codex_models_manager::manager: failed to refresh available models: request timed out".into(),
            })
        );
        assert_eq!(out.stderr, raw.as_bytes());
    }
    let out = ran("", "\x1b[0m\n\x1b]title\x07\n\x1b", false);
    assert_eq!(
        finish("codex", &out, b"", 16),
        Err(CompleteError::Failed { harness: "codex".into(), detail: "exit status 1".into() })
    );
}
