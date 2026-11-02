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
//! - `finish {loginId, code?}`: Claude gets the code the callback page shows
//!   on stdin and has [`CLAUDE_FINISH_WAIT`] to exit; Codex finishes its
//!   device flow by itself, waited for until the sign-in expires. Signed in
//!   means exit 0 and the sign-in now in the agent's own store (Claude's
//!   `.credentials.json` `claudeAiOauth`; Codex's `auth.json` tokens or key),
//!   read as `/etc/cmux/agent-auth.sh` reads them, never their values.
//! - `api_key {agent, key}`: Claude's `settings.json` gets `env.ANTHROPIC_API_KEY`
//!   (other keys kept, 0600, written whole); Codex runs `codex login
//!   --with-api-key` with the key on stdin.
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

pub mod parse;
#[cfg(test)]
mod tests;

/// Listed in `initialize`'s `_meta.acpmux.features`: this daemon answers
/// `_acpmux/agent_login/*`.
pub const FEATURE: &str = "agent_login";
/// How long `start` reads the CLI's output for its link.
pub const URL_WAIT: Duration = Duration::from_secs(20);
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
];

/// `error.data.reason` values.
pub mod reason {
    pub const UNSUPPORTED_AGENT: &str = "unsupported_agent";
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
}

/// An agent whose own sign-in this runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Agent {
    Claude,
    Codex,
}

impl Agent {
    pub fn parse(name: &str) -> Option<Agent> {
        match name {
            "claude" => Some(Agent::Claude),
            "codex" => Some(Agent::Codex),
            _ => None,
        }
    }

    pub fn name(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
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
        self.env.get(key).cloned().or_else(|| std::env::var(key).ok()).filter(|v| !v.is_empty())
    }

    fn home(&self) -> PathBuf {
        self.var("HOME").map(PathBuf::from).or_else(dirs::home_dir).unwrap_or_default()
    }

    /// Where `agent` keeps its sign-in: `CLAUDE_CONFIG_DIR` or `~/.claude`;
    /// `CODEX_HOME` or `~/.codex`.
    pub fn store(&self, agent: Agent) -> PathBuf {
        match agent {
            Agent::Claude => self
                .var("CLAUDE_CONFIG_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| self.home().join(".claude")),
            Agent::Codex => self
                .var("CODEX_HOME")
                .map(PathBuf::from)
                .unwrap_or_else(|| self.home().join(".codex")),
        }
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
        for key in MODEL_PLANE_ENV {
            cmd.env_remove(key);
        }
        cmd.env_remove("DISPLAY")
            .env_remove("WAYLAND_DISPLAY")
            .env("BROWSER", "true")
            .env("TERM", "dumb")
            .env("NO_COLOR", "1")
            .env("CMUX_CLAUDE_AUTH", "own")
            .env("CMUX_CODEX_AUTH", "own");
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

/// Whether `agent`'s own sign-in is in `store`, read as `agent-auth.sh`
/// reads it (`cmux_agent_has_own_login`), never the values: Claude's
/// `.credentials.json` with `claudeAiOauth`; Codex's `auth.json` with tokens
/// or an API key.
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
}

impl Drop for Folder {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// The running CLI of one sign-in.
struct Running {
    child: Child,
    stdin: Option<ChildStdin>,
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
    machine.refuse_shared()?;
    // One sign-in per agent: the previous one stops, unless its finish is
    // running (it may be writing the sign-in now).
    let previous = {
        let table = lock_table();
        table.get(&agent).map(|e| (e.id.clone(), e.running.clone()))
    };
    if let Some((id, running)) = previous {
        // Held across the stop, so no finish takes it in between.
        let Ok(_held) = running.try_lock() else {
            return Err(LoginError::new(
                reason::BUSY,
                format!("a {} sign-in is finishing on this machine", agent.name()),
            ));
        };
        end(&id);
    }
    let store = cli.store(agent);
    if agent == Agent::Codex {
        // `codex login` needs its home to exist.
        private_dir(&store).map_err(|e| {
            LoginError::new(reason::FAILED, format!("make {}: {e}", store.display()))
        })?;
    }
    let folder = Folder::new(agent)
        .map_err(|e| LoginError::new(reason::FAILED, format!("make a temp folder: {e}")))?;
    let args: &[&str] = match agent {
        Agent::Claude => &["auth", "login", "--claudeai"],
        Agent::Codex => &["login", "--device-auth"],
    };
    let mut cmd = cli.command(args, &folder.0);
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
        if let Some(offer) = parse::offer(agent, &text) {
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
    let id = uuid::Uuid::now_v7().to_string();
    let expires_at_ms = now_ms() + EXPIRY.as_millis() as u64;
    let stdin = child.stdin.take();
    let entry = Entry {
        id: id.clone(),
        agent,
        group,
        expires: Instant::now() + EXPIRY,
        store,
        running: Arc::new(tokio::sync::Mutex::new(Running { child, stdin, _folder: folder })),
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
    Ok(Started {
        login_id: id,
        url: offer.url,
        needs_code: agent == Agent::Claude,
        user_code: offer.user_code,
        expires_at_ms,
    })
}

fn boxed<R: AsyncRead + Unpin + Send + 'static>(r: R) -> Box<dyn AsyncRead + Unpin + Send> {
    Box::new(r)
}

/// Finishes sign-in `login_id` (module docs). Claude needs `code`.
pub async fn finish(login_id: &str, code: Option<&str>) -> Result<Finished, LoginError> {
    let found = {
        let table = lock_table();
        table
            .values()
            .find(|e| e.id == login_id)
            .map(|e| (e.agent, e.expires, e.store.clone(), e.running.clone()))
    };
    let Some((agent, expires, store, running)) = found else {
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
        Agent::Claude => {
            let code = code.map(str::trim).filter(|c| one_line(c, 4096)).ok_or_else(|| {
                LoginError::new(reason::BAD_CODE, "paste the code the sign-in page shows")
            })?;
            Some(Zeroizing::new(format!("{code}\n")))
        }
        Agent::Codex => None,
    };
    let Ok(mut run) = running.try_lock() else {
        return Err(LoginError::new(reason::BUSY, "this sign-in is already finishing"));
    };
    if let Some(line) = &code {
        let Some(mut stdin) = run.stdin.take() else {
            end(login_id);
            return Err(LoginError::new(
                reason::FAILED,
                "the sign-in already took a code: start again",
            ));
        };
        let wrote = stdin.write_all(line.as_bytes()).await.and(stdin.flush().await);
        drop(stdin);
        if wrote.is_err() {
            end(login_id);
            return Err(LoginError::new(reason::FAILED, "the sign-in stopped: start again"));
        }
    }
    let wait = match agent {
        Agent::Claude => Instant::now() + CLAUDE_FINISH_WAIT,
        Agent::Codex => expires,
    };
    let status = tokio::time::timeout_at(wait, run.child.wait()).await;
    drop(run);
    end(login_id);
    let status = match status {
        Err(_) if agent == Agent::Codex => {
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
        return Err(match agent {
            Agent::Claude => LoginError::new(
                reason::BAD_CODE,
                "claude did not accept the code: start again and paste the new code",
            ),
            Agent::Codex => LoginError::new(reason::FAILED, "codex did not finish signing in"),
        });
    }
    // macOS: Claude Code keeps its sign-in in the login keychain, which acpmux
    // never reads (`claude_auth.rs`); its exit says it.
    let signed_in =
        signed_in_at(agent, &store) || (cfg!(target_os = "macos") && agent == Agent::Claude);
    Ok(Finished { agent, signed_in, store })
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
    machine.refuse_shared()?;
    let key = key.trim();
    if !one_line(key, 512) {
        return Err(LoginError::new(reason::BAD_CODE, "that is not an API key"));
    }
    match agent {
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
