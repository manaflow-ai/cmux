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
/// `MUX_HARNESS`, else `DEFAULT_HARNESS`; the compactor's
/// `OPTCHAT_COMPACTOR_HARNESS`. With nothing set, the host then takes
/// `default_harness` of acpmux's answer.
pub fn harness_choice(
    chief: Option<&str>,
    mux: Option<&str>,
    compactor: Option<&str>,
) -> (String, String) {
    let turn = chief.or(mux).unwrap_or(DEFAULT_HARNESS).to_owned();
    let compactor = compactor.map_or_else(|| turn.clone(), str::to_owned);
    (turn, compactor)
}

/// The compactor's harness when none is set (Lawrence 2026-10-09: "just
/// always use haiku for default compactor"): the turns' own when it is a
/// Claude harness (claude-sr stays claude-sr), else `claude`, the Claude
/// route acpmux has (the configured CodeRouter route, else the user's own
/// login).
pub fn default_compactor_harness(turn: &str, family: Family, claude: &str) -> String {
    if family == Family::Claude {
        turn.to_owned()
    } else {
        claude.to_owned()
    }
}

/// `ACPMUX_PROBE_HARNESSES` of the acpmux daemon this host starts: the
/// harnesses the Chief can use, so its model probes never start another
/// harness's agent (a Claude-only Chief never starts codex-acp). The set
/// turn, compactor and subagent harnesses and engine.json's, and always the
/// Claude routes (`DEFAULT_HARNESS`, `CODEROUTER_HARNESS`): the default turn
/// harness, and the compactor of a turn harness that is not Claude.
pub fn probe_harnesses(
    chief: Option<&str>,
    compactor: Option<&str>,
    sub: Option<&str>,
    engine: &crate::engine::EngineChoice,
) -> String {
    let names: std::collections::BTreeSet<&str> = [
        chief,
        compactor,
        sub,
        engine.harness.as_deref(),
        engine.compactor_harness.as_deref(),
    ]
    .into_iter()
    .flatten()
    .chain([DEFAULT_HARNESS, CODEROUTER_HARNESS])
    .collect();
    names.into_iter().collect::<Vec<_>>().join(",")
}

/// The default harness: acpmux's own Claude Code adapter (`claude_stdio`)
/// running the user's own `claude` login. The subrouter pool (`claude-sr`)
/// is only an explicit choice.
pub const DEFAULT_HARNESS: &str = "claude";

/// The harness the Chief uses when none is set: the configured CodeRouter
/// route (`claude-cr`, which acpmux has only when `coderouterClaudeRoute`
/// names one) whether or not it can run, so an unavailable route is
/// refused with its reason instead of silently moving to another account;
/// else `DEFAULT_HARNESS`.
pub fn default_harness(answer: &serde_json::Value) -> &'static str {
    if answer
        .get("harnesses")
        .and_then(|h| h.get(CODEROUTER_HARNESS))
        .is_some()
    {
        CODEROUTER_HARNESS
    } else {
        DEFAULT_HARNESS
    }
}

/// Which codex the codex sessions run, in host.log and the trace (event
/// `codex`: path and `--version`). Without the Chief's own copy, one line
/// says that the PATH codex runs and may not read the view back.
fn trace_codex(paths: &Paths, trace: &crate::trace::Trace, log: &dyn Fn(String)) {
    let (path, own) = match crate::codex_home::chief_codex(paths) {
        Some(p) => (p, true),
        None => {
            log(format!(
                "codex: the Chief's own codex is not installed at {}; codex sessions run the PATH codex, which may ignore the Chief's prompt cache key",
                paths.codex_bin.display()
            ));
            (PathBuf::from("codex"), false)
        }
    };
    let version = std::process::Command::new(&path)
        .arg("--version")
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default();
    trace.emit(
        "codex",
        serde_json::json!({"path": path.display().to_string(), "own": own, "version": version}),
    );
    if own {
        log(format!("codex: {} ({version})", path.display()));
    }
}

/// acpmux's profile for a configured CodeRouter Claude route.
pub const CODEROUTER_HARNESS: &str = "claude-cr";

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
    if family == Family::Claude {
        env.extend(session_dir::QUIET_ENV.map(|(k, v)| (k.to_owned(), v.to_owned())));
    }
    if family == Family::Codex {
        env.insert(
            CODEX_CACHE_KEY_ENV.to_owned(),
            codex_cache_key(home, "turn"),
        );
        if let Some(codex) = crate::codex_home::chief_codex(paths) {
            env.insert(
                crate::codex_home::CODEX_PATH_ENV.to_owned(),
                codex.display().to_string(),
            );
        }
        if isolate {
            // The Chief's own codex home: no native subagents (its subagents
            // are `chief spawn` sessions), no user MCP servers, hooks or skills.
            env.insert(
                "CODEX_HOME".to_owned(),
                paths.turn_codex.display().to_string(),
            );
        }
    }
    if family == Family::Claude && isolate {
        // The preset's system prompt carries the instructions: no CLAUDE.md
        // file reaches a turn (the user's own ~/.claude/CLAUDE.md included).
        env.insert("CLAUDE_CODE_DISABLE_CLAUDE_MDS".to_owned(), "1".to_owned());
    }
    if family == Family::Claude {
        // claude-sr (when chosen): every turn of this Chief on one sticky
        // subrouter account. Other Claude routes ignore the variable.
        env.insert(
            crate::compactor::SUBROUTER_SESSION_KEY_ENV.to_owned(),
            codex_cache_key(home, "turn"),
        );
    }
    // The reference's Claude Code path: no user settings (user MCP servers,
    // hooks, plugins), no skills or slash commands, only TURN_TOOLS of the
    // built-ins; the session directory's own settings and .mcp.json stay,
    // and the user's login still signs in.
    let args = if family == Family::Claude && isolate {
        turn_isolation_args()
    } else {
        Vec::new()
    };
    (isolate || family != Family::Other).then(|| Preset {
        name: turn_preset_name(home, family),
        harness: harness.to_owned(),
        env,
        args,
        system_prompt: (family == Family::Claude).then(|| system_text.to_owned()),
    })
}

/// The built-in tools a turn is offered (an allowlist: a built-in a later
/// Claude Code adds is not offered); the Chief's MCP tools come on top.
pub const TURN_TOOLS: [&str; 7] = [
    "Bash",
    "Read",
    "Edit",
    "Write",
    "WebFetch",
    "WebSearch",
    "ToolSearch",
];

/// The Claude Code args of an isolated turn: no user or local setting
/// source, no skills or slash commands, only `TURN_TOOLS` of the built-ins
/// (acpmux's preset allowlist).
pub fn turn_isolation_args() -> Vec<String> {
    vec![
        "--setting-sources".to_owned(),
        "project".to_owned(),
        "--disable-slash-commands".to_owned(),
        "--tools".to_owned(),
        TURN_TOOLS.join(","),
    ]
}

/// A subagent preset `name`: the user's own environment (subagents do real
/// work in the user's repositories), the pinned cmux env, its cache key,
/// and on a Claude harness its system prompt `text`.
#[allow(clippy::too_many_arguments)]
pub fn subagent_preset(
    paths: &Paths,
    home: &std::path::Path,
    name: String,
    profile: &str,
    family: Family,
    isolate: bool,
    text: &str,
    pinned: &BTreeMap<String, String>,
) -> Preset {
    let mut env = if isolate {
        session_dir::isolation_env(paths)
    } else {
        BTreeMap::new()
    };
    env.insert(session_dir::SUBAGENT_ENV.to_owned(), "1".to_owned());
    if family == Family::Claude {
        env.extend(session_dir::QUIET_ENV.map(|(k, v)| (k.to_owned(), v.to_owned())));
    }
    // Subagents' cmux calls reach the same app daemon as the Chief's.
    env.extend(pinned.clone());
    if family == Family::Codex {
        env.insert(CODEX_CACHE_KEY_ENV.to_owned(), codex_cache_key(home, "sub"));
    }
    if family == Family::Claude {
        env.insert(
            crate::compactor::SUBROUTER_SESSION_KEY_ENV.to_owned(),
            codex_cache_key(home, "sub"),
        );
    }
    Preset {
        name,
        harness: profile.to_owned(),
        env,
        args: Vec::new(),
        system_prompt: (family == Family::Claude).then(|| text.to_owned()),
    }
}

/// The turn preset's name: `optchat-chief-<home id>`, and
/// `optchat-chief-codex-<home id>` for codex, so both can be installed and
/// a turn can swap harness families (engine.rs).
pub fn turn_preset_name(home: &std::path::Path, family: Family) -> String {
    match family {
        Family::Codex => format!("optchat-chief-codex-{}", crate::paths::home_id(home)),
        _ => format!("optchat-chief-{}", crate::paths::home_id(home)),
    }
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
    crate::cmux_env::pin(&mut session_env, &socket, daemon_socket, bundled.as_deref());
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
    // SIGTERM, SIGINT and SIGHUP stop the host and what it started (E20).
    watch_stop_signals();
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
    // A status left by a host that crashed mid-wait says nothing true now.
    crate::settle_status::SettleStatus::new(&paths.settle_status).clear();
    let started = start(&paths, &home, &daemon_socket, source);
    if STOPPING.load(std::sync::atomic::Ordering::SeqCst) {
        // A stop signal: whatever `start` returned (its acpmux connection
        // may close under it), stop what this host started and exit 0.
        if let Err(e) = &started {
            log(format!("while stopping: {e}"));
        }
        stop_started_acpmux();
        return 0;
    }
    match started {
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
    // One setting picks the harness of turns and compactor alike.
    // engine.json's compactor fields apply at host start (engine.rs).
    let engine_choice_file = crate::engine::load(&crate::engine::path(home));
    let chief_set = env("OPTCHAT_CHIEF_HARNESS").or_else(|| env("MUX_HARNESS"));
    let compactor_set = crate::engine::compactor_harness_setting(
        env("OPTCHAT_COMPACTOR_HARNESS"),
        &engine_choice_file,
    );
    let sub_set = env("OPTCHAT_SUBAGENT_HARNESS");
    // The acpmux daemon this host starts runs the children: pinned too. Its
    // model probes start only the harnesses this Chief can use.
    let mut daemon_env = pinned.clone();
    daemon_env.insert(
        "ACPMUX_PROBE_HARNESSES".to_owned(),
        probe_harnesses(
            chief_set.as_deref(),
            compactor_set.as_deref(),
            sub_set.as_deref(),
            &engine_choice_file,
        ),
    );
    crate::acpmux_daemon::set_child_env(daemon_env);
    let instructions = crate::prompt::user_instructions(&paths.instructions);
    let (mut harness, mut compactor_harness) =
        harness_choice(chief_set.as_deref(), None, compactor_set.as_deref());
    let engine_choice = env("OPTCHAT_CHIEF_ENGINE");
    // Section 9's subagents run on this harness (default the Chief's).
    let mut sub_harness = sub_set.clone().unwrap_or_else(|| harness.clone());
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
    // Spec 4 (gist 3c190e0): a compaction sends the turns' own system
    // prompt, so it reads it from the turns' cache entry.
    let claude_text =
        crate::prompt::system_text(instructions.as_deref(), &crate::prompt::Tools::Mcp);
    let mut config = Config {
        agent: crate::prompt::AGENT.to_owned(),
        prompt: optchat_host::CompactPrompt::Custom(claude_text.clone()),
        reporter: Arc::new(|r: &Report| log(format!("memory: {r}"))),
        db: Some(paths.memory_db.clone()),
        ..Config::default()
    };
    let route = compact_route(env("OPTCHAT_COMPACTOR").as_deref(), &config)?;
    if route == CompactRoute::Api {
        // The same compactor model settings as the acpmux route.
        if let Some(model) =
            env("OPTCHAT_COMPACTOR_MODEL").or_else(|| engine_choice_file.compactor_model.clone())
        {
            config.model = model;
        }
        if let Some(effort) = env("OPTCHAT_COMPACTOR_EFFORT") {
            config.effort = Some(effort);
        }
    }
    if engine_choice.as_deref() == Some("native") && route == CompactRoute::Api {
        // And the native turns' tools (never called), for the same entry.
        config.tools = Some(crate::native::Native::tools());
    }
    // The harness family decides each session's layout and isolation; acpmux
    // says what a harness is (its declared family, else its kind and
    // command), never its name. Only the native engine with the API
    // compactor runs without acpmux.
    let uses_acpmux = !(engine_choice.as_deref() == Some("native") && route == CompactRoute::Api);
    let mut families = BTreeMap::new();
    let mut profiles_by_name: BTreeMap<String, String> = BTreeMap::new();
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
        // Every admitted harness's family and profile, for a turn that
        // swaps harness between turns (engine.rs); refused ones stay out.
        for name in answer
            .get("harnesses")
            .and_then(serde_json::Value::as_object)
            .into_iter()
            .flat_map(|m| m.keys())
        {
            let p = crate::harness_gate::plan(&answer, name);
            if p.admitted.is_ok() {
                families.insert(name.clone(), p.family);
                profiles_by_name.insert(name.clone(), p.profile.clone());
            }
        }
        // Nothing set: the configured CodeRouter route when acpmux has one,
        // else the user's own Claude login (default_harness).
        if chief_set.is_none() {
            harness = default_harness(&answer).to_owned();
            if sub_set.is_none() {
                sub_harness = harness.clone();
            }
        }
        // The compactor runs on a Claude route unless set otherwise, whatever
        // the turns run on (engine.json may swap them to codex per turn).
        if compactor_set.is_none() {
            let turn_family = crate::harness_gate::plan(&answer, &harness).family;
            compactor_harness =
                default_compactor_harness(&harness, turn_family, default_harness(&answer));
        }
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
    // The first harness of a family (the default harness when it is one):
    // the other family's turn preset names it.
    let first_of = |f: Family| -> Option<String> {
        if family == f {
            return Some(harness.clone());
        }
        families
            .iter()
            .find(|(_, v)| **v == f)
            .map(|(k, _)| k.clone())
    };
    let claude = family == Family::Claude;
    // A Claude Code harness reads the optchat MCP server from the session
    // directory; acpmux gives any other harness no MCP server, so its memory
    // tools are the launcher's commands.
    let tools = if claude {
        crate::prompt::Tools::Mcp
    } else {
        crate::prompt::Tools::Cli(paths.bin.join("chief").display().to_string())
    };
    let setup = SessionSetup {
        exe: exe.display().to_string(),
        cmux_mcp: env("CMUX_MCP_COMMAND"),
        env: session_env,
        instructions: instructions.clone(),
        tools,
        user_env: session_dir::host_user_env(),
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
    let _ = STOP_TX.set(tx.clone());
    // Turn sessions get their own Claude Code configuration (section 7: a
    // fresh call with nothing carried over). OPTCHAT_CHIEF_ISOLATE=0 turns it
    // off, for a harness that needs the user's configuration to sign in. On
    // a Claude harness the preset also carries each turn's system prompt
    // (the cached layout), with or without the isolation.
    let isolate = env("OPTCHAT_CHIEF_ISOLATE").as_deref() != Some("0");
    // The Claude turn preset carries the Claude system text (MCP tools).
    let mut preset = turn_preset(paths, home, &turn_profile, family, isolate, &claude_text);
    // A harness without the project settings' env (codex) reads its tools'
    // env from the acpmux daemon and the preset: the preset pins cmux.
    if let Some(preset) = preset.as_mut() {
        preset.env.extend(pinned.clone());
    }
    let claude_preset_name = turn_preset_name(home, Family::Claude);
    // The other family's turn preset, for a swap between turns.
    let other_family = if family == Family::Codex {
        Family::Claude
    } else {
        Family::Codex
    };
    let other_preset = first_of(other_family)
        .map(|h| profiles_by_name.get(&h).cloned().unwrap_or(h))
        .and_then(|p| turn_preset(paths, home, &p, other_family, isolate, &claude_text))
        .map(|mut p| {
            p.env.extend(pinned.clone());
            p
        });
    let claude_installed =
        family == Family::Claude || (other_family == Family::Claude && other_preset.is_some());
    let codex_preset = (family == Family::Codex
        || (other_family == Family::Codex && other_preset.is_some()))
    .then(|| turn_preset_name(home, Family::Codex));
    if codex_preset.is_some() || compactor_family == Family::Codex {
        trace_codex(paths, &trace, &log);
    }
    if codex_preset.is_some()
        && isolate
        && let Err(e) =
            crate::codex_home::prepare_turn_codex_home(paths, &crate::codex_home::user_codex_home())
    {
        log(format!("the codex turns' CODEX_HOME: {e}"));
    }
    // Compactor sessions require their own presets and configuration, which
    // OPTCHAT_CHIEF_ISOLATE never turns off: without them, every node would
    // run the user's hooks, MCP servers and auto-memory on the chat's text.
    // The compactor's speed (OPTCHAT_COMPACTOR_SPEED, else engine.json's
    // compactor_speed), fixed at host start like its harness.
    let compactor_speed =
        env("OPTCHAT_COMPACTOR_SPEED").or_else(|| engine_choice_file.compactor_speed.clone());
    let compactor_fast = match compactor_speed.as_deref() {
        Some(speed) => match crate::engine::check_speed(speed, compactor_family) {
            Ok(()) => crate::engine::is_fast(Some(speed)),
            Err(reason) => {
                log(format!("compactor: {reason}; it runs at the default speed"));
                false
            }
        },
        None => false,
    };
    let mut required = Vec::new();
    if route == CompactRoute::Acpmux {
        crate::compactor::prepare_config(&paths.compactor_config)
            .map_err(|e| format!("creating {}: {e}", paths.compactor_config.display()))?;
        if compactor_family == Family::Codex {
            crate::compactor::prepare_codex_homes_at(
                paths,
                &crate::compactor::user_codex_home(),
                compactor_fast,
            )?;
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
    let sub_preset = |name: String, profile: &str, family: Family, text: &str| {
        subagent_preset(paths, home, name, profile, family, isolate, text, &pinned)
    };
    if uses_acpmux {
        required.push(sub_preset(
            sub_preset_name.clone(),
            &sub_profile,
            sub_family,
            &sub_text,
        ));
        // Subagents follow the turn's engine (engine.json) unless pinned:
        // the other family's subagent preset, and its instructions.
        let sub_other = if sub_family == Family::Codex {
            Family::Claude
        } else {
            Family::Codex
        };
        if sub_set.is_none()
            && let Some(name) = crate::subagents::family_preset(&sub_preset_name, sub_other)
            && let Some(profile) =
                first_of(sub_other).map(|h| profiles_by_name.get(&h).cloned().unwrap_or(h))
        {
            let other_tools = if sub_other == Family::Claude {
                crate::prompt::Tools::Mcp
            } else {
                crate::prompt::Tools::Cli(paths.bin.join("chief").display().to_string())
            };
            let other_text =
                crate::prompt::subagent_system_text(instructions.as_deref(), &other_tools);
            if sub_other == Family::Codex
                && let Err(e) = session_dir::write_subagent_agents_md(paths, &other_text)
            {
                log(format!("writing the subagent directory's AGENTS.md: {e}"));
            }
            required.push(sub_preset(name, &profile, sub_other, &other_text));
        }
    }
    if let Some(other) = other_preset {
        required.push(other);
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
    // The turns' cache TTL, which the brain decides per turn; the compactor's
    // Claude Code nodes take it too (one TTL per route).
    let shared_ttl = crate::prompt::SharedTtl::default();
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
                .or_else(|| engine_choice_file.compactor_model.clone())
                .or_else(|| crate::compactor::compactor_model_for(compactor_family));
            let compactor_effort = env("OPTCHAT_COMPACTOR_EFFORT");
            let port: Arc<dyn AgentPort> = agents.clone();
            // One gate: at most COMPACTOR_SESSIONS sessions across both models.
            let slots = Slots::with_spares(
                crate::compactor::compactor_sessions(),
                crate::compactor::compactor_spares(),
            );
            let compactor_log: crate::compactor::Log = Arc::new(|line: &str| log(line));
            let shared_ttl = shared_ttl.clone();
            let build = |model: Option<&str>| {
                let spec = compactor_spec(paths, home, &compactor_harness, compactor_family, model);
                let spec = crate::compactor::CompactorSpec {
                    effort: compactor_effort.clone().or(spec.effort.clone()),
                    fast: compactor_fast,
                    ..spec
                };
                AcpmuxCompactor::new(port.clone(), spec, slots.clone())
                    .with_log(compactor_log.clone())
                    .with_trace(trace.clone())
                    .with_cache_ttl(shared_ttl.clone())
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
                .map(|m| Arc::new(build(Some(m))) as Arc<dyn CompactModel>);
            // An account without the compactor model (Haiku on some
            // subscriptions) builds with the turn model instead, logged once.
            // The other route while the first is exhausted (a 503 with
            // retry-after): OPTCHAT_COMPACTOR_ALT_HARNESS, else the user's
            // own `claude` login for a pooled or routed Claude harness.
            let admitted: Vec<String> = families.keys().cloned().collect();
            let alternate = env("OPTCHAT_COMPACTOR_ALT_HARNESS")
                .or_else(|| crate::compactor::derived_alternate(&compactor_harness, &admitted));
            if let Some(alt) = &alternate {
                log(format!(
                    "compactor: {alt} builds while {compactor_harness} is exhausted"
                ));
            }
            let main = build(compactor_model.as_deref())
                .with_alternate_harness(alternate)
                .with_model_fallback(env("OPTCHAT_CHIEF_MODEL"))
                .with_warm(crate::compactor::WARM_SESSIONS)
                .shared();
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
    // `optchat-chief settings` reaches the brain, which owns the settings.
    let settings_tx = Mutex::new(tx.clone());
    let control: crate::tools::Control = Arc::new(move |request: crate::tools::ControlRequest| {
        use crate::tools::ControlRequest;
        let tx = settings_tx.lock().expect("settings tx").clone();
        let stopping = |_| "the host is stopping".to_owned();
        let wait = Duration::from_secs(30);
        let late = |_| "the host did not answer".to_owned();
        match request {
            ControlRequest::Set(key, value) => {
                let (reply, answer) = channel();
                tx.send(Input::Setting { key, value, reply })
                    .map_err(stopping)?;
                answer.recv_timeout(wait).map_err(late)?
            }
            ControlRequest::Show => {
                let (reply, answer) = channel();
                tx.send(Input::Settings { reply }).map_err(stopping)?;
                answer
                    .recv_timeout(wait)
                    .map(|v| format!("{v:#}"))
                    .map_err(late)
            }
            ControlRequest::SpawnPolicy => {
                let (reply, answer) = channel();
                tx.send(Input::SpawnPolicy { reply }).map_err(stopping)?;
                answer
                    .recv_timeout(wait)
                    .map(Option::unwrap_or_default)
                    .map_err(late)
            }
            ControlRequest::Engine(request) => {
                let (reply, answer) = channel();
                tx.send(Input::Engine { request, reply })
                    .map_err(stopping)?;
                answer
                    .recv_timeout(wait)
                    .map(|v| v.to_string())
                    .map_err(late)
            }
            ControlRequest::StopSubagent(name) => {
                let (reply, answer) = channel();
                tx.send(Input::StopSubagent { name, reply })
                    .map_err(stopping)?;
                answer
                    .recv_timeout(wait)
                    .map(|v| v.to_string())
                    .map_err(late)
            }
            ControlRequest::Stop => {
                let (reply, answer) = channel();
                tx.send(Input::Stop { reply }).map_err(stopping)?;
                answer
                    .recv_timeout(wait)
                    .map(|v| v.to_string())
                    .map_err(late)
            }
        }
    });
    // Section 9: spawn and tell, served beside zoom and date (acpmux only).
    let workspaces_off = env("OPTCHAT_SUBAGENT_WORKSPACES").as_deref() == Some("0");
    // Where subagent workspaces go: the app that started this host, else
    // (an always-on brain with no app) this host's own session daemon, so
    // any app connected to this machine's session shows them.
    let cloud_install = match &source {
        Source::Cloud { install } => install.install.clone(),
        Source::Local { .. } => None,
    };
    let workspaces: Option<Arc<dyn crate::workspaces::Workspaces>> = if workspaces_off {
        None
    } else if crate::workspaces::AppWorkspaces::from_env(daemon_socket).is_some() {
        // hq-6d 2026-10-09: always the Chief's owner daemon (`--daemon-socket`), also when the
        // app started this host: one place, the Chief's machine row in the app, and the
        // workspaces outlive the app. The tabs name the Chief home's acpmux (`chief:<home id>`).
        Some(Arc::new(crate::workspaces::DaemonWorkspaces {
            daemon: daemon_socket.into(),
            host: crate::workspaces::chief_host(home),
            host_name: crate::workspaces::host_name(),
            harness: Some(sub_harness.clone()),
        }) as Arc<dyn crate::workspaces::Workspaces>)
    } else {
        cloud_install.map(|install| {
            Arc::new(crate::workspaces::DaemonWorkspaces {
                daemon: daemon_socket.into(),
                host: format!("install:{install}"),
                host_name: crate::workspaces::host_name(),
                harness: Some(sub_harness.clone()),
            }) as Arc<dyn crate::workspaces::Workspaces>
        })
    };
    let no_workspace_reason = if workspaces_off {
        "subagent workspaces are turned off on this Chief host".to_owned()
    } else {
        "this Chief host has neither a cmux app nor a cloud install, so no cmux app shows this subagent".to_owned()
    };
    let mut sub_starter = None;
    let orchestrator = uses_acpmux.then(|| {
        let spawner = crate::subagents::Spawner::new(
            chat.clone(),
            agents.clone(),
            crate::subagents::SubagentSettings {
                harness: sub_harness.clone(),
                policy: env("MUX_POLICY").unwrap_or_else(|| "approve-all".into()),
                model: env("OPTCHAT_SUBAGENT_MODEL"),
                effort: None,
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
        .with_pinned_harness(sub_set.is_some())
        .with_workspaces(workspaces.clone())
        .with_no_workspace_reason(no_workspace_reason.clone());
        let spawner = Arc::new(spawner);
        sub_starter = Some(spawner.queue_starter());
        spawner as Arc<dyn crate::tools::Orchestrator>
    });
    log(format!(
        "subagents: {}; workspaces: {}; trace: {}",
        if uses_acpmux {
            format!("spawn/tell on {sub_harness} sessions through acpmux")
        } else {
            "off (no acpmux)".to_owned()
        },
        workspaces.as_ref().map_or_else(
            || format!("off ({no_workspace_reason})"),
            |w| format!("one per subagent, in {}", w.place())
        ),
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
            control: Some(control),
            inspector: start_inspector(paths, &chat, &claude_text),
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
    // The host env's TTL (Claude Code's own switches, then
    // OPTCHAT_CACHE_TTL) over the Chief's cache.ttl setting.
    let cache_ttl_env = crate::prompt::cache_ttl_from_env(&|k: &str| env(k));
    if let Some(v) = env("OPTCHAT_CACHE_TTL")
        && crate::prompt::CacheTtl::parse(&v).is_none()
    {
        log(format!("OPTCHAT_CACHE_TTL={v:?} is not 5m or 1h; ignored"));
    }
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
            // The direct API: 5 minutes unless OPTCHAT_CACHE_TTL or cache.ttl
            // says otherwise (read at host start).
            let native_ttl = cache_ttl_env
                .or(
                    crate::chief_settings::ChiefSettings::load(&paths.root.join("settings.json"))
                        .cache_ttl,
                )
                .unwrap_or(crate::prompt::CacheTtl::FiveMinutes);
            Engine::Native(Arc::new(
                Native::new(native_config, Arc::new(model), crate::native::RETRY_BASE)
                    .with_trace(trace.clone())
                    .with_cache_ttl(native_ttl),
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
        turn_idle_limit: {
            let minutes = env("OPTCHAT_CHIEF_TURN_IDLE_MIN")
                .and_then(|v| v.trim().parse::<u64>().ok())
                .unwrap_or(crate::turn::DEFAULT_TURN_IDLE.as_secs() / 60);
            (minutes > 0).then(|| Duration::from_secs(minutes * 60))
        },
        engine,
        turn_preset: claude_installed.then_some(claude_preset_name),
        chief_id: crate::paths::home_id(home),
        system_text: claude_text,
        engine_file: Some(crate::engine::path(home)),
        families,
        codex_preset,
        settings_file: paths.root.join("settings.json"),
        trace_dir: Some(paths.root.join("traces")),
        cache_ttl: cache_ttl_env,
        shared_ttl,
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
    .with_settle_status(crate::settle_status::SettleStatus::new(
        &paths.settle_status,
    ))
    .with_workspaces(workspaces);
    let mut brain = brain;
    brain.set_sub_starter(sub_starter);
    // Finished subagents' workspaces stay with a done mark unless this says close.
    brain.set_sub_close_on_finish(env("OPTCHAT_SUBAGENT_ON_FINISH").as_deref() == Some("close"));
    if let Some(describer) = describer {
        brain.set_describer(describer);
    }
    let probe_delay = Arc::new(ProbeDelay::default());
    spawn_probe(
        probe_delay.clone(),
        model,
        fallback,
        system,
        route,
        tx.clone(),
    );
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
    BRAIN_RUNNING.store(true, std::sync::atomic::Ordering::SeqCst);
    let fatal = brain.run(rx);
    probe_delay.stop();
    chat.shutdown();
    Ok(fatal)
}

const STOP_SIGNALS: [libc::c_int; 3] = [libc::SIGTERM, libc::SIGINT, libc::SIGHUP];

/// The write end of the stop pipe, for the signal handler.
static STOP_PIPE: std::sync::atomic::AtomicI32 = std::sync::atomic::AtomicI32::new(-1);

extern "C" fn on_stop_signal(signal: libc::c_int) {
    let fd = STOP_PIPE.load(std::sync::atomic::Ordering::Relaxed);
    if fd >= 0 {
        let byte = signal as u8;
        // SAFETY: write(2) is async-signal-safe; the buffer is one live byte.
        unsafe { libc::write(fd, (&raw const byte).cast(), 1) };
    }
}

/// Catches the stop signals with a handler that writes to a pipe (a
/// handler, not a blocked mask: children inherit a mask, but exec resets a
/// handler, so the acpmux daemon and the harnesses still stop on SIGTERM).
/// Returns the pipe's read end.
fn catch_stop_signals() -> Option<std::fs::File> {
    use std::os::fd::FromRawFd;
    let mut fds = [0 as libc::c_int; 2];
    // SAFETY: `fds` is a valid out-array of two descriptors.
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return None;
    }
    for fd in fds {
        // SAFETY: a descriptor this call just made; FD_CLOEXEC keeps it out of children.
        unsafe { libc::fcntl(fd, libc::F_SETFD, libc::FD_CLOEXEC) };
    }
    STOP_PIPE.store(fds[1], std::sync::atomic::Ordering::Relaxed);
    for signal in STOP_SIGNALS {
        // SAFETY: a zeroed sigaction with a valid handler and an empty mask.
        unsafe {
            let mut action = std::mem::zeroed::<libc::sigaction>();
            action.sa_sigaction = on_stop_signal as *const () as libc::sighandler_t;
            libc::sigemptyset(&mut action.sa_mask);
            action.sa_flags = libc::SA_RESTART;
            libc::sigaction(signal, &action, std::ptr::null_mut());
        }
    }
    // SAFETY: the read end is ours alone from here on.
    Some(unsafe { std::fs::File::from_raw_fd(fds[0]) })
}

/// The brain's input, for the stop watcher.
static STOP_TX: std::sync::OnceLock<std::sync::mpsc::Sender<Input>> = std::sync::OnceLock::new();

/// A stop signal arrived.
static STOPPING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// Stops the acpmux daemon this host started, once: its agent hosts and
/// their sessions (and their MCP children) end with it; a daemon this host
/// did not start is left alone. A second caller waits for the first.
fn stop_started_acpmux() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        crate::acpmux_daemon::shutdown_started(&|line| log(line));
    });
}

/// Set just before the brain's loop starts.
static BRAIN_RUNNING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

/// One thread waits for a stop signal and hands it to the brain, which
/// stops; the host then stops the acpmux daemon it started and exits 0.
fn watch_stop_signals() {
    use std::io::Read;
    let Some(mut pipe) = catch_stop_signals() else {
        log("stop signals: no pipe; SIGTERM ends the host at once");
        return;
    };
    let spawned = std::thread::Builder::new()
        .name("stop-signals".into())
        .spawn(move || {
            let mut byte = [0u8; 1];
            while pipe.read_exact(&mut byte).is_ok() {
                let signal = libc::c_int::from(byte[0]);
                STOPPING.store(true, std::sync::atomic::Ordering::SeqCst);
                let running = BRAIN_RUNNING.load(std::sync::atomic::Ordering::SeqCst);
                let sent = running
                    && STOP_TX
                        .get()
                        .is_some_and(|tx| tx.send(Input::Shutdown { signal }).is_ok());
                // Before the brain runs nothing is in flight: stop here.
                // Once it runs, it stops and `start` stops acpmux after it.
                if !sent {
                    log(format!("signal {signal}: stopping before the brain runs"));
                    stop_started_acpmux();
                    std::process::exit(0);
                }
            }
        });
    if let Err(e) = spawned {
        log(format!("stop signals: no watcher thread ({e})"));
    }
}

/// Builds one tiny node through the compactor's route, with its main and
/// its fallback model, in the background: when either cannot (acpmux down,
/// the harness not signed in, a 429, an unserved fallback model, a
/// compactor session that offers tools), host.log gets one line and the
/// Chief conversation one notice, instead of every turn waiting on settle
/// with nothing said.
fn spawn_probe(
    delay: Arc<ProbeDelay>,
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
            // A transient failure (the network, an exhausted route) is
            // retried after a backoff through the host's delay, quietly; a
            // real fault is posted once; the host's end stops the probe.
            let probe = || probe_models(&*model, fallback.as_deref(), &system);
            let Some(result) = probe_until_ready(&probe, &*delay, &|line: &str| log(line)) else {
                return;
            };
            match result {
                Ok(line) => {
                    log(format!(
                        "compactor probe ({}{}) built a node in {} ms: {line}",
                        route.name(),
                        if fallback.is_some() {
                            ", fallback too"
                        } else {
                            ""
                        },
                        started.elapsed().as_millis()
                    ));
                    let _ = tx.send(Input::CompactorStatus(Ok(())));
                }
                Err(e) => match probe_notice(route, &e) {
                    Some(text) => {
                        let _ = tx.send(Input::CompactorStatus(Err(text)));
                    }
                    None => log(format!(
                        "compactor probe: summaries wait for the model: ready in ~{}m ({e})",
                        optchat_host::capacity_wait(&e)
                            .unwrap_or_default()
                            .as_secs()
                            .div_ceil(60)
                    )),
                },
            }
        });
    if let Err(e) = spawned {
        log(format!("starting the compactor probe: {e}"));
    }
}

/// A wait the host can cut short: the start-up probe's retry delay. No
/// sleep in runtime code: `ProbeDelay` waits on a condition variable that
/// `stop` wakes (the host's end).
pub trait Delay: Send + Sync {
    /// Waits `d`; false when stopped (now or during the wait).
    fn wait(&self, d: std::time::Duration) -> bool;
}

/// The host's `Delay`, stopped when the host ends.
#[derive(Default)]
pub struct ProbeDelay {
    stopped: std::sync::Mutex<bool>,
    woken: std::sync::Condvar,
}

impl ProbeDelay {
    pub fn stop(&self) {
        *self
            .stopped
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner) = true;
        self.woken.notify_all();
    }
}

impl Delay for ProbeDelay {
    fn wait(&self, d: std::time::Duration) -> bool {
        let stopped = self
            .stopped
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let (stopped, _) = self
            .woken
            .wait_timeout_while(stopped, d, |s| !*s)
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        !*stopped
    }
}

/// The start-up probe: `probe` again after each transient failure, with
/// `delay` between tries; None when the delay was stopped.
pub fn probe_until_ready(
    probe: &dyn Fn() -> Result<String, String>,
    delay: &dyn Delay,
    log: &dyn Fn(&str),
) -> Option<Result<String, String>> {
    let mut attempt = 0;
    loop {
        match probe() {
            Err(e) => match probe_retry_wait(&e, attempt) {
                Some(wait) => {
                    log(&format!(
                        "compactor probe: {e}; trying again in {} s",
                        wait.as_secs()
                    ));
                    if !delay.wait(wait) {
                        return None;
                    }
                    attempt += 1;
                }
                None => return Some(Err(e)),
            },
            ok => return Some(ok),
        }
    }
}

/// How long the start-up probe waits before it tries again after `error`
/// (its `attempt`-th failure, from 0); None: no retry (a real fault).
pub fn probe_retry_wait(error: &str, attempt: u32) -> Option<std::time::Duration> {
    use std::time::Duration;
    const MAX: Duration = Duration::from_secs(120);
    if let Some(wait) = optchat_host::capacity_wait(error) {
        return Some(wait.min(MAX));
    }
    let lower = error.to_ascii_lowercase();
    let transient = [
        "network error",
        "check your internet connection",
        "connection was lost",
        "connection refused",
        "connection reset",
        "timed out",
        "did not answer within",
        "overloaded",
    ]
    .iter()
    .any(|t| lower.contains(t));
    transient.then(|| Duration::from_secs(1u64 << attempt.min(16)).min(MAX))
}

/// The notice a failed start-up probe posts in the Chief conversation;
/// None posts none (the failure is only logged).
pub fn probe_notice(route: CompactRoute, error: &str) -> Option<String> {
    // An exhausted route or a transient error is a wait, not a fault:
    // nothing to post (the probe tries again).
    if probe_retry_wait(error, 0).is_some() {
        return None;
    }
    let remedy = match route {
        CompactRoute::Acpmux => {
            "Check that acpmux runs and that its Claude harness signs in, or set \
             OPTCHAT_ANTHROPIC_BASE_URL and OPTCHAT_ANTHROPIC_API_KEY for an endpoint \
             that takes Messages API calls."
        }
        CompactRoute::Api => {
            "Check OPTCHAT_ANTHROPIC_BASE_URL and OPTCHAT_ANTHROPIC_API_KEY, or set \
             OPTCHAT_COMPACTOR=acpmux to build summaries in acpmux sessions."
        }
    };
    Some(format!(
        "The memory compactor cannot build summaries ({} route: {error}). Messages \
         that need a summary wait, and so does every reply, until it can. {remedy}",
        route.name()
    ))
}

/// The read-only memory inspector (inspect/http.rs) on 127.0.0.1, its
/// address and token in `optchat/inspector.json` for the app. Off with
/// `OPTCHAT_INSPECTOR=0`; a failure only logs (the Chief runs without it).
/// Returns the inspector for the tools socket's `inspect` tool too.
fn start_inspector(
    paths: &Paths,
    chat: &Arc<OptChat>,
    system_text: &str,
) -> Option<Arc<crate::inspect::Inspector>> {
    let _ = std::fs::remove_file(&paths.inspector);
    if env("OPTCHAT_INSPECTOR").as_deref() == Some("0") {
        return None;
    }
    let inspector = Arc::new(crate::inspect::Inspector::new(
        chat.clone(),
        paths.traces.clone(),
        paths.settle_status.clone(),
        system_text.to_owned(),
    ));
    let started = crate::inspect::http::new_secret().and_then(|token| {
        let bind = std::net::SocketAddr::from(([127, 0, 0, 1], 0));
        crate::inspect::http::start(inspector.clone(), bind, token)
    });
    match started.and_then(|running| {
        crate::inspect::http::publish(&paths.inspector, &running).map(|()| running)
    }) {
        Ok(running) if crate::inspect::http::PAGE_IS_PLACEHOLDER => log(format!(
            "memory inspector on {} (placeholder page: this binary was built without the inspector bundle)",
            running.url()
        )),
        Ok(running) => log(format!("memory inspector on {}", running.url())),
        Err(e) => log(format!("memory inspector not started: {e}")),
    }
    Some(inspector)
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
