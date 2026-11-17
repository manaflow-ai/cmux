//! Changes close together share the summaries above them; the change book
//! builds each shared summary once, after every change below it, not once per
//! change (2026-11-17: redescribing 8 nearby screenshot notes queued 128
//! rebuilds, 16 per note, and took 41 minutes of serial model calls).

use std::collections::BTreeMap;
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use optchat_chief::inspect::edit::Editor;
use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, Kind, ModelError, NodeId, OptChat, Reply,
    SystemClock,
};

const WAIT: Duration = Duration::from_secs(60);

/// A compactor that counts its calls per node and, while `hold` is set,
/// waits before answering (so a test can queue changes behind a running one).
#[derive(Default)]
struct Counting {
    calls: Mutex<BTreeMap<NodeId, usize>>,
    order: Mutex<Vec<NodeId>>,
    hold: Mutex<bool>,
    released: Condvar,
}

impl Counting {
    fn total(&self) -> usize {
        self.calls.lock().unwrap().values().sum()
    }
    fn release(&self) {
        *self.hold.lock().unwrap() = false;
        self.released.notify_all();
    }
}

impl CompactModel for Counting {
    fn call(&self, request: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        *self.calls.lock().unwrap().entry(request.node).or_default() += 1;
        self.order.lock().unwrap().push(request.node);
        let mut held = self.hold.lock().unwrap();
        while *held {
            held = self.released.wait(held).unwrap();
        }
        drop(held);
        let input = request.step.split_once("<input>\n").map_or("", |(_, r)| r);
        let line = format!(
            "S{} {}",
            request.node.name(),
            input
                .split_whitespace()
                .take(30)
                .collect::<Vec<_>>()
                .join(" ")
        );
        Ok(Reply::text(
            optchat_core::cut_at_bytes(&line, 400).to_owned(),
        ))
    }
}

/// The built lines from message `id`'s own line up.
fn above(chat: &OptChat, id: u64) -> Vec<NodeId> {
    (0..63)
        .map(|l| NodeId::new(l, id >> l))
        .take_while(|n| chat.node(*n).is_some())
        .collect()
}

#[test]
fn nearby_changes_build_each_shared_summary_once_and_after_every_change_below_it() {
    let dir = tempfile::tempdir().unwrap();
    let model = Arc::new(Counting::default());
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    let chat = Arc::new(
        OptChat::open_with(
            dir.path().join("chat"),
            config,
            model.clone(),
            Arc::new(SystemClock),
        )
        .unwrap(),
    );
    for k in 0..64u64 {
        chat.append(
            Kind::User,
            &format!("message {k} {}", "filler words ".repeat(60)),
        )
        .unwrap();
    }
    assert!(chat.wait_idle(None, Some(WAIT)), "the compactor settles");
    let editor = Editor::open(chat.clone(), dir.path());
    model.calls.lock().unwrap().clear();
    model.order.lock().unwrap().clear();

    // The first change's rebuild is held in the model, so the next changes
    // queue behind it, as 8 redescriptions arriving within seconds did.
    *model.hold.lock().unwrap() = true;
    let targets = [5u64, 6, 9, 12];
    for &id in &targets {
        editor
            .redescribe(id, &format!("NEWWORDS{id} {}", "fresh words ".repeat(60)))
            .unwrap();
        if id == targets[0] {
            let deadline = std::time::Instant::now() + WAIT;
            while model.total() == 0 {
                assert!(std::time::Instant::now() < deadline, "no rebuild started");
                std::thread::sleep(Duration::from_millis(5));
            }
        }
    }
    model.release();
    assert!(editor.wait_rebuilt(WAIT));

    let mut wanted: BTreeMap<NodeId, usize> = BTreeMap::new();
    for &id in &targets {
        for n in above(&chat, id) {
            *wanted.entry(n).or_default() += 1;
        }
    }
    let calls = model.calls.lock().unwrap().clone();
    let per_change: usize = wanted.values().sum();
    let total: usize = calls.values().sum();
    // The first change's own line was running when the others came; it is
    // not shared. Every other line is built once.
    assert_eq!(
        total,
        wanted.len(),
        "each summary once: {total} calls for {} lines ({per_change} if built per change): {calls:?}"
    );
    assert!(changes_left(&editor).is_empty(), "nothing stale");

    // Bottom-up: a summary is built after every changed line below it.
    let order = model.order.lock().unwrap().clone();
    let at = |n: NodeId| order.iter().rposition(|m| *m == n).unwrap();
    for (node, _) in &wanted {
        for &id in &targets {
            let leaf = NodeId::new(0, id);
            if node.l > 0 && id >> node.l == node.i {
                assert!(
                    at(leaf) < at(*node),
                    "{} before {}",
                    node.name(),
                    leaf.name()
                );
            }
        }
    }
    // Every change's own line holds its new words.
    let leafs: Vec<String> = targets
        .iter()
        .map(|id| chat.node(NodeId::new(0, *id)).unwrap())
        .collect();
    for (id, leaf) in targets.iter().zip(&leafs) {
        assert!(leaf.contains(&format!("NEWWORDS{id}")), "{leaf}");
    }
}

fn changes_left(editor: &Editor) -> Vec<serde_json::Value> {
    editor.changes()["stale"].as_array().unwrap().clone()
}
