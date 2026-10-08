//! Pins the prompt-cache rate (spec 3.3, gist 3c190e0): a synthetic
//! 3,000-message chat replayed against a model of Anthropic's cache. Entries
//! are stored only at cache marks; a request reads the longest marked prefix
//! it finds looking back up to 20 blocks from each of its marks; an entry
//! lives 5 minutes from its last read. Turns mark the system prompt, the
//! view's last whole 4-line block and the request's end; each tool step of a
//! turn is one more request. Compactions are marked the same way over their
//! own view. The spec measured turns 98.6% and compactions 96.2%.
//!
//! The rate is bytes read from the cache over the request's prefix (every
//! byte before what the request adds: the new message or task, or a step's
//! new tool call and result).

use std::cell::RefCell;
use std::collections::hash_map::DefaultHasher;
use std::collections::HashMap;
use std::hash::{Hash, Hasher};

use optchat_core::*;

#[derive(Default)]
struct Mem {
    messages: RefCell<Vec<(Kind, String)>>,
    nodes: RefCell<HashMap<NodeId, String>>,
}

impl Store for Mem {
    fn message(&self, i: u64) -> (Kind, String) {
        self.messages.borrow()[i as usize].clone()
    }
    fn node(&self, id: NodeId) -> Option<String> {
        self.nodes.borrow().get(&id).cloned()
    }
}

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn range(&mut self, lo: u64, hi: u64) -> u64 {
        lo + self.next() % (hi - lo)
    }
}

fn summary(node: NodeId) -> String {
    let mut h = DefaultHasher::new();
    node.hash(&mut h);
    let len = if node.l == 0 { 180 } else { 380 } + (h.finish() % 132) as usize;
    let mut s = format!("sum {}: ", node.name());
    while s.len() < len {
        s.push_str("item; ");
    }
    s.truncate(len);
    s
}

const LIFE: f64 = 300.0;
const LOOKBACK: usize = 20;

#[derive(Default)]
struct Cache {
    entries: HashMap<u64, f64>,
}

struct Request {
    /// Cumulative hash and byte length at the end of each block.
    ends: Vec<(u64, usize)>,
    marks: Vec<usize>,
}

impl Request {
    fn new(blocks: &[(&str, bool)]) -> Request {
        let mut h = DefaultHasher::new();
        let mut len = 0;
        let mut ends = Vec::new();
        let mut marks = Vec::new();
        for (k, (text, mark)) in blocks.iter().enumerate() {
            text.hash(&mut h);
            len += text.len();
            ends.push((h.finish(), len));
            if *mark {
                marks.push(k);
            }
        }
        Request { ends, marks }
    }
}

impl Cache {
    /// Bytes read from the cache; then the request's marks are written.
    fn send(&mut self, r: &Request, now: f64) -> usize {
        let mut read = 0;
        for &m in &r.marks {
            for j in (m.saturating_sub(LOOKBACK)..=m).rev() {
                let (key, len) = r.ends[j];
                if self.entries.get(&key).is_some_and(|t| now - t <= LIFE) {
                    self.entries.insert(key, now);
                    read = read.max(len);
                    break;
                }
            }
        }
        for &m in &r.marks {
            self.entries.insert(r.ends[m].0, now);
        }
        read
    }
}

#[derive(Default)]
struct Rate {
    read: usize,
    prefix: usize,
}

impl Rate {
    fn pct(&self) -> f64 {
        100.0 * self.read as f64 / self.prefix as f64
    }
}

/// The marked blocks of a call: system, the view in 4-line blocks (a mark
/// on the last whole one), then `tail` blocks (a mark on the last).
fn blocks<'a>(system: &'a str, view: &'a str, tail: &[&'a str]) -> Vec<(&'a str, bool)> {
    let pieces = block_pieces(view);
    let whole = pieces.len() - 1;
    let mut out = vec![(system, true)];
    for (k, p) in pieces.into_iter().enumerate() {
        out.push((p, whole > 0 && k + 1 == whole));
    }
    for (k, t) in tail.iter().enumerate() {
        out.push((*t, k + 1 == tail.len()));
    }
    out
}

#[test]
fn a_3000_message_chat_reads_98_percent_of_turns_and_96_of_compactions_from_the_cache() {
    let system = format!(
        "{}\n\n# Instructions\n\n{}",
        CompactPrompt::Taelin.text("Chief"),
        "The user's own instructions. ".repeat(140)
    );
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    let mut cache = Cache::default();
    let (mut turns, mut compactions) = (Rate::default(), Rate::default());
    let mut rng = Rng(0x2545F4914F6CDD1D);
    let mut now = 0.0f64;
    let total = 3_000u64;

    // Logs one message, then runs the compactor until it is idle, each
    // model call as one marked request at `now`.
    let mut log = |memory: &mut Memory, kind: Kind, text: String, now: f64, cache: &mut Cache| {
        store.messages.borrow_mut().push((kind, text));
        memory.append();
        loop {
            let work = memory.pump(&store);
            if work.is_empty() {
                break;
            }
            for w in work {
                match w {
                    Work::Free { node, text } => {
                        store.nodes.borrow_mut().insert(node, text);
                    }
                    Work::Model { node } => {
                        let req = compact_request(memory, &store, node, system.clone()).unwrap();
                        let b = blocks(&system, &req.context, &[&req.step]);
                        let r = Request::new(&b);
                        compactions.read += cache.send(&r, now);
                        compactions.prefix += system.len() + req.context.len();
                        let text = summary(node);
                        store.nodes.borrow_mut().insert(node, text.clone());
                        memory.complete(node, &text).unwrap();
                    }
                }
            }
        }
    };

    while memory.len() < total {
        // A turn: the view rendered before the new message is logged.
        assert!(memory.settled());
        let view = render_view(&memory, &store).text;
        let ask = format!("user asks for step {} of the work", memory.len());
        let mut tail: Vec<String> = vec![ask.clone()];
        let first = {
            let t: Vec<&str> = tail.iter().map(String::as_str).collect();
            Request::new(&blocks(&system, &view, &t))
        };
        turns.read += cache.send(&first, now);
        turns.prefix += system.len() + view.len();
        log(&mut memory, Kind::User, ask, now, &mut cache);
        let steps = rng.range(0, 13);
        for s in 0..steps {
            now += rng.range(3, 20) as f64;
            let call = format!("tool: shell {{\"cmd\": \"step {s} of {}\"}}", memory.len());
            let result = "r".repeat(rng.range(200, 6_000) as usize);
            let before: usize = system.len() + view.len() + tail.iter().map(String::len).sum::<usize>();
            tail.push(call.clone());
            tail.push(result.clone());
            let t: Vec<&str> = tail.iter().map(String::as_str).collect();
            let r = Request::new(&blocks(&system, &view, &t));
            turns.read += cache.send(&r, now);
            turns.prefix += before;
            log(&mut memory, Kind::Tool, call, now, &mut cache);
            log(&mut memory, Kind::Echo, result, now, &mut cache);
        }
        now += rng.range(3, 20) as f64;
        let reply = "Done: ".to_string() + &"a".repeat(rng.range(50, 900) as usize);
        log(&mut memory, Kind::Talk, reply, now, &mut cache);
        // The user reads and answers; one turn in 100 after a long break.
        now += if rng.range(0, 100) == 0 {
            rng.range(600, 7_200) as f64
        } else {
            rng.range(15, 240) as f64
        };
    }
    eprintln!(
        "cache replay over {} messages: turns {:.2}% ({} of {} bytes), compactions {:.2}% ({} of {} bytes)",
        memory.len(),
        turns.pct(),
        turns.read,
        turns.prefix,
        compactions.pct(),
        compactions.read,
        compactions.prefix
    );
    assert!(turns.pct() >= 98.0, "turns read {:.2}%", turns.pct());
    assert!(compactions.pct() >= 96.0, "compactions read {:.2}%", compactions.pct());
}
