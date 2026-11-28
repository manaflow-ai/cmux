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

use std::collections::HashMap;
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
/// A caller joins a host's running lookup only while it is this young: the legs of one dial
/// ask together, while a lookup older than this is likely stuck on a DNS that has since come
/// back, so the next caller asks again (at most `DNS_BOUND / JOIN_WINDOW` per host at once).
pub const JOIN_WINDOW: Duration = Duration::from_secs(1);
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

/// One shared DNS lookup: `None` while it runs, then its answer (`None` when DNS failed).
type SharedLookup = tokio::sync::watch::Receiver<Option<Option<Vec<IpAddr>>>>;

/// Takes a host's lookup off [`State::refreshing`] however its task ends (a runtime that
/// shuts down mid-lookup too), so the next caller asks DNS again.
struct Unregister {
    routes: Arc<RouteLiterals>,
    host: String,
    id: u64,
}

impl Drop for Unregister {
    fn drop(&mut self) {
        let mut state = self.routes.lock();
        // A newer lookup for the host may have taken the slot; leave it.
        if state.refreshing.get(&self.host).is_some_and(|running| running.id == self.id) {
            state.refreshing.remove(&self.host);
        }
    }
}

/// A host's lookup under way.
struct Running {
    id: u64,
    started: tokio::time::Instant,
    lookup: SharedLookup,
}

/// The answer `lookup` gives within `limit`: `None` when DNS failed, ended or is slower.
async fn answer_within(mut lookup: SharedLookup, limit: Duration) -> Option<Vec<IpAddr>> {
    let wait = async move {
        loop {
            if let Some(found) = lookup.borrow_and_update().clone() {
                return found;
            }
            if lookup.changed().await.is_err() {
                return lookup.borrow().clone().flatten();
            }
        }
    };
    tokio::time::timeout(limit, wait).await.ok().flatten()
}

#[derive(Default)]
struct State {
    hosts: HashMap<String, Entry>,
    /// The DNS lookup under way for each host, shared by every caller that asks meanwhile.
    refreshing: HashMap<String, Running>,
    /// The id the next lookup takes.
    next_lookup: u64,
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
        let remembered = self.remembered(&host);
        let lookup = self.shared_lookup(&host);
        let Some(remembered) = remembered else {
            // Nothing to fall back on: wait for DNS, bounded so a resolver that hangs ends the
            // lookup rather than the dial.
            return answer_within(lookup, DNS_BOUND)
                .await
                .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, format!("{host}: no address")));
        };
        // Every caller waits out the grace on the one shared lookup, so a dial's legs that ask
        // for the same host at once each get DNS's answer when it comes in time.
        if let Some(found) = answer_within(lookup, self.grace).await {
            return Ok(found);
        }
        tracing::info!(%host, grace_ms = self.grace.as_millis(), "DNS failed or slow; dialing the remembered literals");
        Ok(remembered)
    }

    /// The DNS lookup of `host` under way, or a new one. Its answer is remembered.
    fn shared_lookup(self: &Arc<Self>, host: &str) -> SharedLookup {
        let mut state = self.lock();
        let now = tokio::time::Instant::now();
        if let Some(running) = state.refreshing.get(host)
            && now.duration_since(running.started) < JOIN_WINDOW
        {
            return running.lookup.clone();
        }
        let (tx, rx) = tokio::sync::watch::channel(None);
        let id = state.next_lookup;
        state.next_lookup += 1;
        state.refreshing.insert(host.to_owned(), Running { id, started: now, lookup: rx.clone() });
        drop(state);
        let unregister = Unregister { routes: Arc::clone(self), host: host.to_owned(), id };
        let lookup = self.resolver.lookup(host);
        tokio::spawn(async move {
            let found = match tokio::time::timeout(DNS_BOUND, lookup).await {
                Ok(Ok(found)) if !found.is_empty() => {
                    unregister.routes.store(&unregister.host, &found);
                    Some(found)
                }
                _ => None,
            };
            drop(unregister);
            let _ = tx.send(Some(found));
        });
        rx
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

    /// Forget everything; the file too, when there is one. The literals are public servers'
    /// addresses, nothing of the account's, so sign-out need not call it.
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
    let mut file = std::fs::File::create(&partial)?;
    std::io::Write::write_all(&mut file, text.as_bytes())?;
    // On disk before the rename, so a crash leaves the old file or the new one, never a torn one.
    file.sync_all()?;
    std::fs::rename(&partial, path)
}

#[cfg(test)]
#[path = "route_literals_tests.rs"]
mod tests;
