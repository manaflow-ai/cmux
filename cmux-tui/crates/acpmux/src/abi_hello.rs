//! The ABI hello (hq RFD 0178, build 3): every `initialize` carries `{abi, build, features[]}`
//! both ways, so two acpmux builds agree on what they share instead of upgrading in lockstep.
//!
//! - `abi` is [`crate::protocol::ABI`], the newest revision of `spec/acpmux-abi.compat.json`, the
//!   file the wire ABI gate (cmux#55527) makes every breaking change add a revision to (#57322
//!   sends it in the daemon's reply; this module sends it in the client's and peer's hello too).
//! - `build` is the sender's build id (`build_info.rs`).
//! - `features` are the ids each side reads or serves (`capabilities.rs`,
//!   `server/client_features.rs`), already exchanged before this module.
//!
//! The rule is Linux's: an old peer degrades, it never errors. Nothing in a peer's hello can fail
//! its `initialize`: a missing, malformed or newer `abi` is read as what it is ([`Skew`]) and the
//! connection goes on. What a peer does with the skew (send a new field only once the other side
//! lists it; translate by the compat rules) is the caller's; this module only says it.
//!
//! The daemon counts the hellos it heard since it started by client, revision and build, and
//! `_acpmux/status` reports them as `abi.peers` ([`status`]): which builds still talk to it, and
//! how far behind their ABI is.

use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::sync::{Mutex, OnceLock};

/// The most distinct `(client, abi, build)` rows the status keeps; past it the rest count in
/// `omitted`, so a fleet of many builds costs a bounded map.
const MAX_ROWS: usize = 256;

/// Puts this build's `abi` and `build` into a hello's `_meta.acpmux` map.
pub fn stamp(meta: &mut serde_json::Map<String, Value>) {
    meta.insert("abi".to_owned(), json!(crate::protocol::ABI));
    meta.insert("build".to_owned(), json!(crate::hub::build()));
}

/// How a peer's ABI revision stands against this build's.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Skew {
    /// The peer sent no readable `abi`: a build from before the hello. It works as it always did.
    PreHello,
    /// The peer is behind: it may expect a member a later revision removed.
    Older,
    Same,
    /// The peer is ahead: it sends a new field only once this side lists the feature.
    Newer,
}

impl Skew {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::PreHello => "pre-hello",
            Self::Older => "older",
            Self::Same => "same",
            Self::Newer => "newer",
        }
    }
}

/// The skew of a peer whose hello said ABI revision `abi` (none: it said no readable one).
pub fn skew(abi: Option<u32>) -> Skew {
    let ours = crate::protocol::ABI;
    match abi {
        None => Skew::PreHello,
        Some(r) if r < ours => Skew::Older,
        Some(r) if r == ours => Skew::Same,
        Some(_) => Skew::Newer,
    }
}

/// What one side's hello said, read so that nothing in it can fail: a missing or malformed value
/// is `None`.
#[derive(Clone, Debug, Default, PartialEq, Eq, PartialOrd, Ord)]
pub struct Hello {
    pub client: String,
    pub abi: Option<u32>,
    pub build: Option<String>,
}

/// Reads a peer's hello: the client's `initialize` params, or the daemon's `initialize` result
/// (the result has `agentInfo` where params have `clientInfo`).
pub fn read(hello: &Value) -> Hello {
    let client = hello
        .pointer("/clientInfo/name")
        .or_else(|| hello.pointer("/agentInfo/name"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .chars()
        .take(64)
        .collect();
    // 0 is what `peer_abi` reads for none or a malformed value; revisions start at the base, 1.
    let abi = Some(crate::protocol::peer_abi(hello)).filter(|&abi| abi > 0);
    let build = hello
        .pointer("/_meta/acpmux/build")
        .and_then(Value::as_str)
        .map(|b| b.chars().take(64).collect());
    Hello { client, abi, build }
}

fn seen() -> &'static Mutex<(BTreeMap<Hello, u64>, u64)> {
    static SEEN: OnceLock<Mutex<(BTreeMap<Hello, u64>, u64)>> = OnceLock::new();
    SEEN.get_or_init(Default::default)
}

/// Counts one hello the daemon heard.
pub fn note(hello: Hello) {
    let mut guard = seen().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let (rows, omitted) = &mut *guard;
    if let Some(n) = rows.get_mut(&hello) {
        *n += 1;
    } else if rows.len() < MAX_ROWS {
        rows.insert(hello, 1);
    } else {
        *omitted += 1;
    }
}

/// `_acpmux/status`'s `abi`: this build's revision and the hellos heard since the start, by
/// client, revision and build, each with its skew.
pub fn status() -> Value {
    let guard = seen().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let (rows, omitted) = &*guard;
    let peers: Vec<Value> = rows
        .iter()
        .map(|(h, n)| {
            json!({"client": h.client, "abi": h.abi, "build": h.build,
                "skew": skew(h.abi).as_str(), "hellos": n})
        })
        .collect();
    json!({"abi": crate::protocol::ABI, "peers": peers, "omitted": omitted})
}

#[cfg(test)]
#[path = "abi_hello_tests.rs"]
mod tests;
