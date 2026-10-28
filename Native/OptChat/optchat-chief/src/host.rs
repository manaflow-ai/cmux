//! `optchat-chief host --daemon-socket PATH --mux-home DIR`: the brain host
//! the app starts when `CMUX_NEXT_MUX_HOST` names this executable. A second
//! launch for the same home exits 0 (the app launches it on every Home open).

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
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
const PASSTHROUGH: [&str; 5] = [
    "CMUX_SOCKET_PATH",
    crate::cmux_env::APP_DAEMON_KEY,
    "ACPMUX_SOCKET",
    "ACPMUX_HOME",
    "ACPMUX_BIN",
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

/// The compactor's harness at host start, from acpmux's start-up `answer`:
/// the set one (`OPTCHAT_COMPACTOR_HARNESS`, else engine.json's
/// `compactor_harness`), else the turns' Claude harness (engine.json's
/// `harness`, else the host's `turn`), else `default_harness`. On a
/// machine whose only Claude login is the subrouter, a Chief set to
/// `claude-sr` compacts there too, not on a `claude` that is not signed in
/// (cosmic-gray 2026-10-14).
pub fn compactor_harness_for(
    answer: &serde_json::Value,
    set: Option<&str>,
    turn: &str,
    engine: &crate::engine::EngineChoice,
) -> String {
    if let Some(set) = set {
        return set.to_owned();
    }
    // engine.json's harness when it is Claude, else the host's `turn` when
    // it is (a codex engine on a claude-sr host still compacts on claude-sr).
    let turn = engine
        .harness
        .as_deref()
        .filter(|h| crate::harness_gate::plan(answer, h).family == Family::Claude)
        .unwrap_or(turn);
    let family = crate::harness_gate::plan(answer, turn).family;
    default_compactor_harness(turn, family, default_harness(answer))
}

/// `ACPMUX_PROBE_HARNESSES` of the acpmux daemon this host starts: the
/// harnesses the Chief can use, so its model probes never start another
/// harness's agent (a Claude-only Chief never starts codex-acp). The set
/// turn, compactor and subagent harnesses and engine.json's, and always the
/// Claude routes (`DEFAULT_HARNESS`, `CODEROUTER_HARNESS`, `SR2_HARNESS`): the default turn
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
    .chain([DEFAULT_HARNESS, CODEROUTER_HARNESS, SR2_HARNESS])
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
/// else the user's own Claude CLI (`DEFAULT_HARNESS`: the `claude` acpmux
/// finds on the login shell's PATH, run with the user's own
/// `~/.claude/settings.json` and login; Lawrence 2026-10-19: "make sure
/// Chief, by default, will talk to the correct Claude, using the user's
/// Claude CLI"). The subrouter2 route (`claude-sr2`) is an explicit choice
/// (`chief engine set --harness claude-sr2`), and the default only when
/// acpmux has no usable `claude` but can run sr2.
pub fn default_harness(answer: &serde_json::Value) -> &'static str {
    let harnesses = answer.get("harnesses");
    if harnesses.and_then(|h| h.get(CODEROUTER_HARNESS)).is_some() {
        return CODEROUTER_HARNESS;
    }
    let runnable_stdio = |name: &str| {
        harnesses.and_then(|h| h.get(name)).is_some_and(|p| {
            p.get("kind").and_then(serde_json::Value::as_str) == Some("claude-stdio")
                && p.get("unavailable").is_none()
        })
    };
    if !runnable_stdio(DEFAULT_HARNESS) && runnable_stdio(SR2_HARNESS) {
        SR2_HARNESS
    } else {
        DEFAULT_HARNESS
    }
}

/// Records which executable (and its `--version`) the turns, compactor and
/// subagents run, for `engine show` and host.log (Lawrence 2026-10-19: show
/// which Claude the Chief talks to). A refused role is left out.
fn record_resolved(home: &std::path::Path, plans: [&crate::harness_gate::Plan; 3]) {
    let mut versions: BTreeMap<String, String> = BTreeMap::new();
    let mut resolve = |plan: &crate::harness_gate::Plan| {
        plan.admitted.as_ref().ok().map(|a| {
            let version = versions
                .entry(a.argv0.clone())
                .or_insert_with(|| crate::engine::binary_version(&a.argv0))
                .clone();
            crate::engine::ResolvedHarness {
                harness: a.profile.clone(),
                kind: a.kind.clone(),
                argv0: a.argv0.clone(),
                version,
            }
        })
    };
    let resolved = crate::engine::ResolvedEngine {
        turn: resolve(plans[0]),
        compactor: resolve(plans[1]),
        subagent: resolve(plans[2]),
    };
    if let Some(t) = &resolved.turn {
        log(format!("turn CLI: {} {}", t.argv0, t.version));
    }
    if let Err(e) = crate::engine::save_resolved(home, &resolved) {
        log(format!(
            "writing {}: {e}",
            crate::engine::resolved_path(home).display()
        ));
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

/// acpmux's profile for Claude Code through the subrouter2 gateway
/// (`~/.config/cmux/harnesses/claude-sr2.toml`, command `sr2 claude`).
pub const SR2_HARNESS: &str = "claude-sr2";

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
    // Only acpmux's cmux MCP server (cx-4a5w2), as acpmux's built-in turn
    // presets set it for a Chief that sends no env.
    let (servers_key, servers) = session_dir::TURN_TOOL_SERVERS;
    env.insert(servers_key.to_owned(), servers.to_owned());
    // The cmux MCP server lists only the Chief's tools and refuses the rest,
    // `cmux_exec` scripts included (acpmux `MCP_TOOLS_ENV`). The deny rules
    // stay as the second guard.
    env.insert(
        session_dir::TURN_TOOLS_ENV.to_owned(),
        session_dir::CHIEF_CMUX_TOOLS.join(","),
    );
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
        // acpmux sends it as X-Subrouter-Session (sr2 and plain routes too):
        // a fresh Claude process per turn stays on one account and its cache.
        env.insert(
            crate::compactor::SUBROUTER_SESSION_HEADER_ENV.to_owned(),
            "1".to_owned(),
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
/// Claude Code adds is not offered). On top, the Chief's own MCP tools load
/// with the turn and the cmux MCP tools wait behind ToolSearch
/// (`session_dir::TURN_SETTINGS_ENV`).
pub const TURN_TOOLS: [&str; 7] = [
    "Bash",
    "Read",
    "Edit",
    "Write",
    "WebFetch",
    "WebSearch",
    "ToolSearch",
];

/// The settings a turn reads: the session folder's project and local
/// files, never the user's. Claude Code takes an allow rule for an MCP tool
/// only from the local file (2.1.305), and the Chief's own tools must never
/// wait on an approval (`approval::turn_allowed_tools`).
pub const TURN_SETTING_SOURCES: &str = "project,local";

/// The Claude Code args of an isolated turn: no user setting source (the
/// session folder's project and local files only), no skills or slash commands, only `TURN_TOOLS` of the built-ins
/// (acpmux's preset allowlist).
pub fn turn_isolation_args() -> Vec<String> {
    vec![
        "--setting-sources".to_owned(),
        TURN_SETTING_SOURCES.to_owned(),
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
        args: if family == Family::Claude {
            subagent_claude_args()
        } else {
            Vec::new()
        },
        system_prompt: (family == Family::Claude).then(|| text.to_owned()),
    }
}

/// Tools a Chief subagent never uses, besides `session_dir::SUBAGENT_DENIED_TOOLS`
/// (Claude Code's own subagents and the tools that wait for a human): the
/// ones that need the user's own opt-in in their own chat (`Workflow`,
/// `/loop`'s `ScheduleWakeup`, crons), and the cmux app's menu-action tools
/// (`app_*`, 584 of them; the `cmux action` CLI keeps every one). Measured
/// on Claude Code 2.1.305 with a one-word prompt (2026-10-23): 36,345 prompt
/// tokens with all of them, 18,751 without, on every subagent request.
pub const SUBAGENT_EXTRA_DENIED_TOOLS: [&str; 6] = [
    "Workflow",
    "ScheduleWakeup",
    "CronCreate",
    "CronDelete",
    "CronList",
    "mcp__cmux__app_*",
];

/// A Claude subagent's args: the deny list by argument, since the subagent
/// runs in its task's folder, where the subagent folder's project settings
/// never apply. No setting-source limit: subagents keep the user's settings.
pub fn subagent_claude_args() -> Vec<String> {
    let denied: Vec<&str> = session_dir::SUBAGENT_DENIED_TOOLS
        .iter()
        .chain(SUBAGENT_EXTRA_DENIED_TOOLS.iter())
        .copied()
        .collect();
    vec!["--disallowedTools".to_owned(), denied.join(",")]
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
    // A host without its own app (the Cloud Chief VM): its turns reach the
    // user's app through the relay that `CMUX_CHIEF_APP_SOCKET` names. An
    // app's own `CMUX_SOCKET_PATH` wins.
    if !session_env.contains_key("CMUX_SOCKET_PATH")
        && let Some(relay) =
            inherited(crate::cmux_env::REMOTE_APP_KEY).filter(|value| !value.is_empty())
    {
        session_env.insert("CMUX_SOCKET_PATH".to_owned(), relay);
    }
    // Its tabs open beside the Chief's chat (the app does not know a turn's
    // agent session; cmux_env::HOME_CHAT_KEY).
    session_env.insert(crate::cmux_env::HOME_CHAT_KEY.to_owned(), "1".to_owned());
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

/// The build-session kill switch, the test of acpmux launch_policy.rs.
fn agent_launch_disabled() -> bool {
    env("ACPMUX_AGENT_LAUNCH").is_some_and(|v| v.trim().eq_ignore_ascii_case("deny"))
        || env("CMUX_AGENTS_DISABLED").is_some_and(|v| v.trim() == "1")
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
    let _ = HOST_HOME.set(home.clone());
    // A moved Chief answers from its new host only (chief-migration-DESIGN.md 4).
    if let Some(why) = crate::migrate::refusal(&home) {
        eprintln!("optchat-chief host: {why}");
        return crate::migrate::MOVED_EXIT;
    }
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
    // cx-tgf4h: agents are off in this build session (acpmux refuses every
    // launch), so no turn could start; the host would only hold messages.
    if agent_launch_disabled() {
        log("not starting: agents are disabled in this build session \
             (ACPMUX_AGENT_LAUNCH=deny or CMUX_AGENTS_DISABLED=1)");
        return 0;
    }
    let _lock = match HostLock::take(&paths.host_lock, started_ms) {
        Ok(lock) => {
            // A stop mark an earlier host of this home left says nothing now.
            crate::lock::clear_stopping(&paths.host_lock);
            // The app may ask this host to hand off when idle (SIGUSR1).
            crate::lock::mark_handoff_when_idle(&paths.host_lock);
            lock
        }
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
    let settle = crate::settle_status::SettleStatus::new(&paths.settle_status);
    settle.clear();
    // The start-up probe says again when the compactor cannot work.
    settle.compactor_fault(None);
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
        Ok(fatal) if fatal.starts_with(crate::brain::HANDOFF_WHEN_IDLE) => {
            // The app hands acpmux off and starts the next host.
            log(format!("stopping: {fatal}"));
            0
        }
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

/// This Chief's record from the local owner's Chief registry, read on its
/// own bound connection (chief_profile.rs `ChiefTools::start`: no registry
/// or no record, every tool; the daemon away, a non-default Chief does not
/// start and the default Chief has zoom and date only until the link is up).
fn load_chief_tools(
    source: &Source,
    daemon_socket: &str,
    membership: &crate::membership::Membership,
) -> Result<crate::chief_profile::ChiefTools, String> {
    use crate::chief_profile::{ChiefTools, ProfileClient};
    let Source::Local { token_file } = source else {
        return Ok(ChiefTools::none());
    };
    let client = ProfileClient::new(
        daemon_socket.into(),
        token_file.clone(),
        membership.participant.clone(),
    );
    ChiefTools::start(Some(client), membership.is_default(), &|line: String| {
        log(line)
    })
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
    // Each turn reads the person's Home workspace with the CLI the turns use (home_view).
    let home_view = crate::home_view::HomeView {
        cli: crate::home_view::HomeView::cli_for(
            pinned
                .get(crate::cmux_env::BUNDLED_CLI_KEY)
                .map(std::path::Path::new),
        ),
        env: pinned.clone(),
    };
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
    // The Chief home whose codex homes acpmux's built-in codex presets use
    // (acpmux `config/chief_builtins.rs`): in the daemon's own environment.
    // A shared acpmux (one per Chief home) names the Chief home, whose
    // `c/<id>` directories hold the other Chiefs (acpmux maps their ids).
    let chief_mux_home = env("CMUX_CHIEF_HOME")
        .filter(|_| crate::acpmux_daemon::shared())
        .unwrap_or_else(|| home.display().to_string());
    daemon_env.insert("ACPMUX_CHIEF_MUX_HOME".to_owned(), chief_mux_home);
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
    // Who this Chief is in the conversations (membership): its participant
    // and which messages of the owner's other conversations wake it.
    let membership =
        crate::membership::Membership::from_env(matches!(source, Source::Local { .. }))?
            .with_owner(match &source {
                Source::Local { .. } => Some(cmux_chief::rules::USER_LOCAL),
                Source::Cloud { install } => install.user.as_deref(),
            });
    log(format!(
        "conversations: as {}{}",
        membership.participant,
        if membership.local_side {
            format!(
                ", and the local conversations it takes part in ({:?})",
                membership.group_wake
            )
        } else {
            String::new()
        }
    ));
    let instructions = match (
        crate::prompt::chief_instructions(&paths.person, &paths.instructions),
        membership.instructions(),
    ) {
        (Some(base), Some(channels)) => Some(format!("{base}\n\n{channels}")),
        (base, channels) => base.or(channels),
    };
    // This Chief's record (multi-Chief S5): its profile goes into the turns'
    // (and compactions') system text after everything above; subagents keep
    // the text without it (they are not this Chief). Its grant limits the
    // turn's tools (chief_profile.rs).
    let chief_tools = Arc::new(load_chief_tools(&source, daemon_socket, &membership)?);
    let sub_instructions = instructions.clone();
    let instructions = chief_tools.instructions(instructions);
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
        // else the user's own Claude CLI (default_harness).
        if chief_set.is_none() {
            harness = default_harness(&answer).to_owned();
            if sub_set.is_none() {
                sub_harness = harness.clone();
            }
        }
        // The compactor runs on a Claude route unless set otherwise: the
        // turns' engine harness when it is one, else the default route
        // (engine.json may swap the turns to codex per turn).
        compactor_harness = compactor_harness_for(
            &answer,
            compactor_set.as_deref(),
            &harness,
            &engine_choice_file,
        );
        let (turn, compactor, sub) = (
            plan(&harness, "turn"),
            plan(&compactor_harness, "compactor"),
            plan(&sub_harness, "subagent"),
        );
        record_resolved(home, [&turn, &compactor, &sub]);
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
    // directory; acpmux gives no other harness the optchat server (only its
    // own agent tools), so its memory tools are the launcher's commands.
    let tools = if claude {
        crate::prompt::Tools::Mcp
    } else {
        crate::prompt::Tools::Cli(paths.bin.join("chief").display().to_string())
    };
    let setup = SessionSetup {
        exe: exe.display().to_string(),
        env: session_env,
        instructions: instructions.clone(),
        tools,
        user_env: session_dir::host_user_env(),
        profile_tool: chief_tools.grant().allows("profile"),
        chiefs_tool: chief_tools.grant().allows("chiefs"),
    };
    session_dir::write(paths, &setup).map_err(|e| format!("writing the session directory: {e}"))?;
    // The skills cmux ships, shared by every Chief (skills.rs); a failure
    // costs only the skill, never the host.
    if let Err(e) = crate::skills::install_builtin(&crate::skills::shared_dir(&paths.home)) {
        eprintln!("optchat-chief: installing the shipped Chief skills: {e}");
    }
    // The tool packs cmux ships (toolpacks.rs); their skills reach each
    // Chief through session_dir::write (toolpacks::sync_skills).
    if let Err(e) = crate::toolpacks::install_builtin(&crate::toolpacks::shared_dir(&paths.home)) {
        eprintln!("optchat-chief: installing the shipped tool packs: {e}");
    }
    // Section 9: every subagent's directory and system prompt.
    let sub_tools = if sub_family == Family::Claude {
        crate::prompt::Tools::Mcp
    } else {
        crate::prompt::Tools::Cli(paths.bin.join("chief").display().to_string())
    };
    let sub_text = crate::prompt::subagent_system_text(sub_instructions.as_deref(), &sub_tools);
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
    // An app update replaces this binary while this process keeps the old code,
    // and the relaunched app keeps a host that holds the lock: hand off once no
    // turn runs (update_watch.rs). OPTCHAT_BINARY_WATCH=0 turns it off.
    if env("OPTCHAT_BINARY_WATCH").as_deref() != Some("0") {
        watch_binary(&exe, tx.clone());
    }
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
        && let Err(e) = (|| {
            // No turn survives a brain-host restart. Remove every old Codex
            // transcript/database then recreate the stable config, sign-in
            // link and installation id that prompt caching needs.
            crate::codex_home::wipe_codex_home(&paths.turn_codex)?;
            crate::codex_home::prepare_turn_codex_home(paths, &crate::codex_home::user_codex_home())
                .map_err(std::io::Error::other)
        })()
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
                crate::prompt::subagent_system_text(sub_instructions.as_deref(), &other_tools);
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
    // The reaction classifier (brain/reaction_wake.rs) is the same deny-all
    // acpmux model on its own nodes; the Messages API route has none, so a
    // reaction there is a quiet note.
    let mut judge: Option<Arc<dyn crate::brain::ReactionJudge>> = None;
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
            judge = Some(main.clone() as Arc<dyn crate::brain::ReactionJudge>);
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
        // Bounded: acpmux_daemon::ensure gives a starting daemon up to 60 s
        // (SPAWN_LIMIT), and query_harnesses ran it before this wait.
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
            ControlRequest::StopAll => {
                let (reply, answer) = channel();
                tx.send(Input::StopAll { reply }).map_err(stopping)?;
                answer
                    .recv_timeout(wait)
                    .map(|v| v.to_string())
                    .map_err(late)
            }
            ControlRequest::Restart(names) => {
                let (reply, answer) = channel();
                tx.send(Input::RestartSubagents { names, reply })
                    .map_err(stopping)?;
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
    // B4 (cloud-subagents-DESIGN.md): the pool tool resumes and pauses
    // cloud peers' VMs; a no-op until `deploy.sh up` names it in
    // ~/.config/cloud-subagents/vm-cmd.
    let cloud_vms: Option<Arc<dyn crate::cloud_vms::CloudVms>> = env("HOME").map(|h| {
        Arc::new(crate::cloud_vms::CommandVms::in_home(std::path::Path::new(
            &h,
        ))) as Arc<dyn crate::cloud_vms::CloudVms>
    });
    // Cloud subagents' own sandbox keys (agent_keys.rs): on when
    // ~/.config/cmux/agent-issuer.json names an issuer credential.
    let agent_keys: Option<Arc<dyn crate::agent_keys::AgentKeys>> =
        env("HOME").and_then(
            |h| match crate::agent_keys::Issuer::load(std::path::Path::new(&h)) {
                Ok(issuer) => issuer.map(|i| Arc::new(i) as Arc<dyn crate::agent_keys::AgentKeys>),
                Err(e) => {
                    eprintln!("optchat-chief: agent keys: {e}");
                    None
                }
            },
        );
    let placed = crate::workspaces::placement(
        workspaces_off,
        daemon_socket,
        &|k: &str| env(k),
        cloud_install.as_deref(),
    );
    let workspaces: Option<Arc<dyn crate::workspaces::Workspaces>> = match placed {
        crate::workspaces::Placement::Off => None,
        crate::workspaces::Placement::App(daemon) => {
            // a423: workspaces an older host left on the owner daemon move into the user's
            // session, once per start, off the start path (best effort; a failure is logged).
            if Path::new(daemon_socket) != daemon.as_path() {
                let (owner, app) = (PathBuf::from(daemon_socket), daemon.clone());
                std::thread::spawn(move || {
                    match crate::workspaces::adopt_owner_workspaces(&owner, &app) {
                        Ok(0) => {}
                        Ok(n) => eprintln!("optchat: moved {n} workspaces into the user's session"),
                        Err(e) => eprintln!("optchat: workspaces stay on the Chief's session: {e}"),
                    }
                });
            }
            // a423 (2026-10-21): the app's daemon, the user's own session, so a subagent's
            // workspace is the same kind of workspace as one the user makes (it outlives the app
            // as the app's daemon does). The tabs name the Chief home's acpmux (`chief:<home id>`).
            // A Chief no app opened (`cmux chief --chief-home`): the link dangles, so
            // its workspaces go to this host's own session until an app opens Home.
            let fallback = (Path::new(daemon_socket) != daemon.as_path())
                .then(|| PathBuf::from(daemon_socket));
            Some(Arc::new(crate::workspaces::DaemonWorkspaces {
                daemon,
                host: crate::workspaces::chief_host(home),
                host_name: crate::workspaces::host_name(),
                harness: Some(sub_harness.clone()),
                personal: true,
                fallback,
            }) as Arc<dyn crate::workspaces::Workspaces>)
        }
        crate::workspaces::Placement::Cloud(daemon, install) => {
            Some(Arc::new(crate::workspaces::DaemonWorkspaces {
                daemon,
                host: format!("install:{install}"),
                host_name: crate::workspaces::host_name(),
                harness: Some(sub_harness.clone()),
                personal: false,
                fallback: None,
            }) as Arc<dyn crate::workspaces::Workspaces>)
        }
        // Fresh Chief with no app in its environment (user 12374): the host's own session.
        crate::workspaces::Placement::OwnDaemon(daemon) => {
            Some(Arc::new(crate::workspaces::DaemonWorkspaces {
                daemon,
                host: crate::workspaces::chief_host(home),
                host_name: crate::workspaces::host_name(),
                harness: Some(sub_harness.clone()),
                personal: false,
                fallback: None,
            }) as Arc<dyn crate::workspaces::Workspaces>)
        }
    };
    let no_workspace_reason = if workspaces_off {
        "subagent workspaces are turned off on this Chief host".to_owned()
    } else {
        "this Chief host could not reach a cmux session to make the workspace in".to_owned()
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
                // Before any turn names one: medium, as the turns run.
                effort: crate::effort::turn_effort(env("OPTCHAT_SUBAGENT_EFFORT"), sub_family),
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
        .with_person(paths.person.clone())
        .with_pinned_harness(sub_set.is_some())
        .with_harness_grant(chief_tools.clone())
        .with_workspaces(workspaces.clone())
        .with_no_workspace_reason(no_workspace_reason.clone())
        // OPTCHAT_SUBAGENT_PEER: subagents run on that acpmux peer (a cloud
        // VM) and take no local slot (plans/cmux-next/cloud-subagents-DESIGN.md).
        .with_cloud(crate::subagents::CloudPlacement::from_env(
            env,
            sub_text.clone(),
        ))
        // `control cloud PEER` sets a peer at run time with no env.
        .with_cloud_text(sub_text.clone())
        .with_cloud_vms(cloud_vms.clone())
        .with_agent_keys(agent_keys.clone())
        // cloud_workspace: the app's own Cloud actions (#25596).
        .with_cloud_workspaces(
            crate::cloud_workspace::CloudWorkspaces::from_env(&|k: &str| env(k)).map(Arc::new),
        );
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
    // Chiefs on other machines (peer_chiefs.rs): their messages reach the
    // brain as notes, and `tell("chief:<name>")` reaches them.
    let peers_path = crate::peer_chiefs::Config::path(&paths.root);
    let peers = match crate::peer_chiefs::PeerChiefs::from_file(&peers_path) {
        Ok(peers) => peers,
        Err(e) => {
            log(format!("peer chiefs off: {e}"));
            None
        }
    };
    if let Some(peers) = &peers {
        let tx = Mutex::new(tx.clone());
        peers.spawn_inbox(
            Box::new(move |text| {
                tx.lock()
                    .expect("peer chiefs tx")
                    .send(Input::PeerChiefNote { text })
                    .is_ok()
            }),
            Arc::new(|line: &str| log(line)),
        );
    }
    crate::tools::serve_all(
        &paths.tools_socket,
        crate::tools::Served {
            memory: chat.clone(),
            orchestrator,
            control: Some(control),
            inspector: start_inspector(paths, &chat, &claude_text),
            chief: Some(chief_tools.clone()),
            // The turn names of `Settings::turn_prefix`, the subagent names
            // of the sub preset (`optchat-sub-<home id>-<id>`).
            turn: Some(crate::turn_caller::TurnBinding::for_home(
                &turn_prefix(home),
                &crate::paths::home_id(home),
            )),
            peers,
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
        turn_prefix: turn_prefix(home),
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
        home_view: Some(home_view),
        membership: membership.clone(),
        keep_turn_session: env("CHIEF_KEEP_TURN_SESSION").as_deref() != Some("0"),
    };
    let brain_log: crate::brain::Log = Arc::new(|line: &str| log(line));
    // Section 10: persist after each turn.
    // The backup repository follows a moved Chief (migrate.rs backup_id).
    let backup = crate::backup::Backup::new(crate::backup::BackupConfig::for_home(
        paths,
        &crate::migrate::backup_id(home),
    ));
    let retention =
        crate::turn_retention::TurnRetention::new(paths, &crate::compactor::user_claude_home());
    if let Err(e) = retention.cleanup() {
        log(format!(
            "cleaning expired turn transcripts at start failed: {e}"
        ));
    }
    let persister = crate::persist::Persister::start(
        paths.chat.clone(),
        paths.memory_db.clone(),
        Some(backup),
        Some(retention),
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
    // The app watches only the default Chief's state/ (cx-oqnw3 review): another
    // Chief still hears a compactor fault as its message until the app watches its home.
    .with_compactor_messages(membership.participant != crate::chief_profile::DEFAULT_CHIEF)
    .with_workspaces(workspaces);
    let mut brain = brain;
    brain.set_sub_starter(sub_starter);
    let idle = brain.cloud_auto_pause_idle();
    brain.set_cloud_vms(cloud_vms, idle);
    if let Some(home) = env("HOME") {
        brain.set_fleet_jobs(
            Some(std::sync::Arc::new(
                crate::fleet_wait::CommandFleet::in_home(std::path::Path::new(&home)),
            )),
            std::time::Duration::from_secs(30),
        );
    }
    brain.set_agent_keys(agent_keys, crate::agent_keys::REVOKE_AFTER_DONE);
    // No cap on subagents at work unless OPTCHAT_MAX_LIVE_SUBAGENTS sets one.
    brain.set_max_live(crate::subagents::live_limit(
        env(crate::subagents::MAX_LIVE_ENV).as_deref(),
    ));
    // Finished subagents' workspaces stay, names untouched, unless this says close.
    brain.set_sub_close_on_finish(env("OPTCHAT_SUBAGENT_ON_FINISH").as_deref() == Some("close"));
    // A person's message steered into the running turn and still unread
    // after 3 s interrupts the turn (brain/steer.rs);
    // OPTCHAT_STEER_DEADLINE_SECONDS=0 waits for the next tool boundary.
    brain.set_steer_deadline(Some(
        env("OPTCHAT_STEER_DEADLINE_SECONDS")
            .and_then(|s| s.trim().parse::<u64>().ok())
            .map_or(crate::brain::STEER_DEADLINE, std::time::Duration::from_secs),
    ));
    // Subagents that stop on a model or network error continue on their own
    // (auto_resume.rs); OPTCHAT_AUTO_RESUME=off turns it off.
    brain.set_auto_resume(crate::auto_resume::ResumePolicy::from_env(env), None);
    if let Some(describer) = describer {
        brain.set_describer(describer);
    }
    if let Some(judge) = judge {
        brain.set_reaction_judge(judge);
    }
    // Link cards on the Chief's replies (link_preview.rs); `0` turns them off.
    if env("OPTCHAT_CHIEF_LINK_PREVIEWS").as_deref() != Some("0") {
        brain.set_previewer(Arc::new(crate::link_preview::HttpFetcher::new()));
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
    // A default Chief that could not read its record at start reads it each
    // time the link comes up, until it has it (zoom and date only until then).
    let sink =
        crate::chief_profile::read_record_on_up(chief_tools.clone(), sink, brain_log.clone());
    match source {
        Source::Local { token_file } => {
            let (display_name, title) = LinkConfig::names_from_env();
            daemon::spawn_link(
                LinkConfig {
                    socket: daemon_socket.into(),
                    token_file,
                    display_name,
                    title,
                    participant: membership.participant.clone(),
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

/// An update's "hand off when idle" (the app, `ChiefHostStop`): the brain
/// stops between turns and the host exits without ending its acpmux, which
/// the app then hands off.
const HANDOFF_SIGNAL: libc::c_int = libc::SIGUSR1;

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
    for signal in STOP_SIGNALS.into_iter().chain([HANDOFF_SIGNAL]) {
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

/// Stops what this host owns on its acpmux, once (a second caller waits
/// for the first). One acpmux per Chief home (hq-6d 2026-10-14): the
/// daemon stops only when its last user leaves.
/// - The daemon this host started (the default Chief's host, a VM Chief's
///   own daemon): stopped with its agent hosts, unless another Chief uses
///   it (`agents::other_users`); then only this Chief's own sessions end and
///   the daemon keeps running for them. A daemon already gone (a handoff:
///   the app stopped it and the next build's daemon adopts the sessions) is
///   left alone, and so is the next daemon on its socket.
/// - A shared acpmux (`acpmux_daemon::shared`): this Chief's own sessions
///   end; when no other Chief uses the daemon, it stops too.
///
/// Before it looks for other users a stopping host marks itself stopping
/// (`lock::mark_stopping`) and ends its own sessions, so when Chiefs stop
/// at once the last one to look stops the daemon. A daemon this host
/// neither started nor shares is left alone.
fn stop_started_acpmux() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let home = HOST_HOME.get().cloned().unwrap_or_else(mux_home);
        let shared = crate::acpmux_daemon::shared();
        let chief_home = env("CMUX_CHIEF_HOME")
            .filter(|_| shared)
            .map_or_else(|| home.clone(), PathBuf::from);
        // No start begins from here; a start in flight finishes first.
        let mut started = crate::acpmux_daemon::take_started();
        if started.as_mut().is_some_and(|daemon| daemon.gone()) {
            // A handoff stopped it: the next build's daemon adopts this
            // Chief's sessions, and the daemon on the socket is not ours.
            log("acpmux: the daemon this host started already stopped (a handoff or the app); nothing to stop");
            return;
        }
        if !shared && started.is_none() {
            // A daemon it found running is the app's, a supervisor's or
            // another Chief's.
            return;
        }
        // Every stopping Chief first marks itself stopping and ends its own
        // sessions, then looks for other users: the last one to look sees
        // all the others gone and stops the daemon, also when all stop at
        // once (the supervisor stops every brain together).
        crate::lock::mark_stopping(&home.join("state/host.lock"));
        match crate::agents::end_own_sessions(&home) {
            Ok(names) => log(format!("acpmux: ended this Chief's {} session(s)", names.len())),
            Err(e) => log(format!("acpmux: ending this Chief's sessions: {e}")),
        }
        match crate::agents::other_users(&home, &chief_home) {
            Ok(users) if !users.is_empty() => {
                log(format!(
                    "acpmux: other Chiefs use it, the daemon keeps running: {}",
                    users.join(", ")
                ));
            }
            Ok(_) => {
                log("acpmux: no other Chief uses it; stopping it");
                match started.take() {
                    // A shared host stops within the supervisor's grace:
                    // the shutdown runs on without it.
                    _ if shared => crate::acpmux_daemon::shutdown_shared(&|line| log(line)),
                    Some(daemon) => {
                        daemon.shutdown(&|line| log(line));
                    }
                    None => {}
                }
            }
            Err(e) if !shared => {
                log(format!("acpmux: its users unknown ({e}); stopping the daemon it started"));
                if let Some(daemon) = started.take() {
                    daemon.shutdown(&|line| log(line));
                }
            }
            Err(e) => log(format!("acpmux: its users unknown ({e}); the daemon keeps running")),
        }
    });
}

/// Looks at this host's binary every `CHECK_EVERY`; the first time another file
/// is at its path, asks the brain to hand off once no turn runs.
fn watch_binary(exe: &Path, tx: std::sync::mpsc::Sender<Input>) {
    let watch = crate::update_watch::ExeWatch::new(exe);
    let shown = exe.display().to_string();
    let spawned = std::thread::Builder::new()
        .name("binary-watch".into())
        .spawn(move || {
            loop {
                // A fixed check interval for a file on disk (no change event to wait on).
                std::thread::sleep(crate::update_watch::CHECK_EVERY);
                if watch.replaced() {
                    log(format!("{shown} was replaced on disk (an update)"));
                    let _ = tx.send(Input::BinaryReplaced);
                    return;
                }
            }
        });
    if let Err(e) = spawned {
        log(format!(
            "binary watch: no thread ({e}); an update waits for the next restart"
        ));
    }
}

/// This host's `MUX_HOME` (`--mux-home`), for the stop path.
static HOST_HOME: std::sync::OnceLock<PathBuf> = std::sync::OnceLock::new();

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
                if signal == HANDOFF_SIGNAL {
                    let running = BRAIN_RUNNING.load(std::sync::atomic::Ordering::SeqCst);
                    let sent = running
                        && STOP_TX
                            .get()
                            .is_some_and(|tx| tx.send(Input::HandoffWhenIdle).is_ok());
                    if !sent {
                        // No turn can run yet: hand off now; the app stops acpmux.
                        log("handoff requested before the brain runs: exiting");
                        std::process::exit(0);
                    }
                    continue;
                }
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
        "The memory compactor cannot build summaries ({} route: {error}). Replies \
         go on and read the lines it cannot summarize unsummarized (a turn waits at most \
         10 s on compaction) until it can. {remedy}",
        route.name()
    ))
}

/// The memory inspector for the tools socket's `inspect` tool (the app's
/// native Memory Inspector asks through its daemon), with the owner's
/// change book (`inspect/edit.rs`). Off with `OPTCHAT_INSPECTOR=0`. The old
/// web page on 127.0.0.1 (inspect/http.rs, its address and token in
/// `optchat/inspector.json`) starts only with `OPTCHAT_INSPECTOR_WEB=1`, the
/// fallback; a failure only logs (the Chief runs without it).
fn start_inspector(
    paths: &Paths,
    chat: &Arc<OptChat>,
    system_text: &str,
) -> Option<Arc<crate::inspect::Inspector>> {
    let _ = std::fs::remove_file(&paths.inspector);
    if env("OPTCHAT_INSPECTOR").as_deref() == Some("0") {
        return None;
    }
    let editor = crate::inspect::edit::Editor::open(chat.clone(), &paths.root);
    let inspector = Arc::new(
        crate::inspect::Inspector::new(
            chat.clone(),
            paths.traces.clone(),
            paths.settle_status.clone(),
            system_text.to_owned(),
        )
        .with_editor(editor),
    );
    if env("OPTCHAT_INSPECTOR_WEB").as_deref() != Some("1") {
        log("memory inspector: native (through the daemon); web page off");
        return Some(inspector);
    }
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

/// The turn session names' prefix (`Settings::turn_prefix`, and the tools
/// socket's turn binding, turn_caller.rs): `optchat-<home id>`.
fn turn_prefix(home: &std::path::Path) -> String {
    format!("optchat-{}", crate::paths::home_id(home))
}
