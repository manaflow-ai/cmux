//! Where the core's memory stands, saved in `state` (`memory/checkpoint`):
//! the view, the compaction view and their batch state. Taelin's recipe
//! (gist 3c190e0, 3.2) saves the view to `view.json` and loads it at start,
//! and never rebuilds it from the log: a rebuilt view differs from the live
//! one, and every cache entry dies. This is that file, in the database's
//! state table so it commits with the rest. The host saves it after every
//! message and at shutdown; a fold from message 0 happens only when there
//! is no usable checkpoint (a first start after an import or an older store).

use std::io;

use optchat_core::{Checkpoint, Memory, NodeId};
use serde_json::{json, Value};

use super::{Built, Db};

/// The state key of the checkpoint.
pub const CHECKPOINT_KEY: &str = "memory/checkpoint";
/// Messages between two saved checkpoints: every one (spec 3.2).
pub const EVERY: u64 = 1;

pub fn encode(c: &Checkpoint) -> String {
    let parts = |v: &[NodeId]| v.iter().map(|p| json!([p.l, p.i])).collect::<Vec<Value>>();
    json!({
        "t": c.t,
        "low": c.low,
        "view": parts(&c.view),
        "compact_view": parts(&c.compact_view),
        "merging": c.merging,
        "compact_merging": c.compact_merging,
    })
    .to_string()
}

pub fn decode(text: &str) -> Option<Checkpoint> {
    let v: Value = serde_json::from_str(text).ok()?;
    let low = v["low"]
        .as_array()?
        .iter()
        .map(Value::as_u64)
        .collect::<Option<Vec<u64>>>()?;
    let parts = |v: &Value| {
        v.as_array()?
            .iter()
            .map(|p| {
                let l = p.get(0)?.as_u64()?;
                let i = p.get(1)?.as_u64()?;
                (l < 64).then(|| NodeId::new(l as u32, i))
            })
            .collect::<Option<Vec<NodeId>>>()
    };
    let view = parts(&v["view"])?;
    // An older build's checkpoint has no compaction view: the resume derives it.
    let compact_view = match v.get("compact_view") {
        Some(c) => parts(c)?,
        None => Vec::new(),
    };
    Some(Checkpoint {
        t: v["t"].as_u64()?,
        low,
        view,
        compact_view,
        merging: v["merging"].as_bool().unwrap_or(false),
        compact_merging: v["compact_merging"].as_bool().unwrap_or(false),
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

/// The core's memory for `db`: resumed from its checkpoint whenever it has
/// one that fits the store, however far behind (the messages after it are
/// appended as live); else folded from every node's size (`built`, when the
/// caller has them already, after an import). Either way the result is lazy
/// and its checkpoint is saved, so the next start resumes.
pub fn load(db: &mut Db, built: Option<Built>, budget: usize) -> io::Result<(Memory, Loaded)> {
    if built.is_none() {
        let saved = db.state(CHECKPOINT_KEY)?.as_deref().and_then(decode);
        if let Some(c) = saved {
            let frontier = db.frontier(&c.low)?;
            if let Some(m) = Memory::resume(&c, db.len(), frontier, budget, &*db) {
                if db.len() > c.t {
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
