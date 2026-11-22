//! Harness discovery: `~/.acpx/config.json` entries and adapters on PATH.

use std::collections::BTreeMap;

use super::{HarnessKind, HarnessProfile, codex_through_adapter_package, which};

/// The profile name of a configured CodeRouter Claude route.
pub const CODEROUTER_CLAUDE_PROFILE: &str = "claude-cr";

/// Env that names the CodeRouter Claude route; wins over the config key.
pub const CODEROUTER_CLAUDE_ROUTE_ENV: &str = "ACPMUX_CODEROUTER_CLAUDE_ROUTE";

/// The configured CodeRouter Claude route: `ACPMUX_CODEROUTER_CLAUDE_ROUTE`
/// (daemon or login env), else `coderouterClaudeRoute`. Only one plain
/// subcommand word counts (no flag, no space).
pub fn coderouter_claude_route(configured: Option<&str>) -> Option<String> {
    let env = std::env::var(CODEROUTER_CLAUDE_ROUTE_ENV)
        .ok()
        .or_else(|| crate::login_env::var(CODEROUTER_CLAUDE_ROUTE_ENV));
    valid_route(env.as_deref().or(configured))
}

fn valid_route(route: Option<&str>) -> Option<String> {
    let route = route?.trim();
    (!route.is_empty()
        && !route.starts_with('-')
        && route.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.')))
    .then(|| route.to_owned())
}

/// Look for agent adapters in the acpx config and on PATH. `route`: the
/// configured CodeRouter Claude route, if any.
pub fn discover_harnesses(route: Option<&str>) -> BTreeMap<String, HarnessProfile> {
    let acpx = dirs::home_dir()
        .and_then(|home| std::fs::read_to_string(home.join(".acpx").join("config.json")).ok());
    let mut found = discover_harnesses_from(acpx.as_deref(), &which);
    add_coderouter_route(&mut found, route, &which);
    found
}

/// Adds `claude-cr` (`coderouter <route>`, else `cr <route>`, kind
/// `claude-stdio`) when a route is configured and the CLI is on PATH.
/// `coderouter` goes first: another tool may be installed as `cr`.
pub fn add_coderouter_route(
    found: &mut BTreeMap<String, HarnessProfile>,
    route: Option<&str>,
    which: &dyn Fn(&str) -> Option<String>,
) {
    let Some(route) = valid_route(route) else { return };
    let Some(bin) = which("coderouter").or_else(|| which("cr")) else { return };
    found.insert(
        CODEROUTER_CLAUDE_PROFILE.to_owned(),
        HarnessProfile {
            kind: HarnessKind::ClaudeStdio,
            argv: vec![bin, route],
            env: BTreeMap::new(),
            description: Some("Claude through the configured CodeRouter route".into()),
            fallback: None,
            family: Some("claude".into()),
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
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
        // Claude through the subrouter account pool: `sr claude proxy`.
        // Only when a user names `claude-sr`; never a default or fallback.
        ("claude-sr", "sr"),
        // oh-my-pi (can1357/oh-my-pi), a pi fork with a native ACP server.
        ("omp", "omp"),
        // Prime Agent (PrimeIntellect-ai/prime-agent), a pi fork: `--mode acp`.
        ("prime", "prime-agent"),
        // Grok (xAI's grok CLI) speaks ACP itself: `grok agent stdio`.
        ("grok", "grok"),
        // Cursor's CLI speaks ACP itself: `cursor-agent acp` (newer installs
        // name the launcher `agent`; see cursor_agent_launcher below).
        ("cursor", "cursor-agent"),
    ] {
        // An ~/.acpx entry keeps its name, except the reserved Claude names:
        // `claude` and `claude-sr` are acpmux's own Claude Code adapter
        // whenever their binary is on PATH (an ~/.acpx `claude` is usually
        // the claude-acp ACP adapter). Only config.json can rebind them.
        let reserved = matches!(name, "claude" | "claude-sr" | "claude-cr");
        if agents.contains_key(name) && !reserved {
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
                "omp" => (HarnessKind::Acp, vec![path, "acp".into()]),
                "prime-agent" => (HarnessKind::Acp, vec![path, "--mode".into(), "acp".into()]),
                "grok" => (HarnessKind::Acp, vec![path, "agent".into(), "stdio".into()]),
                "cursor-agent" => (HarnessKind::Acp, vec![path, "acp".into()]),
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
                    description: Some(if bin == "sr" {
                        "Claude through the subrouter account pool".into()
                    } else {
                        "found on PATH".into()
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
    // Cursor's installer links `~/.local/bin/agent` into its install
    // (`.../cursor-agent/versions/<v>/cursor-agent`). `agent` is too common a
    // name to trust by itself: only a launcher that resolves there counts.
    if !agents.contains_key("cursor")
        && let Some(path) = which("agent").filter(|p| cursor_agent_launcher(p))
    {
        agents.insert(
            "cursor".to_owned(),
            HarnessProfile {
                kind: HarnessKind::Acp,
                argv: vec![path, "acp".into()],
                env: BTreeMap::new(),
                description: Some("found on PATH".into()),
                fallback: None,
                family: None,
                models: vec![],
                model: None,
                effort: None,
                policy: None,
            },
        );
    }
    // Codex speaks ACP only through its adapter. Without a codex-acp on PATH (or an ~/.acpx
    // entry), an installed codex still gets a harness through the pinned adapter package.
    if !agents.contains_key("codex")
        && let Some(profile) =
            codex_through_adapter_package(which("codex").as_deref(), which("npx").as_deref())
    {
        agents.insert("codex".to_owned(), profile);
    }
    agents
}

/// True when the program at `path` resolves (through links) to Cursor's
/// `cursor-agent` binary.
fn cursor_agent_launcher(path: &str) -> bool {
    std::fs::canonicalize(path)
        .ok()
        .and_then(|real| real.file_name().map(|n| n == "cursor-agent"))
        .unwrap_or(false)
}
