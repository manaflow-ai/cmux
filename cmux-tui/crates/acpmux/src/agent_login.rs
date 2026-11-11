//! `_acpmux/agent_login/*`: an agent CLI's own sign-in, run on the machine
//! this daemon runs on (a person's Cloud machine), so the chat's sign-in card
//! can sign that machine in without the Mac's login ever leaving the Mac
//! (copying it may be against the agent's terms). The server side is
//! `server/agent_login.rs`; this is the work.
//!
//! - `start {agent}` runs `claude auth login --claudeai` or `codex login
//!   --device-auth` in a private temp folder, reads its output for at most
//!   [`URL_WAIT`] and [`OUTPUT_CAP`] bytes, and answers the link to open (only
//!   an https link on a host of `parse::ALLOWED_HOSTS`) and Codex's one-time
//!   code. One sign-in per agent: a new start stops the previous one. A
//!   sign-in is stopped after [`EXPIRY`], on `cancel`, and with this daemon
//!   (its own process group, killed on drop).
//!   Claude also gets a `BROWSER` of its own: a shim in the sign-in's private
//!   folder that saves the page Claude asks to open (its automatic link, whose
//!   approve redirects to Claude's own listener at
//!   `http://localhost:<port>/callback` on this machine) to a 0600 file and
//!   opens nothing. `start` waits up to [`AUTO_URL_WAIT`] after the printed
//!   link for it and answers it (`autoUrl`, `callbackPort`) only when it is
//!   an allowed link with exactly that redirect (`parse::auto_url`). The
//!   person's Mac opens it in a browser tab whose localhost is this machine
//!   (cmux's remote localhost carries the bytes), so the approve signs Claude
//!   in with no code pasted (Leo 2026-11-02: one click plus the provider's
//!   approve page, with nothing else).
//! - `finish {loginId, code?}`: Claude gets the code the callback page shows
//!   on stdin and has [`CLAUDE_FINISH_WAIT`] to exit. With no code, after a
//!   start that answered `autoUrl`, it waits for Claude to exit on its own
//!   (the approve reached its listener) until the sign-in expires; a code
//!   pasted meanwhile still goes to Claude's stdin, as the fallback. Codex
//!   finishes its device flow by itself, waited for until the sign-in
//!   expires. Signed in
//!   means exit 0 and the sign-in now in the agent's own store (Claude's
//!   `.credentials.json` `claudeAiOauth`; Codex's `auth.json` tokens or key),
//!   read as `/etc/cmux/agent-auth.sh` reads them, never their values.
//! - `api_key {agent, key}`: Claude's `settings.json` gets `env.ANTHROPIC_API_KEY`
//!   (other keys kept, 0600, written whole); Codex runs `codex login
//!   --with-api-key` with the key on stdin; Gemini's `.gemini/.env` gets
//!   `GEMINI_API_KEY` and its `settings.json` `security.auth.selectedType =
//!   "gemini-api-key"` ([`merge_gemini_api_key`]).
//! - Gemini CLI signs in here with an API key only (`start` is
//!   `unsupported`); the Grok CLI with its device flow only (`grok login
//!   --device-auth`, finished by itself like Codex's; `api_key` is
//!   `unsupported`: grok reads `XAI_API_KEY` from its env, which the person's
//!   vault delivers).
//! - Cursor (`cursor-agent login`, Leo 2026-11-10: "if somebody has a ChatGPT
//!   subscription or a Cursor subscription"): like Codex, it prints one
//!   `https://cursor.com/...` link (only that host, [`parse::CURSOR_HOSTS`]),
//!   waits for the approve itself and exits 0 once its
//!   `<XDG_CONFIG_HOME or ~/.config>/cursor/auth.json` holds the sign-in;
//!   `NO_OPEN_BROWSER=1` keeps it from opening one. It takes no code and no
//!   key here: a Cursor API key reaches the agent as the Cloud secret
//!   `CURSOR_API_KEY` instead.
//!
//! The CLI is the one this daemon starts the agent with (the `claude` or
//! `codex` harness profile, else `claude`/`codex` on the login PATH), with
//! this daemon's environment minus every model-plane value
//! ([`MODEL_PLANE_ENV`]), so no CodeRouter or team value outranks or receives
//! the person's own sign-in; with no display and `BROWSER=true`, so nothing
//! opens a browser on the machine; and `CMUX_<AGENT>_AUTH=own`, so a cmux
//! Cloud image's launcher (`/etc/cmux/claude`, `/etc/cmux/codex`) adds no
//! CodeRouter configuration to it.
//!
//! On a team machine every member runs as the same Unix user, so an own
//! sign-in there would be every member's: refused (`shared_machine`) when
//! `/etc/cmux/vm-kind` exists and is not `owner`, as `agent-auth.sh`'s
//! `cmux_agent_own_login_allowed` (fail closed: unreadable is shared).
//!
//! Nothing here logs, traces, records or answers a code, key or token.

use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde_json::Value;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::Notify;
use tokio::time::Instant;
use zeroize::Zeroizing;

mod hot;
pub mod parse;
#[cfg(test)]
mod tests;

/// Listed in `initialize`'s `_meta.acpmux.features`: this daemon answers
/// `_acpmux/agent_login/*`.
pub const FEATURE: &str = "agent_login";
/// How long `start` reads the CLI's output for its link.
pub const URL_WAIT: Duration = Duration::from_secs(20);
/// How long `start` waits, after Claude printed its link, for the page Claude
/// asked its `BROWSER` to open (it asks right after printing).
pub const AUTO_URL_WAIT: Duration = Duration::from_secs(2);
/// The file, in a sign-in's private folder, the `BROWSER` shim saves to.
const AUTO_URL_FILE: &str = "auto-url";
/// The most of that file read.
const AUTO_URL_CAP: u64 = 16 * 1024;
/// Claude's `BROWSER` (module docs): saves its arguments, one per line, and
/// opens nothing. Its folder is the sign-in's own (0700); the file is 0600.
const BROWSER_SHIM: &str = r#"#!/bin/sh
# cmux: keeps the sign-in page this CLI asks to open for the chat's sign-in card; opens nothing here.
umask 077
dir=$(dirname "$0")
printf '%s\n' "$@" > "$dir/.auto-url.$$" && mv -f "$dir/.auto-url.$$" "$dir/auto-url"
"#;
/// How much of the CLI's output is kept.
pub const OUTPUT_CAP: usize = 64 * 1024;
/// How long a sign-in lives (Codex's device code expires in 15 minutes).
pub const EXPIRY: Duration = Duration::from_secs(15 * 60);
/// How long Claude has to exit after it got the code.
pub const CLAUDE_FINISH_WAIT: Duration = Duration::from_secs(120);
/// How long `codex login --with-api-key` has.
pub const API_KEY_WAIT: Duration = Duration::from_secs(60);

/// The model-plane values the sign-in never sees: they would receive the
/// person's sign-in or outrank it.
pub const MODEL_PLANE_ENV: &[&str] = &[
    "ANTHROPIC_API_KEY",
    "ANTHROPIC_AUTH_TOKEN",
    "ANTHROPIC_BASE_URL",
    "CLAUDE_CODE_OAUTH_TOKEN",
    "OPENAI_API_KEY",
    "OPENAI_BASE_URL",
    "CODEX_API_KEY",
    "ANTHROPIC_CUSTOM_HEADERS",
    "CLAUDE_CODE_USE_BEDROCK",
    "CLAUDE_CODE_USE_VERTEX",
    "CLAUDE_CODE_USE_FOUNDRY",
    "GEMINI_API_KEY",
    "GOOGLE_API_KEY",
    "XAI_API_KEY",
];

/// The account-home variables pinned on the CLI's command (`Cli::command`), so it
/// signs in where [`Cli::store`] looks.
pub const HOME_ENV: &[&str] =
    &["HOME", "CODEX_HOME", "CLAUDE_CONFIG_DIR", "GEMINI_CLI_HOME", "GROK_HOME"];

/// `error.data.reason` values.
pub mod reason {
    pub const UNSUPPORTED_AGENT: &str = "unsupported_agent";
    /// A known agent that does not sign in this way here (Gemini's `start`,
    /// Grok's `api_key`).
    pub const UNSUPPORTED: &str = "unsupported";
    pub const SHARED_MACHINE: &str = "shared_machine";
    pub const BUSY: &str = "busy";
    pub const CLI_MISSING: &str = "cli_missing";
    pub const NO_URL: &str = "no_url";
    pub const BAD_CODE: &str = "bad_code";
    pub const EXPIRED: &str = "expired";
    pub const FAILED: &str = "failed";
    pub const UNKNOWN_LOGIN: &str = "unknown_login";
    /// A `sessionId` that names no chat here or on a peer.
    pub const UNKNOWN_SESSION: &str = "unknown_session";
    /// `start {agent: "<agent>@gateway"}` on a machine whose team cmux's gateway does not
    /// serve for that agent ([`Machine::gateway_access`]).
    pub const NO_GATEWAY: &str = "no_gateway";
}

/// `start {agent: "claude@gateway"}` (or `codex@gateway`): the chat's agent uses cmux's
/// gateway (SR2: the team's CodeRouter account, through the machine's edge) instead of a sign-in
/// of its own, as `cr use team <agent>` records it. The suffix rides the sign-in card's existing
/// `start` step, so every host and relay that carries a sign-in carries this too.
pub const GATEWAY_SUFFIX: &str = "@gateway";

/// The agent a `start` names with [`GATEWAY_SUFFIX`]: only the agents the image's
/// `/etc/cmux/agent-auth.sh` routes through the gateway (Claude, Codex).
pub fn gateway_agent(name: &str) -> Option<Agent> {
    let agent = Agent::parse(name.strip_suffix(GATEWAY_SUFFIX)?)?;
    matches!(agent, Agent::Claude | Agent::Codex).then_some(agent)
}

/// The switch for the gateway fallback: with it on, a Cloud chat whose Claude has no credential,
/// on a machine whose team cmux's gateway serves, uses the gateway without asking (its first send
/// goes again there, `hub/auto_resume/first_send.rs`). Off by default until the founders turn
/// billing on; the machine's daemon environment turns it on (`CMUX_GATEWAY_FALLBACK=1`).
pub const GATEWAY_FALLBACK_ENV: &str = "CMUX_GATEWAY_FALLBACK";

/// Whether `value` (the [`GATEWAY_FALLBACK_ENV`] value) turns the fallback on: only an explicit
/// `1`, `true`, `yes` or `on`. Unset, empty or anything else is off.
pub fn gateway_fallback(value: Option<&str>) -> bool {
    value.is_some_and(|v| {
        let v = v.trim();
        ["1", "true", "yes", "on"].iter().any(|on| v.eq_ignore_ascii_case(on))
    })
}

/// [`gateway_fallback`] of this daemon's environment.
pub fn gateway_fallback_on() -> bool {
    gateway_fallback(std::env::var(GATEWAY_FALLBACK_ENV).ok().as_deref())
}

/// How long [`Machine::gateway_access`] waits for the image's answer (its own request gives up
/// after 5 s; an answer is kept 60 s).
pub const GATEWAY_ACCESS_WAIT: Duration = Duration::from_secs(10);

/// Asks the image's own check (`cmux_agent_team_access`, the one every launcher and `cr use`
/// run), with the model plane loaded the way `cr` loads it when this daemon's environment lacks
/// it. Arguments: the agent-auth library, the machine's `model-plane.env`, the agent. Exit 0: the
/// team has an account for the agent; 1: none; 2: no answer; 3: unreachable.
const GATEWAY_ACCESS_SH: &str = r#"lib=$1 plane=$2 agent=$3
if [ -z "${CMUX_CODEROUTER_URL-}" ]; then
  for f in "${HOME:-/root}/.config/cmux/model-plane.env" "$plane"; do
    if [ -f "$f" ]; then set -a; . "$f"; set +a; break; fi
  done
fi
. "$lib" || exit 2
cmux_agent_team_access "$agent"
"#;

/// An agent whose own sign-in this runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Agent {
    Claude,
    Codex,
    /// Gemini CLI: an API key only.
    Gemini,
    /// The Grok CLI: its device flow only.
    Grok,
    /// `cursor-agent`: its browser sign-in only.
    Cursor,
}

impl Agent {
    pub const ALL: [Agent; 5] =
        [Agent::Claude, Agent::Codex, Agent::Gemini, Agent::Grok, Agent::Cursor];

    pub fn parse(name: &str) -> Option<Agent> {
        Agent::ALL.into_iter().find(|a| a.name() == name)
    }

    pub fn name(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
            Agent::Gemini => "gemini",
            Agent::Grok => "grok",
            Agent::Cursor => "cursor",
        }
    }

    /// `start` runs the CLI's own browser or device sign-in.
    pub fn signs_in_by_link(self) -> bool {
        self != Agent::Gemini
    }

    /// `api_key` saves a key for it.
    pub fn takes_api_key(self) -> bool {
        !matches!(self, Agent::Grok | Agent::Cursor)
    }

    /// Its store under a home with no override: `.claude`, `.codex`, `.gemini`, `.grok`,
    /// `.config/cursor`.
    pub fn home_dir_name(self) -> &'static str {
        match self {
            Agent::Claude => ".claude",
            Agent::Codex => ".codex",
            Agent::Gemini => ".gemini",
            Agent::Grok => ".grok",
            Agent::Cursor => ".config/cursor",
        }
    }

    /// The program on the login PATH when no harness profile names one.
    pub fn program(self) -> &'static str {
        match self {
            Agent::Cursor => "cursor-agent",
            agent => agent.name(),
        }
    }
}

/// Why a sign-in step failed: one of [`reason`] and a sentence (never a
/// secret, never the CLI's output).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct LoginError {
    pub reason: &'static str,
    pub message: String,
}

impl LoginError {
    pub fn new(reason: &'static str, message: impl Into<String>) -> LoginError {
        LoginError { reason, message: message.into() }
    }
}

/// How the agent's CLI runs here: the program, options before the
/// subcommand (Codex's `-c`, `-p`, which pick where it keeps its sign-in) and
/// the harness profile's own env over this daemon's.
#[derive(Debug, Clone, Default)]
pub struct Cli {
    pub program: String,
    pub globals: Vec<String>,
    pub env: BTreeMap<String, String>,
}

impl Cli {
    /// A variable as the CLI sees it: the profile's, else this daemon's.
    fn var(&self, key: &str) -> Option<String> {
        self.env
            .get(key)
            .cloned()
            .or_else(|| crate::login_env::var(key))
            .or_else(|| std::env::var(key).ok())
            .filter(|v| !v.is_empty())
    }

    fn home(&self) -> PathBuf {
        self.var("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default()
    }

    /// Where `agent` keeps its sign-in: `CLAUDE_CONFIG_DIR` or `~/.claude`;
    /// `CODEX_HOME` or `~/.codex`; `$GEMINI_CLI_HOME/.gemini` or `~/.gemini`
    /// (Gemini CLI's homedir() is `GEMINI_CLI_HOME || os.homedir()`);
    /// `GROK_HOME` or `~/.grok`.
    pub fn store(&self, agent: Agent) -> PathBuf {
        let own = |key: &str| self.var(key).map(PathBuf::from);
        match agent {
            Agent::Claude => own("CLAUDE_CONFIG_DIR"),
            Agent::Codex => own("CODEX_HOME"),
            Agent::Gemini => own("GEMINI_CLI_HOME").map(|h| h.join(".gemini")),
            Agent::Grok => own("GROK_HOME"),
            // `cursor-agent` keeps `auth.json` here on Linux (`harness_health/agent_files.rs`).
            Agent::Cursor => Some(
                own("XDG_CONFIG_HOME")
                    .unwrap_or_else(|| self.home().join(".config"))
                    .join("cursor"),
            ),
        }
        .unwrap_or_else(|| self.home().join(agent.home_dir_name()))
    }

    /// The command, its env shaped as the module docs say, in `cwd`; no
    /// stdio set.
    pub fn command(&self, args: &[&str], cwd: &Path) -> Command {
        let mut cmd = Command::new(&self.program);
        crate::login_env::apply_tokio(&mut cmd);
        crate::config::scrub_nested_claude_env_tokio(&mut cmd);
        for (k, _) in std::env::vars_os() {
            if k.to_string_lossy().starts_with("ACPMUX_") {
                cmd.env_remove(&k);
            }
        }
        for key in crate::cua_socket::AGENT_SCRUBBED_ENV {
            cmd.env_remove(key);
        }
        cmd.env_remove("CODEX_THREAD_ID")
            .env_remove("OMPCODE")
            .env_remove("CLAUDECODE")
            .env_remove("CLAUDE_CODE_ENTRYPOINT");
        cmd.envs(&self.env);
        // Pin the same resolved homes used by store(), including login-shell-only values.
        // The generic child allowlist deliberately excludes these family-specific keys.
        for key in HOME_ENV {
            if let Some(value) = self.var(key) {
                cmd.env(key, value);
            }
        }
        // Cursor's store follows XDG_CONFIG_HOME: the CLI gets exactly the one store() resolved,
        // so the sign-in it writes is the one finish reads.
        match self.var("XDG_CONFIG_HOME") {
            Some(value) => cmd.env("XDG_CONFIG_HOME", value),
            None => cmd.env_remove("XDG_CONFIG_HOME"),
        };
        for key in MODEL_PLANE_ENV {
            cmd.env_remove(key);
        }
        cmd.env_remove("DISPLAY")
            .env_remove("WAYLAND_DISPLAY")
            .env("BROWSER", "true")
            .env("NO_OPEN_BROWSER", "1")
            .env("TERM", "dumb")
            .env("NO_COLOR", "1")
            .env("CMUX_CLAUDE_AUTH", "own")
            .env("CMUX_CODEX_AUTH", "own")
            .env("CMUX_GEMINI_AUTH", "own")
            .env("CMUX_GROK_AUTH", "own");
        // A Cursor key in this daemon's environment (a Cloud secret) would outrank the sign-in.
        for key in ["CURSOR_API_KEY", "CURSOR_AUTH_TOKEN"] {
            cmd.env_remove(key);
        }
        cmd.args(&self.globals).args(args).current_dir(cwd);
        cmd
    }
}

/// The machine a sign-in runs on: `root` holds `etc/cmux` (`/` outside
/// tests), `home` is this daemon's user's home.
#[derive(Debug, Clone)]
pub struct Machine {
    pub root: PathBuf,
    pub home: PathBuf,
}

impl Machine {
    /// On a team machine (module docs): `etc/cmux/vm-kind` exists and is not
    /// `owner`, or cannot be read.
    pub fn shared(&self) -> bool {
        let kind = self.root.join("etc/cmux/vm-kind");
        match std::fs::symlink_metadata(&kind) {
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => false,
            Err(_) => true,
            Ok(_) => match std::fs::read(&kind) {
                Ok(bytes) => {
                    String::from_utf8_lossy(bytes.get(..64).unwrap_or(&bytes)).trim() != "owner"
                }
                Err(_) => true,
            },
        }
    }

    /// A cmux Cloud image: its launchers pick each agent's sign-in mode
    /// (`/etc/cmux/agent-auth.sh`).
    pub fn cloud_image(&self) -> bool {
        self.root.join("etc/cmux/agent-auth.sh").is_file()
    }

    /// Records that `agent` uses its own sign-in here
    /// (`~/.config/cmux/agent-auth/<agent>` = `own`), so the image's launcher
    /// stops using the team's CodeRouter for it. Only on a cmux Cloud image.
    pub fn choose_own(&self, agent: Agent) -> std::io::Result<bool> {
        if !self.cloud_image() {
            return Ok(false);
        }
        let dir = self.home.join(".config/cmux/agent-auth");
        private_dir(&dir)?;
        write_private(&dir.join(agent.name()), b"own\n")?;
        Ok(true)
    }

    /// Records that `agent` uses cmux's gateway here, as `cr use team <agent>` does
    /// (`~/.config/cmux/agent-auth/<agent>` = `team`), and drops the image's kept team-access
    /// answer (`~/.cache/cmux/agent-access`) as `cr use` does, so the next launch asks again.
    /// Only on a cmux Cloud image.
    pub fn choose_team(&self, agent: Agent) -> std::io::Result<bool> {
        if !self.cloud_image() {
            return Ok(false);
        }
        let dir = self.home.join(".config/cmux/agent-auth");
        private_dir(&dir)?;
        write_private(&dir.join(agent.name()), b"team\n")?;
        match std::fs::remove_file(self.home.join(".cache/cmux/agent-access")) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e),
            _ => Ok(true),
        }
    }

    /// Whether cmux's gateway serves `agent` for this machine's team, answered by the image's
    /// own `/etc/cmux/agent-auth.sh` (`cmux_agent_team_access`, one `GET
    /// /api/coderouter/agent-access` through the machine's edge, kept 60 s), never a check of
    /// its own: `Some(true)` the team has an account for it, `Some(false)` none, `None` not a
    /// cmux Cloud image, an agent the image does not route, or no answer.
    pub async fn gateway_access(&self, agent: Agent) -> Option<bool> {
        if !matches!(agent, Agent::Claude | Agent::Codex) || !self.cloud_image() {
            return None;
        }
        let mut cmd = Command::new("/bin/sh");
        cmd.arg("-c")
            .arg(GATEWAY_ACCESS_SH)
            .arg("sh")
            .arg(self.root.join("etc/cmux/agent-auth.sh"))
            .arg(self.root.join("etc/cmux/model-plane.env"))
            .arg(agent.name())
            .env("HOME", &self.home)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .kill_on_drop(true);
        let status = tokio::time::timeout(GATEWAY_ACCESS_WAIT, cmd.status()).await.ok()?.ok()?;
        match status.code() {
            Some(0) => Some(true),
            Some(1) => Some(false),
            _ => None,
        }
    }

    fn refuse_shared(&self) -> Result<(), LoginError> {
        if self.shared() {
            return Err(LoginError::new(
                reason::SHARED_MACHINE,
                "this is a team machine: every member runs as the same user, so an own sign-in here would be everyone's",
            ));
        }
        Ok(())
    }
}

/// `dir` and any parent it makes, owner-only; `dir` itself set to 0700.
fn private_dir(dir: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::{DirBuilderExt, PermissionsExt};
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        std::fs::set_permissions(dir, std::fs::Permissions::from_mode(0o700))
    }
    #[cfg(not(unix))]
    {
        std::fs::create_dir_all(dir)
    }
}

/// Writes `bytes` to `path` whole or not at all: a new owner-only (0600)
/// file beside it, synced, renamed over it.
pub fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let dir = path.parent().unwrap_or(Path::new("."));
    let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("file");
    let tmp = dir.join(format!(".{name}.{}.{}.tmp", std::process::id(), now_nanos()));
    let mut open = std::fs::OpenOptions::new();
    open.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        open.mode(0o600);
    }
    let written = (|| {
        let mut file = open.open(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp, path)
    })();
    if written.is_err() {
        let _ = std::fs::remove_file(&tmp);
    }
    written
}

fn now_nanos() -> u128 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0)
}

fn now_ms() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_millis() as u64).unwrap_or(0)
}

/// Sets `env.ANTHROPIC_API_KEY` in `<store>/settings.json`, keeping every
/// other setting. A file that is not a JSON object is left alone (an error).
pub fn merge_claude_api_key(store: &Path, key: &str) -> Result<(), String> {
    let path = store.join("settings.json");
    let mut doc = match std::fs::read(&path) {
        Ok(bytes) if bytes.iter().all(u8::is_ascii_whitespace) => Value::Object(Default::default()),
        Ok(bytes) => serde_json::from_slice::<Value>(&bytes)
            .map_err(|_| format!("{} is not valid JSON; fix it or remove it", path.display()))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Value::Object(Default::default()),
        Err(e) => return Err(format!("read {}: {e}", path.display())),
    };
    let Some(obj) = doc.as_object_mut() else {
        return Err(format!("{} is not a JSON object", path.display()));
    };
    let env = obj.entry("env").or_insert_with(|| Value::Object(Default::default()));
    let Some(env) = env.as_object_mut() else {
        return Err(format!("`env` in {} is not an object", path.display()));
    };
    env.insert("ANTHROPIC_API_KEY".into(), Value::String(key.to_owned()));
    let bytes = Zeroizing::new(
        serde_json::to_vec_pretty(&doc).map_err(|e| format!("encode settings: {e}"))?,
    );
    private_dir(store).map_err(|e| format!("make {}: {e}", store.display()))?;
    write_private(&path, &bytes).map_err(|e| format!("write {}: {e}", path.display()))
}

/// A JSON object file at `path` (missing or blank: empty), or why not.
fn read_json_object(path: &Path) -> Result<serde_json::Map<String, Value>, String> {
    let doc = match std::fs::read(path) {
        Ok(bytes) if bytes.iter().all(u8::is_ascii_whitespace) => Value::Object(Default::default()),
        Ok(bytes) => serde_json::from_slice::<Value>(&bytes)
            .map_err(|_| format!("{} is not valid JSON; fix it or remove it", path.display()))?,
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Value::Object(Default::default()),
        Err(e) => return Err(format!("read {}: {e}", path.display())),
    };
    match doc {
        Value::Object(obj) => Ok(obj),
        _ => Err(format!("{} is not a JSON object", path.display())),
    }
}

/// The `KEY` a dotenv line sets (`KEY=...` or `export KEY=...`), if any.
fn dotenv_key(line: &str) -> Option<&str> {
    let line = line.trim_start();
    let line = line.strip_prefix("export ").map(str::trim_start).unwrap_or(line);
    let (key, _) = line.split_once('=')?;
    let key = key.trim();
    (!key.is_empty() && !key.starts_with('#')).then_some(key)
}

/// The value of `key` in the dotenv text, unquoted.
fn dotenv_value<'a>(text: &'a str, key: &str) -> Option<&'a str> {
    text.lines().rev().find(|l| dotenv_key(l) == Some(key)).and_then(|l| {
        let value = l.split_once('=')?.1.trim();
        let value = value
            .strip_prefix('"')
            .and_then(|v| v.strip_suffix('"'))
            .or_else(|| value.strip_prefix('\'').and_then(|v| v.strip_suffix('\'')))
            .unwrap_or(value);
        Some(value)
    })
}

/// A Gemini API key's characters: letters, digits, `-`, `_`, `.` (no quote,
/// space or `#` a dotenv reader could take for something else).
pub fn gemini_key_shape(key: &str) -> bool {
    one_line(key, 512) && key.chars().all(|c| c.is_ascii_alphanumeric() || "-_.".contains(c))
}

/// Saves `key` where Gemini CLI reads it with no shell env: `<store>/.env`
/// gets `GEMINI_API_KEY=<key>` (its other lines kept, an earlier
/// `GEMINI_API_KEY` line replaced), and `<store>/settings.json` gets
/// `security.auth.selectedType = "gemini-api-key"` (other settings kept). Both
/// 0600, written whole. A settings file that is not a JSON object, or whose
/// `security` or `security.auth` is not one, is left alone (an error), and
/// then the `.env` is not touched either.
pub fn merge_gemini_api_key(store: &Path, key: &str) -> Result<(), String> {
    if !gemini_key_shape(key) {
        return Err("that is not a Gemini API key".into());
    }
    let settings_path = store.join("settings.json");
    let mut settings = read_json_object(&settings_path)?;
    let security = settings.entry("security").or_insert_with(|| Value::Object(Default::default()));
    let Some(security) = security.as_object_mut() else {
        return Err(format!("`security` in {} is not an object", settings_path.display()));
    };
    let auth = security.entry("auth").or_insert_with(|| Value::Object(Default::default()));
    let Some(auth) = auth.as_object_mut() else {
        return Err(format!("`security.auth` in {} is not an object", settings_path.display()));
    };
    auth.insert("selectedType".into(), Value::String("gemini-api-key".into()));
    let env_path = store.join(".env");
    let old = match std::fs::read(&env_path) {
        Ok(bytes) => Zeroizing::new(
            String::from_utf8(bytes)
                .map_err(|_| format!("{} is not text; fix it or remove it", env_path.display()))?,
        ),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Zeroizing::new(String::new()),
        Err(e) => return Err(format!("read {}: {e}", env_path.display())),
    };
    let mut env = Zeroizing::new(String::with_capacity(old.len() + key.len() + 16));
    for line in old.lines() {
        if dotenv_key(line) != Some("GEMINI_API_KEY") {
            env.push_str(line);
            env.push('\n');
        }
    }
    env.push_str("GEMINI_API_KEY=");
    env.push_str(key);
    env.push('\n');
    let settings = serde_json::to_vec_pretty(&Value::Object(settings))
        .map_err(|e| format!("encode settings: {e}"))?;
    private_dir(store).map_err(|e| format!("make {}: {e}", store.display()))?;
    write_private(&settings_path, &settings)
        .map_err(|e| format!("write {}: {e}", settings_path.display()))?;
    write_private(&env_path, env.as_bytes())
        .map_err(|e| format!("write {}: {e}", env_path.display()))
}

/// Whether `agent`'s own sign-in is in `store`, read as `agent-auth.sh`
/// reads it (`cmux_agent_has_own_login`), never the values: Claude's
/// `.credentials.json` with `claudeAiOauth`; Codex's `auth.json` with tokens
/// or an API key; Gemini's `oauth_creds.json`, or a `.env` with a non-empty
/// `GEMINI_API_KEY`; Grok's non-empty `auth.json`.
pub fn signed_in_at(agent: Agent, store: &Path) -> bool {
    let read = |name: &str| {
        std::fs::read(store.join(name)).ok().and_then(|b| serde_json::from_slice::<Value>(&b).ok())
    };
    match agent {
        Agent::Claude => read(".credentials.json")
            .and_then(|v| v.get("claudeAiOauth").map(|o| !o.is_null()))
            .unwrap_or(false),
        Agent::Codex => read("auth.json").is_some_and(|v| {
            v.get("tokens").and_then(Value::as_object).is_some_and(|t| !t.is_empty())
                || v.get("OPENAI_API_KEY").and_then(Value::as_str).is_some_and(|k| !k.is_empty())
        }),
        Agent::Gemini => {
            store.join("oauth_creds.json").is_file()
                || std::fs::read(store.join(".env")).ok().is_some_and(|b| {
                    let text = Zeroizing::new(String::from_utf8_lossy(&b).into_owned());
                    dotenv_value(&text, "GEMINI_API_KEY").is_some_and(|v| !v.is_empty())
                })
        }
        Agent::Grok => std::fs::read(store.join("auth.json"))
            .is_ok_and(|b| !Zeroizing::new(b).iter().all(u8::is_ascii_whitespace)),
        // Cursor's `auth.json`: a non-empty object with a non-empty string in it (its token
        // fields have moved between releases, so no one name is required).
        Agent::Cursor => read("auth.json").is_some_and(|v| {
            v.as_object()
                .is_some_and(|o| o.values().any(|f| f.as_str().is_some_and(|s| !s.is_empty())))
        }),
    }
}

/// A code or key fit for a CLI's stdin: one line of printable ASCII.
pub fn one_line(secret: &str, max: usize) -> bool {
    !secret.is_empty() && secret.len() <= max && secret.chars().all(|c| c.is_ascii_graphic())
}

/// A started sign-in, as `start` answers it.
#[derive(Debug, Clone)]
pub struct Started {
    pub login_id: String,
    pub url: String,
    /// Claude's automatic link and the port of its listener's
    /// `http://localhost:<port>/callback` (module docs).
    pub auto_url: Option<String>,
    pub callback_port: Option<u16>,
    pub user_code: Option<String>,
    pub needs_code: bool,
    pub expires_at_ms: u64,
}

/// How `finish` ended: signed in or not, and which agent (for the caller's
/// next steps).
#[derive(Debug, Clone)]
pub struct Finished {
    pub agent: Agent,
    pub signed_in: bool,
    /// The account whose login actually finished, retained from start rather than the caller.
    pub store: PathBuf,
    /// The first finish to see the CLI end (a paste that raced a wait for
    /// the approve sees the same end): only it takes the after-sign-in steps.
    pub fresh: bool,
}

/// A private temp folder the CLI runs in, removed with the sign-in.
struct Folder(PathBuf);

impl Folder {
    fn new(agent: Agent) -> std::io::Result<Folder> {
        let path = std::env::temp_dir().join(format!(
            "cmux-agent-login-{}-{}-{}",
            agent.name(),
            std::process::id(),
            now_nanos()
        ));
        #[cfg(unix)]
        {
            use std::os::unix::fs::DirBuilderExt;
            std::fs::DirBuilder::new().mode(0o700).create(&path)?;
        }
        #[cfg(not(unix))]
        {
            std::fs::DirBuilder::new().create(&path)?;
            crate::owner_only::restrict(&path)?;
        }
        Ok(Folder(path))
    }

    /// Writes the `BROWSER` shim (module docs) into the folder, owner-only.
    fn browser_shim(&self) -> std::io::Result<PathBuf> {
        let path = self.0.join("open-sign-in");
        let mut open = std::fs::OpenOptions::new();
        open.write(true).create_new(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            open.mode(0o700);
        }
        use std::io::Write;
        let mut file = open.open(&path)?;
        file.write_all(BROWSER_SHIM.as_bytes())?;
        file.sync_all()?;
        Ok(path)
    }

    /// The automatic link the shim saved, once it is a whole allowed one.
    fn auto_url(&self) -> Option<(String, u16)> {
        use std::io::Read;
        let path = self.0.join(AUTO_URL_FILE);
        // Only a plain file the shim made (never a link out of the folder).
        if !std::fs::symlink_metadata(&path).ok()?.is_file() {
            return None;
        }
        let mut text = String::new();
        std::fs::File::open(&path).ok()?.take(AUTO_URL_CAP).read_to_string(&mut text).ok()?;
        parse::auto_url(&text)
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The running CLI of one sign-in.
struct Running {
    child: Child,
    /// A finish saw the CLI end (`Finished::fresh`).
    settled: bool,
    _folder: Folder,
}

/// One sign-in in the table.
struct Entry {
    id: String,
    agent: Agent,
    /// The CLI's process group (its pid), kept to stop it without the lock.
    group: Option<u32>,
    expires: Instant,
    store: PathBuf,
    /// `start` answered an automatic link: a finish with no code waits for
    /// the CLI to end on its own.
    auto: bool,
    /// The CLI's stdin, apart from `running`, so a pasted code still reaches
    /// it while a finish with no code waits on the CLI.
    stdin: Arc<tokio::sync::Mutex<Option<ChildStdin>>>,
    /// A code was written to the CLI: it may be writing the sign-in now.
    code_sent: Arc<std::sync::atomic::AtomicBool>,
    /// Held by `finish` while it waits on the CLI.
    running: Arc<tokio::sync::Mutex<Running>>,
}

/// The sign-ins in progress: at most one per agent.
fn table() -> &'static StdMutex<HashMap<Agent, Entry>> {
    static TABLE: OnceLock<StdMutex<HashMap<Agent, Entry>>> = OnceLock::new();
    TABLE.get_or_init(Default::default)
}

fn lock_table() -> std::sync::MutexGuard<'static, HashMap<Agent, Entry>> {
    table().lock().unwrap_or_else(|e| e.into_inner())
}

#[cfg(unix)]
fn kill_group(group: Option<u32>) {
    if let Some(pid) = group.and_then(|p| i32::try_from(p).ok()).filter(|p| *p > 0) {
        // SAFETY: killpg only sends a signal; the group is the sign-in's own.
        unsafe {
            libc::killpg(pid, libc::SIGKILL);
        }
    }
}

#[cfg(not(unix))]
fn kill_group(_group: Option<u32>) {}

/// Takes the sign-in `id` (any agent) out of the table and stops its CLI.
fn end(id: &str) -> bool {
    let entry = {
        let mut table = lock_table();
        let agent = table.iter().find(|(_, e)| e.id == id).map(|(a, _)| *a);
        agent.and_then(|a| table.remove(&a))
    };
    match entry {
        Some(e) => {
            kill_group(e.group);
            true
        }
        None => false,
    }
}

/// Reads `pipe` into `out` (at most [`OUTPUT_CAP`] kept; the rest read and
/// dropped, so the CLI never blocks on a full pipe), waking `notify` on each
/// read and when it ends.
async fn pump<R: AsyncRead + Unpin>(
    mut pipe: R,
    out: Arc<StdMutex<Vec<u8>>>,
    notify: Arc<Notify>,
    ended: Arc<AtomicUsize>,
) {
    let mut chunk = [0u8; 4096];
    loop {
        match pipe.read(&mut chunk).await {
            Ok(0) | Err(_) => break,
            Ok(n) => {
                let mut buf = out.lock().unwrap_or_else(|e| e.into_inner());
                let room = OUTPUT_CAP.saturating_sub(buf.len());
                buf.extend_from_slice(chunk.get(..n.min(room)).unwrap_or_default());
            }
        }
        notify.notify_one();
    }
    ended.fetch_add(1, Ordering::SeqCst);
    notify.notify_one();
}

/// Starts `agent`'s own sign-in with `cli` on `machine` (module docs).
pub async fn start(machine: &Machine, cli: &Cli, agent: Agent) -> Result<Started, LoginError> {
    if !agent.signs_in_by_link() {
        return Err(LoginError::new(
            reason::UNSUPPORTED,
            format!("{} signs in on this machine with an API key", agent.name()),
        ));
    }
    machine.refuse_shared()?;
    // One sign-in per agent: the previous one stops, unless its finish is
    // running (it may be writing the sign-in now).
    let previous = {
        let table = lock_table();
        table.get(&agent).map(|e| (e.id.clone(), e.running.clone(), e.code_sent.clone()))
    };
    if let Some((id, running, code_sent)) = previous {
        // Held across the stop, so no finish takes it in between. A finish
        // that only waits for an approve (no code given) is no reason to keep
        // it: the person started again.
        match running.try_lock() {
            Ok(_held) => {
                end(&id);
            }
            Err(_) if !code_sent.load(Ordering::SeqCst) => {
                end(&id);
            }
            Err(_) => {
                return Err(LoginError::new(
                    reason::BUSY,
                    format!("a {} sign-in is finishing on this machine", agent.name()),
                ));
            }
        }
    }
    let store = cli.store(agent);
    if agent != Agent::Claude {
        // `codex login` needs its home to exist; Grok's and Cursor's are made private first.
        private_dir(&store).map_err(|e| {
            LoginError::new(reason::FAILED, format!("make {}: {e}", store.display()))
        })?;
    }
    let folder = Folder::new(agent)
        .map_err(|e| LoginError::new(reason::FAILED, format!("make a temp folder: {e}")))?;
    let args: &[&str] = match agent {
        Agent::Claude => &["auth", "login", "--claudeai"],
        Agent::Codex | Agent::Grok => &["login", "--device-auth"],
        Agent::Cursor => &["login"],
        // Refused above (`signs_in_by_link`).
        Agent::Gemini => &[],
    };
    let mut cmd = cli.command(args, &folder.0);
    if agent == Agent::Claude {
        let shim = folder.browser_shim().map_err(|e| {
            LoginError::new(reason::FAILED, format!("make the sign-in's browser: {e}"))
        })?;
        cmd.env("BROWSER", shim);
    }
    cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    #[cfg(unix)]
    cmd.process_group(0);
    let mut child = cmd.spawn().map_err(|e| match e.kind() {
        std::io::ErrorKind::NotFound => LoginError::new(
            reason::CLI_MISSING,
            format!("{} is not installed on this machine", agent.name()),
        ),
        _ => LoginError::new(reason::FAILED, format!("start {}: {e}", agent.name())),
    })?;
    let group = child.id();
    let output = Arc::new(StdMutex::new(Vec::new()));
    let notify = Arc::new(Notify::new());
    let ended = Arc::new(AtomicUsize::new(0));
    for pipe in
        [child.stdout.take().map(boxed), child.stderr.take().map(boxed)].into_iter().flatten()
    {
        tokio::spawn(pump(pipe, output.clone(), notify.clone(), ended.clone()));
    }
    let deadline = Instant::now() + URL_WAIT;
    let offer = loop {
        let text = {
            let buf = output.lock().unwrap_or_else(|e| e.into_inner());
            String::from_utf8_lossy(&buf).into_owned()
        };
        if let Some(offer) = hot::offer(agent, &text) {
            break Some(offer);
        }
        if ended.load(Ordering::SeqCst) >= 2 {
            break None;
        }
        if tokio::time::timeout_at(deadline, notify.notified()).await.is_err() {
            break None;
        }
    };
    let Some(offer) = offer else {
        kill_group(group);
        let _ = child.kill().await;
        return Err(LoginError::new(
            reason::NO_URL,
            format!("{} did not show a sign-in link", agent.name()),
        ));
    };
    // Claude asks its BROWSER to open the automatic link right after it
    // printed the other one.
    let auto = match agent {
        Agent::Claude => {
            let deadline = Instant::now() + AUTO_URL_WAIT;
            loop {
                if let Some(found) = folder.auto_url() {
                    break Some(found);
                }
                if Instant::now() >= deadline || ended.load(Ordering::SeqCst) >= 2 {
                    break None;
                }
                tokio::time::sleep(Duration::from_millis(50)).await;
            }
        }
        Agent::Codex | Agent::Gemini | Agent::Grok | Agent::Cursor => None,
    };
    let id = uuid::Uuid::now_v7().to_string();
    let expires_at_ms = now_ms() + EXPIRY.as_millis() as u64;
    let stdin = child.stdin.take();
    let entry = Entry {
        id: id.clone(),
        agent,
        group,
        expires: Instant::now() + EXPIRY,
        store,
        auto: auto.is_some(),
        stdin: Arc::new(tokio::sync::Mutex::new(stdin)),
        code_sent: Default::default(),
        running: Arc::new(tokio::sync::Mutex::new(Running {
            child,
            settled: false,
            _folder: folder,
        })),
    };
    if let Some(old) = lock_table().insert(agent, entry) {
        // A start that raced this one: the later one wins.
        kill_group(old.group);
    }
    let expiring = id.clone();
    tokio::spawn(async move {
        tokio::time::sleep(EXPIRY).await;
        end(&expiring);
    });
    let (auto_url, callback_port) = auto.map_or((None, None), |(u, p)| (Some(u), Some(p)));
    Ok(Started {
        login_id: id,
        url: offer.url,
        auto_url,
        callback_port,
        needs_code: agent == Agent::Claude,
        user_code: offer.user_code,
        expires_at_ms,
    })
}

fn boxed<R: AsyncRead + Unpin + Send + 'static>(r: R) -> Box<dyn AsyncRead + Unpin + Send> {
    Box::new(r)
}

/// Finishes sign-in `login_id` (module docs). Claude needs `code`, unless
/// its start answered an automatic link.
pub async fn finish(login_id: &str, code: Option<&str>) -> Result<Finished, LoginError> {
    let found = {
        let table = lock_table();
        table.values().find(|e| e.id == login_id).map(|e| {
            (
                e.agent,
                e.expires,
                e.store.clone(),
                e.auto,
                e.stdin.clone(),
                e.code_sent.clone(),
                e.running.clone(),
            )
        })
    };
    let Some((agent, expires, store, auto, stdin, code_sent, running)) = found else {
        return Err(LoginError::new(
            reason::UNKNOWN_LOGIN,
            "no sign-in with that id is running here: start again",
        ));
    };
    if Instant::now() >= expires {
        end(login_id);
        return Err(LoginError::new(reason::EXPIRED, "the sign-in expired: start again"));
    }
    let code = match agent {
        Agent::Claude => match code.map(str::trim) {
            Some(c) if one_line(c, 4096) => Some(Zeroizing::new(format!("{c}\n"))),
            // No code after an automatic link: wait for the approve.
            None if auto => None,
            _ => {
                return Err(LoginError::new(
                    reason::BAD_CODE,
                    "paste the code the sign-in page shows",
                ));
            }
        },
        // Device flows finish by themselves.
        Agent::Codex | Agent::Gemini | Agent::Grok | Agent::Cursor => None,
    };
    if let Some(line) = &code {
        let Ok(mut slot) = stdin.try_lock() else {
            return Err(LoginError::new(reason::BUSY, "this sign-in is already finishing"));
        };
        let Some(mut pipe) = slot.take() else {
            return Err(LoginError::new(reason::BUSY, "this sign-in is already finishing"));
        };
        code_sent.store(true, Ordering::SeqCst);
        let wrote = pipe.write_all(line.as_bytes()).await.and(pipe.flush().await);
        drop(pipe);
        drop(slot);
        if wrote.is_err() {
            end(login_id);
            return Err(LoginError::new(reason::FAILED, "the sign-in stopped: start again"));
        }
    }
    let wait = match code {
        Some(_) => Instant::now() + CLAUDE_FINISH_WAIT,
        None => expires,
    };
    // A code pasted while a finish waits for the approve: that finish holds
    // the CLI; this one waits its turn and reads the same end.
    let mut run = if code.is_some() {
        match tokio::time::timeout_at(wait, running.lock()).await {
            Ok(run) => run,
            Err(_) => {
                end(login_id);
                return Err(LoginError::new(
                    reason::FAILED,
                    "claude did not finish signing in: start again",
                ));
            }
        }
    } else {
        let Ok(run) = running.try_lock() else {
            return Err(LoginError::new(reason::BUSY, "this sign-in is already finishing"));
        };
        run
    };
    let status = tokio::time::timeout_at(wait, run.child.wait()).await;
    let fresh = !run.settled;
    if matches!(status, Ok(Ok(_))) {
        run.settled = true;
    }
    drop(run);
    end(login_id);
    let status = match status {
        Err(_) if code.is_none() => {
            return Err(LoginError::new(reason::EXPIRED, "the sign-in expired: start again"));
        }
        Err(_) => {
            return Err(LoginError::new(
                reason::FAILED,
                "claude did not finish signing in: start again",
            ));
        }
        Ok(Err(e)) => return Err(LoginError::new(reason::FAILED, format!("wait: {e}"))),
        Ok(Ok(status)) => status,
    };
    if !status.success() {
        // The expiry stopped it while this waited.
        if Instant::now() >= expires {
            return Err(LoginError::new(reason::EXPIRED, "the sign-in expired: start again"));
        }
        return Err(match (agent, code_sent.load(Ordering::SeqCst)) {
            (Agent::Claude, true) => LoginError::new(
                reason::BAD_CODE,
                "claude did not accept the code: start again and paste the new code",
            ),
            (Agent::Claude, false) => {
                LoginError::new(reason::FAILED, "claude did not finish signing in: start again")
            }
            (Agent::Cursor, _) => {
                LoginError::new(reason::FAILED, "cursor-agent did not finish signing in")
            }
            (agent, _) => LoginError::new(
                reason::FAILED,
                format!("{} did not finish signing in", agent.name()),
            ),
        });
    }
    // macOS: Claude Code keeps its sign-in in the login keychain, which acpmux
    // never reads (`claude_auth.rs`); its exit says it.
    let signed_in =
        signed_in_at(agent, &store) || (cfg!(target_os = "macos") && agent == Agent::Claude);
    Ok(Finished { agent, signed_in, store, fresh })
}

/// Stops sign-in `login_id`; nothing when none runs.
pub fn cancel(login_id: &str) -> bool {
    end(login_id)
}

/// Saves `key` as `agent`'s own sign-in (module docs).
pub async fn save_api_key(
    machine: &Machine,
    cli: &Cli,
    agent: Agent,
    key: &str,
) -> Result<(), LoginError> {
    if agent == Agent::Cursor {
        // `cursor-agent` reads a key only from its environment or `--api-key`, never a file of
        // its own: the key goes in as the Cloud secret `CURSOR_API_KEY`.
        return Err(LoginError::new(
            reason::UNSUPPORTED_AGENT,
            "Cursor takes an API key as the Cloud secret CURSOR_API_KEY",
        ));
    }
    if !agent.takes_api_key() {
        return Err(LoginError::new(
            reason::UNSUPPORTED,
            format!(
                "{} takes no saved key here: it signs in with its own sign-in, or reads its key from your vault",
                agent.name()
            ),
        ));
    }
    machine.refuse_shared()?;
    let key = key.trim();
    if !one_line(key, 512) {
        return Err(LoginError::new(reason::BAD_CODE, "that is not an API key"));
    }
    match agent {
        Agent::Gemini => {
            if !gemini_key_shape(key) {
                return Err(LoginError::new(reason::BAD_CODE, "that is not a Gemini API key"));
            }
            merge_gemini_api_key(&cli.store(agent), key)
                .map_err(|e| LoginError::new(reason::FAILED, e))
        }
        // Refused above (`takes_api_key`).
        Agent::Grok | Agent::Cursor => Err(LoginError::new(
            reason::UNSUPPORTED,
            format!("{} takes no saved key here", agent.name()),
        )),
        Agent::Claude => merge_claude_api_key(&cli.store(agent), key)
            .map_err(|e| LoginError::new(reason::FAILED, e)),
        Agent::Codex => {
            let store = cli.store(agent);
            private_dir(&store).map_err(|e| {
                LoginError::new(reason::FAILED, format!("make {}: {e}", store.display()))
            })?;
            let folder = Folder::new(agent)
                .map_err(|e| LoginError::new(reason::FAILED, format!("make a temp folder: {e}")))?;
            let cmd = cli.command(&["login", "--with-api-key"], &folder.0);
            let input = Zeroizing::new(format!("{key}\n"));
            match crate::complete::run::run(cmd, Some(input.as_bytes()), API_KEY_WAIT).await {
                Ok(out) if out.success && signed_in_at(agent, &store) => Ok(()),
                Ok(out) if out.success => Err(LoginError::new(
                    reason::FAILED,
                    "codex saved no key where this machine's codex reads it",
                )),
                Ok(_) => Err(LoginError::new(reason::BAD_CODE, "codex did not accept the key")),
                Err(crate::complete::run::RunError::Timeout) => {
                    Err(LoginError::new(reason::FAILED, "codex did not finish saving the key"))
                }
                Err(crate::complete::run::RunError::Spawn(e)) => {
                    Err(if e.contains("No such file") {
                        LoginError::new(
                            reason::CLI_MISSING,
                            "codex is not installed on this machine",
                        )
                    } else {
                        LoginError::new(reason::FAILED, format!("start codex: {e}"))
                    })
                }
            }
        }
    }
}
