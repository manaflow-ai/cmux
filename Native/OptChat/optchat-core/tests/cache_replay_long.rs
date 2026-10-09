//! The prompt-cache rate over a long chat (10,000+ messages): many view batch
//! merges (128 KB down to 64 KB), deep tree levels, human gaps between turns,
//! turns that arrive while compactions still run, and turns with many tool
//! steps. The cache model is Anthropic's: entries only at cache marks, a mark
//! reads the longest entry it finds looking back up to 20 blocks, an entry
//! lives `ttl` from its last read or write.
//!
//! A turn's request is laid out as Claude Code sends it (measured with a
//! capture proxy, Claude Code 2.1.287, 2026-10-08): the harness's tools and
//! system prompt plus our system prompt (marked), the view in 4-line blocks
//! with our ONE mark (`mark_piece`), the new messages, then Claude Code's
//! environment message (date, cwd, model) with its own mark at the request
//! end. Each tool step of a turn is one more request, the end mark moved to
//! its last block.
//!
//! The rate of a turn is bytes read from the cache over the request's prefix
//! (the harness prefix, our system prompt and the view: every byte before
//! what the turn adds).

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

/// Blocks the API looks back from a mark for an earlier entry.
const LOOKBACK: usize = 20;

/// Cache entries: the prefix hash at a marked block's end, and when it was
/// last read or written.
struct Cache {
    ttl: f64,
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
        assert!(marks.len() <= 4, "the API takes at most 4 marks");
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
                if self.entries.get(&key).is_some_and(|t| now - t <= self.ttl) {
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

/// A Claude Code request: harness prefix and our system prompt (marked), the
/// view pieces with our mark on `mark`, the turn's blocks, then the
/// environment message with the end mark (on the last block when the turn
/// has tool steps after it).
fn turn_request(
    harness: &str,
    system: &str,
    pieces: &[&str],
    mark: Option<usize>,
    turn: &[String],
    env: &str,
) -> Request {
    let mut out: Vec<(&str, bool)> = vec![(harness, true), (system, true)];
    for (k, p) in pieces.iter().enumerate() {
        out.push((p, mark == Some(k)));
    }
    let (first, steps) = turn.split_first().expect("the new messages");
    out.push((first, false));
    out.push((env, steps.is_empty()));
    for (k, s) in steps.iter().enumerate() {
        out.push((s, k + 1 == steps.len()));
    }
    Request::new(&out)
}

/// Turns per window for the minimum rate.
const WINDOW: usize = 50;

struct Run {
    /// The highest tree level in the final view.
    levels: u32,
    /// Per turn: bytes read and prefix bytes of its first request, whether
    /// the gap before it was longer than the TTL, and whether the view
    /// changed before the last turn's mark (a batch merge).
    turns: Vec<(usize, usize, bool, bool)>,
    merges: usize,
    compactions: (usize, usize),
    messages: u64,
    resumes_checked: usize,
}

fn run(ttl: f64, total: u64) -> Run {
    let system = format!(
        "{}\n\n# Instructions\n\n{}",
        CompactPrompt::Taelin.text("Chief"),
        "The user's own instructions. ".repeat(140)
    );
    // Claude Code's tools and its own system prompt: about 20k tokens.
    let harness = "tool schema; ".repeat(6_000);
    let env = "# Environment\nYou have been invoked in the following environment: ...\nToday's date is 2026-10-08.\n".repeat(4);
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    let mut cache = Cache {
        ttl,
        entries: HashMap::new(),
    };
    let mut rng = Rng(0x2545F4914F6CDD1D);
    let mut now = 0.0f64;
    // When the compactor is busy until: a turn waits for it (section 6).
    let mut busy_until = 0.0f64;
    let mut compactions = (0usize, 0usize);
    let mut turns = Vec::new();
    let mut merges = 0usize;
    let mut last_mark: Option<String> = None;
    let mut resumes_checked = 0usize;
    let mut next_resume = 60_000usize;

    // Logs one message at `now`, then runs the compactor until it is idle;
    // its calls run in rounds of a second each, after `now`.
    let mut log = |memory: &mut Memory,
                   kind: Kind,
                   text: String,
                   now: f64,
                   cache: &mut Cache,
                   busy_until: &mut f64| {
        store.messages.borrow_mut().push((kind, text));
        memory.append();
        let mut at = now.max(*busy_until);
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
                        at += 1.0;
                        let req = compact_request(memory, &store, node, system.clone()).unwrap();
                        let pieces = block_pieces(&req.context);
                        let mark = mark_piece(&req.context, None);
                        let r = turn_request(
                            &harness,
                            &system,
                            &pieces,
                            mark,
                            std::slice::from_ref(&req.step),
                            &env,
                        );
                        compactions.0 += cache.send(&r, at);
                        compactions.1 += harness.len() + system.len() + req.context.len();
                        let text = summary(node);
                        store.nodes.borrow_mut().insert(node, text.clone());
                        memory.complete(node, &text).unwrap();
                    }
                }
            }
        }
        *busy_until = at;
    };

    // The first turn has no turn before it: it counts as after a long gap.
    let mut last_gap = f64::INFINITY;
    while memory.len() < total {
        // A turn starts once the view is settled: a turn that arrives while
        // the compactor still works waits for it.
        now = now.max(busy_until);
        assert!(memory.settled());
        let view = render_view(&memory, &store).text;
        let pieces = block_pieces(&view);
        let mark = mark_piece(&view, last_mark.as_deref());
        // A batch merge rewrote a line before the last turn's mark.
        let merged = last_mark
            .as_deref()
            .is_some_and(|prev| !view.starts_with(prev));
        merges += usize::from(merged);
        last_mark = mark.map(|k| pieces[..=k].concat());
        let ask = format!("user asks for step {} of the work", memory.len());
        let mut tail: Vec<String> = vec![ask.clone()];
        let first = turn_request(&harness, &system, &pieces, mark, &tail, &env);
        let read = cache.send(&first, now);
        turns.push((
            read,
            harness.len() + system.len() + view.len(),
            last_gap > ttl,
            merged,
        ));
        // Spec 3.2: a resumed host renders the same view, so its request
        // has the same prefix, at any size.
        if view.len() >= next_resume {
            let checkpoint = memory.checkpoint();
            let frontier: Vec<(NodeId, usize)> = store
                .nodes
                .borrow()
                .iter()
                .filter(|(id, _)| {
                    checkpoint
                        .low
                        .get(id.l as usize)
                        .is_none_or(|low| id.i >= *low)
                })
                .map(|(id, t)| (*id, t.len()))
                .collect();
            let resumed =
                Memory::resume(&checkpoint, memory.len(), frontier, VIEW, &store).unwrap();
            let again = render_view(&resumed, &store).text;
            assert_eq!(again, view, "a resumed view differs at {} bytes", view.len());
            assert_eq!(mark_piece(&again, None), mark_piece(&view, None));
            resumes_checked += 1;
            next_resume = if next_resume >= 120_000 { usize::MAX } else { next_resume + 20_000 };
        }
        log(&mut memory, Kind::User, ask, now, &mut cache, &mut busy_until);
        // Most turns take a few tool steps; one in twenty takes 30 to 60
        // (60 to 120 view lines, past the API's 20-block lookback).
        let steps = match rng.range(0, 20) {
            0 => rng.range(30, 61),
            1..=6 => rng.range(4, 16),
            _ => rng.range(0, 4),
        };
        for s in 0..steps {
            now += rng.range(3, 20) as f64;
            let call = format!("tool: shell {{\"cmd\": \"step {s} of {}\"}}", memory.len());
            let result = "r".repeat(rng.range(200, 6_000) as usize);
            tail.push(call.clone());
            tail.push(result.clone());
            let r = turn_request(&harness, &system, &pieces, mark, &tail, &env);
            cache.send(&r, now);
            log(&mut memory, Kind::Tool, call, now, &mut cache, &mut busy_until);
            log(&mut memory, Kind::Echo, result, now, &mut cache, &mut busy_until);
        }
        now += rng.range(3, 20) as f64;
        let reply = "Done: ".to_string() + &"a".repeat(rng.range(50, 900) as usize);
        log(&mut memory, Kind::Talk, reply, now, &mut cache, &mut busy_until);
        // The user's pace: one turn in six comes at once (the compactor may
        // still run), most within minutes, some after 5 to 50 minutes, a few
        // after hours.
        last_gap = match rng.range(0, 100) {
            0..=15 => rng.range(1, 4) as f64,
            16..=79 => rng.range(15, 240) as f64,
            80..=95 => rng.range(300, 3_000) as f64,
            _ => rng.range(3_600, 14_400) as f64,
        };
        now += last_gap;
    }
    let levels = (0..64u32)
        .rev()
        .find(|l| memory.view().iter().any(|p| p.l == *l))
        .unwrap_or(0);
    Run {
        levels,
        turns,
        merges,
        compactions,
        messages: memory.len(),
        resumes_checked,
    }
}

fn pct(read: usize, prefix: usize) -> f64 {
    100.0 * read as f64 / prefix.max(1) as f64
}

/// The lowest rate of any `WINDOW` consecutive warm turns (gap within the TTL).
fn min_window(turns: &[(usize, usize, bool, bool)]) -> f64 {
    let warm: Vec<&(usize, usize, bool, bool)> = turns.iter().filter(|t| !t.2).collect();
    warm.windows(WINDOW)
        .map(|w| pct(w.iter().map(|t| t.0).sum(), w.iter().map(|t| t.1).sum()))
        .fold(f64::INFINITY, f64::min)
}

/// Warm turns that read less than half their prefix.
fn cold(turns: &[(usize, usize, bool, bool)], merged: bool) -> usize {
    turns
        .iter()
        .filter(|t| !t.2 && t.3 == merged && t.0 * 2 < t.1)
        .count()
}

#[test]
fn ten_thousand_messages_keep_warm_turns_at_95_percent_with_one_hour_marks() {
    let r = run(3_600.0, 10_000);
    let warm: Vec<_> = r.turns.iter().filter(|t| !t.2).collect();
    let all = pct(
        warm.iter().map(|t| t.0).sum(),
        warm.iter().map(|t| t.1).sum(),
    );
    let min = min_window(&r.turns);
    eprintln!(
        "1h: {} messages, {} turns ({} warm), {} batch merges, warm turns {:.2}% (min per {WINDOW}-turn window {:.2}%), compactions {:.2}%, tree levels {}, cold warm turns: {} after a merge, {} otherwise; {} resumes checked",
        r.messages,
        r.turns.len(),
        warm.len(),
        r.merges,
        all,
        min,
        pct(r.compactions.0, r.compactions.1),
        r.levels,
        cold(&r.turns, true),
        cold(&r.turns, false),
        r.resumes_checked
    );
    assert!(r.merges >= 5, "only {} batch merges", r.merges);
    assert!(r.levels >= 5, "the tree is only {} levels deep", r.levels);
    assert!(r.resumes_checked >= 3);
    // A batch merge costs one rewrite of the view after it, not one per
    // message; no other warm turn misses the view.
    assert_eq!(cold(&r.turns, false), 0, "warm turns that missed the cache with no merge before them");
    assert!(
        cold(&r.turns, true) <= r.merges,
        "{} cold turns for {} merges",
        cold(&r.turns, true),
        r.merges
    );
    assert!(min >= 95.0, "warm turns read {min:.2}% in their worst window");
}

#[test]
fn five_minute_marks_lose_the_turns_after_a_coffee_break_and_one_hour_marks_keep_them() {
    let five = run(300.0, 4_000);
    let hour = run(3_600.0, 4_000);
    let rate = |r: &Run| {
        pct(
            r.turns.iter().map(|t| t.0).sum(),
            r.turns.iter().map(|t| t.1).sum(),
        )
    };
    eprintln!(
        "all turns: 5m {:.2}%, 1h {:.2}%",
        rate(&five),
        rate(&hour)
    );
    assert!(rate(&hour) > rate(&five) + 5.0);
    // Within the TTL both read the same.
    assert!((min_window(&five.turns) - min_window(&hour.turns)).abs() < 1.0);
}
