//! The IP literals each host a dial used last resolved to, so a dial needs no DNS.
//!
//! A phone dial names hosts in four places: the TURN servers and STUN servers `/v1/ice` lists,
//! the signaling WebSocket and the HTTP API. When the resolver that answers for them is down
//! (a Cloudflare DNS outage: once the OS cache's 60 s run out, every off-Cloudflare TURN and
//! STUN name stops resolving), a dial that resolves them fails. Every lookup here goes through
//! [`RouteLiterals::resolve`]: with nothing remembered it asks DNS and remembers the answer;
//! with literals remembered it asks DNS too and gives DNS [`DNS_GRACE`] (happy eyeballs, RFC
//! 8305's resolution delay) before dialing the remembered literals, so a server that moved is
//! dialed at its new address whenever DNS works, and a dial with DNS down costs at most the
//! grace. The DNS answer still refreshes the memory when it lands later.
//!
//! Only the connect address changes: TLS still names and verifies the host (SNI and the
//! certificate name), so a remembered literal can never stand in for another server.
//!
//! Constant cost: at most [`MAX_ADDRS`] addresses per host, [`MAX_HOSTS`] hosts, one DNS
//! refresh in flight per host, entries older than [`TTL`] forgotten. Persisted (when the app
//! names a file, [`RouteLiterals::set_file`]) as versioned JSON ([`FORMAT_VERSION`]); a file
//! of another version or shape loads as what it can, never fails a dial.

use std::collections::{HashMap, HashSet};
use std::future::Future;
use std::io;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::pin::Pin;
use std::sync::{Arc, Mutex, OnceLock, PoisonError};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};

/// One host's lookup.
pub type Lookup = Pin<Box<dyn Future<Output = io::Result<Vec<IpAddr>>> + Send>>;

/// A name resolver (the system's, or a test's).
pub trait Resolver: Send + Sync {
    /// The addresses of `host` (a name, never a literal).
    fn lookup(&self, host: &str) -> Lookup;
}

/// The system resolver (`getaddrinfo` on tokio's blocking pool).
#[derive(Debug, Default, Clone, Copy)]
pub struct SystemResolver;

impl Resolver for SystemResolver {
    fn lookup(&self, host: &str) -> Lookup {
        let host = host.to_owned();
        Box::pin(async move {
            let found = tokio::net::lookup_host((host.as_str(), 0)).await?;
            Ok(found.map(|address| address.ip()).collect())
        })
    }
}

/// Addresses remembered per host.
pub const MAX_ADDRS: usize = 4;
/// Hosts remembered (a dial uses a handful); the oldest goes first.
pub const MAX_HOSTS: usize = 32;
/// How long a remembered literal is trusted with DNS down.
pub const TTL: Duration = Duration::from_secs(7 * 24 * 60 * 60);
/// How long a lookup with literals remembered waits for DNS before dialing them.
pub const DNS_GRACE: Duration = Duration::from_millis(100);
/// How long a refresh waits for DNS before it gives up (a resolver that never answers).
pub const DNS_BOUND: Duration = Duration::from_secs(10);
/// The persisted format's version.
pub const FORMAT_VERSION: u32 = 1;
/// An unchanged entry is written again only once it is this old (constant writes per dial).
const REWRITE_AFTER: Duration = Duration::from_secs(24 * 60 * 60);

/// One host's remembered addresses: the one a dial last reached first.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
struct Entry {
    #[serde(default)]
    addrs: Vec<IpAddr>,
    /// When DNS answered or a dial reached one, in Unix seconds.
    #[serde(default)]
    at: u64,
}

/// The persisted form.
#[derive(Debug, Default, Serialize, Deserialize)]
struct Stored {
    #[serde(default)]
    version: u32,
    #[serde(default)]
    hosts: HashMap<String, Entry>,
}

#[derive(Default)]
struct State {
    hosts: HashMap<String, Entry>,
    refreshing: HashSet<String>,
    file: Option<PathBuf>,
}

/// The process's remembered literals ([`RouteLiterals::shared`]), or a test's.
pub struct RouteLiterals {
    resolver: Arc<dyn Resolver>,
    grace: Duration,
    state: Mutex<State>,
}

impl std::fmt::Debug for RouteLiterals {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        let hosts = self.lock().hosts.len();
        f.debug_struct("RouteLiterals").field("hosts", &hosts).field("grace", &self.grace).finish()
    }
}

fn now_secs() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map_or(0, |since| since.as_secs())
}

/// `host` as the memory keys it: lower case, no trailing dot, no IPv6 brackets.
fn key(host: &str) -> String {
    host.trim_start_matches('[').trim_end_matches(']').trim_end_matches('.').to_ascii_lowercase()
}

/// `host:port` or `[v6]:port` → `(host, port)`; no port gives `default_port`.
pub fn split_host_port(text: &str, default_port: u16) -> Option<(String, u16)> {
    if let Some(rest) = text.strip_prefix('[') {
        let (host, after) = rest.split_once(']')?;
        let port = match after.strip_prefix(':') {
            Some(port) => port.parse().ok()?,
            None if after.is_empty() => default_port,
            None => return None,
        };
        return Some((host.to_owned(), port));
    }
    match text.rsplit_once(':') {
        Some((host, _)) if host.contains(':') => Some((text.to_owned(), default_port)),
        Some((host, port)) => Some((host.to_owned(), port.parse().ok()?)),
        None => Some((text.to_owned(), default_port)),
    }
}

impl RouteLiterals {
    /// A memory that asks `resolver`, with nothing remembered and no file.
    #[must_use]
    pub fn new(resolver: Arc<dyn Resolver>) -> Self {
        Self { resolver, grace: DNS_GRACE, state: Mutex::new(State::default()) }
    }

    /// The process's memory, on the system resolver.
    #[must_use]
    pub fn shared() -> Arc<Self> {
        static SHARED: OnceLock<Arc<RouteLiterals>> = OnceLock::new();
        Arc::clone(SHARED.get_or_init(|| Arc::new(Self::new(Arc::new(SystemResolver)))))
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// The remembered addresses of `host` within [`TTL`].
    #[must_use]
    pub fn remembered(&self, host: &str) -> Option<Vec<IpAddr>> {
        let state = self.lock();
        let entry = state.hosts.get(&key(host))?;
        let fresh = now_secs().saturating_sub(entry.at) < TTL.as_secs();
        (fresh && !entry.addrs.is_empty()).then(|| entry.addrs.clone())
    }

    /// Every address `text` (`host:port`, `[v6]:port`, or no port: `default_port`) names: a
    /// literal at once, a name by DNS, or by its remembered literals when DNS does not answer
    /// within the grace.
    pub async fn resolve(self: &Arc<Self>, text: &str, default_port: u16) -> io::Result<Vec<SocketAddr>> {
        let (host, port) = split_host_port(text, default_port)
            .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, format!("bad address {text}")))?;
        Ok(self.resolve_host(&host).await?.into_iter().map(|ip| SocketAddr::new(ip, port)).collect())
    }

    /// [`Self::resolve`] for a bare host.
    pub async fn resolve_host(self: &Arc<Self>, host: &str) -> io::Result<Vec<IpAddr>> {
        let host = key(host);
        if let Ok(ip) = host.parse::<IpAddr>() {
            return Ok(vec![ip]);
        }
        let Some(remembered) = self.remembered(&host) else {
            let found = self.resolver.lookup(&host).await?;
            if found.is_empty() {
                return Err(io::Error::new(io::ErrorKind::NotFound, format!("{host}: no address")));
            }
            self.store(&host, &found);
            return Ok(found);
        };
        if !self.lock().refreshing.insert(host.clone()) {
            // A refresh is under way (a dial's other leg, or DNS hanging): it updates the memory.
            return Ok(remembered);
        }
        let (tx, rx) = tokio::sync::oneshot::channel();
        let (me, lookup) = (Arc::clone(self), self.resolver.lookup(&host));
        let refreshing = host.clone();
        tokio::spawn(async move {
            let found = match tokio::time::timeout(DNS_BOUND, lookup).await {
                Ok(Ok(found)) if !found.is_empty() => {
                    me.store(&refreshing, &found);
                    Some(found)
                }
                _ => None,
            };
            me.lock().refreshing.remove(&refreshing);
            let _ = tx.send(found);
        });
        match tokio::time::timeout(self.grace, rx).await {
            Ok(Ok(Some(found))) => Ok(found),
            Ok(_) => {
                tracing::info!(%host, "DNS failed; dialing the remembered literals");
                Ok(remembered)
            }
            Err(_) => {
                tracing::info!(%host, grace_ms = self.grace.as_millis(), "DNS slow; dialing the remembered literals");
                Ok(remembered)
            }
        }
    }

    /// Remember `found` as `host`'s addresses (a DNS answer), the address a dial last reached
    /// kept first when DNS still names it.
    pub fn store(&self, host: &str, found: &[IpAddr]) {
        let host = key(host);
        let mut addrs: Vec<IpAddr> = Vec::with_capacity(MAX_ADDRS);
        let mut state = self.lock();
        let previous = state.hosts.get(&host).cloned();
        if let Some(first) = previous.as_ref().and_then(|entry| entry.addrs.first())
            && found.contains(first)
        {
            addrs.push(*first);
        }
        for ip in found {
            if addrs.len() < MAX_ADDRS && !addrs.contains(ip) {
                addrs.push(*ip);
            }
        }
        self.put(&mut state, host, addrs, previous);
    }

    /// A dial reached `host` at `ip`: it goes first.
    pub fn confirm(&self, host: &str, ip: IpAddr) {
        let host = key(host);
        if host.parse::<IpAddr>().is_ok() {
            return;
        }
        let mut state = self.lock();
        let previous = state.hosts.get(&host).cloned();
        let mut addrs = vec![ip];
        for other in previous.iter().flat_map(|entry| &entry.addrs) {
            if addrs.len() < MAX_ADDRS && !addrs.contains(other) {
                addrs.push(*other);
            }
        }
        self.put(&mut state, host, addrs, previous);
    }

    fn put(&self, state: &mut State, host: String, addrs: Vec<IpAddr>, previous: Option<Entry>) {
        let at = now_secs();
        let unchanged = previous.as_ref().is_some_and(|entry| {
            entry.addrs == addrs && at.saturating_sub(entry.at) < REWRITE_AFTER.as_secs()
        });
        if unchanged {
            return;
        }
        state.hosts.insert(host, Entry { addrs, at });
        while state.hosts.len() > MAX_HOSTS {
            let oldest = state.hosts.iter().min_by_key(|(_, entry)| entry.at).map(|(host, _)| host.clone());
            let Some(oldest) = oldest else { break };
            state.hosts.remove(&oldest);
        }
        if let Some(path) = state.file.clone() {
            let text = encode(&state.hosts);
            if let Err(error) = write_atomically(&path, &text) {
                tracing::debug!(%error, path = %path.display(), "route literals not saved");
            }
        }
    }

    /// Keep the memory in `path`: what it holds now is loaded (entries this process has not
    /// learned yet), and every change from here on is written there. Returns the entries loaded.
    pub fn set_file(&self, path: impl Into<PathBuf>) -> usize {
        let path = path.into();
        let loaded = std::fs::read_to_string(&path).map(|text| decode(&text)).unwrap_or_default();
        let mut state = self.lock();
        let count = loaded.len();
        for (host, entry) in loaded {
            state.hosts.entry(host).or_insert(entry);
        }
        state.file = Some(path);
        count
    }

    /// Forget everything (sign out); the file too, when there is one.
    pub fn clear(&self) {
        let mut state = self.lock();
        state.hosts.clear();
        if let Some(path) = state.file.clone() {
            let _ = write_atomically(&path, &encode(&state.hosts));
        }
    }

    /// The memory as its file holds it.
    #[must_use]
    pub fn encoded(&self) -> String {
        encode(&self.lock().hosts)
    }
}

fn encode(hosts: &HashMap<String, Entry>) -> String {
    let stored = Stored { version: FORMAT_VERSION, hosts: hosts.clone() };
    serde_json::to_string(&stored).unwrap_or_default()
}

/// The fresh, well-formed entries of a file of any version: a file with no `hosts` (an older
/// or empty one), or one that does not parse, gives none; entries past [`TTL`], with no
/// address, or beyond the bounds are dropped.
fn decode(text: &str) -> HashMap<String, Entry> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(text) else { return HashMap::new() };
    let Some(hosts) = value.get("hosts").and_then(serde_json::Value::as_object) else {
        return HashMap::new();
    };
    let now = now_secs();
    let mut out: Vec<(String, Entry)> = hosts
        .iter()
        .filter_map(|(host, entry)| {
            let mut entry: Entry = serde_json::from_value(entry.clone()).ok()?;
            entry.addrs.truncate(MAX_ADDRS);
            let fresh = now.saturating_sub(entry.at) < TTL.as_secs();
            (fresh && !entry.addrs.is_empty()).then(|| (key(host), entry))
        })
        .collect();
    out.sort_by_key(|(_, entry)| std::cmp::Reverse(entry.at));
    out.truncate(MAX_HOSTS);
    out.into_iter().collect()
}

fn write_atomically(path: &Path, text: &str) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)?;
    }
    let partial = path.with_extension("partial");
    std::fs::write(&partial, text)?;
    std::fs::rename(&partial, path)
}

#[cfg(test)]
#[path = "route_literals_tests.rs"]
mod tests;
