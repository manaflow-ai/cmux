//! `optchat-chief host --daemon-socket PATH --mux-home DIR`: the brain host
//! the app starts when `CMUX_NEXT_MUX_HOST` names this executable. A second
//! launch for the same home exits 0 (the app launches it on every Home open).

use std::collections::BTreeMap;
use std::path::PathBuf;
use std::sync::mpsc::channel;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use optchat_host::{AnthropicModel, CompactModel, Config, OptChat, Report, SystemClock};

use crate::acpmux::{Acpmux, AgentEvent, AgentPort, Family, Preset};
use crate::brain::{Brain, Engine, Input, Settings, parent_tag};
use crate::cli::{Flags, env};
use crate::compactor::{
    AcpmuxCompactor, CODEX_CACHE_KEY_ENV, CompactRoute, Slots, codex_cache_key, compact_route,
    compactor_presets, compactor_spec, probe_models,
};
use crate::daemon::{self, LinkConfig};
use crate::lock::{HostLock, LockError};
use crate::log::log;
use crate::native::{HttpModel, Native, NativeConfig};
use crate::paths::{Paths, mux_home};
use crate::session_dir::{self, SessionSetup};
use crate::state::StateFile;

/// Env passed through to the turn's tools, as mux/host passes it.
const PASSTHROUGH: [&str; 6] = [
    "CMUX_SOCKET_PATH",
    crate::cmux_env::APP_DAEMON_KEY,
    "ACPMUX_SOCKET",
    "ACPMUX_HOME",
    "ACPMUX_BIN",
    "CMUX_MCP_COMMAND",
];

/// A turn longer than this is stopped (minutes; `OPTCHAT_CHIEF_TURN_LIMIT_MIN`,
/// 0 for none). Long enough for a big refactor, short enough that a hung
/// harness does not silence the Chief for a day.
const DEFAULT_TURN_LIMIT_MIN: u64 = 180;

/// The native engine's model (`OPTCHAT_CHIEF_MODEL`); its effort is
/// `effort::native_effort` (medium, as Taelin runs it).
const NATIVE_MODEL: &str = "claude-opus-5-5";
/// Longest one bash command of the native engine may run.
const BASH_TIMEOUT: Duration = Duration::from_secs(600);

/// The commit this binary was built from (`OPTCHAT_BUILD_COMMIT` at build
/// time), so host.log shows which code a dogfood run is.
const BUILD: &str = match option_env!("OPTCHAT_BUILD_COMMIT") {
    Some(commit) => commit,
    None => "unknown",
};

/// The turn harness and the compactor harness: `OPTCHAT_CHIEF_HARNESS`, else
/// `MUX_HARNESS`, else claude-sr; the compactor's `OPTCHAT_COMPACTOR_HARNESS`.
pub fn harness_choice(
    chief: Option<&str>,
    mux: Option<&str>,
    compactor: Option<&str>,
) -> (String, String) {
    let turn = chief.or(mux).unwrap_or(DEFAULT_HARNESS).to_owned();
    let compactor = compactor.map_or_else(|| turn.clone(), str::to_owned);
    (turn, compactor)
}

/// The default harness: acpmux's own Claude Code adapter (`claude_stdio`)
/// launched through `sr claude proxy`, the team subrouter's account pool.
pub const DEFAULT_HARNESS: &str = "claude-sr";

/// The turn sessions' acpmux preset, or None when a turn needs none: on
/// a Claude harness it carries each turn's system prompt (the cached
/// layout); on codex the Chief's turn `prompt_cache_key` (an env the cmux
/// codex fork reads; upstream codex ignores it); with `isolate`, the turn
/// sessions' own Claude Code configuration (`session_dir::isolation_env`).
pub fn turn_preset(
    paths: &Paths,
    home: &std::path::Path,
    harness: &str,
    family: Family,
    isolate: bool,
    system_text: &str,
) -> Option<Preset> {
    let mut env = if isolate {
        session_dir::isolation_env(paths)
    } else {
        BTreeMap::new()
    };
    if family == Family::Codex {
        env.insert(
            CODEX_CACHE_KEY_ENV.to_owned(),
            codex_cache_key(home, "turn"),
        );
    }
    (isolate || family != Family::Other).then(|| Preset {
        name: format!("optchat-chief-{}", crate::paths::home_id(home)),
        harness: harness.to_owned(),
        env,
        args: Vec::new(),
        system_prompt: (family == Family::Claude).then(|| system_text.to_owned()),
    })
}

/// The families of the turn and the compactor harness, from acpmux's own
/// harness metadata (`_acpmux/harnesses`).
pub fn harness_families(
    answer: &serde_json::Value,
    harness: &str,
    compactor_harness: &str,
) -> Result<(Family, Family), String> {
    Ok((
        crate::acpmux::harness_family(answer, harness)?,
        crate::acpmux::harness_family(answer, compactor_harness)?,
    ))
}

/// The env every turn session's tools see (and the `chief` launcher bakes
/// in): this home, the daemon and acpmux sockets, the passed-through keys and
/// PATH. `inherited` reads the host's own env; `exe` is this executable.
pub fn session_env(
    home: &std::path::Path,
    daemon_socket: &str,
    acpmux_socket: &std::path::Path,
    exe: &std::path::Path,
    inherited: &dyn Fn(&str) -> Option<String>,
) -> BTreeMap<String, String> {
    let mut session_env = BTreeMap::new();
    session_env.insert("MUX_HOME".to_owned(), home.display().to_string());
    session_env.insert("CMUX_DAEMON_SOCKET".to_owned(), daemon_socket.to_owned());
    session_env.insert(
        "ACPMUX_SOCKET".to_owned(),
        acpmux_socket.display().to_string(),
    );
    for key in PASSTHROUGH {
        if let Some(value) = inherited(key) {
            session_env.insert(key.to_owned(), value);
        }
    }
    session_env.insert(
        "PATH".to_owned(),
        inherited("PATH").unwrap_or_else(|| "/usr/bin:/bin".into()),
    );
    // Every `cmux` call reaches this app's daemon (see cmux_env).
    let socket = crate::cmux_env::app_daemon_socket(daemon_socket, inherited);
    let bundled = crate::cmux_env::bundled_bin(exe);
    crate::cmux_env::pin(&mut session_env, &socket, bundled.as_deref());
    session_env
}

/// Where the Chief conversation lives (`--conversation-source`).
pub enum Source {
    /// The local owner of the daemon (local-conversations-v1), bound as
    /// agent_mux with the app's token: the app starts this host.
    Local { token_file: Option<PathBuf> },
    /// The chief's cloud main conversation through the daemon's
    /// cloud-conversations-v1 proxy, as the chief principal (an always-on
    /// brain host; brains/DESIGN-cmux-lawrence.md).
    Cloud {
        install: Box<crate::cloud::auth::InstallFile>,
    },
}

/// `--conversation-source local|cloud` (`OPTCHAT_CONVERSATION_SOURCE`,
/// default local); cloud reads `--cloud-install FILE` (`OPTCHAT_CLOUD_INSTALL`).
pub fn conversation_source(flags: &Flags) -> Result<Source, String> {
    let kind = flags
        .value("conversation-source")
        .map(str::to_owned)
        .or_else(|| env("OPTCHAT_CONVERSATION_SOURCE"))
        .unwrap_or_else(|| "local".into());
    match kind.as_str() {
        "local" => {
            let token_file = env("MUX_AGENT_TOKEN_FILE").map(PathBuf::from);
            if daemon::read_token(token_file.as_deref()).is_none() {
                // Without the token the owner stamps the host as the user and refuses
                // every agent_mux write; the app starts the host with MUX_AGENT_TOKEN_FILE.
                return Err(
                    "MUX_AGENT_TOKEN_FILE is missing or empty; start the host from cmux".into(),
                );
            }
            Ok(Source::Local { token_file })
        }
        "cloud" => {
            let path = flags
                .value("cloud-install")
                .map(str::to_owned)
                .or_else(|| env("OPTCHAT_CLOUD_INSTALL"))
                .ok_or("--conversation-source cloud needs --cloud-install FILE (or OPTCHAT_CLOUD_INSTALL)")?;
            let install = crate::cloud::auth::InstallFile::load(std::path::Path::new(&path))?;
            let missing: Vec<&str> = [
                ("install", install.install.is_none()),
                ("user", install.user.is_none()),
                ("chief", install.chief.is_none()),
                ("conversation", install.conversation.is_none()),
            ]
            .into_iter()
            .filter_map(|(k, m)| m.then_some(k))
            .collect();
            if !missing.is_empty() {
                return Err(format!(
                    "{path} has no {}: run `optchat-chief cloud pair` (or `cloud register` and `cloud chief`) first",
                    missing.join(", ")
                ));
            }
            Ok(Source::Cloud {
                install: Box::new(install),
            })
        }
        other => Err(format!(
            "unknown --conversation-source {other} (local or cloud)"
        )),
    }
}

/// Runs the host; returns the exit code.
pub fn run(flags: &Flags, started_ms: u64) -> i32 {
    let Some(daemon_socket) = flags
        .value("daemon-socket")
        .map(str::to_owned)
        .or_else(|| env("CMUX_DAEMON_SOCKET"))
    else {
        eprintln!("optchat-chief host: needs --daemon-socket PATH (or CMUX_DAEMON_SOCKET)");
        return 2;
    };
    let home = flags
        .value("mux-home")
        .map(PathBuf::from)
        .unwrap_or_else(mux_home);
    let source = match conversation_source(flags) {
        Ok(source) => source,
        Err(why) => {
            eprintln!("optchat-chief host: {why}");
            return 2;
        }
    };
    let paths = Paths::new(&home);
    if let Err(e) = paths.create() {
        log(format!("creating {}: {e}", paths.root.display()));
        return 1;
    }
    let _lock = match HostLock::take(&paths.host_lock, started_ms) {
        Ok(lock) => lock,
        Err(LockError::Held) => {
            log(format!("already running for {}", home.display()));
            return 0;
        }
        Err(e @ LockError::Older(_)) => {
            log(format!("{e}; not starting"));
            return 0;
        }
        Err(LockError::Io(e)) => {
            log(format!("taking {}: {e}", paths.host_lock.display()));
            return 1;
        }
    };
    match start(&paths, &home, &daemon_socket, source) {
        Ok(fatal) => {
            log(format!("stopping: {fatal}"));
            1
        }
        Err(e) => {
            log(e);
            1
        }
    }
}

fn start(
    paths: &Paths,
    home: &std::path::Path,
    daemon_socket: &str,
    source: Source,
) -> Result<String, String> {
    let exe = std::env::current_exe()
        .and_then(|p| p.canonicalize())
        .map_err(|e| format!("finding this executable: {e}"))?;
    let acpmux_socket = crate::acpmux_daemon::socket_path();
    let session_env = session_env(home, daemon_socket, &acpmux_socket, &exe, &env);
    let pinned = crate::cmux_env::pinned_subset(&session_env);
    // The acpmux daemon this host starts runs the children: pinned too.
    crate::acpmux_daemon::set_child_env(pinned.clone());
    let instructions = crate::prompt::user_instructions(&paths.instructions);
    // One setting picks the harness of turns and compactor alike.
    let (harness, compactor_harness) = harness_choice(
        env("OPTCHAT_CHIEF_HARNESS").as_deref(),
        env("MUX_HARNESS").as_deref(),
        env("OPTCHAT_COMPACTOR_HARNESS").as_deref(),
    );
    let engine_choice = env("OPTCHAT_CHIEF_ENGINE");
    // Section 9's subagents run on this harness (default the Chief's).
    let sub_harness = env("OPTCHAT_SUBAGENT_HARNESS").unwrap_or_else(|| harness.clone());
    // The monitoring trace (trace.rs); OPTCHAT_TRACE_FULL=1 adds whole texts.
    let trace = match crate::trace::Trace::open(
        &paths.traces,
        env("OPTCHAT_TRACE_FULL").as_deref() == Some("1"),
    ) {
        Ok(trace) => trace,
        Err(e) => {
            log(format!(
                "opening the trace {}: {e}; tracing is off",
                paths.traces.display()
            ));
            crate::trace::Trace::off()
        }
    };
    let config = Config {
        agent: crate::prompt::AGENT.to_owned(),
        reporter: Arc::new(|r: &Report| log(format!("memory: {r}"))),
        db: Some(paths.memory_db.clone()),
        ..Config::default()
    };
    let route = compact_route(env("OPTCHAT_COMPACTOR").as_deref(), &config)?;
    // The harness family decides each session's layout and isolation; acpmux
    // says what a harness is (its declared family, else its kind and
    // command), never its name. Only the native engine with the API
    // compactor runs without acpmux.
    let uses_acpmux = !(engine_choice.as_deref() == Some("native") && route == CompactRoute::Api);
    // Claude only through acpmux's own Claude Code adapter (harness_gate):
    // each harness is found by kind and command, and a refused one leaves
    // the host up with each of its sessions refused in the chat.
    let (family, compactor_family, sub_family, profiles) = if uses_acpmux {
        let answer = crate::acpmux::query_harnesses(&acpmux_socket, &|line: &str| log(line))
            .map_err(|e| format!("reading acpmux's harnesses: {e}"))?;
        let plan = |name: &str, role: &str| {
            let plan = crate::harness_gate::plan(&answer, name);
            match &plan.admitted {
                Ok(a) => log(format!("{role} harness: {}", a.describe())),
                Err(e) => log(format!(
                    "{role} harness {name} refused: {e}; its sessions are refused until acpmux has the adapter"
                )),
            }
            plan
        };
        let (turn, compactor, sub) = (
            plan(&harness, "turn"),
            plan(&compactor_harness, "compactor"),
            plan(&sub_harness, "subagent"),
        );
        (
            turn.family,
            compactor.family,
            sub.family,
            [turn.profile, compactor.profile, sub.profile],
        )
    } else {
        (
            Family::Other,
            Family::Other,
            Family::Other,
            [
                harness.clone(),
                compactor_harness.clone(),
                sub_harness.clone(),
            ],
        )
    };
    // The profiles the presets name (the session itself asks by its route).
    let [turn_profile, compactor_profile, sub_profile] = profiles;
    let claude = family == Family::Claude;
    // A Claude Code harness reads the optchat MCP server from the session
    // directory; acpmux gives any other harness no MCP server, so its memory
    // tools are the launcher's commands.
    let tools = if claude {
        crate::prompt::Tools::Mcp
    } else {
        crate::prompt::Tools::Cli(paths.bin.join("chief").display().to_string())
    };
    let system_text = crate::prompt::system_text(instructions.as_deref(), &tools);
    let setup = SessionSetup {
        exe: exe.display().to_string(),
        cmux_mcp: env("CMUX_MCP_COMMAND"),
        env: session_env,
        instructions: instructions.clone(),
        tools,
    };
    session_dir::write(paths, &setup).map_err(|e| format!("writing the session directory: {e}"))?;
    // Section 9: every subagent's directory and system prompt.
    let sub_tools = if sub_family == Family::Claude {
        crate::prompt::Tools::Mcp
    } else {
        crate::prompt::Tools::Cli(paths.bin.join("chief").display().to_string())
    };
    let sub_text = crate::prompt::subagent_system_text(instructions.as_deref(), &sub_tools);
    let sub_setup = SessionSetup {
        tools: sub_tools,
        ..setup.clone()
    };
    session_dir::write_subagent(paths, &sub_setup, &sub_text)
        .map_err(|e| format!("writing the subagent directory: {e}"))?;

    let (base_url, api_key) = (config.base_url.clone(), config.api_key.clone());

    // acpmux first: the compactor's acpmux route needs the connection before
    // the memory opens and starts building nodes. Its events wait in the
    // channel until the brain runs.
    let (tx, rx) = channel();
    // Turn sessions get their own Claude Code configuration (section 7: a
    // fresh call with nothing carried over). OPTCHAT_CHIEF_ISOLATE=0 turns it
    // off, for a harness that needs the user's configuration to sign in. On
    // a Claude harness the preset also carries each turn's system prompt
    // (the cached layout), with or without the isolation.
    let isolate = env("OPTCHAT_CHIEF_ISOLATE").as_deref() != Some("0");
    let mut preset = turn_preset(paths, home, &turn_profile, family, isolate, &system_text);
    // A harness without the project settings' env (codex) reads its tools'
    // env from the acpmux daemon and the preset: the preset pins cmux.
    if let Some(preset) = preset.as_mut() {
        preset.env.extend(pinned);
    }
    let turn_preset_name = format!("optchat-chief-{}", crate::paths::home_id(home));
    // Compactor sessions require their own presets and configuration, which
    // OPTCHAT_CHIEF_ISOLATE never turns off: without them, every node would
    // run the user's hooks, MCP servers and auto-memory on the chat's text.
    let mut required = Vec::new();
    if route == CompactRoute::Acpmux {
        crate::compactor::prepare_config(&paths.compactor_config)
            .map_err(|e| format!("creating {}: {e}", paths.compactor_config.display()))?;
        if compactor_family == Family::Codex {
            crate::compactor::prepare_codex_homes(paths, &crate::compactor::user_codex_home())?;
        }
        required.extend(compactor_presets(
            paths,
            home,
            &compactor_profile,
            compactor_family,
        ));
    }
    // The subagent preset: required, so a subagent never falls back to the
    // turn preset (whose system prompt is the Chief's view).
    let sub_preset_name = format!("optchat-sub-{}", crate::paths::home_id(home));
    if uses_acpmux {
        let mut env = if isolate {
            session_dir::isolation_env(paths)
        } else {
            BTreeMap::new()
        };
        env.insert(session_dir::SUBAGENT_ENV.to_owned(), "1".to_owned());
        if sub_family == Family::Codex {
            env.insert(CODEX_CACHE_KEY_ENV.to_owned(), codex_cache_key(home, "sub"));
        }
        required.push(Preset {
            name: sub_preset_name.clone(),
            harness: sub_profile.clone(),
            env,
            args: Vec::new(),
            system_prompt: (sub_family == Family::Claude).then(|| sub_text.clone()),
        });
    }
    let agents = Acpmux::new(acpmux_socket.clone(), preset, required);
    let first_link = Arc::new((Mutex::new(false), Condvar::new()));
    {
        let tx = tx.clone();
        let first_link = first_link.clone();
        let link_log: crate::brain::Log = Arc::new(|line: &str| log(line));
        agents.spawn_link(
            Arc::new(move |event| {
                if matches!(event, AgentEvent::Up(_) | AgentEvent::Down) {
                    *first_link
                        .0
                        .lock()
                        .unwrap_or_else(std::sync::PoisonError::into_inner) = true;
                    first_link.1.notify_all();
                }
                let _ = tx.send(Input::from(event));
            }),
            link_log,
        );
    }

    // The describer of turn images (chief-done.md item 12) is the compactor's
    // deny-all acpmux model; the Messages API route has none yet, so its log
    // keeps image references without descriptions.
    type Route = (
        Arc<dyn CompactModel>,
        Option<Arc<dyn CompactModel>>,
        String,
        Option<Arc<dyn crate::brain::images::Describe>>,
    );
    let (model, fallback, route_text, describer): Route = match route {
        CompactRoute::Api => (
            Arc::new(AnthropicModel::new(&config)),
            config
                .fallback_model
                .as_deref()
                .map(|m| Arc::new(AnthropicModel::with_model(&config, m)) as Arc<dyn CompactModel>),
            format!(
                "{} over the Messages API at {}",
                config.model, config.base_url
            ),
            None,
        ),
        CompactRoute::Acpmux => {
            // The Claude models are Claude-only: another harness builds with
            // its own default model unless OPTCHAT_COMPACTOR_MODEL names one,
            // and has no refusal fallback model.
            let compactor_claude = compactor_family == Family::Claude;
            let compactor_model = env("OPTCHAT_COMPACTOR_MODEL")
                .or_else(|| compactor_claude.then(|| config.model.clone()));
            let compactor_effort = env("OPTCHAT_COMPACTOR_EFFORT");
            let port: Arc<dyn AgentPort> = agents.clone();
            // One gate: at most JOBS compactor sessions across both models.
            let slots = Slots::new(optchat_core::JOBS);
            let compactor_log: crate::compactor::Log = Arc::new(|line: &str| log(line));
            let build = |model: Option<&str>| {
                let spec = compactor_spec(paths, home, &compactor_harness, compactor_family, model);
                let spec = crate::compactor::CompactorSpec {
                    effort: compactor_effort.clone().or(spec.effort.clone()),
                    ..spec
                };
                Arc::new(
                    AcpmuxCompactor::new(port.clone(), spec, slots.clone())
                        .with_log(compactor_log.clone())
                        .with_trace(trace.clone()),
                )
            };
            let effort = compactor_effort
                .clone()
                .or_else(|| crate::compactor::compactor_effort(compactor_family));
            let text = format!(
                "{} at effort {} in deny-all {compactor_harness} sessions through acpmux",
                compactor_model
                    .as_deref()
                    .unwrap_or("the harness's default model"),
                effort.as_deref().unwrap_or("default")
            );
            let fallback = config
                .fallback_model
                .as_deref()
                .filter(|_| compactor_claude)
                .map(|m| build(Some(m)) as Arc<dyn CompactModel>);
            let main = build(compactor_model.as_deref());
            let describer = main.clone() as Arc<dyn crate::brain::images::Describe>;
            (
                main as Arc<dyn CompactModel>,
                fallback,
                text,
                Some(describer),
            )
        }
    };
    log(format!(
        "optchat-chief {} (build {BUILD}); compactor: {route_text}",
        env!("CARGO_PKG_VERSION"),
    ));
    if route == CompactRoute::Acpmux {
        // Bounded: acpmux_daemon::ensure gives a starting daemon 30 s.
        let (lock, cv) = &*first_link;
        let linked = lock
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let _ = cv
            .wait_timeout_while(linked, Duration::from_secs(40), |done| !*done)
            .unwrap_or_else(std::sync::PoisonError::into_inner);
    }
    let system = config.prompt.text(&config.agent);
    let chat = Arc::new(
        OptChat::open_with_fallback(
            &paths.chat,
            config,
            model.clone(),
            fallback.clone(),
            Arc::new(SystemClock),
        )
        .map_err(|e| format!("opening the memory: {e}"))?,
    );
    // Section 9: spawn and tell, served beside zoom and date (acpmux only).
    let workspaces: Option<Arc<dyn crate::workspaces::Workspaces>> =
        if env("OPTCHAT_SUBAGENT_WORKSPACES").as_deref() == Some("0") {
            None
        } else {
            crate::workspaces::AppWorkspaces::from_env(daemon_socket)
                .map(|w| Arc::new(w) as Arc<dyn crate::workspaces::Workspaces>)
        };
    let orchestrator = uses_acpmux.then(|| {
        let spawner = crate::subagents::Spawner::new(
            chat.clone(),
            agents.clone(),
            crate::subagents::SubagentSettings {
                harness: sub_harness.clone(),
                policy: env("MUX_POLICY").unwrap_or_else(|| "approve-all".into()),
                model: env("OPTCHAT_SUBAGENT_MODEL"),
                preset: Some(sub_preset_name.clone()),
                cwd: paths.subagent.clone(),
                prefix: format!("optchat-sub-{}", crate::paths::home_id(home)),
                parent: parent_tag(home),
                claude_md: (sub_family == Family::Claude).then(|| sub_text.clone()),
            },
            tx.clone(),
            Arc::new(|line: &str| log(line)),
        )
        .with_trace(trace.clone())
        .with_workspaces(workspaces.clone());
        Arc::new(spawner) as Arc<dyn crate::tools::Orchestrator>
    });
    log(format!(
        "subagents: {}; workspaces: {}; trace: {}",
        if uses_acpmux {
            format!("spawn/tell on {sub_harness} sessions through acpmux")
        } else {
            "off (no acpmux)".to_owned()
        },
        if workspaces.is_some() {
            "one per subagent, through the app's control socket"
        } else {
            "off (no CMUX_SOCKET_PATH or OPTCHAT_SUBAGENT_WORKSPACES=0)"
        },
        if trace.is_on() {
            paths.traces.display().to_string()
        } else {
            "off".to_owned()
        }
    ));
    crate::tools::serve_all(
        &paths.tools_socket,
        crate::tools::Served {
            memory: chat.clone(),
            orchestrator,
        },
    )
    .map_err(|e| format!("serving the memory tools: {e}"))?;
    let status = chat.status();
    // Section 10: on start, print the view, so the log shows what the agent sees.
    log(format!(
        "pid {}, MUX_HOME {}, daemon {daemon_socket}, acpmux {}; memory: {} messages, {} view lines ({} unbuilt)\n{}",
        std::process::id(),
        home.display(),
        acpmux_socket.display(),
        status.messages,
        status.view_lines,
        status.unbuilt,
        chat.render_view().text
    ));

    // The default stays acpmux: the team subrouter answers raw Messages API
    // calls for Claude models with 429 (it serves Claude Code clients), so
    // the native engine needs an endpoint that takes API calls
    // (OPTCHAT_ANTHROPIC_BASE_URL plus a key). Checked live on 2026-10-04.
    let engine = match engine_choice.as_deref() {
        Some("native") => {
            let native_config = NativeConfig {
                model: env("OPTCHAT_CHIEF_MODEL").unwrap_or_else(|| NATIVE_MODEL.into()),
                effort: Some(crate::effort::native_effort(env("OPTCHAT_CHIEF_EFFORT"))),
                max_tokens: 64_000,
                server_fallback: env("OPTCHAT_CHIEF_SERVER_FALLBACK").as_deref() == Some("1"),
                system: crate::prompt::claude_md(instructions.as_deref()),
                cwd: paths.session.clone(),
                env: native_env(&setup, paths),
                bash_timeout: BASH_TIMEOUT,
                pwd_file: paths.root.join("bash.pwd"),
            };
            log(format!(
                "turns: native engine, {} at effort {} via {}",
                native_config.model,
                native_config.effort.as_deref().unwrap_or("default"),
                base_url
            ));
            let model = HttpModel::new(&base_url, api_key, native_config.server_fallback);
            Engine::Native(Arc::new(
                Native::new(native_config, Arc::new(model), optchat_host::RETRY)
                    .with_trace(trace.clone()),
            ))
        }
        None | Some("acpmux") => {
            log(format!(
                "turns: {harness} sessions through acpmux ({}); no Messages API",
                match family {
                    Family::Claude => "cached layout: the turn preset's system prompt holds the view head, one cache marker".to_owned(),
                    Family::Codex => format!(
                        "automatic prefix caching: instructions in AGENTS.md, view first, messages last, prompt_cache_key {}",
                        codex_cache_key(home, "turn")
                    ),
                    Family::Other => "automatic prefix caching: instructions in AGENTS.md, view first, messages last".to_owned(),
                }
            ));
            Engine::Acpmux
        }
        Some(other) => {
            return Err(format!(
                "OPTCHAT_CHIEF_ENGINE={other}: use native or acpmux"
            ));
        }
    };
    let turn_limit = env("OPTCHAT_CHIEF_TURN_LIMIT_MIN")
        .and_then(|m| m.parse::<u64>().ok())
        .unwrap_or(DEFAULT_TURN_LIMIT_MIN);
    let settings = Settings {
        session_dir: paths.session.clone(),
        harness,
        policy: env("MUX_POLICY").unwrap_or_else(|| "approve-all".into()),
        model: env("OPTCHAT_CHIEF_MODEL"),
        effort: crate::effort::turn_effort(env("OPTCHAT_CHIEF_EFFORT"), family),
        parent: parent_tag(home),
        turn_prefix: format!("optchat-{}", crate::paths::home_id(home)),
        agent_gap: Duration::from_millis(cmux_chief::rules::AGENT_GAP_RETRY_MS),
        turn_limit: (turn_limit > 0).then(|| Duration::from_secs(turn_limit * 60)),
        engine,
        turn_preset: claude.then_some(turn_preset_name),
        chief_id: crate::paths::home_id(home),
        system_text,
    };
    let brain_log: crate::brain::Log = Arc::new(|line: &str| log(line));
    // Section 10: persist after each turn.
    let backup = crate::backup::Backup::new(crate::backup::BackupConfig::for_home(
        paths,
        &crate::paths::home_id(home),
    ));
    let persister = crate::persist::Persister::start(
        paths.chat.clone(),
        paths.memory_db.clone(),
        Some(backup),
        brain_log.clone(),
    )
    .map_err(|e| format!("starting the persister: {e}"))?;
    let brain = Brain::new(
        chat.clone(),
        agents.clone(),
        settings,
        StateFile::new(&paths.state),
        tx.clone(),
        brain_log.clone(),
    )
    .on_turn_end(Arc::new(move |key: &str| persister.turn_ended(key)))
    .with_trace(trace.clone())
    .with_workspaces(workspaces);
    let mut brain = brain;
    if let Some(describer) = describer {
        brain.set_describer(describer);
    }
    spawn_probe(model, fallback, system, route, tx.clone());
    let sink: Arc<dyn Fn(daemon::DaemonEvent) + Send + Sync> = Arc::new(move |event| {
        let _ = tx.send(Input::from(event));
    });
    match source {
        Source::Local { token_file } => {
            let (display_name, title) = LinkConfig::names_from_env();
            daemon::spawn_link(
                LinkConfig {
                    socket: daemon_socket.into(),
                    token_file,
                    display_name,
                    title,
                },
                sink,
                brain_log,
            );
        }
        Source::Cloud { install } => {
            let (chief, conversation) = (
                install.chief.clone().unwrap_or_default(),
                install.conversation.clone().unwrap_or_default(),
            );
            log(format!(
                "conversation source: cloud ({} as {chief}, conversation {conversation}, api {})",
                daemon_socket, install.api_base_url
            ));
            crate::cloud::link::spawn_cloud_link(
                crate::cloud::link::CloudLinkConfig {
                    socket: daemon_socket.into(),
                    chief,
                    conversation,
                },
                Arc::new(crate::cloud::auth::InstallTokens::new(
                    *install,
                    Arc::new(crate::cloud::auth::UreqHttp),
                )),
                sink,
                brain_log,
            );
        }
    }
    let fatal = brain.run(rx);
    chat.shutdown();
    Ok(fatal)
}

/// Builds one tiny node through the compactor's route, with its main and
/// its fallback model, in the background: when either cannot (acpmux down,
/// the harness not signed in, a 429, an unserved fallback model, a
/// compactor session that offers tools), host.log gets one line and the
/// Chief conversation one notice, instead of every turn waiting on settle
/// with nothing said.
fn spawn_probe(
    model: Arc<dyn CompactModel>,
    fallback: Option<Arc<dyn CompactModel>>,
    system: String,
    route: CompactRoute,
    tx: std::sync::mpsc::Sender<Input>,
) {
    let spawned = std::thread::Builder::new()
        .name("optchat-compact-probe".into())
        .spawn(move || {
            let started = std::time::Instant::now();
            match probe_models(&*model, fallback.as_deref(), &system) {
                Ok(line) => log(format!(
                    "compactor probe ({}{}) built a node in {} ms: {line}",
                    route.name(),
                    if fallback.is_some() { ", fallback too" } else { "" },
                    started.elapsed().as_millis()
                )),
                Err(e) => {
                    let remedy = match route {
                        CompactRoute::Acpmux => {
                            "Check that acpmux runs and that its claude-sr harness signs in, or set \
                             OPTCHAT_ANTHROPIC_BASE_URL and OPTCHAT_ANTHROPIC_API_KEY for an endpoint \
                             that takes Messages API calls."
                        }
                        CompactRoute::Api => {
                            "Check OPTCHAT_ANTHROPIC_BASE_URL and OPTCHAT_ANTHROPIC_API_KEY, or set \
                             OPTCHAT_COMPACTOR=acpmux to build summaries in acpmux sessions."
                        }
                    };
                    let text = format!(
                        "The memory compactor cannot build summaries ({} route: {e}). Messages \
                         that need a summary wait, and so does every reply, until it can. {remedy}",
                        route.name()
                    );
                    let key = format!("notice:optchat:compactor:{}", now_ms());
                    let _ = tx.send(Input::Notice { key, text });
                }
            }
        });
    if let Err(e) = spawned {
        log(format!("starting the compactor probe: {e}"));
    }
}

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// The native bash tool's env: the turn session's, with the `chief`
/// launcher first on PATH (as `session_dir::settings_json` gives Claude Code).
fn native_env(setup: &SessionSetup, paths: &Paths) -> BTreeMap<String, String> {
    let mut env = setup.env.clone();
    let path = env
        .get("PATH")
        .cloned()
        .unwrap_or_else(|| "/usr/bin:/bin".into());
    env.insert("PATH".into(), format!("{}:{path}", paths.bin.display()));
    env
}
