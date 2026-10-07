//! Where the core's memory stands, saved in `state` (`memory/checkpoint`),
//! so a start reads the view and a few frontier nodes by key instead of
//! folding the whole log again (section 5.2, "At load", which stays the
//! fallback). A stale checkpoint is fine: the messages after it are folded
//! in as at load. The host saves one every `EVERY` messages and at shutdown.

use std::io;

use optchat_core::{Checkpoint, Memory, NodeId};
use serde_json::{json, Value};

use super::{Built, Db};

/// The state key of the checkpoint.
pub const CHECKPOINT_KEY: &str = "memory/checkpoint";
/// Messages between two saved checkpoints: a start folds at most this many.
pub const EVERY: u64 = 256;
/// A checkpoint more messages behind than this is not resumed from: its
/// frontier and tail would cost about what a full fold does (the log was
/// written by something else, an import or an old build).
pub const STALE: u64 = 16 * EVERY;

pub fn encode(c: &Checkpoint) -> String {
    let view: Vec<Value> = c.view.iter().map(|p| json!([p.l, p.i])).collect();
    json!({"t": c.t, "low": c.low, "view": view}).to_string()
}

pub fn decode(text: &str) -> Option<Checkpoint> {
    let v: Value = serde_json::from_str(text).ok()?;
    let low = v["low"]
        .as_array()?
        .iter()
        .map(Value::as_u64)
        .collect::<Option<Vec<u64>>>()?;
    let view = v["view"]
        .as_array()?
        .iter()
        .map(|p| {
            let l = p.get(0)?.as_u64()?;
            let i = p.get(1)?.as_u64()?;
            (l < 64).then(|| NodeId::new(l as u32, i))
        })
        .collect::<Option<Vec<NodeId>>>()?;
    Some(Checkpoint {
        t: v["t"].as_u64()?,
        low,
        view,
    })
}

/// How the memory was loaded.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Loaded {
    /// From the checkpoint: O(view + frontier + messages since).
    Resumed,
    /// Folded from message 0 (no usable checkpoint, or right after an import).
    Folded,
}

/// The core's memory for `db`: resumed from its checkpoint when it has a
/// usable one (not more than `STALE` messages behind), else folded from every node's size (`built`, when the caller
/// has them already). Either way the result is lazy and its checkpoint is
/// saved, so the next start resumes.
pub fn load(db: &mut Db, built: Option<Built>, budget: usize) -> io::Result<(Memory, Loaded)> {
    if built.is_none() {
        let saved = db.state(CHECKPOINT_KEY)?.as_deref().and_then(decode);
        if let Some(c) = saved.filter(|c| db.len().saturating_sub(c.t) <= STALE) {
            let frontier = db.frontier(&c.low)?;
            if let Some(m) = Memory::resume(&c, db.len(), frontier, budget, &*db) {
                if db.len() - c.t > EVERY {
                    save(db, &m)?;
                }
                return Ok((m, Loaded::Resumed));
            }
        }
    }
    let built = match built {
        Some(b) => b,
        None => db.all_sizes()?,
    };
    let mut m = Memory::load(db.len(), built, budget);
    m.make_lazy();
    save(db, &m)?;
    Ok((m, Loaded::Folded))
}

pub fn save(db: &mut Db, m: &Memory) -> io::Result<()> {
    db.put_state(&[(CHECKPOINT_KEY.to_owned(), Some(encode(&m.checkpoint())))])
}
