//! The compactor runner (section 4): after every append, completion and
//! failure it pumps the core, stores free nodes, and starts one worker thread
//! per model call (the core caps them at `JOBS`). Workers never hold the
//! chat's lock while the model runs.

use std::collections::hash_map::DefaultHasher;
use std::collections::{BTreeMap, BTreeSet, HashMap, HashSet};
use std::hash::{Hash, Hasher};
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::{Duration, Instant};

use optchat_core::{
    block_cuts, compact_request, finish_line, size_check_in, CompactRequest, Memory, NodeId,
    SizeCheck, Work,
};

use crate::clock::Clock;
use crate::db::Db;
use crate::model::{CompactModel, Followup, ModelError, Reply};
use crate::report::{Report, Reporter};

/// Everything behind the chat's one mutex.
pub struct State {
    pub memory: Memory,
    pub store: Db,
    /// Messages appended since the last saved checkpoint.
    pub appended: u64,
    /// Nodes whose last call failed, with their first error.
    pub failing: BTreeMap<NodeId, String>,
    /// Failing nodes whose error repeats on every try (a request error):
    /// settle does not wait for them.
    pub stuck: BTreeSet<NodeId>,
    /// Every stuck node built since the last one got stuck.
    pub recovered: bool,
    pub closed: bool,
    /// Set by a failed write; the chat stops writing until a restart.
    pub fatal: Option<String>,
    /// Reports raised under the lock, delivered after it is released.
    pub reports: Vec<Report>,
}

impl State {
    pub fn writable(&self) -> bool {
        !self.closed && self.fatal.is_none()
    }

    /// Saves where the memory stands (`db::checkpoint`); a failure costs
    /// only a longer fold at the next start, so it is reported, not fatal.
    pub fn save_checkpoint(&mut self) {
        match crate::db::checkpoint::save(&mut self.store, &self.memory) {
            Ok(()) => self.appended = 0,
            Err(e) => self.reports.push(Report::Checkpoint {
                error: e.to_string(),
            }),
        }
    }

    /// A write failed (its transaction rolled back): writing stops here
    /// until a restart, which reopens the database.
    pub fn set_fatal(&mut self, error: String) {
        if self.fatal.is_none() {
            self.reports.push(Report::Fatal {
                error: error.clone(),
            });
            self.fatal = Some(error);
        }
    }
}

pub struct Shared {
    pub state: Mutex<State>,
    /// Signalled on every change of the view or the compactor (section 6: settle
    /// is woken on every fit).
    pub changed: Condvar,
    pub model: Arc<dyn CompactModel>,
    /// Builds a node the model declined (None: retry the same call).
    pub fallback: Option<Arc<dyn CompactModel>>,
    pub clock: Arc<dyn Clock>,
    /// The compactor's system prompt, constant for the process.
    pub system: String,
    pub retry: Duration,
    pub reporter: Reporter,
    /// The marked prefixes being written (single-flight, spec 3.3).
    pub flight: Flight,
}

/// Single-flight of cache writes (spec 3.3, gist 3c190e0): a call whose
/// marked prefix another call is writing waits until that call's response
/// starts (`CompactModel::call_started`), when the cache entry exists;
/// otherwise both pay to write it. It matters because compactions start
/// many at a time on one prefix. A model that cannot see its response start
/// reports it with the reply.
#[derive(Default)]
pub struct Flight {
    state: Mutex<FlightState>,
    done: Condvar,
}

#[derive(Default)]
struct FlightState {
    /// Prefixes a call is writing, its response not started yet.
    writing: HashSet<u64>,
    /// Prefixes whose writer's response started, with the last time a call
    /// went on them: their cache entry exists, so calls go without waiting.
    written: HashMap<u64, Instant>,
}

/// How long a written prefix counts as cached after its last call: the
/// API's default cache lifetime (5 minutes, refreshed by every read). A
/// call after it writes again.
pub const FLIGHT_TTL: Duration = Duration::from_secs(300);

/// Written prefixes kept before expired ones are dropped.
const FLIGHT_KEEP: usize = 1024;

impl Flight {
    /// Waits while another call writes `key`. True: this call writes it (the
    /// caller then calls `started` or `leave`); false: it is cached.
    fn enter(&self, key: u64) -> bool {
        let mut st = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        loop {
            if st.writing.contains(&key) {
                st = self
                    .done
                    .wait(st)
                    .unwrap_or_else(std::sync::PoisonError::into_inner);
                continue;
            }
            let now = Instant::now();
            if let Some(at) = st.written.get_mut(&key) {
                if now.duration_since(*at) <= FLIGHT_TTL {
                    *at = now;
                    return false;
                }
            }
            st.written.remove(&key);
            st.writing.insert(key);
            return true;
        }
    }

    /// The writer's response started: its entry exists, every waiting call goes.
    fn started(&self, key: u64) {
        let mut st = self
            .state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        st.writing.remove(&key);
        let now = Instant::now();
        if st.written.len() >= FLIGHT_KEEP {
            st.written
                .retain(|_, at| now.duration_since(*at) <= FLIGHT_TTL);
        }
        st.written.insert(key, now);
        drop(st);
        self.done.notify_all();
    }

    /// The writer failed before its response started: the next call writes.
    fn leave(&self, key: u64) {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
            .writing
            .remove(&key);
        self.done.notify_all();
    }
}

/// The prefix a compaction's cache mark covers: its system prompt and its
/// view up to the last whole 4-line block.
pub fn marked_key(request: &CompactRequest) -> u64 {
    let end = block_cuts(&request.context).last().copied().unwrap_or(0);
    let mut h = DefaultHasher::new();
    request.system.hash(&mut h);
    request.context[..end].hash(&mut h);
    h.finish()
}

/// The model behind a `Flight`: a node's first call waits while another
/// call writes the same marked prefix, and holds it until its response
/// starts.
struct Gated<'a> {
    inner: &'a dyn CompactModel,
    flight: &'a Flight,
    key: u64,
}

impl CompactModel for Gated<'_> {
    fn call(&self, request: &CompactRequest, followups: &[Followup]) -> Result<Reply, ModelError> {
        if !followups.is_empty() {
            return self.inner.call(request, followups);
        }
        if !self.flight.enter(self.key) {
            return self.inner.call(request, followups);
        }
        let begun = std::sync::atomic::AtomicBool::new(false);
        let started = || {
            if !begun.swap(true, std::sync::atomic::Ordering::SeqCst) {
                self.flight.started(self.key);
            }
        };
        let reply = self.inner.call_started(request, followups, &started);
        if !begun.load(std::sync::atomic::Ordering::SeqCst) {
            // Failed before its response started: nothing was written.
            self.flight.leave(self.key);
        }
        reply
    }

    fn end(&self, request: &CompactRequest) {
        self.inner.end(request);
    }
}

impl Shared {
    pub fn lock(&self) -> MutexGuard<'_, State> {
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Releases the lock, then delivers the reports raised under it.
    pub fn unlock(&self, mut st: MutexGuard<'_, State>) {
        let reports = std::mem::take(&mut st.reports);
        drop(st);
        for r in &reports {
            (self.reporter)(r);
        }
    }
}

/// Pumps the core and starts what it asks for. Called with the lock held
/// after every append, completion and failure, and once at open.
pub fn drive(shared: &Arc<Shared>, st: &mut State) {
    if st.writable() {
        let work = st.memory.pump(&st.store);
        // Free nodes first, in one transaction: the core already counts them
        // as built, and a model request built below reads them (as children
        // or as view lines).
        let free: Vec<(NodeId, &str)> = work
            .iter()
            .filter_map(|w| match w {
                Work::Free { node, text } => Some((*node, text.as_str())),
                Work::Model { .. } => None,
            })
            .collect();
        if let Err(e) = st.store.append_nodes(&free) {
            st.set_fatal(format!("writing {} free nodes: {e}", free.len()));
        }
        if st.writable() {
            for w in work {
                if let Work::Model { node } = w {
                    start(shared, st, node);
                }
            }
        }
    }
    shared.changed.notify_all();
}

fn start(shared: &Arc<Shared>, st: &mut State, node: NodeId) {
    let request = match compact_request(&st.memory, &st.store, node, shared.system.clone()) {
        Ok(request) => request,
        // A built node without its text: the store lost data; no model call
        // may write a node from the stand-in, and no retry can bring it back.
        Err(missing) => {
            st.memory.fail(node);
            st.set_fatal(format!("building node {}: {missing}", node.name()));
            return;
        }
    };
    let sh = shared.clone();
    let spawned = thread::Builder::new()
        .name(format!("optchat-compact-{}", node.name()))
        .spawn(move || job(sh, request));
    if let Err(e) = spawned {
        // No thread, no call: free the slot so a later pump starts it again.
        st.memory.fail(node);
        st.reports.push(Report::NodeFailed {
            node,
            error: format!("cannot start a worker: {e}"),
        });
    }
}

/// One node: the model conversation without the lock, then store and complete
/// under it; or, on failure, the fixed retry wait with the node still busy
/// (as the spec's pump does), then release it and pump again.
fn job(shared: Arc<Shared>, request: CompactRequest) {
    let node = request.node;
    let key = marked_key(&request);
    let gated = |model: &'_ Arc<dyn CompactModel>| {
        let model: &dyn CompactModel = &**model;
        run_node(
            &Gated {
                inner: model,
                flight: &shared.flight,
                key,
            },
            &request,
        )
    };
    let result = match gated(&shared.model) {
        // A refusal repeats on every try: ask the fallback model, in a fresh
        // conversation (the declined model's blocks mean nothing to it).
        Err(declined) if declined.refused => match &shared.fallback {
            Some(fallback) => gated(fallback).map_err(|e| {
                ModelError::new(format!("{declined}; the fallback model failed too: {e}"))
            }),
            None => Err(declined),
        },
        other => other,
    };
    let mut st = shared.lock();
    if !st.writable() {
        return;
    }
    let error = match result {
        Ok(text) => {
            // The node and its completion: the row commits before the core
            // counts it built, so a crash leaves it either stored or to build.
            if let Err(e) = st.store.append_nodes(&[(node, &text)]) {
                st.set_fatal(format!("writing node {}: {e}", node.name()));
                shared.changed.notify_all();
                return shared.unlock(st);
            }
            st.failing.remove(&node);
            if st.stuck.remove(&node) && st.stuck.is_empty() {
                st.recovered = true;
            }
            {
                let s = &mut *st;
                if let Err(e) = s.memory.complete_in(node, &text, &s.store) {
                    s.set_fatal(format!("completing node {}: {e}", node.name()));
                }
            }
            drive(&shared, &mut st);
            return shared.unlock(st);
        }
        Err(e) => e,
    };
    let class = crate::model::error_class(&error.message).filter(|c| c.permanent());
    if !st.failing.contains_key(&node) {
        st.reports.push(Report::NodeFailed {
            node,
            error: error.message.clone(),
        });
        st.failing.insert(node, error.message);
    }
    if let Some(class) = &class {
        if st.stuck.insert(node) {
            st.recovered = false;
            st.reports.push(Report::NodeStuck {
                node,
                class: class.to_string(),
            });
        }
    }
    shared.changed.notify_all();
    shared.unlock(st);
    shared.clock.sleep(if class.is_some() {
        crate::STUCK_RETRY
    } else {
        shared.retry
    });
    let mut st = shared.lock();
    if !st.writable() {
        return;
    }
    st.memory.fail(node);
    drive(&shared, &mut st);
    shared.unlock(st);
}

/// The model conversation for one node with the size loop (section 4.3): each
/// over-long reply is answered in the SAME conversation with where the limit
/// cuts it; after `TRIES` the shortest try wins.
/// The model's conversation is ended once, whatever the outcome, and a
/// line whose call showed only part of its message starts with the cut.
pub fn run_node(model: &dyn CompactModel, request: &CompactRequest) -> Result<String, ModelError> {
    let result = size_loop(model, request);
    model.end(request);
    result.map(|line| finish_line(request, &line))
}

fn size_loop(model: &dyn CompactModel, request: &CompactRequest) -> Result<String, ModelError> {
    let mut followups: Vec<Followup> = Vec::new();
    let mut tries: Vec<String> = Vec::new();
    // A cut message's line gets the cut prefix in front (`finish_line`), so
    // the reply is measured against what is left of NODE; a reply that
    // already starts with the prefix is measured without it.
    let room = request.room();
    loop {
        let reply = model.call(request, &followups)?;
        let text = match &request.cut {
            Some(prefix) => reply
                .text
                .trim()
                .strip_prefix(prefix.trim_end())
                .unwrap_or(&reply.text),
            None => &reply.text,
        };
        tries.push(text.to_string());
        match size_check_in(&tries, room) {
            SizeCheck::Accept(text) => return Ok(text),
            SizeCheck::Fail => return Err(ModelError::new("empty reply")),
            SizeCheck::Retry(retry) => followups.push(Followup { reply, retry }),
        }
    }
}

/// The node a start-up probe asks for; no tree reaches level 63.
pub const PROBE_NODE: NodeId = NodeId::new(63, 0);

/// Builds one tiny node through `model`, as the compactor would (one
/// conversation, the size loop, `end`), so a host can say at start that its
/// compactor cannot build anything instead of every turn waiting silently.
pub fn probe(model: &dyn CompactModel, system: &str) -> Result<String, ModelError> {
    let request = CompactRequest {
        node: PROBE_NODE,
        system: system.to_owned(),
        context: "<chat>\n</chat>".to_owned(),
        step: "This is a start-up check of the compactor. Compress this message into one \
               line, in at most 64 bytes:\nuser: ping"
            .to_owned(),
        cut: None,
    };
    run_node(model, &request)
}
