//! Harness discovery: `~/.acpx/config.json` entries and adapters on PATH.

use std::collections::BTreeMap;

use super::{HarnessKind, HarnessProfile, codex_through_adapter_package, which};

/// Look for agent adapters in the acpx config and on PATH.
pub fn discover_harnesses() -> BTreeMap<String, HarnessProfile> {
    let acpx = dirs::home_dir()
        .and_then(|home| std::fs::read_to_string(home.join(".acpx").join("config.json")).ok());
    discover_harnesses_from(acpx.as_deref(), &which)
}

/// `discover_harnesses` over an `~/.acpx/config.json` text and a PATH lookup.
pub fn discover_harnesses_from(
    acpx: Option<&str>,
    which: &dyn Fn(&str) -> Option<String>,
) -> BTreeMap<String, HarnessProfile> {
    let mut agents = BTreeMap::new();
    if let Some(text) = acpx
        && let Ok(v) = serde_json::from_str::<serde_json::Value>(text)
        && let Some(map) = v.get("agents").and_then(|a| a.as_object())
    {
        for (name, profile) in map {
            if let Some(argv) = profile.get("argv").and_then(|a| a.as_array()) {
                let argv: Vec<String> =
                    argv.iter().filter_map(|s| s.as_str().map(str::to_owned)).collect();
                if !argv.is_empty() {
                    agents.insert(
                        name.clone(),
                        HarnessProfile {
                            kind: HarnessKind::Acp,
                            argv,
                            env: BTreeMap::new(),
                            description: Some("imported from ~/.acpx".into()),
                            fallback: None,
                            family: None,
                            models: vec![],
                            model: None,
                            effort: None,
                            policy: None,
                        },
                    );
                }
            }
        }
    }
    for (name, bin) in [
        ("codex", "codex-acp"),
        ("claude", "claude"),
        ("gemini", "gemini"),
        ("opencode", "opencode"),
        ("opencode-v2", "opencode2"),
        ("deepseek", "dsh"),
        // pi (earendil-works/pi) speaks ACP through the pi-acp adapter,
        // which spawns `pi --mode rpc`: `bun add -g pi-acp`.
        ("pi", "pi-acp"),
        // Claude through CodeRouter's Bedrock route: `cr claude-david` runs
        // the local Claude Code against the metered Bedrock gateway. The
        // default Claude route (Lawrence 2026-10-08); `coderouter` is the
        // long name of the same CLI.
        ("claude-cr", "cr"),
        ("claude-cr", "coderouter"),
        // Claude through the subrouter account pool: `sr claude proxy`.
        // Only when a user asks for `claude-sr` by name; never a default.
        ("claude-sr", "sr"),
        // oh-my-pi (can1357/oh-my-pi), a pi fork with a native ACP server.
        ("omp", "omp"),
        // Prime Agent (PrimeIntellect-ai/prime-agent), a pi fork: `--mode acp`.
        ("prime", "prime-agent"),
    ] {
        // An ~/.acpx entry keeps its name, except the reserved Claude names:
        // `claude` and `claude-sr` are acpmux's own Claude Code adapter
        // whenever their binary is on PATH (an ~/.acpx `claude` is usually
        // the claude-acp ACP adapter). Only config.json can rebind them.
        let reserved = matches!(name, "claude" | "claude-sr" | "claude-cr");
        if agents.contains_key(name) && !reserved {
            continue;
        }
        // `cr` and `coderouter` are one CLI: the first one found serves.
        if name == "claude-cr"
            && agents.get(name).is_some_and(|p: &HarnessProfile| p.kind == HarnessKind::ClaudeStdio)
        {
            continue;
        }
        if let Some(path) = which(bin) {
            if reserved && agents.contains_key(name) {
                tracing::info!(
                    agent = name,
                    "acpmux's own Claude Code adapter replaces the ~/.acpx entry"
                );
            }
            let (kind, argv) = match bin {
                "claude" => (HarnessKind::ClaudeStdio, vec![path]),
                "sr" => (HarnessKind::ClaudeStdio, vec![path, "claude".into(), "proxy".into()]),
                "cr" | "coderouter" => {
                    (HarnessKind::ClaudeStdio, vec![path, CODEROUTER_CLAUDE_COMMAND.into()])
                }
                "omp" => (HarnessKind::Acp, vec![path, "acp".into()]),
                "prime-agent" => (HarnessKind::Acp, vec![path, "--mode".into(), "acp".into()]),
                "gemini" => (HarnessKind::Acp, vec![path, "--experimental-acp".into()]),
                "opencode" | "opencode2" => (HarnessKind::Acp, vec![path, "acp".into()]),
                "dsh" => (HarnessKind::Acp, vec![path, "--profile".into(), "acp".into()]),
                _ => (HarnessKind::Acp, vec![path]),
            };
            agents.insert(
                name.to_owned(),
                HarnessProfile {
                    kind,
                    argv,
                    env: BTreeMap::new(),
                    description: Some(match bin {
                        "sr" => "Claude through the subrouter account pool".into(),
                        "cr" | "coderouter" => "Claude through CodeRouter's Bedrock route".into(),
                        _ => "found on PATH".into(),
                    }),
                    fallback: None,
                    family: if matches!(bin, "dsh" | "opencode2") {
                        Some(name.into())
                    } else {
                        None
                    },
                    models: vec![],
                    model: None,
                    effort: None,
                    policy: None,
                },
            );
        }
    }
    // Codex speaks ACP only through its adapter. Without a codex-acp on PATH (or an ~/.acpx
    // entry), an installed codex still gets a harness through the pinned adapter package.
    if !agents.contains_key("codex")
        && let Some(profile) =
            codex_through_adapter_package(which("codex").as_deref(), which("npx").as_deref())
    {
        agents.insert("codex".to_owned(), profile);
    }
    // A direct Claude falls over to CodeRouter when its account is exhausted.
    // Never to the subrouter: that pool is only an explicit choice.
    if agents.contains_key("claude-cr")
        && let Some(c) = agents.get_mut("claude")
        && c.fallback.is_none()
    {
        c.fallback = Some("claude-cr".into());
    }
    agents
}

/// The `cr` subcommand that runs Claude Code through CodeRouter's Bedrock
/// route (coderouter `run_claude_david`).
pub const CODEROUTER_CLAUDE_COMMAND: &str = "claude-david";
