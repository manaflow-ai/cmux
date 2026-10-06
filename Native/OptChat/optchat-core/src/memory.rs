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
    /// Byte size of a built node's text. A store that keeps sizes apart
    /// (an index) answers without reading the text.
    fn node_size(&self, id: NodeId) -> Option<usize> {
        self.node(id).map(|t| t.len())
    }
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

/// Where a lazy `Memory` stands, for a host to save and `resume` from:
/// message count, the lowest unbuilt index per level, and the view.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Checkpoint {
    pub t: u64,
    pub low: Vec<u64>,
    pub view: Vec<NodeId>,
}

/// One chat's memory state. Single writer: one `Memory` per chat.
///
/// A node is built when its index is below its level's `low` (every node
/// there is built) or it is in `frontier` (built out of order above it).
/// Sizes of nodes below `low` are kept in `sizes`: all of them for a memory
/// made with `new` or `load`; for a lazy one (`resume`, `make_lazy`) only
/// the view's parts, the rest read from the store by key when a merge needs
/// one. A lazy memory takes the `_in` methods, which get the store.
#[derive(Clone, Debug)]
pub struct Memory {
    /// Number of messages, T.
    t: u64,
    /// Built nodes at or above their level's `low`, with their sizes.
    frontier: HashMap<NodeId, usize>,
    /// Sizes of built nodes below `low` (all, or only the view's when lazy).
    sizes: HashMap<NodeId, usize>,
    lazy: bool,
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
            frontier: HashMap::new(),
            sizes: HashMap::new(),
            lazy: false,
            low: Vec::new(),
            view: Vec::new(),
            view_size: 0,
            busy: HashSet::new(),
            budget,
        }
    }

    /// Rebuilds the state after a restart: the view is not saved, it is folded
    /// again from message 0 with the stored nodes (section 5.2, "At load").
    /// O(T) in time and in the sizes it keeps; see `resume`.
    pub fn load(t: u64, built: impl IntoIterator<Item = (NodeId, usize)>, budget: usize) -> Memory {
        let mut m = Memory::new(budget);
        m.frontier = built.into_iter().collect();
        let levels = m
            .frontier
            .keys()
            .map(|n| n.l as usize + 1)
            .max()
            .unwrap_or(0);
        m.low = vec![0; levels];
        for l in 0..levels {
            m.advance_low(l as u32);
        }
        for _ in 0..t {
            m.push_message(&NoStore);
        }
        m
    }

    /// Picks up from a saved `Checkpoint` without reading the whole log:
    /// `frontier` is every stored node at or above the checkpoint's `low` of
    /// its level (with its size); the view's sizes come from `store` by key;
    /// messages `checkpoint.t..t` are folded in as at load (section 5.2).
    /// The result is lazy. None when the checkpoint does not fit the store
    /// (a view that does not tile `[0, checkpoint.t)`, a merged part that is
    /// not stored, more messages in it than `t`): the host then `load`s.
    pub fn resume(
        checkpoint: &Checkpoint,
        t: u64,
        frontier: impl IntoIterator<Item = (NodeId, usize)>,
        budget: usize,
        store: &dyn Store,
    ) -> Option<Memory> {
        if checkpoint.t > t || checkpoint.low.len() > 64 {
            return None;
        }
        let mut m = Memory::new(budget);
        m.lazy = true;
        m.low = checkpoint.low.clone();
        m.frontier = frontier.into_iter().collect();
        let levels = m
            .frontier
            .keys()
            .map(|n| n.l as usize + 1)
            .max()
            .unwrap_or(0)
            .max(m.low.len());
        m.low.resize(levels, 0);
        for l in 0..levels {
            m.advance_low(l as u32);
        }
        let mut at = 0u64;
        for part in &checkpoint.view {
            if part.start() != at || part.checked_end().is_none_or(|e| e > checkpoint.t) {
                return None;
            }
            at = part.end();
            let size = if m.is_built(*part) {
                m.size(*part, store)?
            } else if part.l == 0 {
                PLACEHOLDER.len()
            } else {
                return None;
            };
            if m.is_built(*part) {
                m.sizes.insert(*part, size);
            }
            m.view.push(*part);
            m.view_size += size;
        }
        if at != checkpoint.t {
            return None;
        }
        m.t = checkpoint.t;
        while m.t < t {
            m.push_message(store);
        }
        m.fit(store);
        Some(m)
    }

    /// Where this memory stands, for `resume`.
    pub fn checkpoint(&self) -> Checkpoint {
        Checkpoint {
            t: self.t,
            low: self.low.clone(),
            view: self.view.clone(),
        }
    }

    /// Drops the sizes of nodes outside the view (they are read from the
    /// store when needed): from here on only the `_in` methods may change it.
    pub fn make_lazy(&mut self) {
        self.lazy = true;
        self.prune();
    }

    pub fn is_lazy(&self) -> bool {
        self.lazy
    }

    fn prune(&mut self) {
        let view: HashSet<NodeId> = self.view.iter().copied().collect();
        self.sizes.retain(|id, _| view.contains(id));
    }

    /// Size of a built node: from memory, else (lazy) from the store.
    fn size(&self, id: NodeId, store: &dyn Store) -> Option<usize> {
        self.frontier
            .get(&id)
            .or_else(|| self.sizes.get(&id))
            .copied()
            .or_else(|| store.node_size(id))
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
        self.low.get(id.l as usize).is_some_and(|low| id.i < *low)
            || self.frontier.contains_key(&id)
    }

    pub fn busy(&self) -> impl Iterator<Item = &NodeId> {
        self.busy.iter()
    }

    /// Appends one message (the host has stored and fsynced it) and returns its id.
    /// Call `pump` afterwards. Not for a lazy memory (`append_in`).
    pub fn append(&mut self) -> u64 {
        debug_assert!(!self.lazy, "a lazy memory appends with append_in");
        self.append_in(&NoStore)
    }

    /// `append` for any memory: sizes it does not hold come from `store`.
    pub fn append_in(&mut self, store: &dyn Store) -> u64 {
        self.push_message(store);
        self.t - 1
    }

    fn push_message(&mut self, store: &dyn Store) {
        let part = NodeId::new(0, self.t);
        self.t += 1;
        self.view.push(part);
        self.view_size += self.part_size(part, store);
        self.fit(store);
    }

    /// A view part's size; an unbuilt part counts the placeholder.
    fn part_size(&self, part: NodeId, store: &dyn Store) -> usize {
        if !self.is_built(part) {
            return PLACEHOLDER.len();
        }
        // A built node the store cannot size is a failing store; the
        // placeholder keeps the budget arithmetic going until `failed`
        // stops the pump.
        self.size(part, store).unwrap_or(PLACEHOLDER.len())
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
                            self.build(id, text.len(), store);
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
    /// Call `pump` afterwards. Not for a lazy memory (`complete_in`).
    pub fn complete(&mut self, node: NodeId, text: &str) {
        debug_assert!(!self.lazy, "a lazy memory completes with complete_in");
        self.complete_in(node, text, &NoStore);
    }

    /// `complete` for any memory: sizes it does not hold come from `store`.
    pub fn complete_in(&mut self, node: NodeId, text: &str, store: &dyn Store) {
        self.busy.remove(&node);
        self.build(node, text.len(), store);
    }

    /// A model call for `node` failed: it can be started again (after the host's
    /// fixed retry wait, section 4.1).
    pub fn fail(&mut self, node: NodeId) {
        self.busy.remove(&node);
    }

    fn build(&mut self, id: NodeId, len: usize, store: &dyn Store) {
        if self.is_built(id) {
            return;
        }
        self.frontier.insert(id, len);
        self.advance_low(id.l);
        // Only a level-0 part can be in the view unbuilt (a parent enters only once built).
        if id.l == 0 {
            if let Ok(k) = self.view.binary_search_by_key(&id.start(), |p| p.start()) {
                if self.view[k] == id {
                    self.view_size = self.view_size - PLACEHOLDER.len() + len;
                    self.sizes.insert(id, len);
                }
            }
        }
        self.fit(store);
    }

    /// Moves `low` past built nodes; their sizes leave the frontier (a lazy
    /// memory keeps only the view's, see `prune`).
    fn advance_low(&mut self, l: u32) {
        let l = l as usize;
        if self.low.len() <= l {
            self.low.resize(l + 1, 0);
        }
        while let Some(size) = self.frontier.remove(&NodeId::new(l as u32, self.low[l])) {
            self.sizes.insert(NodeId::new(l as u32, self.low[l]), size);
            self.low[l] += 1;
        }
        if self.lazy && self.sizes.len() > 4 * self.view.len() + 4096 {
            self.prune();
        }
    }

    /// Merges the most due pair of built siblings while the view is over budget
    /// (section 5.2). Most due = the oldest relative to its weight 2^(l+2). A
    /// pair whose parent is not built yet is passed over. Never splits.
    fn fit(&mut self, store: &dyn Store) {
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
            let (left, right) = (self.view[k], self.view[k + 1]);
            let removed = self.part_size(left, store) + self.part_size(right, store);
            let added = self.part_size(parent, store);
            self.view.splice(k..k + 2, [parent]);
            self.view_size = self.view_size - removed + added;
            if self.lazy {
                self.sizes.remove(&left);
                self.sizes.remove(&right);
            }
            self.sizes.insert(parent, added);
        }
    }

    /// (T - start_a) / 2^(la+2) > (T - start_b) / 2^(lb+2), in exact integers.
    fn more_due(&self, a: NodeId, b: NodeId) -> bool {
        let age = |n: NodeId| (self.t - n.start()) as u128;
        (age(a) << (b.l + 2)) > (age(b) << (a.l + 2))
    }
}

/// The store of a memory that holds every size itself (`new`, `load`).
struct NoStore;

impl Store for NoStore {
    // Only sizes are asked of it (and it has none); messages are read
    // through the store `pump` gets.
    fn message(&self, _: u64) -> (Kind, String) {
        (Kind::Note, String::new())
    }

    fn node(&self, _: NodeId) -> Option<String> {
        None
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
