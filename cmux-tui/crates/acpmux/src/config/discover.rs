//! Harness discovery: `~/.acpx/config.json` entries and adapters on PATH.

use std::collections::BTreeMap;

use super::{HarnessKind, HarnessProfile, which};

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
    add_cmux_router(&mut found, &which);
    add_uniichat(&mut found, self_argv());
    found
}

/// The profile name of the built-in UniiChat harness.
pub const UNIICHAT_PROFILE: &str = "unii";

/// This process's own binary and the prefix that reaches its subcommands
/// (`cmux acp …` when acpmux runs inside cmux): the bundled adapter.
fn self_argv() -> Option<Vec<String>> {
    let exe = std::env::current_exe().ok()?;
    let mut argv = vec![exe.to_string_lossy().into_owned()];
    argv.extend(crate::daemon::daemon_prefix().iter().map(|p| p.to_string_lossy().into_owned()));
    Some(argv)
}

/// Adds `unii`: a Chief or chat on UniiChat (uniichat.com, or the server
/// `$UNII_URL` names) through the bundled `uniichat-agent` adapter, which
/// speaks UniiChat's own protocol with the sign-in `unii login` keeps. It
/// needs no program on PATH, so it is always offered; a missing sign-in
/// fails the session with the setup steps. A profile file named `unii`
/// (the old `cli-agent` one) still wins.
pub fn add_uniichat(found: &mut BTreeMap<String, HarnessProfile>, self_argv: Option<Vec<String>>) {
    if found.contains_key(UNIICHAT_PROFILE) {
        return;
    }
    let Some(mut argv) = self_argv else { return };
    argv.push("uniichat-agent".into());
    found.insert(
        UNIICHAT_PROFILE.to_owned(),
        HarnessProfile {
            kind: HarnessKind::Acp,
            argv,
            env: BTreeMap::new(),
            description: Some("UniiChat: one chat that never ends (uniichat.com)".into()),
            fallback: None,
            family: Some("unii".into()),
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
}

/// The profile name of the cmux model router harness.
pub const CMUX_ROUTER_PROFILE: &str = "cmux";

/// The models the hosted cmux model router serves (backend
/// apps/api/src/inference/catalog.ts): `(id, name)`. The first is the profile
/// default. The live list is GET /v1/models through the relay.
pub const CMUX_ROUTER_MODELS: &[(&str, &str)] = &[
    ("qwen/qwen3.7-flash", "Qwen3.7 Flash"),
    ("z-ai/glm-5.3", "GLM-5.3"),
    ("moonshotai/kimi-k3", "Kimi K3"),
    ("deepseek/deepseek-v4-pro", "DeepSeek V4 Pro"),
    ("deepseek/deepseek-v4.1-flash", "DeepSeek V4.1 Flash"),
    ("moonshotai/kimi-k2.7-code", "Kimi K2.7 Code"),
    ("minimax/minimax-m3", "MiniMax M3"),
    ("z-ai/glm-5.3-flash", "GLM-5.3 Flash"),
    ("deepseek/deepseek-v4-flash", "DeepSeek V4 Flash"),
    ("openai/gpt-oss-120b", "gpt-oss-120b"),
    ("meta/llama-4-scout", "Llama 4 Scout"),
];

/// Adds `cmux`: Claude Code (acpmux's own adapter) on the built-in `cmux`
/// route, so it runs the cmux model router's open-source models through the
/// local relay. Needs `claude` on PATH; a native agent comes later.
pub fn add_cmux_router(
    found: &mut BTreeMap<String, HarnessProfile>,
    which: &dyn Fn(&str) -> Option<String>,
) {
    if found.contains_key(CMUX_ROUTER_PROFILE) {
        return;
    }
    let Some(claude) = which("claude") else { return };
    let default = CMUX_ROUTER_MODELS[0].0;
    let env = BTreeMap::from([
        (crate::routes::PROFILE_ROUTE_KEY.to_owned(), crate::routes::CMUX_ROUTE_ID.to_owned()),
        // Claude Code's background calls name Haiku/Sonnet aliases; the
        // router serves only its own models.
        ("ANTHROPIC_DEFAULT_HAIKU_MODEL".to_owned(), default.to_owned()),
        ("ANTHROPIC_SMALL_FAST_MODEL".to_owned(), default.to_owned()),
    ]);
    found.insert(
        CMUX_ROUTER_PROFILE.to_owned(),
        HarnessProfile {
            kind: HarnessKind::ClaudeStdio,
            argv: vec![claude],
            env,
            description: Some("open-source models through the cmux model router".into()),
            fallback: None,
            family: Some("claude".into()),
            models: CMUX_ROUTER_MODELS
                .iter()
                .map(|(id, name)| super::DeclaredModel::Full {
                    id: (*id).into(),
                    name: Some((*name).into()),
                })
                .collect(),
            model: Some(default.into()),
            effort: None,
            policy: None,
        },
    );
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
    // A `codex` the user imported from ~/.acpx stays theirs.
    let codex_imported = agents.contains_key("codex");
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
    // Muse Code (Meta's `muse`) has no ACP mode: it speaks its own session
    // protocol (`muse serve`), which acpmux does not bridge yet. It is offered
    // as a terminal harness (`cmux harness run muse`); its chats come from the
    // chat index (`muse resume <id>`) and its status from its hooks.
    if !agents.contains_key("muse")
        && let Some(path) = which("muse")
    {
        agents.insert(
            "muse".to_owned(),
            HarnessProfile {
                kind: HarnessKind::Terminal,
                argv: vec![path],
                env: BTreeMap::new(),
                description: Some("Muse Code, found on PATH; runs in a terminal tab".into()),
                fallback: None,
                family: Some("muse".into()),
                models: vec![],
                model: None,
                effort: None,
                policy: None,
            },
        );
    }
    // Codex through `codex app-server`, bridged in process (cmux-codex-acp,
    // `codex_app_server.rs`), is `codex` whenever codex is installed; an ACP
    // adapter on PATH stays as `codex-acp`. A profile's (or the family's)
    // CODEX_PATH picks the codex binary it runs (`agent.rs`), and a `prefer`
    // list still picks among the family's profiles. Without an adapter on
    // PATH no npx adapter package is offered: it reads the account through
    // codex's `account/read`, which a ChatGPT login behind a routing proxy
    // (subrouter) fails, so its chats never started; the bridge does not.
    if !codex_imported && let Some(codex) = which("codex") {
        if let Some(adapter) = agents.remove("codex") {
            agents.entry(CODEX_ACP.to_owned()).or_insert(adapter);
        }
        let bridge = |description: &str| HarnessProfile {
            kind: HarnessKind::Acp,
            argv: vec![codex.clone(), "app-server".into()],
            env: BTreeMap::new(),
            description: Some(description.into()),
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        };
        // Names the bridge stands in for, so sessions, presets and model picks
        // that recorded them run it: its name before it became `codex`, and
        // `codex-acp` when no adapter is on PATH.
        let alias = "Codex through codex app-server, in process (same as codex)";
        agents.entry(CODEX_APP_SERVER.to_owned()).or_insert_with(|| bridge(alias));
        agents.entry(CODEX_ACP.to_owned()).or_insert_with(|| bridge(alias));
        agents.insert("codex".to_owned(), bridge("Codex through codex app-server, in process"));
    }
    agents
}

/// The harness name of the Codex ACP adapter once `codex` is the bridge.
pub const CODEX_ACP: &str = "codex-acp";

/// The bridge's name before the flip (kept for what recorded it).
pub const CODEX_APP_SERVER: &str = "codex-app-server";

/// True when the program at `path` resolves (through links) to Cursor's
/// `cursor-agent` binary.
fn cursor_agent_launcher(path: &str) -> bool {
    std::fs::canonicalize(path)
        .ok()
        .and_then(|real| real.file_name().map(|n| n == "cursor-agent"))
        .unwrap_or(false)
}

#[cfg(test)]
mod uniichat_tests {
    use super::*;

    #[test]
    fn unii_is_built_in_through_the_bundled_adapter() {
        let mut found = BTreeMap::new();
        add_uniichat(&mut found, Some(vec!["/App/bin/cmux".into(), "acp".into()]));
        let unii = &found[UNIICHAT_PROFILE];
        assert_eq!(unii.argv, vec!["/App/bin/cmux", "acp", "uniichat-agent"]);
        assert_eq!(unii.kind, HarnessKind::Acp);
        assert_eq!(unii.family.as_deref(), Some("unii"));
    }

    #[test]
    fn a_unii_profile_file_still_wins() {
        let mut found = BTreeMap::new();
        add_uniichat(&mut found, Some(vec!["/a/acpmux".into()]));
        let mine = HarnessProfile { argv: vec!["/mine".into()], ..found[UNIICHAT_PROFILE].clone() };
        let mut found = BTreeMap::from([(UNIICHAT_PROFILE.to_owned(), mine.clone())]);
        add_uniichat(&mut found, Some(vec!["/a/acpmux".into()]));
        assert_eq!(found[UNIICHAT_PROFILE], mine);
    }
}
