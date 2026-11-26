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
use std::time::{Duration, Instant};

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
    where_resolves(plane, plane_host_resolves)
}

/// `plane` whole when every host its base URLs name resolves (`resolves`, asked once per host),
/// else nothing.
pub fn where_resolves(
    plane: BTreeMap<String, String>,
    resolves: impl Fn(&str) -> bool,
) -> BTreeMap<String, String> {
    let hosts = plane_hosts(&plane);
    if hosts.is_empty() || hosts.iter().any(|host| !resolves(host)) {
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
/// How long "it does not resolve" and "the resolver did not answer" are reused: a hung resolver
/// costs one wait per burst of spawns, not one per spawn. Short, as a "no" on a machine whose edge
/// rule is still arriving is wrong a moment later: held for [`ANSWER_REUSE`], it dropped the route
/// from every spawn of the next minute, the restart that was to pick it up too (production
/// cloud-chat-replies, 2026-11-26: "This Cloud machine's Claude has no model route").
const NO_ANSWER_REUSE: Duration = Duration::from_secs(10);

/// How long an answer about `host` is reused: `Some(ok)` the resolver answered, None it did not.
pub(crate) fn reuse_for(answer: Option<bool>) -> Duration {
    match answer {
        Some(true) => ANSWER_REUSE,
        _ => NO_ANSWER_REUSE,
    }
}

static CACHE: Mutex<Option<(String, Instant, bool)>> = Mutex::new(None);

fn cache() -> std::sync::MutexGuard<'static, Option<(String, Instant, bool)>> {
    CACHE.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
}

/// One lookup of `host`, never from the cache, waiting at most [`RESOLVE_WAIT`]; its answer is
/// kept for the next spawns ([`reuse_for`]). The lookup asks for the same target as
/// `codex_cloud_auth::host_resolves`; this one is blocking (spawns fill their env synchronously),
/// so it runs on its own thread.
fn lookup_now(host: &str) -> bool {
    let target = crate::codex_cloud_auth::lookup_target(host.to_owned());
    let (tx, rx) = std::sync::mpsc::channel();
    let lookup = std::thread::Builder::new().name("model-plane-resolve".into()).spawn(move || {
        let ok = target.to_socket_addrs().is_ok_and(|mut addrs| addrs.next().is_some());
        let _ = tx.send(ok);
    });
    if lookup.is_err() {
        return false;
    }
    let answer = rx.recv_timeout(RESOLVE_WAIT).ok();
    let ok = answer.unwrap_or(false);
    *cache() = Some((host.to_owned(), Instant::now() + reuse_for(answer), ok));
    ok
}

/// Whether `host` resolves here, from a short cache ([`reuse_for`]), else [`lookup_now`].
pub(crate) fn plane_host_resolves(host: &str) -> bool {
    if let Some((cached, until, ok)) = cache().as_ref()
        && cached == host
        && Instant::now() < *until
    {
        return *ok;
    }
    lookup_now(host)
}

/// How long a turn that failed with no model route waits for the machine's route to resolve
/// ([`route_arrives`]) on a machine up less than [`YOUNG_MACHINE`]: the provider's edge rule for a
/// machine made a moment ago. On an older machine the route is asked once: one that has not come
/// by then is not coming, and its Sign in shows at once.
pub const ROUTE_WAIT: Duration = Duration::from_secs(20);
/// A machine up less than this may still be getting its edge rule.
pub const YOUNG_MACHINE: Duration = Duration::from_secs(10 * 60);
/// The pause between two lookups of [`route_arrives`].
const ROUTE_STEP: Duration = Duration::from_secs(2);

/// The hosts the image's route names (`/etc/cmux/model-plane.env`, trusted only as root's), or
/// none: this machine was given no route to wait for.
pub fn image_plane_hosts() -> Vec<String> {
    if !crate::cloud_host::is_cloud_vm() {
        return Vec::new();
    }
    plane_hosts(&read_at(Path::new(PLANE_FILE), true).unwrap_or_default())
}

/// The base URL hosts of `plane`, each once; empty when one names no host.
pub fn plane_hosts(plane: &BTreeMap<String, String>) -> Vec<String> {
    let mut hosts: Vec<String> = BASE_URLS
        .iter()
        .filter_map(|key| plane.get(*key))
        .map(|url| origin_host(url).to_owned())
        .collect();
    hosts.sort_unstable();
    hosts.dedup();
    if hosts.iter().any(String::is_empty) {
        return Vec::new();
    }
    hosts
}

/// How long this machine has been up (`/proc/uptime`), or None where that does not read.
pub fn machine_uptime() -> Option<Duration> {
    let text = std::fs::read_to_string("/proc/uptime").ok()?;
    let secs: f64 = text.split_whitespace().next()?.parse().ok()?;
    secs.is_finite().then(|| Duration::from_secs_f64(secs.max(0.0)))
}

/// How long [`route_arrives`] may wait on a machine up `uptime`: [`ROUTE_WAIT`] while young, else
/// none (one round of lookups).
pub fn route_wait_for(uptime: Option<Duration>) -> Duration {
    match uptime {
        Some(up) if up < YOUNG_MACHINE => ROUTE_WAIT,
        _ => Duration::ZERO,
    }
}

/// Whether every one of `hosts` resolves within `wait`: `resolves` asked for each until all do,
/// `sleep` between rounds, `clock` the time since the first. No hosts: false (no route to wait for).
pub fn arrives_within(
    hosts: &[String],
    wait: Duration,
    mut resolves: impl FnMut(&str) -> bool,
    mut sleep: impl FnMut(Duration),
    clock: impl Fn() -> Duration,
) -> bool {
    if hosts.is_empty() {
        return false;
    }
    loop {
        if hosts.iter().all(|host| resolves(host)) {
            return true;
        }
        let spent = clock();
        if spent >= wait {
            return false;
        }
        sleep(ROUTE_STEP.min(wait - spent));
    }
}

/// Whether the image's model route resolves now, waiting for it as [`route_wait_for`] says:
/// fresh lookups ([`lookup_now`]), so a "no" the cache held since the spawn does not answer, and
/// a "yes" is kept, so the agent's restart gets the route. Blocking: call off the runtime.
pub fn route_arrives() -> bool {
    let hosts = image_plane_hosts();
    let began = Instant::now();
    arrives_within(&hosts, route_wait_for(machine_uptime()), lookup_now, std::thread::sleep, || {
        began.elapsed()
    })
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
