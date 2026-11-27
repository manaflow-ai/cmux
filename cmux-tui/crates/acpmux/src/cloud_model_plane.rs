//! A Cloud machine's model route for every agent acpmux starts there.
//!
//! The image bakes `/etc/cmux/model-plane.env` (root-owned, the same bytes on every machine,
//! web/services/coderouter/vmGuestEnv.ts): base URLs at the coderouter edge alias
//! (`https://coderouter.cmux.internal`) and the public placeholder key. The machine's edge rule
//! (cmux-platform CoderouterEdge) adds the per-machine token, so the guest holds no provider
//! login and the Mac copies none to it.
//!
//! A login shell sources that file (agent-config.sh), but it sets Claude's pair aside for its
//! terminal launcher, and acpmux's own process (a systemd user unit) never sources it. A
//! remote-origin launch (`apply_remote_tokio`) gets no provider variables at all. So an agent
//! acpmux started had no base URL and no key: Claude said "Not logged in" and never reached the
//! edge. Every harness spawn on a Cloud machine therefore gets the file's variables for each name
//! it does not already have: the daemon's own env, the login shell, a profile, preset, session
//! or bound route still win, and a route's unset list still removes them.
//!
//! Only the file's fixed names are read, never a token: a value that looks like one (a route
//! token or a JWT) drops the file, as does a file that is not root's or is writable by others.

use std::collections::BTreeMap;
use std::net::ToSocketAddrs as _;
use std::path::Path;
use std::sync::Mutex;
use std::time::{Duration, Instant, SystemTime};

/// Where the image keeps the model route.
pub const PLANE_FILE: &str = "/etc/cmux/model-plane.env";
/// The public placeholder agents send; the edge swaps in the machine's token.
pub const PLACEHOLDER: &str = "cmux-vm-edge-placeholder";
/// The names the file may set; anything else in it is ignored.
pub const KEYS: [&str; 5] = [
    "OPENAI_BASE_URL",
    "OPENAI_API_KEY",
    "CMUX_CODEROUTER_URL",
    "ANTHROPIC_BASE_URL",
    "ANTHROPIC_API_KEY",
];

/// Why the file gave no route.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Problem {
    Missing,
    /// Not a regular file owned by root and writable only by it.
    Untrusted,
    /// A token-shaped value, a base URL that is not https, or no base URL at all.
    Invalid,
}

impl Problem {
    pub fn word(self) -> &'static str {
        match self {
            Problem::Missing => "missing",
            Problem::Untrusted => "untrusted",
            Problem::Invalid => "invalid",
        }
    }
}

/// `export NAME='value'` lines as `renderVmGuestModelPlaneEnvFile` writes them (a `'\''` inside
/// a value is a quote). Lines in any other shape, and names outside [`KEYS`], are skipped.
pub fn parse(text: &str) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for line in text.lines() {
        let line = line.trim();
        let Some(rest) = line.strip_prefix("export ") else { continue };
        let Some((name, quoted)) = rest.split_once('=') else { continue };
        if !KEYS.contains(&name) {
            continue;
        }
        let Some(value) = unquote(quoted) else { continue };
        if !value.is_empty() {
            out.insert(name.to_owned(), value);
        }
    }
    out
}

fn unquote(quoted: &str) -> Option<String> {
    let inner = quoted.strip_prefix('\'')?.strip_suffix('\'')?;
    // A quote other than the `'\''` escape is not this file's shape.
    (!inner.replace("'\\''", "").contains('\'')).then(|| inner.replace("'\\''", "'"))
}

fn token_shaped(value: &str) -> bool {
    let jwt = value.split('.').count() == 3 && value.starts_with("eyJ");
    value.contains("crt_") || jwt || value.contains("sk-ant-") || value.contains("sk-proj-")
}

/// The file's variables, checked: every base URL https, no token-shaped value, both base URLs there.
pub fn validate(vars: BTreeMap<String, String>) -> Result<BTreeMap<String, String>, Problem> {
    if vars.values().any(|v| token_shaped(v)) {
        return Err(Problem::Invalid);
    }
    let https = |k: &str| vars.get(k).is_some_and(|v| v.starts_with("https://"));
    if !https("ANTHROPIC_BASE_URL") || !https("OPENAI_BASE_URL") {
        return Err(Problem::Invalid);
    }
    if vars.get("CMUX_CODEROUTER_URL").is_some_and(|v| !v.starts_with("https://")) {
        return Err(Problem::Invalid);
    }
    Ok(vars)
}

/// The route in `path`. `require_root`: the file must be root's and writable only by root (the
/// image's), never a symlink.
pub fn read_at(path: &Path, require_root: bool) -> Result<BTreeMap<String, String>, Problem> {
    let meta = match std::fs::symlink_metadata(path) {
        Ok(meta) => meta,
        Err(_) => return Err(Problem::Missing),
    };
    if !meta.is_file() || meta.len() > 64 * 1024 {
        return Err(Problem::Untrusted);
    }
    #[cfg(unix)]
    if require_root {
        use std::os::unix::fs::MetadataExt as _;
        if meta.uid() != 0 || meta.mode() & 0o022 != 0 {
            return Err(Problem::Untrusted);
        }
    }
    #[cfg(not(unix))]
    let _ = require_root;
    let text = std::fs::read_to_string(path).map_err(|_| Problem::Untrusted)?;
    validate(parse(&text))
}

/// This machine's route: the image file's on a Cloud VM where its host resolves, nothing
/// elsewhere. Read on every call (a few hundred bytes), so a `cmux host update` that rewrites it
/// applies to the next spawn.
///
/// Every image bakes the file, but `coderouter.cmux.internal` resolves only where the backend
/// installs the machine's edge rule: development. Staging and production install none, so there
/// the route pointed every agent at a host that does not exist and took over from the person's
/// own sign-in (every Cloud journey on staging after #40159, cmux-platform#1442). A route whose
/// host does not resolve is therefore no route, the rule `claude_cloud_auth::team_pair` and
/// `codex_cloud_auth::own_reason` already apply to the team origin.
pub fn machine_plane() -> BTreeMap<String, String> {
    if !crate::cloud_host::is_cloud_vm() {
        return BTreeMap::new();
    }
    let plane = read_at(Path::new(PLANE_FILE), true).unwrap_or_default();
    where_resolves(plane, spawn_host_resolves)
}

/// `plane` whole when every host its base URLs name resolves (`resolves`, asked once per host),
/// else nothing.
pub fn where_resolves(
    plane: BTreeMap<String, String>,
    resolves: impl Fn(&str) -> bool,
) -> BTreeMap<String, String> {
    let mut hosts: Vec<&str> =
        BASE_URLS.iter().filter_map(|key| plane.get(*key)).map(|url| origin_host(url)).collect();
    hosts.sort_unstable();
    hosts.dedup();
    if hosts.is_empty() || hosts.iter().any(|host| host.is_empty() || !resolves(host)) {
        return BTreeMap::new();
    }
    plane
}

/// The names in [`KEYS`] that hold a base URL.
const BASE_URLS: [&str; 3] = ["ANTHROPIC_BASE_URL", "OPENAI_BASE_URL", "CMUX_CODEROUTER_URL"];

/// The host (with its port, if any) of an `https://` URL, as `claude_cloud_auth::team_pair`
/// reads the team origin's.
fn origin_host(url: &str) -> &str {
    url.trim_start_matches("https://").split(['/', '?', '#']).next().unwrap_or("")
}

/// How long one spawn waits for the resolver before it starts without the route.
const RESOLVE_WAIT: Duration = Duration::from_secs(5);
/// How long "it resolves" is reused, so a burst of spawns asks the resolver once.
const ANSWER_REUSE: Duration = Duration::from_secs(60);
/// How long "it does not resolve" is reused: a burst only. The edge's name can start resolving a
/// moment after the machine binds (cmux-platform CloudCore.ts checkEdgeDns resets and kicks the
/// guest's resolver then), and an agent started without the route keeps none for its whole life,
/// so a "no" held for a minute signed out every agent started in that minute (production
/// 2026-11-26 21:46 UTC, vm_c2229ccc0ebaabe2a575: both agents not edge-routed on a fresh create).
const NO_REUSE: Duration = Duration::from_secs(2);
/// How long "the resolver did not answer" is reused: a hung resolver costs one wait per burst of
/// spawns, not one per spawn.
const NO_ANSWER_REUSE: Duration = Duration::from_secs(10);

/// One remembered resolver answer for one host.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Answer {
    host: String,
    until: Instant,
    resolves: bool,
}

impl Answer {
    /// `resolved`: the resolver's answer, `None` when it gave none within [`RESOLVE_WAIT`].
    fn new(host: &str, now: Instant, resolved: Option<bool>) -> Self {
        let (resolves, reuse) = match resolved {
            Some(true) => (true, ANSWER_REUSE),
            Some(false) => (false, NO_REUSE),
            None => (false, NO_ANSWER_REUSE),
        };
        Answer { host: host.to_owned(), until: now + reuse, resolves }
    }

    /// The answer for `host` at `now`, while it is still reused.
    fn reused(&self, host: &str, now: Instant) -> Option<bool> {
        (self.host == host && now < self.until).then_some(self.resolves)
    }
}

/// Whether `host` resolves here, from a short cache ([`Answer`]). The lookup asks for the same
/// target as `codex_cloud_auth::host_resolves`; this one is blocking (spawns fill their env
/// synchronously), so it runs on its own thread and gives up after [`RESOLVE_WAIT`] (unreachable).
pub(crate) fn plane_host_resolves(host: &str) -> bool {
    static CACHE: Mutex<Option<Answer>> = Mutex::new(None);
    let cache = || CACHE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if let Some(ok) = cache().as_ref().and_then(|answer| answer.reused(host, Instant::now())) {
        return ok;
    }
    let target = crate::codex_cloud_auth::lookup_target(host.to_owned());
    let (tx, rx) = std::sync::mpsc::channel();
    let lookup = std::thread::Builder::new().name("model-plane-resolve".into()).spawn(move || {
        let ok = target.to_socket_addrs().is_ok_and(|mut addrs| addrs.next().is_some());
        let _ = tx.send(ok);
    });
    if lookup.is_err() {
        return false;
    }
    let answer = Answer::new(host, Instant::now(), rx.recv_timeout(RESOLVE_WAIT).ok());
    let ok = answer.resolves;
    *cache() = Some(answer);
    ok
}

/// How long a spawn waits for the edge's name to start resolving before it starts without the
/// route. The platform checks the name after every bind and claim and resets and kicks the guest's
/// resolver when it does not answer (cmux-platform NeverBoundProbe.ts edgeDnsCheckCommand: its
/// lookups, flush and restart fit in about 25 s), and an agent started before that keeps no route
/// for its whole life: production 2026-11-26 23:49 UTC, cloud-chat-pro-no-relogin and
/// cloud-chat-replies-production failed "Claude has no model route" while later starts on the
/// same kind of machine were routed.
const EDGE_WAIT: Duration = Duration::from_secs(25);
/// How often a waiting spawn asks again (the "no" cache, [`NO_REUSE`], spaces the real lookups).
const EDGE_POLL: Duration = Duration::from_secs(1);
/// A run of "does not resolve" answers with no gap this long is one streak, and only its first
/// [`EDGE_WAIT`] is waited: a machine whose name never resolves (no edge rule) pays the wait once,
/// not on every spawn. Wall-clock time, so a spare paused and claimed later waits again.
const STREAK_SPAN: Duration = Duration::from_secs(600);

/// The current run of "does not resolve" answers for the plane's host.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Streak {
    /// Spawns wait for the name until this.
    wait_until: SystemTime,
    /// The last "does not resolve" answer.
    last_no: SystemTime,
}

impl Streak {
    /// Until when a spawn that just read "does not resolve" at `now` waits: the current streak's
    /// end, or a fresh [`EDGE_WAIT`] when there is none or its last "no" is [`STREAK_SPAN`] old.
    fn wait_until(streak: &mut Option<Streak>, now: SystemTime) -> SystemTime {
        match streak {
            Some(s) if now.duration_since(s.last_no).map_or(true, |gap| gap < STREAK_SPAN) => {
                s.last_no = now;
                s.wait_until
            }
            _ => {
                let fresh = Streak { wait_until: now + EDGE_WAIT, last_no: now };
                *streak = Some(fresh);
                fresh.wait_until
            }
        }
    }
}

/// Asks `ask` every [`EDGE_POLL`] until it says the name resolves or `now` reaches `until`.
fn wait_for_name(
    mut ask: impl FnMut() -> bool,
    mut now: impl FnMut() -> SystemTime,
    mut sleep: impl FnMut(Duration),
    until: SystemTime,
) -> bool {
    loop {
        let Ok(left) = until.duration_since(now()) else { return false };
        if left.is_zero() {
            return false;
        }
        sleep(left.min(EDGE_POLL));
        if ask() {
            return true;
        }
    }
}

/// [`plane_host_resolves`] for a spawn: a name that does not resolve yet is waited for, once per
/// [`Streak`], so an agent started while the platform kicks the guest's resolver still gets the
/// route.
fn spawn_host_resolves(host: &str) -> bool {
    static STREAK: Mutex<Option<Streak>> = Mutex::new(None);
    let streak = || STREAK.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    if plane_host_resolves(host) {
        *streak() = None;
        return true;
    }
    // Read before the wait, so the lock is not held while it sleeps.
    let until = Streak::wait_until(&mut streak(), SystemTime::now());
    let routed =
        wait_for_name(|| plane_host_resolves(host), SystemTime::now, std::thread::sleep, until);
    let mut streak = streak();
    if routed {
        *streak = None;
    } else if let Some(s) = streak.as_mut() {
        s.last_no = SystemTime::now();
    }
    routed
}

/// The `plane` variables for each name `present` says the child does not have yet.
pub fn missing(
    plane: &BTreeMap<String, String>,
    present: impl Fn(&str) -> bool,
) -> Vec<(String, String)> {
    plane.iter().filter(|(k, _)| !present(k)).map(|(k, v)| (k.clone(), v.clone())).collect()
}

/// Whether `cmd`'s child gets `key`: set on it, or inherited from this process (`inherits`)
/// and not removed.
fn has(cmd: &std::process::Command, inherits: bool, key: &str) -> bool {
    match cmd.get_envs().find(|(k, _)| *k == std::ffi::OsStr::new(key)) {
        Some((_, value)) => value.is_some_and(|v| !v.is_empty()),
        None => inherits && std::env::var_os(key).is_some_and(|v| !v.is_empty()),
    }
}

/// Adds the machine's route to a harness command. `inherits`: the command was not `env_clear`ed.
pub fn fill_std(cmd: &mut std::process::Command, inherits: bool) {
    let plane = machine_plane();
    if plane.is_empty() {
        return;
    }
    let add = missing(&plane, |key| has(cmd, inherits, key));
    cmd.envs(add);
}

/// Same, for tokio's process builder.
pub fn fill_tokio(cmd: &mut tokio::process::Command, inherits: bool) {
    let plane = machine_plane();
    if plane.is_empty() {
        return;
    }
    let add = missing(&plane, |key| has(cmd.as_std(), inherits, key));
    cmd.envs(add);
}

/// Adds the machine's route to an environment computed without spawning (sign-in checks).
pub fn fill_map(env: &mut BTreeMap<String, String>) {
    for (key, value) in missing(&machine_plane(), |key| env.get(key).is_some_and(|v| !v.is_empty()))
    {
        env.insert(key, value);
    }
}

#[cfg(test)]
#[path = "cloud_model_plane_tests.rs"]
mod tests;
