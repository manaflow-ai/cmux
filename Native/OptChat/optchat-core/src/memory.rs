use std::collections::{HashMap, HashSet};

use crate::node::{Kind, NodeId};
use crate::{JOBS, NODE, PLACEHOLDER, VIEW};

/// What a host stores (message texts and node texts). The core keeps only
/// sizes and the view, so a million-message chat does not live in memory.
pub trait Store {
    /// Kind and whole text of message `i` (which exists).
    fn message(&self, i: u64) -> (Kind, String);
    /// Text of a built node.
    fn node(&self, id: NodeId) -> Option<String>;
    /// Whether a read since the host last cleared it failed (a host whose
    /// reads can fail, such as the hosted store over DO SQLite, answers a
    /// failed read with a stand-in and sets this). `pump` stops before it
    /// builds or starts anything from such a read, so a failed read never
    /// becomes a permanent node.
    fn failed(&self) -> bool {
        false
    }
}

/// A node the compactor should build now (section 4.1).
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Work {
    /// The source already fits in `NODE` bytes, so it IS the node: the core
    /// built it already; the host only stores `text`.
    Free { node: NodeId, text: String },
    /// A model call: the host builds it with `compact_request`, then calls
    /// `complete` (or `fail`).
    Model { node: NodeId },
}

/// One chat's memory state. Single writer: one `Memory` per chat.
#[derive(Clone, Debug)]
pub struct Memory {
    /// Number of messages, T.
    t: u64,
    /// Every built node with the byte size of its text.
    built: HashMap<NodeId, usize>,
    /// Lowest index not built yet, per level (the scan starts there).
    low: Vec<u64>,
    /// The view: parts tiling [0, T), oldest first (section 5).
    view: Vec<NodeId>,
    /// Sum of the view parts' text sizes; an unbuilt part counts the placeholder.
    view_size: usize,
    /// Nodes with a model call running.
    busy: HashSet<NodeId>,
    budget: usize,
}

impl Default for Memory {
    fn default() -> Self {
        Memory::new(VIEW)
    }
}

impl Memory {
    pub fn new(budget: usize) -> Memory {
        Memory {
            t: 0,
            built: HashMap::new(),
            low: Vec::new(),
            view: Vec::new(),
            view_size: 0,
            busy: HashSet::new(),
            budget,
        }
    }

    /// Rebuilds the state after a restart: the view is not saved, it is folded
    /// again from message 0 with the stored nodes (section 5.2, "At load").
    pub fn load(t: u64, built: impl IntoIterator<Item = (NodeId, usize)>, budget: usize) -> Memory {
        let mut m = Memory::new(budget);
        m.built = built.into_iter().collect();
        let levels = m.built.keys().map(|n| n.l as usize + 1).max().unwrap_or(0);
        m.low = vec![0; levels];
        for l in 0..levels {
            m.advance_low(l as u32);
        }
        for _ in 0..t {
            m.push_message();
        }
        m
    }

    pub fn len(&self) -> u64 {
        self.t
    }

    pub fn is_empty(&self) -> bool {
        self.t == 0
    }

    pub fn view(&self) -> &[NodeId] {
        &self.view
    }

    pub fn view_size(&self) -> usize {
        self.view_size
    }

    pub fn budget(&self) -> usize {
        self.budget
    }

    pub fn is_built(&self, id: NodeId) -> bool {
        self.built.contains_key(&id)
    }

    pub fn busy(&self) -> impl Iterator<Item = &NodeId> {
        self.busy.iter()
    }

    /// Appends one message (the host has stored and fsynced it) and returns its id.
    /// Call `pump` afterwards.
    pub fn append(&mut self) -> u64 {
        self.push_message();
        self.t - 1
    }

    fn push_message(&mut self) {
        let part = NodeId::new(0, self.t);
        self.t += 1;
        self.view.push(part);
        self.view_size += self.part_size(part);
        self.fit();
    }

    fn part_size(&self, part: NodeId) -> usize {
        self.built.get(&part).copied().unwrap_or(PLACEHOLDER.len())
    }

    /// The first message whose view line is not built yet, or T (section 4.1, `first`).
    pub fn first(&self) -> u64 {
        self.view
            .iter()
            .find(|p| !self.is_built(**p))
            .map_or(self.t, |p| p.start())
    }

    /// Whether every view line is a summary: an agent turn starts only then (section 6).
    pub fn settled(&self) -> bool {
        self.view.iter().all(|p| self.is_built(*p))
    }

    /// The nodes to build now, smallest level first, in the spec's order:
    /// sources present, not built, not running, and everything before the
    /// node's end already summarized. Free nodes are built on the spot (and
    /// can unlock more); model calls are capped at `JOBS` running.
    pub fn pump(&mut self, store: &dyn Store) -> Vec<Work> {
        let mut out = Vec::new();
        // Free nodes built in this call: the host stores them only after it returns,
        // and a free parent built in the same call reads its children from here.
        let mut fresh: HashMap<NodeId, String> = HashMap::new();
        'again: loop {
            let first = self.first();
            let mut l = 0u32;
            while (1u64 << l) <= self.t {
                let mut i = self.low.get(l as usize).copied().unwrap_or(0);
                while (i + 1) << l <= self.t {
                    let id = NodeId::new(l, i);
                    let end = if l == 0 { i } else { id.end() };
                    if end > first {
                        break;
                    }
                    if !self.is_built(id) && !self.busy.contains(&id) && self.ready(id) {
                        let free = free_text(id, store, &fresh);
                        if store.failed() {
                            return out;
                        }
                        if let Some(text) = free {
                            self.build(id, &text);
                            fresh.insert(id, text.clone());
                            out.push(Work::Free { node: id, text });
                            continue 'again;
                        }
                        // Deviation (README): the spec checks JOBS before any
                        // node; JOBS caps model calls, and a free node is none,
                        // so free nodes above are built even with JOBS running.
                        if self.busy.len() >= JOBS {
                            return out;
                        }
                        self.busy.insert(id);
                        out.push(Work::Model { node: id });
                    }
                    i += 1;
                }
                l += 1;
            }
            return out;
        }
    }

    fn ready(&self, id: NodeId) -> bool {
        match id.children() {
            None => id.i < self.t,
            Some((a, b)) => self.is_built(a) && self.is_built(b),
        }
    }

    /// A model call for `node` produced `text` (the host stored and fsynced it).
    /// Call `pump` afterwards.
    pub fn complete(&mut self, node: NodeId, text: &str) {
        self.busy.remove(&node);
        self.build(node, text);
    }

    /// A model call for `node` failed: it can be started again (after the host's
    /// fixed retry wait, section 4.1).
    pub fn fail(&mut self, node: NodeId) {
        self.busy.remove(&node);
    }

    fn build(&mut self, id: NodeId, text: &str) {
        if self.built.insert(id, text.len()).is_some() {
            return;
        }
        self.advance_low(id.l);
        // Only a level-0 part can be in the view unbuilt (a parent enters only once built).
        if id.l == 0 {
            if let Ok(k) = self.view.binary_search_by_key(&id.start(), |p| p.start()) {
                if self.view[k] == id {
                    self.view_size = self.view_size - PLACEHOLDER.len() + text.len();
                }
            }
        }
        self.fit();
    }

    fn advance_low(&mut self, l: u32) {
        let l = l as usize;
        if self.low.len() <= l {
            self.low.resize(l + 1, 0);
        }
        while self.built.contains_key(&NodeId::new(l as u32, self.low[l])) {
            self.low[l] += 1;
        }
    }

    /// Merges the most due pair of built siblings while the view is over budget
    /// (section 5.2). Most due = the oldest relative to its weight 2^(l+2). A
    /// pair whose parent is not built yet is passed over. Never splits.
    fn fit(&mut self) {
        while self.view_size > self.budget {
            let mut best: Option<(usize, NodeId)> = None;
            for k in 0..self.view.len().saturating_sub(1) {
                let (a, b) = (self.view[k], self.view[k + 1]);
                if a.l != b.l
                    || !a.i.is_multiple_of(2)
                    || b.i != a.i + 1
                    || !self.is_built(a.parent())
                {
                    continue;
                }
                if best.is_none_or(|(_, cur)| self.more_due(a, cur)) {
                    best = Some((k, a));
                }
            }
            let Some((k, a)) = best else { break };
            let parent = a.parent();
            let removed = self.part_size(self.view[k]) + self.part_size(self.view[k + 1]);
            self.view.splice(k..k + 2, [parent]);
            self.view_size = self.view_size - removed + self.part_size(parent);
        }
    }

    /// (T - start_a) / 2^(la+2) > (T - start_b) / 2^(lb+2), in exact integers.
    fn more_due(&self, a: NodeId, b: NodeId) -> bool {
        let age = |n: NodeId| (self.t - n.start()) as u128;
        (age(a) << (b.l + 2)) > (age(b) << (a.l + 2))
    }
}

/// The node's text when its source already fits in `NODE` bytes (section 3):
/// a short message verbatim, or two children joined by a newline.
fn free_text(id: NodeId, store: &dyn Store, fresh: &HashMap<NodeId, String>) -> Option<String> {
    let node = |c: NodeId| fresh.get(&c).cloned().or_else(|| store.node(c));
    let text = match id.children() {
        None => {
            let (kind, text) = store.message(id.i);
            format!("{}: {}", kind.as_str(), text)
        }
        Some((a, b)) => format!("{}\n{}", node(a)?, node(b)?),
    };
    (text.len() <= NODE).then_some(text)
}
