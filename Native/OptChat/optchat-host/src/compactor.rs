//! The compactor runner (section 4): after every append, completion and
//! failure it pumps the core, stores free nodes, and starts one worker thread
//! per model call (the core caps them at `JOBS`). Workers never hold the
//! chat's lock while the model runs.

use std::collections::BTreeMap;
use std::sync::{Arc, Condvar, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

use optchat_core::{
    compact_request, finish_line, size_check_in, CompactRequest, Memory, NodeId, SizeCheck, Work,
};

use crate::clock::Clock;
use crate::files::FileStore;
use crate::model::{CompactModel, Followup, ModelError};
use crate::report::{Report, Reporter};

/// Everything behind the chat's one mutex.
pub struct State {
    pub memory: Memory,
    pub store: FileStore,
    /// Nodes whose last call failed, with their first error.
    pub failing: BTreeMap<NodeId, String>,
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

    /// A write failed: the file may end in a partial line that the next
    /// append would glue onto, so writing stops here. Load repairs it.
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
        // Free nodes first: the core already counts them as built, and a model
        // request built below reads them (as children or as view lines).
        for w in &work {
            if let Work::Free { node, text } = w {
                if let Err(e) = st.store.append_node(*node, text) {
                    st.set_fatal(format!("writing node {}: {e}", node.name()));
                    break;
                }
            }
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
    let request = compact_request(&st.memory, &st.store, node, shared.system.clone());
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
    let result = match run_node(&*shared.model, &request) {
        // A refusal repeats on every try: ask the fallback model, in a fresh
        // conversation (the declined model's blocks mean nothing to it).
        Err(declined) if declined.refused => match &shared.fallback {
            Some(fallback) => run_node(&**fallback, &request).map_err(|e| {
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
            if let Err(e) = st.store.append_node(node, &text) {
                st.set_fatal(format!("writing node {}: {e}", node.name()));
                shared.changed.notify_all();
                return shared.unlock(st);
            }
            st.failing.remove(&node);
            st.memory.complete(node, &text);
            drive(&shared, &mut st);
            return shared.unlock(st);
        }
        Err(e) => e,
    };
    if !st.failing.contains_key(&node) {
        st.reports.push(Report::NodeFailed {
            node,
            error: error.message.clone(),
        });
        st.failing.insert(node, error.message);
    }
    shared.changed.notify_all();
    shared.unlock(st);
    shared.clock.sleep(shared.retry);
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
