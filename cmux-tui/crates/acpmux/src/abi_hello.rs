//! The ABI hello (hq RFD 0178, build 3): every `initialize` carries `{abi, build, features[]}`
//! both ways, so two acpmux builds agree on what they share instead of upgrading in lockstep.
//!
//! - `abi` is `{rev, base}`: the newest revision of `spec/acpmux-abi.compat.json`, the file the
//!   wire ABI gate (cmux#55527) makes every breaking change add a revision to. It is read from
//!   that file at compile time, so the hello and the gate cannot disagree.
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

/// The `_meta.acpmux` key the hello's ABI revision goes under, in both directions.
pub const FIELD: &str = "abi";

/// The gate's compat file: its `base` and the `rev` of each revision since.
const COMPAT: &str = include_str!("../spec/acpmux-abi.compat.json");

/// The most distinct `(client, rev, build)` rows the status keeps; past it the rest count in
/// `omitted`, so a fleet of many builds costs a bounded map.
const MAX_ROWS: usize = 256;

/// This build's ABI: `(base, rev)`, `rev` being the newest revision in the compat file (the base
/// when it has none).
pub fn revision() -> (u64, u64) {
    static REVISION: OnceLock<(u64, u64)> = OnceLock::new();
    *REVISION.get_or_init(|| parse_revision(COMPAT))
}

fn parse_revision(compat: &str) -> (u64, u64) {
    let v: Value = serde_json::from_str(compat).unwrap_or(Value::Null);
    let base = v.get("base").and_then(Value::as_u64).unwrap_or(1);
    let rev = v
        .get("revisions")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|r| r.get("rev").and_then(Value::as_u64))
        .max()
        .unwrap_or(base)
        .max(base);
    (base, rev)
}

/// The `abi` value this build says in its hello.
pub fn own() -> Value {
    let (base, rev) = revision();
    json!({"rev": rev, "base": base})
}

/// Puts this build's `abi` and `build` into a hello's `_meta.acpmux` map.
pub fn stamp(meta: &mut serde_json::Map<String, Value>) {
    meta.insert(FIELD.to_owned(), own());
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

/// The skew of a peer whose hello said ABI revision `rev`.
pub fn skew(rev: Option<u64>) -> Skew {
    let ours = revision().1;
    match rev {
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
    pub rev: Option<u64>,
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
    let rev = hello.pointer(&format!("/_meta/acpmux/{FIELD}/rev")).and_then(Value::as_u64);
    let build = hello
        .pointer("/_meta/acpmux/build")
        .and_then(Value::as_str)
        .map(|b| b.chars().take(64).collect());
    Hello { client, rev, build }
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
    let (base, rev) = revision();
    let guard = seen().lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let (rows, omitted) = &*guard;
    let peers: Vec<Value> = rows
        .iter()
        .map(|(h, n)| {
            json!({"client": h.client, "rev": h.rev, "build": h.build,
                "skew": skew(h.rev).as_str(), "hellos": n})
        })
        .collect();
    json!({"rev": rev, "base": base, "peers": peers, "omitted": omitted})
}

#[cfg(test)]
#[path = "abi_hello_tests.rs"]
mod tests;
