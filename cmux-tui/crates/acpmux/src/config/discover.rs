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
    add_chief(&mut found, self_exe(), &|path| path.is_file());
    found
}

/// The Muse Code ACP adapter's program (cmux-muse-acp).
pub const MUSE_ACP: &str = "muse-acp";

/// Muse Code in a terminal tab, when `muse` itself is the ACP harness.
pub const MUSE_TERMINAL: &str = "muse-terminal";

/// The profile name of the built-in UniiChat harness.
pub const UNIICHAT_PROFILE: &str = "unii";

/// This process's own binary and the prefix that reaches its subcommands
/// (`cmux acp …` when acpmux runs inside cmux): the bundled adapter.
fn self_argv() -> Option<Vec<String>> {
    let this = crate::self_command::SelfCommand::current().ok()?;
    let mut argv = vec![this.exe.to_string_lossy().into_owned()];
    argv.extend(this.args_lossy::<&str>(&[]));
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

/// The profile name of the built-in Chief harness.
pub const CHIEF_PROFILE: &str = "chief";

/// The Chief harness's family: the Chief's own brains refuse it (optchat-chief
/// `harness_gate`), since a Chief turn on it would message that Chief as the person.
pub const CHIEF_FAMILY: &str = "chief";

/// This process's executable, and whether it runs acpmux as `cmux-tui acp …`
/// (a prefix before acpmux's words).
fn self_exe() -> Option<(std::path::PathBuf, bool)> {
    let this = crate::self_command::SelfCommand::current().ok()?;
    Some((this.exe, !this.prefix.is_empty()))
}

/// Adds `chief`: the person's Chief as an agent chat, through `cmux-tui chief acp`
/// (the ACP adapter over the Chief conversation Home shows). The CLI is the
/// multicall binary acpmux is part of: this binary itself when it runs as
/// `cmux-tui acp …`, else the `cmux-tui` beside it (the app bundle links both
/// names to one binary). Never a `cmux` found on PATH, which can be another
/// app's CLI; a standalone acpmux with no `cmux-tui` beside it offers no Chief.
/// A profile file named `chief` wins.
pub fn add_chief(
    found: &mut BTreeMap<String, HarnessProfile>,
    exe: Option<(std::path::PathBuf, bool)>,
    is_file: &dyn Fn(&std::path::Path) -> bool,
) {
    if found.contains_key(CHIEF_PROFILE) {
        return;
    }
    let Some((exe, in_cmux_tui)) = exe else { return };
    let cli = if in_cmux_tui {
        exe
    } else {
        let Some(beside) = exe.parent().map(|dir| dir.join("cmux-tui")) else { return };
        if !is_file(&beside) {
            return;
        }
        beside
    };
    found.insert(
        CHIEF_PROFILE.to_owned(),
        HarnessProfile {
            kind: HarnessKind::Acp,
            argv: vec![cli.to_string_lossy().into_owned(), "chief".into(), "acp".into()],
            env: BTreeMap::new(),
            description: Some("Your Chief: the same chat as Home".into()),
            fallback: None,
            family: Some(CHIEF_FAMILY.into()),
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
/// apps/api/src/inference/catalog.ts and its deployments' `INFERENCE_MODEL_ALLOWLIST`):
/// `(id, name)`, the DeepSeek models only (user, 2026-10-28). The first is the profile
/// default and the Claude fallback model: DeepSeek V4.1 Flash 1017, which takes images.
/// The cmux setting `agents.modelRouter.model` picks another start model from this list
/// (the app's Settings, palette, `cmux settings set` and MCP `settings.set` write it).
/// The live list is GET /v1/models through the relay.
pub const CMUX_ROUTER_MODELS: &[(&str, &str)] = &[
    ("deepseek/deepseek-v4.1-flash-1017", "DeepSeek V4.1 Flash 1017"),
    ("deepseek/deepseek-v4.1-flash", "DeepSeek V4.1 Flash"),
    ("deepseek/deepseek-v4-flash", "DeepSeek V4 Flash"),
    ("deepseek/deepseek-v4-pro", "DeepSeek V4 Pro"),
];

/// The cmux setting that picks the cmux router profile's start model.
pub const CMUX_ROUTER_MODEL_SETTING: &str = "agents.modelRouter.model";

/// The model `agents.modelRouter.model` names in a settings document, if any.
pub fn cmux_router_model_in(doc: &serde_json::Value) -> Option<String> {
    crate::user_settings::value(doc, CMUX_ROUTER_MODEL_SETTING)?.as_str().map(str::to_owned)
}

/// The model `agents.modelRouter.model` names in the settings file now (blocking file IO).
pub fn cmux_router_model_setting() -> Option<String> {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => cmux_router_model_in(&doc),
        _ => None,
    }
}

/// Adds `cmux`: Claude Code (acpmux's own adapter) on the built-in `cmux`
/// route, so it runs the cmux model router's open-source models through the
/// local relay. Needs `claude` on PATH; a native agent comes later.
pub fn add_cmux_router(
    found: &mut BTreeMap<String, HarnessProfile>,
    which: &dyn Fn(&str) -> Option<String>,
) {
    let setting = cmux_router_model_setting();
    add_cmux_router_with(found, which, setting.as_deref());
}

/// `add_cmux_router` with the setting's value passed in. A model the router does not
/// serve keeps the default.
pub fn add_cmux_router_with(
    found: &mut BTreeMap<String, HarnessProfile>,
    which: &dyn Fn(&str) -> Option<String>,
    setting: Option<&str>,
) {
    if found.contains_key(CMUX_ROUTER_PROFILE) {
        return;
    }
    let Some(claude) = which("claude") else { return };
    let Some(&(default, _)) = setting
        .and_then(|m| CMUX_ROUTER_MODELS.iter().find(|(id, _)| *id == m))
        .or_else(|| CMUX_ROUTER_MODELS.first())
    else {
        return;
    };
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
    // A `codex` the user imported from ~/.acpx stays theirs, except the retired cmux ACP
    // installer's own adapter (`~/.local/share/cmux-acp/`): it ran another model than the
    // config named and titled every chat on a second model, so the in-process bridge takes
    // `codex` and the adapter stays as `codex-acp` (user 2026-10-20).
    if agents
        .get("codex")
        .is_some_and(|p| p.argv.first().is_some_and(|a| a.contains("/.local/share/cmux-acp/")))
        && let Some(adapter) = agents.remove("codex")
    {
        agents.entry(CODEX_ACP.to_owned()).or_insert(adapter);
    }
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
        // Hermes Agent (NousResearch/hermes-agent) speaks ACP itself:
        // `hermes acp`. Its provider and model come from ~/.hermes
        // (`hermes model`).
        ("hermes", "hermes"),
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
                "cursor-agent" | "hermes" => (HarnessKind::Acp, vec![path, "acp".into()]),
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
    // Muse Code (Meta's `muse`) has no ACP mode of its own: it speaks its own
    // session protocol (`muse serve`). The cmux-muse-acp adapter
    // (manaflow-ai/cmux-muse-acp, a fork of BrokkAi/muse-acp) bridges it to
    // ACP, so with `muse-acp` on PATH `muse` is an ACP harness: chats, the
    // Chief engine, the model picker (its `configOptions`) and modes. The
    // adapter gets the `muse` it found as `MUSE_CLI`, so a daemon PATH that
    // lacks it still starts Muse. Without the adapter `muse` stays a terminal
    // harness (`cmux harness run muse`); with it the terminal one is
    // `muse-terminal`. Its chats come from the chat index (`muse resume <id>`)
    // either way, and its status from its hooks.
    if let Some(muse) = which("muse") {
        let terminal = HarnessProfile {
            kind: HarnessKind::Terminal,
            argv: vec![muse.clone()],
            env: BTreeMap::new(),
            description: Some("Muse Code, found on PATH; runs in a terminal tab".into()),
            fallback: None,
            family: Some("muse".into()),
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        };
        match which(MUSE_ACP) {
            Some(adapter) if !agents.contains_key("muse") => {
                agents.insert(
                    "muse".to_owned(),
                    HarnessProfile {
                        kind: HarnessKind::Acp,
                        argv: vec![adapter],
                        env: BTreeMap::from([("MUSE_CLI".to_owned(), muse)]),
                        description: Some("Muse Code through the muse-acp adapter".into()),
                        ..terminal.clone()
                    },
                );
                agents.entry(MUSE_TERMINAL.to_owned()).or_insert(terminal);
            }
            Some(_) => {}
            None => {
                agents.entry("muse".to_owned()).or_insert(terminal);
            }
        }
    }
    // Codex through `codex app-server`, bridged in process (cmux-codex-acp,
    // `codex_app_server.rs`), is `codex` whenever codex is installed; an ACP
    // adapter on PATH stays as `codex-acp`. A profile's (or the family's)
    // CODEX_PATH picks the codex binary it runs (`agent.rs`), and a `prefer`
    // list still picks among the family's profiles. Without an adapter on
    // PATH no npx adapter package is offered: it reads the account through
    // codex's `account/read`, which a ChatGPT login behind a routing proxy
    // (subrouter) fails, so its chats never started; the bridge does not.
    if !codex_imported
        && let Some(codex) = which("codex").or_else(|| {
            crate::managed_codex::configured_path().map(|p| p.to_string_lossy().into_owned())
        })
    {
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

#[cfg(test)]
mod chief_tests {
    use super::*;
    use std::path::{Path, PathBuf};

    fn bundle(path: &Path) -> bool {
        path == Path::new("/App/bin/cmux-tui")
    }

    #[test]
    fn chief_is_built_in_through_the_cmux_cli_beside_the_bundled_acpmux() {
        // The app bundle: `acpmux` and `cmux-tui` are links to one multicall binary.
        let mut found = BTreeMap::new();
        add_chief(&mut found, Some((PathBuf::from("/App/bin/acpmux"), false)), &bundle);
        let chief = &found[CHIEF_PROFILE];
        assert_eq!(chief.argv, vec!["/App/bin/cmux-tui", "chief", "acp"]);
        assert_eq!(chief.kind, HarnessKind::Acp);
        assert_eq!(chief.family.as_deref(), Some(CHIEF_FAMILY));
        // `cmux-tui acp …`: the binary itself runs `chief acp`.
        let mut found = BTreeMap::new();
        add_chief(&mut found, Some((PathBuf::from("/opt/cmux-tui"), true)), &|_| false);
        assert_eq!(found[CHIEF_PROFILE].argv, vec!["/opt/cmux-tui", "chief", "acp"]);
    }

    #[test]
    fn a_standalone_acpmux_without_the_cmux_cli_offers_no_chief_and_a_profile_file_wins() {
        let mut found = BTreeMap::new();
        add_chief(&mut found, Some((PathBuf::from("/usr/local/bin/acpmux"), false)), &|_| false);
        assert!(!found.contains_key(CHIEF_PROFILE), "never a `cmux` from PATH: {found:?}");
        let mine = HarnessProfile {
            argv: vec!["/mine".into()],
            kind: HarnessKind::Acp,
            env: BTreeMap::new(),
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        };
        let mut found = BTreeMap::from([(CHIEF_PROFILE.to_owned(), mine.clone())]);
        add_chief(&mut found, Some((PathBuf::from("/App/bin/acpmux"), false)), &bundle);
        assert_eq!(found[CHIEF_PROFILE], mine);
    }

    #[test]
    fn the_chief_is_never_the_automatic_default_harness() {
        // `chief` sorts before `claude`: with no configured default, every new chat on a Mac
        // would start on the person's Chief (seen in the fleet capture, 2026-10-30).
        let mut found = BTreeMap::new();
        add_chief(&mut found, Some((PathBuf::from("/App/bin/acpmux"), false)), &bundle);
        let mut claude = found[CHIEF_PROFILE].clone();
        claude.argv = vec!["claude".into()];
        claude.family = Some("claude".into());
        found.insert("claude".into(), claude);
        let mut cfg = crate::config::Config::default();
        cfg.join_discovered(found.clone());
        cfg.pick_auto_default_for_tests();
        assert_eq!(cfg.default_harness.as_deref(), Some("claude"));
        // With the Chief alone there is no automatic default at all.
        let mut alone = crate::config::Config::default();
        found.remove("claude");
        alone.join_discovered(found);
        alone.pick_auto_default_for_tests();
        assert_eq!(alone.default_harness, None);
    }

    #[test]
    fn the_chief_harness_draws_the_ch_monogram_not_a_picture() {
        let mut found = BTreeMap::new();
        add_chief(&mut found, Some((PathBuf::from("/App/bin/acpmux"), false)), &bundle);
        let profile = &found[CHIEF_PROFILE];
        let spec = crate::config::harness_icon::resolve(
            CHIEF_PROFILE,
            Some("Chief"),
            profile,
            CHIEF_FAMILY,
            None,
        );
        let crate::config::harness_icon::IconSpec::Monogram { text, .. } = spec else {
            panic!("{spec:?}")
        };
        assert_eq!(text, "CH");
    }
}

#[cfg(test)]
mod acpx_codex_tests {
    use super::*;

    fn which(name: &str) -> Option<String> {
        (name == "codex").then(|| "/opt/bin/codex".to_owned())
    }

    /// The cmux ACP installer's own codex-acp (an `~/.acpx` entry under
    /// `~/.local/share/cmux-acp/`) gives way to the in-process bridge: it picked
    /// another model than the config named and asked a second model to title every
    /// chat (user 2026-10-20). It stays reachable as `codex-acp`.
    #[test]
    fn a_retired_cmux_acp_codex_import_gives_way_to_the_bridge() {
        let acpx = r#"{"agents": {"codex": {"argv": ["/Users/me/.local/share/cmux-acp/current/bin/codex-acp"]}}}"#;
        let found = discover_harnesses_from(Some(acpx), &which);
        assert_eq!(found["codex"].argv, ["/opt/bin/codex", "app-server"]);
        assert_eq!(
            found[CODEX_ACP].argv,
            ["/Users/me/.local/share/cmux-acp/current/bin/codex-acp"]
        );
    }

    /// An adapter of the person's own (anywhere else) stays `codex`.
    #[test]
    fn a_persons_own_codex_import_stays_theirs() {
        let acpx = r#"{"agents": {"codex": {"argv": ["/Users/me/bin/my-codex-adapter"]}}}"#;
        let found = discover_harnesses_from(Some(acpx), &which);
        assert_eq!(found["codex"].argv, ["/Users/me/bin/my-codex-adapter"]);
    }
}

#[cfg(test)]
mod muse_tests {
    use super::*;

    fn on_path(names: &'static [&'static str]) -> impl Fn(&str) -> Option<String> {
        move |name| names.contains(&name).then(|| format!("/opt/bin/{name}"))
    }

    /// With the adapter installed, `muse` is an ACP chat harness that runs
    /// the adapter and hands it the `muse` it found; the terminal stays.
    #[test]
    fn muse_acp_makes_muse_an_acp_harness() {
        let found = discover_harnesses_from(None, &on_path(&["muse", "muse-acp"]));
        let muse = &found["muse"];
        assert_eq!(muse.kind, HarnessKind::Acp);
        assert_eq!(muse.argv, ["/opt/bin/muse-acp"]);
        assert_eq!(muse.env.get("MUSE_CLI").map(String::as_str), Some("/opt/bin/muse"));
        assert_eq!(muse.family.as_deref(), Some("muse"));
        let terminal = &found[MUSE_TERMINAL];
        assert_eq!(terminal.kind, HarnessKind::Terminal);
        assert_eq!(terminal.argv, ["/opt/bin/muse"]);
    }

    /// Without the adapter, `muse` stays the terminal harness it was.
    #[test]
    fn muse_without_the_adapter_stays_a_terminal_harness() {
        let found = discover_harnesses_from(None, &on_path(&["muse"]));
        assert_eq!(found["muse"].kind, HarnessKind::Terminal);
        assert!(!found.contains_key(MUSE_TERMINAL));
    }

    /// The adapter alone starts nothing: it needs Muse itself.
    #[test]
    fn the_adapter_without_muse_offers_nothing() {
        let found = discover_harnesses_from(None, &on_path(&["muse-acp"]));
        assert!(!found.contains_key("muse"));
    }

    /// A `muse` the person imported from ~/.acpx stays theirs.
    #[test]
    fn an_imported_muse_stays_theirs() {
        let acpx = r#"{"agents": {"muse": {"argv": ["/Users/me/bin/my-muse"]}}}"#;
        let found = discover_harnesses_from(Some(acpx), &on_path(&["muse", "muse-acp"]));
        assert_eq!(found["muse"].argv, ["/Users/me/bin/my-muse"]);
    }
}

#[cfg(test)]
mod hermes_tests {
    use super::*;

    fn on_path(names: &'static [&'static str]) -> impl Fn(&str) -> Option<String> {
        move |name| names.contains(&name).then(|| format!("/opt/bin/{name}"))
    }

    /// Hermes Agent (NousResearch/hermes-agent) speaks ACP itself: `hermes
    /// acp`. On PATH it is an ACP harness of its own family, so the Chief's
    /// engine picker, `chief engine set --harness hermes` and chats can run it.
    #[test]
    fn hermes_on_path_runs_hermes_acp() {
        let found = discover_harnesses_from(None, &on_path(&["hermes"]));
        let hermes = found.get("hermes").expect("hermes on PATH is a harness");
        assert_eq!(hermes.kind, HarnessKind::Acp);
        assert_eq!(hermes.argv, ["/opt/bin/hermes", "acp"]);
        assert_eq!(crate::config::derive_family("hermes", hermes), "hermes");
    }

    /// A `hermes` the person imported from ~/.acpx stays theirs.
    #[test]
    fn hermes_imported_from_acpx_stays_theirs() {
        let acpx = r#"{"agents": {"hermes": {"argv": ["/Users/me/bin/my-hermes", "acp"]}}}"#;
        let found = discover_harnesses_from(Some(acpx), &on_path(&["hermes"]));
        assert_eq!(found["hermes"].argv, ["/Users/me/bin/my-hermes", "acp"]);
    }
}
