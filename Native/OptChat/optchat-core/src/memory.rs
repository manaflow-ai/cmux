use std::collections::{BTreeSet, HashMap, HashSet};

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

/// `complete` for a node that has no model call running (never handed out
/// by `pump`, already completed, or failed): nothing changes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct NotRunning(pub NodeId);

impl std::fmt::Display for NotRunning {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "node {} has no model call running", self.0.name())
    }
}

impl std::error::Error for NotRunning {}

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

/// Where a `Memory` stands, for a host to save and `resume` from: message
/// count, the lowest unbuilt index per level, the view and the compaction
/// view, and whether a batch of merges is still under way in each. Saved
/// after every message: the view is never rebuilt from the log (spec 3.2,
/// gist 3c190e0: a rebuilt view differs from the live one, and every cache
/// entry dies).
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Checkpoint {
    pub t: u64,
    pub low: Vec<u64>,
    pub view: Vec<NodeId>,
    /// The compaction view; empty in a checkpoint from an older build (the
    /// resume then derives it from the view).
    pub compact_view: Vec<NodeId>,
    /// The view passed its budget and has not reached half of it yet.
    pub merging: bool,
    /// The same for the compaction view.
    pub compact_merging: bool,
}

/// The two views a memory keeps (spec 3.2 and 4).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Which {
    /// The chat's view: what every turn sees.
    Chat,
    /// The compaction view: the chat's view merged further.
    Compact,
}

/// The pair `most_due` picks: due = (T - last) / 2^l, measured from the
/// pair's LAST message, in its own line size; `(T + 1)/2^l - i` in the
/// spec's code, the same order (spec 3.2, gist 3c190e0). Ties go to the
/// oldest pair. Measuring from the pair's first message rewrites old lines
/// that Taelin's push keeps, and every cache entry after them dies.
///
/// Returns the index in `view` of the pair's left line, among adjacent
/// siblings whose parent is `built`.
pub fn most_due(view: &[NodeId], t: u64, built: impl Fn(NodeId) -> bool) -> Option<usize> {
    let mut best: Option<(usize, NodeId)> = None;
    for k in 0..view.len().saturating_sub(1) {
        let (a, b) = (view[k], view[k + 1]);
        if a.l != b.l || !a.i.is_multiple_of(2) || b.i != a.i + 1 || !built(a.parent()) {
            continue;
        }
        if best.is_none_or(|(_, cur)| more_due(t, a, cur)) {
            best = Some((k, a));
        }
    }
    best.map(|(k, _)| k)
}

/// (T + 1 - start_a) / 2^la > (T + 1 - start_b) / 2^lb, in exact integers:
/// `(T + 1)/2^l - i` for each pair, whose left line starts at `start`.
fn more_due(t: u64, a: NodeId, b: NodeId) -> bool {
    let age = |n: NodeId| (t + 1).saturating_sub(n.start()) as u128;
    (age(a) << b.l) > (age(b) << a.l)
}

/// Unbuilt message nodes that may run at once: a message's node starts once
/// fewer than this many lines before it are still unbuilt (spec 4 looks 8
/// ahead; the reference client as many as it runs, `JOBS`).
pub const AHEAD: usize = JOBS;

/// One chat's memory state. Single writer: one `Memory` per chat.
///
/// A node is built when its index is below its level's `low` (every node
/// there is built) or it is in `frontier` (built out of order above it).
/// Sizes of nodes below `low` are kept in `sizes`: all of them for a memory
/// made with `new` or `load`; for a lazy one (`resume`, `make_lazy`) only
/// the views' parts, the rest read from the store by key when a merge needs
/// one. A lazy memory takes the `_in` methods, which get the store.
#[derive(Clone, Debug)]
pub struct Memory {
    /// Number of messages, T.
    t: u64,
    /// Built nodes at or above their level's `low`, with their sizes.
    frontier: HashMap<NodeId, usize>,
    /// Sizes of built nodes below `low` (all, or only the views' when lazy).
    sizes: HashMap<NodeId, usize>,
    lazy: bool,
    /// Lowest index not built yet, per level.
    low: Vec<u64>,
    /// The view: parts tiling [0, T), oldest first (spec 3).
    view: Vec<NodeId>,
    /// Sum of the view parts' text sizes; an unbuilt part counts the placeholder.
    view_size: usize,
    /// The view passed `budget` and is not down to half of it yet.
    merging: bool,
    /// The compaction view (spec 4): the chat's view merged further, between
    /// a quarter and an eighth of `budget`.
    compact_view: Vec<NodeId>,
    compact_size: usize,
    compact_merging: bool,
    /// Merges whose two halves are built and that are not built themselves:
    /// the queue the pump takes them from (never a scan of the tree).
    ready: BTreeSet<NodeId>,
    /// Nodes found not to fit in `NODE` bytes free: they need a model call,
    /// so their source is not read again.
    not_free: HashSet<NodeId>,
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
            merging: false,
            compact_view: Vec::new(),
            compact_size: 0,
            compact_merging: false,
            ready: BTreeSet::new(),
            not_free: HashSet::new(),
            busy: HashSet::new(),
            budget,
        }
    }

    /// A memory folded from message 0 with every node already built: only
    /// for a chat with no saved checkpoint (a first start after an import or
    /// an older store). A live chat resumes its saved view instead; a fold
    /// gives another view, and every cache entry dies (spec 3.2).
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
        m.seed_ready();
        m
    }

    /// Picks up from a saved `Checkpoint` without reading the whole log:
    /// `frontier` is every stored node at or above the checkpoint's `low` of
    /// its level (with its size); the views' sizes come from `store` by key;
    /// messages `checkpoint.t..t` (a crash between a message and its
    /// checkpoint, or an older build's checkpoint) are appended as live. The
    /// saved views are kept as they are: never refit (spec 3.2). The result
    /// is lazy. None when the checkpoint does not fit the store (a view that
    /// does not tile `[0, checkpoint.t)`, a merged part that is not stored,
    /// more messages in it than `t`).
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
        let (view, view_size) = m.restore(&checkpoint.view, checkpoint.t, store)?;
        m.view = view;
        m.view_size = view_size;
        m.merging = checkpoint.merging;
        if checkpoint.compact_view.is_empty() && checkpoint.t > 0 {
            // An older build's checkpoint: the compaction view starts from
            // the view and is merged down at the next message.
            m.compact_view = m.view.clone();
            m.compact_size = m.view_size;
            m.compact_merging = m.compact_size > m.compact_high();
        } else {
            let (cv, cs) = m.restore(&checkpoint.compact_view, checkpoint.t, store)?;
            m.compact_view = cv;
            m.compact_size = cs;
            m.compact_merging = checkpoint.compact_merging;
        }
        m.t = checkpoint.t;
        m.seed_ready();
        while m.t < t {
            m.push_message(store);
        }
        Some(m)
    }

    /// A saved view's parts and size, if they tile `[0, t)` and fit the store.
    fn restore(
        &mut self,
        parts: &[NodeId],
        t: u64,
        store: &dyn Store,
    ) -> Option<(Vec<NodeId>, usize)> {
        let mut at = 0u64;
        let mut size = 0;
        for part in parts {
            if part.start() != at || part.checked_end().is_none_or(|e| e > t) {
                return None;
            }
            at = part.end();
            if self.is_built(*part) {
                let s = self.size(*part, store)?;
                self.sizes.insert(*part, s);
                size += s;
            } else if part.l == 0 {
                size += PLACEHOLDER.len();
            } else {
                return None;
            }
        }
        (at == t).then(|| (parts.to_vec(), size))
    }

    /// Where this memory stands, for `resume`.
    pub fn checkpoint(&self) -> Checkpoint {
        Checkpoint {
            t: self.t,
            low: self.low.clone(),
            view: self.view.clone(),
            compact_view: self.compact_view.clone(),
            merging: self.merging,
            compact_merging: self.compact_merging,
        }
    }

    /// Drops the sizes of nodes outside the views (they are read from the
    /// store when needed): from here on only the `_in` methods may change it.
    pub fn make_lazy(&mut self) {
        self.lazy = true;
        self.prune();
    }

    pub fn is_lazy(&self) -> bool {
        self.lazy
    }

    fn prune(&mut self) {
        let keep: HashSet<NodeId> = self
            .view
            .iter()
            .chain(self.compact_view.iter())
            .copied()
            .collect();
        self.sizes.retain(|id, _| keep.contains(id));
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

    /// The compaction view (spec 4): what a compaction sees, up to its node.
    pub fn compact_view(&self) -> &[NodeId] {
        &self.compact_view
    }

    pub fn compact_view_size(&self) -> usize {
        self.compact_size
    }

    pub fn budget(&self) -> usize {
        self.budget
    }

    /// Where a batch of the view's merges stops: half the budget (64 KB at 128 KB).
    fn view_low(&self) -> usize {
        self.budget / 2
    }

    /// Past this the compaction view merges: a quarter of the budget (32 KB).
    fn compact_high(&self) -> usize {
        self.budget / 4
    }

    /// Where its batch stops: an eighth of the budget (16 KB).
    fn compact_low(&self) -> usize {
        self.budget / 8
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

    /// Spec 3.2, when the view merges: a new message appends its line, and
    /// nothing else changes, until the view passes the budget; then one
    /// batch merges the most due pairs until it is at most half the budget
    /// (pairs whose parent is built; what it cannot reach yet, it merges at
    /// the next messages). The compaction view (spec 4) gets the same line;
    /// when the chat's view merges it starts again from it, merged down to
    /// an eighth of the budget, and it merges again past a quarter.
    fn push_message(&mut self, store: &dyn Store) {
        let part = NodeId::new(0, self.t);
        self.t += 1;
        let size = self.part_size(part, store);
        self.view.push(part);
        self.view_size += size;
        self.compact_view.push(part);
        self.compact_size += size;
        if self.view_size > self.budget {
            self.merging = true;
        }
        let mut merged = false;
        if self.merging {
            merged = self.merge_down(Which::Chat, self.view_low(), store);
            self.merging = self.view_size > self.view_low();
        }
        if merged {
            self.compact_view = self.view.clone();
            self.compact_size = self.view_size;
            self.compact_merging = true;
        } else if self.compact_size > self.compact_high() {
            self.compact_merging = true;
        }
        if self.compact_merging {
            self.merge_down(Which::Compact, self.compact_low(), store);
            self.compact_merging = self.compact_size > self.compact_low();
        }
    }

    /// Merges the most due built pairs of one view until it is at most
    /// `target` bytes, or no pair's parent is built. Never splits. Whether
    /// anything merged.
    fn merge_down(&mut self, which: Which, target: usize, store: &dyn Store) -> bool {
        let (mut view, mut size) = match which {
            Which::Chat => (std::mem::take(&mut self.view), self.view_size),
            Which::Compact => (std::mem::take(&mut self.compact_view), self.compact_size),
        };
        let mut merged = false;
        while size > target {
            let Some(k) = most_due(&view, self.t, |p| self.is_built(p)) else {
                break;
            };
            let (left, right) = (view[k], view[k + 1]);
            let parent = left.parent();
            let removed = self.part_size(left, store) + self.part_size(right, store);
            let added = self.part_size(parent, store);
            view.splice(k..k + 2, [parent]);
            size = size - removed + added;
            self.sizes.insert(parent, added);
            merged = true;
        }
        match which {
            Which::Chat => {
                self.view = view;
                self.view_size = size;
            }
            Which::Compact => {
                self.compact_view = view;
                self.compact_size = size;
            }
        }
        merged
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

    /// The first message whose view line is not built yet, or T.
    pub fn first(&self) -> u64 {
        self.view
            .iter()
            .find(|p| !self.is_built(**p))
            .map_or(self.t, |p| p.start())
    }

    /// Whether every view line is a summary: an agent turn starts only then (spec 6).
    pub fn settled(&self) -> bool {
        self.view.iter().all(|p| self.is_built(*p))
    }

    /// Spec 4, the order: a message's node starts once fewer than `AHEAD`
    /// lines before it are still unbuilt; a merge starts once both its halves
    /// are built. Message nodes come first, then merges, smallest level
    /// first. Free nodes are built on the spot (and can unlock more); model
    /// calls are capped at `JOBS` running. The work comes from queues: the
    /// unbuilt messages from `low[0]` on, and `ready`; the tree is never
    /// scanned.
    pub fn pump(&mut self, store: &dyn Store) -> Vec<Work> {
        let mut out = Vec::new();
        // Free nodes built in this call: the host stores them only after it returns,
        // and a free parent built in the same call reads its children from here.
        let mut fresh: HashMap<NodeId, String> = HashMap::new();
        'again: loop {
            let mut candidates = Vec::new();
            let mut i = self.low.first().copied().unwrap_or(0);
            let mut unbuilt = 0;
            while i < self.t && unbuilt < AHEAD {
                let id = NodeId::new(0, i);
                if !self.is_built(id) {
                    unbuilt += 1;
                    candidates.push(id);
                }
                i += 1;
            }
            candidates.extend(self.ready.iter().copied());
            for id in candidates {
                if self.busy.contains(&id) {
                    continue;
                }
                if !self.not_free.contains(&id) {
                    let free = free_text(id, store, &fresh);
                    if store.failed() {
                        return out;
                    }
                    if let Some(text) = free {
                        self.build(id, text.len());
                        fresh.insert(id, text.clone());
                        out.push(Work::Free { node: id, text });
                        continue 'again;
                    }
                    self.not_free.insert(id);
                }
                // Deviation (README): JOBS caps model calls, and a free node
                // is none, so free nodes are built even with JOBS running.
                if self.busy.len() < JOBS {
                    self.busy.insert(id);
                    out.push(Work::Model { node: id });
                }
            }
            return out;
        }
    }

    /// Fills `ready` after a load or a resume: every merge both of whose
    /// halves are built and that is not built itself.
    fn seed_ready(&mut self) {
        self.ready.clear();
        let levels = self.low.len();
        for l in 0..levels {
            let below = self.low[l];
            let mut p = self.low.get(l + 1).copied().unwrap_or(0);
            while 2 * p + 1 < below {
                let parent = NodeId::new(l as u32 + 1, p);
                if !self.is_built(parent) {
                    self.ready.insert(parent);
                }
                p += 1;
            }
        }
        let frontier: Vec<NodeId> = self.frontier.keys().copied().collect();
        for id in frontier {
            self.queue_parent(id);
        }
    }

    /// Queues `id`'s parent when both halves are built.
    fn queue_parent(&mut self, id: NodeId) {
        let sibling = NodeId::new(id.l, id.i ^ 1);
        let parent = id.parent();
        if self.is_built(id)
            && self.is_built(sibling)
            && !self.is_built(parent)
            && parent.end() <= self.t
        {
            self.ready.insert(parent);
        }
    }

    /// A model call for `node` produced `text` (the host stored and fsynced it).
    /// Call `pump` afterwards. Not for a lazy memory (`complete_in`).
    pub fn complete(&mut self, node: NodeId, text: &str) -> Result<(), NotRunning> {
        debug_assert!(!self.lazy, "a lazy memory completes with complete_in");
        self.complete_in(node, text, &NoStore)
    }

    /// `complete` for any memory. The store is not needed any more (building
    /// a node never merges, spec 3.2); it stays for the hosts' signature.
    pub fn complete_in(
        &mut self,
        node: NodeId,
        text: &str,
        _store: &dyn Store,
    ) -> Result<(), NotRunning> {
        // Only a call `pump` started and that is still running may build its
        // node: a second complete, or one for a node nobody asked for, would
        // count an unrelated text as that node's summary.
        if !self.busy.remove(&node) {
            return Err(NotRunning(node));
        }
        self.build(node, text.len());
        Ok(())
    }

    /// A model call for `node` failed: it can be started again (after the host's
    /// fixed retry wait).
    pub fn fail(&mut self, node: NodeId) {
        self.busy.remove(&node);
    }

    /// Records a built node. The views change only in the size of a
    /// message line that was a placeholder: building never merges.
    fn build(&mut self, id: NodeId, len: usize) {
        if self.is_built(id) {
            return;
        }
        self.frontier.insert(id, len);
        self.ready.remove(&id);
        self.not_free.remove(&id);
        self.advance_low(id.l);
        // Only a level-0 part can be in a view unbuilt (a parent enters only once built).
        if id.l == 0 {
            let mut in_view = false;
            if let Ok(k) = self.view.binary_search_by_key(&id.start(), |p| p.start()) {
                if self.view[k] == id {
                    self.view_size = self.view_size - PLACEHOLDER.len() + len;
                    in_view = true;
                }
            }
            if let Ok(k) = self
                .compact_view
                .binary_search_by_key(&id.start(), |p| p.start())
            {
                if self.compact_view[k] == id {
                    self.compact_size = self.compact_size - PLACEHOLDER.len() + len;
                    in_view = true;
                }
            }
            if in_view {
                self.sizes.insert(id, len);
            }
        }
        self.queue_parent(id);
    }

    /// Moves `low` past built nodes; their sizes leave the frontier (a lazy
    /// memory keeps only the views', see `prune`).
    fn advance_low(&mut self, l: u32) {
        let l = l as usize;
        if self.low.len() <= l {
            self.low.resize(l + 1, 0);
        }
        while let Some(size) = self.frontier.remove(&NodeId::new(l as u32, self.low[l])) {
            self.sizes.insert(NodeId::new(l as u32, self.low[l]), size);
            self.low[l] += 1;
        }
        if self.lazy && self.sizes.len() > 4 * (self.view.len() + self.compact_view.len()) + 4096 {
            self.prune();
        }
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
