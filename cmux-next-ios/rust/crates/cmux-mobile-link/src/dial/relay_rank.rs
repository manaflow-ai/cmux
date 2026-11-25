//! Relay ranking per pair (PROTOCOL.md "Relay ranking"): which relay server
//! a link's two ends should meet on.
//!
//! A relayed WireGuard path is this side → relay → the peer, so what the
//! person feels is the sum of both legs, not this side's leg alone. Each side
//! measures its round trip to every relay it was offered (a STUN Binding to
//! each TURN server from `/v1/ice`, [`refresh`]), sends that vector to the
//! peer (`relayRtt` in `wg-init` / `wg-resp`), and keeps the peer's. An
//! allocation then tries relays by `argmin(own leg + peer's leg)`
//! ([`rank`]): both ends compute the same sums, so they agree on a relay
//! without a round of negotiation.
//!
//! - Measured beats estimated: a leg nobody measured costs [`ESTIMATE_MS`],
//!   a pessimistic far relay, so a measured relay goes first unless it is
//!   slower than that.
//! - A relay whose probe went unanswered is dead ([`DEAD_MS`]) and goes
//!   behind every live one until a later probe answers.
//! - Hysteresis: the relay that last carried the pair keeps it unless the
//!   best beats it by [`SWITCH_MARGIN_MS`] or [`SWITCH_MARGIN_PERCENT`] of
//!   its cost, whichever is larger, so jitter never flaps a link. When an
//!   end's round trip moves past that (a phone that left Wi-Fi, a relay
//!   under load), the next allocation (a redial, a roam, a replaced TURN
//!   stream) moves to the better relay: a pair never stays on its first
//!   relay only because it was first.
//! - Fallback: with no measurement on either side every relay costs the
//!   same, and the order is the order the service listed (today's).
//!
//! Relays are named by host (a TURN server's UDP, TCP and TLS URLs on one
//! host are one relay box). The ranker itself ([`rank`]) is pure and takes
//! any relay ids, so carrier relays, netcheck regions and our own boxes can
//! rank through it too.

use std::collections::{BTreeMap, HashMap};
use std::sync::{Mutex, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use tokio::net::UdpSocket;

/// What a leg costs when neither probe nor peer measured it.
pub const ESTIMATE_MS: u32 = 250;
/// What a leg to a relay that did not answer its probe costs.
pub const DEAD_MS: u32 = 10_000;
/// The least a relay must beat the one carrying the pair by to replace it.
pub const SWITCH_MARGIN_MS: u32 = 10;
/// ... or this share of the carrying relay's cost, when larger.
pub const SWITCH_MARGIN_PERCENT: u32 = 20;
/// A side probes its relays again after this long.
const REFRESH_AFTER: Duration = Duration::from_secs(30);
/// A peer's vector is used this long after it arrived.
const FAR_KEPT: Duration = Duration::from_secs(30 * 60);
/// Bound on one probe's answer; a probe sends [`PROBE_TRIES`] requests.
const PROBE_WAIT: Duration = Duration::from_millis(700);
const PROBE_TRIES: usize = 2;
/// At most this many relays are probed per refresh.
const MAX_PROBED: usize = 8;
/// Weight of a new measurement in the moving average, in percent.
const EWMA_NEW_PERCENT: u32 = 50;

/// One side's leg to one relay.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Leg {
    /// A measured round trip, in milliseconds.
    Measured(u32),
    /// Probed and not answered.
    Dead,
}

impl Leg {
    fn cost(leg: Option<&Leg>) -> u32 {
        match leg {
            Some(Leg::Measured(ms)) => *ms,
            Some(Leg::Dead) => DEAD_MS,
            None => ESTIMATE_MS,
        }
    }
}

/// `candidates` (relay ids in the service's order, each once) from best to
/// worst for a pair whose ends measured `own` and `far`; `current` is the
/// relay carrying the pair now, kept first within the switch margin. Pure:
/// the same inputs from both ends (own and far swapped) give the same order.
pub fn rank(
    candidates: &[String],
    own: &HashMap<String, Leg>,
    far: &HashMap<String, Leg>,
    current: Option<&str>,
) -> Vec<String> {
    let measured = candidates.iter().any(|id| own.contains_key(id) || far.contains_key(id));
    if !measured {
        return candidates.to_vec();
    }
    let total = |id: &str| Leg::cost(own.get(id)).saturating_add(Leg::cost(far.get(id)));
    let mut ordered: Vec<(u32, &String)> = candidates.iter().map(|id| (total(id), id)).collect();
    // Stable: equal sums keep the service's order, on both ends.
    ordered.sort_by_key(|(cost, _)| *cost);
    let mut out: Vec<String> = ordered.iter().map(|(_, id)| (*id).clone()).collect();
    if let Some(current) = current
        && let Some(at) = out.iter().position(|id| id == current)
        && let Some((best, _)) = ordered.first()
    {
        let held = total(current);
        let margin = SWITCH_MARGIN_MS.max(held.saturating_mul(SWITCH_MARGIN_PERCENT) / 100);
        let dead = matches!(own.get(current), Some(Leg::Dead)) || matches!(far.get(current), Some(Leg::Dead));
        if !dead && best.saturating_add(margin) > held {
            let kept = out.remove(at);
            out.insert(0, kept);
        }
    }
    out
}

/// The process's measurements: its own legs, each peer's vector, and the
/// relay that last carried each pair.
#[derive(Default)]
struct Table {
    own: HashMap<String, Leg>,
    probed_at: Option<Instant>,
    probing: bool,
    far: HashMap<String, (HashMap<String, Leg>, Instant)>,
    carried: HashMap<String, String>,
}

fn table() -> &'static Mutex<Table> {
    static TABLE: OnceLock<Mutex<Table>> = OnceLock::new();
    TABLE.get_or_init(Mutex::default)
}

fn lock() -> std::sync::MutexGuard<'static, Table> {
    table().lock().unwrap_or_else(PoisonError::into_inner)
}

/// `relays` (ids in the service's order) ranked for the pair with `peer`
/// (None: this side's legs alone).
pub fn ranked_for(relays: &[String], peer: Option<&str>) -> Vec<String> {
    let mut table = lock();
    let now = Instant::now();
    table.far.retain(|_, (_, at)| now.duration_since(*at) < FAR_KEPT);
    let empty = HashMap::new();
    let far = peer.and_then(|peer| table.far.get(peer)).map_or(&empty, |(far, _)| far);
    let current = peer.and_then(|peer| table.carried.get(peer)).map(String::as_str);
    rank(relays, &table.own, far, current)
}

/// The peer's vector (`relayRtt` from its `wg-init` or `wg-resp`). An empty
/// one (an older peer) leaves what this side knew.
pub fn note_far(peer: &str, vector: &BTreeMap<String, u32>) {
    if vector.is_empty() {
        return;
    }
    let legs = vector
        .iter()
        .map(|(id, ms)| (id.clone(), if *ms >= DEAD_MS { Leg::Dead } else { Leg::Measured(*ms) }))
        .collect();
    lock().far.insert(peer.to_owned(), (legs, Instant::now()));
}

/// `relay` carried the pair with `peer` (an allocation on it succeeded).
pub fn note_carried(peer: &str, relay: &str) {
    lock().carried.insert(peer.to_owned(), relay.to_owned());
}

/// This side's vector, for `relayRtt` (a dead relay as [`DEAD_MS`]).
pub fn own_vector() -> BTreeMap<String, u32> {
    lock().own.iter().map(|(id, leg)| (id.clone(), Leg::cost(Some(leg)))).collect()
}

/// A round trip to `relay` measured elsewhere (a netcheck report), None
/// when it did not answer: folded in like a probe's, and sent to peers.
/// Optional: without it the ranking uses this module's own probes.
pub fn note_measured(relay: &str, answer: Option<u32>) {
    note_own(&mut lock(), relay, answer);
}

/// Fold one probe's answer into this side's leg to `relay`.
fn note_own(table: &mut Table, relay: &str, answer: Option<u32>) {
    let next = match (table.own.get(relay), answer) {
        (_, None) => Leg::Dead,
        (Some(Leg::Measured(old)), Some(ms)) => {
            Leg::Measured((old * (100 - EWMA_NEW_PERCENT) + ms * EWMA_NEW_PERCENT) / 100)
        }
        (_, Some(ms)) => Leg::Measured(ms),
    };
    table.own.insert(relay.to_owned(), next);
}

/// Probe `relays` (`(id, host:port)` of UDP TURN servers) when the last
/// probe is older than [`REFRESH_AFTER`], in a task of its own: a dial never
/// waits for it. Its answers rank the next allocation and go to the peer.
pub fn refresh(relays: Vec<(String, String)>) {
    if relays.is_empty() || tokio::runtime::Handle::try_current().is_err() {
        return;
    }
    {
        let mut table = lock();
        let fresh = table.probed_at.is_some_and(|at| at.elapsed() < REFRESH_AFTER);
        if fresh || table.probing {
            return;
        }
        table.probing = true;
    }
    tokio::spawn(async move {
        let probes = relays
            .into_iter()
            .take(MAX_PROBED)
            .map(|(id, address)| async move { (id, probe(&address).await) });
        let answers = futures_util::future::join_all(probes).await;
        let mut table = lock();
        for (id, answer) in answers {
            note_own(&mut table, &id, answer);
        }
        table.probed_at = Some(Instant::now());
        table.probing = false;
        tracing::debug!(relays = ?table.own, "relay round trips measured");
    });
}

/// One STUN Binding round trip to `address`, in milliseconds (the best of
/// [`PROBE_TRIES`]); None when no request was answered.
async fn probe(address: &str) -> Option<u32> {
    let target = tokio::net::lookup_host(address).await.ok()?.next()?;
    let bind = if target.is_ipv6() { "[::]:0" } else { "0.0.0.0:0" };
    let socket = UdpSocket::bind(bind).await.ok()?;
    let mut best: Option<u32> = None;
    let mut buf = [0u8; 1500];
    for _ in 0..PROBE_TRIES {
        let Some(request) = super::turn::binding_request() else { break };
        let started = Instant::now();
        if socket.send_to(&request, target).await.is_err() {
            continue;
        }
        let answered = tokio::time::timeout(PROBE_WAIT, async {
            loop {
                let (n, from) = socket.recv_from(&mut buf).await.ok()?;
                // The answer to this request: same server, same transaction id.
                if from == target && n >= 20 && buf[8..20] == request[8..20] {
                    return Some(());
                }
            }
        })
        .await;
        if matches!(answered, Ok(Some(()))) {
            let ms = u32::try_from(started.elapsed().as_millis()).unwrap_or(u32::MAX).max(1);
            best = Some(best.map_or(ms, |b| b.min(ms)));
        }
    }
    best
}

#[cfg(test)]
#[path = "relay_rank_tests.rs"]
mod tests;
