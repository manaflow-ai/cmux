//! The rules of Taelin's updated recipe (gist 3c190e0, "UniiChat"): the view's
//! merge order is his rollback push, merges come in sawtooth batches, the
//! compaction view is its own smaller sawtooth, the view is saved and never
//! rebuilt, the cache is marked on 4-line blocks, and compactions get the
//! spec's task text with its ruler.

use std::cell::RefCell;
use std::collections::HashMap;

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

fn summary(node: NodeId) -> String {
    let len = if node.l == 0 { 240 } else { 380 + (node.l as usize * 9).min(120) };
    let mut s = format!("sum {}: ", node.name());
    while s.len() < len {
        s.push_str("item; ");
    }
    s.truncate(len);
    s
}

/// Builds everything the pump hands out (the fake compactor keeps up).
fn drain(memory: &mut Memory, store: &Mem) {
    loop {
        let work = memory.pump(store);
        if work.is_empty() {
            return;
        }
        for w in work {
            match w {
                Work::Free { node, text } => {
                    store.nodes.borrow_mut().insert(node, text);
                }
                Work::Model { node } => {
                    let text = summary(node);
                    store.nodes.borrow_mut().insert(node, text.clone());
                    memory.complete(node, &text).unwrap();
                }
            }
        }
    }
}

fn add(memory: &mut Memory, store: &Mem, k: u64) {
    store
        .messages
        .borrow_mut()
        .push((Kind::Echo, format!("message {k} {}", "x".repeat(700))));
    memory.append();
}

/// Taelin's `push` (rollback_state_list.js) with `life` 0, newest first:
/// a 0 bit absorbs the new state, a 1 bit carries the old one down.
fn push(list: &mut Vec<(bool, u64)>, k: usize, new: u64) {
    if k == list.len() {
        list.push((false, new));
    } else if !list[k].0 {
        list[k].0 = true;
    } else {
        let old = list[k].1;
        list[k] = (false, new);
        push(list, k + 1, old);
    }
}

/// His list as a view: each state starts a line that runs to the next newer one.
fn push_view(list: &[(bool, u64)], t: u64) -> Vec<NodeId> {
    let starts: Vec<u64> = list.iter().rev().map(|(_, s)| *s).collect();
    starts
        .iter()
        .enumerate()
        .map(|(k, s)| {
            let end = starts.get(k + 1).copied().unwrap_or(t);
            let n = end - s;
            assert!(n.is_power_of_two() && s % n == 0);
            NodeId::new(n.trailing_zeros(), s / n)
        })
        .collect()
}

/// Spec 3.2: with his list's length as the budget, the most due pair is
/// exactly the merge his push makes, at every step for t = 0..20,000.
/// Measuring from the pair's first message matches at only a few of them.
#[test]
fn the_merge_order_is_taelins_push_for_t_0_to_20000() {
    let mut list = Vec::new();
    let mut view: Vec<NodeId> = Vec::new();
    for t in 0..=20_000u64 {
        push(&mut list, 0, t);
        let target = push_view(&list, t + 1);
        view.push(NodeId::new(0, t));
        while view.len() > target.len() {
            let k = most_due(&view, t + 1, |_| true).expect("a pair to merge");
            let parent = view[k].parent();
            view.splice(k..k + 2, [parent]);
        }
        assert_eq!(view, target, "the view left push at t = {t}");
    }
}

/// Spec 3.2, the example: at T = 10 with 0+4, 4+4, 8+1, 9+1, push merges 8-9.
#[test]
fn the_most_due_pair_at_t_10_is_8_and_9() {
    let view = [
        NodeId::new(2, 0),
        NodeId::new(2, 1),
        NodeId::new(0, 8),
        NodeId::new(0, 9),
    ];
    assert_eq!(most_due(&view, 10, |_| true), Some(2));
    // A pair whose parent is not built is passed over.
    assert_eq!(
        most_due(&view, 10, |n| n != NodeId::new(1, 4)),
        Some(0)
    );
}

/// Spec 3.2, when: each message only appends its line; once the view passes
/// the budget, one batch merges down to half of it. Building a node never
/// merges.
#[test]
fn the_view_is_a_sawtooth_from_the_budget_down_to_half() {
    let budget = 20_000;
    let store = Mem::default();
    let mut memory = Memory::new(budget);
    let mut batches = 0;
    for k in 0..4_000u64 {
        let before = memory.view().to_vec();
        let size_before = memory.view_size();
        add(&mut memory, &store, k);
        let appended = memory.view().len() == before.len() + 1
            && memory.view()[..before.len()] == before[..];
        if !appended {
            batches += 1;
            assert!(
                memory.view_size() <= budget / 2,
                "a batch ends at half the budget, at {k}: {}",
                memory.view_size()
            );
            assert!(size_before + 29 > budget, "merged before the budget at {k}");
        }
        let view = memory.view().to_vec();
        drain(&mut memory, &store);
        assert_eq!(memory.view(), &view[..], "building nodes changed the view at {k}");
    }
    assert!(batches >= 10, "only {batches} batches");
}

/// Spec 3.2: a batch merges only pairs whose parent is built; what it cannot
/// reach yet it merges at the next messages, until the view is at half.
#[test]
fn a_batch_that_cannot_reach_half_goes_on_at_each_message() {
    let budget = 8_000;
    let store = Mem::default();
    let mut memory = Memory::new(budget);
    // Level-0 nodes built, no merge built: nothing can merge.
    let mut k = 0;
    while memory.view_size() <= budget {
        add(&mut memory, &store, k);
        k += 1;
        for w in memory.pump(&store) {
            if let Work::Model { node } = w {
                if node.l == 0 {
                    // Two of these do not fit one line: every merge is a model call.
                    let text = "z".repeat(300);
                    store.nodes.borrow_mut().insert(node, text.clone());
                    memory.complete(node, &text).unwrap();
                } else {
                    memory.fail(node);
                }
            }
        }
    }
    add(&mut memory, &store, k);
    k += 1;
    assert!(memory.view_size() > budget, "no parent built, no merge");
    drain(&mut memory, &store);
    let stuck = memory.view().to_vec();
    assert_eq!(memory.view(), &stuck[..]);
    add(&mut memory, &store, k);
    assert!(memory.view_size() <= budget / 2, "the next message finishes the batch");
}

/// Spec 4: the compaction view is the chat's view merged further, a 1/8 to
/// 1/4 budget sawtooth (16-32 KB at 128 KB); a compaction sees it up to its
/// node, built lines only, with ids.
#[test]
fn compactions_see_their_own_smaller_view_up_to_the_node() {
    let budget = 64_000;
    let store = Mem::default();
    let mut memory = Memory::new(budget);
    for k in 0..3_000u64 {
        add(&mut memory, &store, k);
        assert!(
            memory.compact_view_size() <= budget / 4 + NODE,
            "compaction view {} at {k}",
            memory.compact_view_size()
        );
        let mut next = 0;
        for p in memory.compact_view() {
            assert_eq!(p.start(), next, "the compaction view tiles the chat");
            next = p.end();
        }
        assert_eq!(next, memory.len());
        for w in memory.pump(&store) {
            match w {
                Work::Free { node, text } => {
                    store.nodes.borrow_mut().insert(node, text);
                }
                Work::Model { node } => {
                    let request =
                        compact_request(&memory, &store, node, "SYSTEM".into()).unwrap();
                    assert!(!request.context.contains(PLACEHOLDER));
                    let upto = if node.l == 0 { node.start() } else { node.end() };
                    for line in request.context.lines().filter(|l| l.contains('|')) {
                        let name = line.split('|').next().unwrap();
                        let (id, n) = name.split_once('+').unwrap();
                        let (id, n): (u64, u64) = (id.parse().unwrap(), n.parse().unwrap());
                        assert!(id + n <= upto, "{name} is past node {}", node.name());
                    }
                    assert!(request.context.len() <= budget / 4 + 4 * NODE);
                    let text = summary(node);
                    store.nodes.borrow_mut().insert(node, text.clone());
                    memory.complete(node, &text).unwrap();
                }
            }
        }
        drain(&mut memory, &store);
    }
}

/// Spec 4, the order: a message's node starts once fewer than 8 lines before
/// it are unbuilt, merges once both halves are built.
#[test]
fn up_to_eight_message_nodes_run_and_merges_start_when_both_halves_are_built() {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for k in 0..20 {
        add(&mut memory, &store, k);
    }
    let first: Vec<NodeId> = memory
        .pump(&store)
        .into_iter()
        .map(|w| match w {
            Work::Model { node } => node,
            other => panic!("{other:?}"),
        })
        .collect();
    assert_eq!(first, (0..8).map(|i| NodeId::new(0, i)).collect::<Vec<_>>());
    // 1..8 finish while 0 runs: one unbuilt line before 8..15, so they start
    // (seven slots), and the merges of built pairs too.
    for i in 1..8 {
        let n = NodeId::new(0, i);
        store.nodes.borrow_mut().insert(n, summary(n));
        memory.complete(n, &summary(n)).unwrap();
    }
    let work = memory.pump(&store);
    let models: Vec<NodeId> = work
        .iter()
        .filter_map(|w| match w {
            Work::Model { node } => Some(*node),
            Work::Free { .. } => None,
        })
        .collect();
    assert_eq!(models, (8..15).map(|i| NodeId::new(0, i)).collect::<Vec<_>>());
    let free: Vec<NodeId> = work
        .iter()
        .filter_map(|w| match w {
            Work::Free { node, .. } => Some(*node),
            Work::Model { .. } => None,
        })
        .collect();
    assert_eq!(free, vec![NodeId::new(1, 1), NodeId::new(1, 2), NodeId::new(1, 3)]);
    assert_eq!(memory.busy().count(), JOBS);
}

/// Spec 3.2: the view is saved and loaded, never rebuilt. A memory resumed
/// from its checkpoint is the live one, compaction view and batch state
/// included, and goes on exactly as the live one does.
#[test]
fn a_resumed_memory_goes_on_exactly_as_the_live_one() {
    let budget = 12_000;
    let store = Mem::default();
    let mut live = Memory::new(budget);
    for k in 0..1_500 {
        add(&mut live, &store, k);
        drain(&mut live, &store);
    }
    let checkpoint = live.checkpoint();
    let frontier: Vec<(NodeId, usize)> = store
        .nodes
        .borrow()
        .iter()
        .filter(|(id, _)| checkpoint.low.get(id.l as usize).is_none_or(|low| id.i >= *low))
        .map(|(id, t)| (*id, t.len()))
        .collect();
    let mut resumed = Memory::resume(&checkpoint, live.len(), frontier, budget, &store).unwrap();
    assert_eq!(resumed.view(), live.view());
    assert_eq!(resumed.compact_view(), live.compact_view());
    for k in 1_500..2_500 {
        add(&mut live, &store, k);
        resumed.append_in(&store);
        drain(&mut live, &store);
        // The store is shared: built nodes reach the resumed memory by key.
        let mut work = resumed.pump(&store);
        while !work.is_empty() {
            for w in work {
                if let Work::Model { node } = w {
                    resumed.complete_in(node, &summary(node), &store).unwrap();
                }
            }
            work = resumed.pump(&store);
        }
        assert_eq!(resumed.view(), live.view(), "diverged at {k}");
        assert_eq!(resumed.compact_view(), live.compact_view(), "diverged at {k}");
    }
}

/// Spec 3.3: the view goes in blocks of 4 lines; the pieces join back.
#[test]
fn the_view_is_cut_in_blocks_of_four_lines() {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for k in 0..203 {
        add(&mut memory, &store, k);
        drain(&mut memory, &store);
    }
    let view = render_view(&memory, &store).text;
    let pieces = block_pieces(&view);
    assert_eq!(pieces.concat(), view);
    let lines = memory.view().len();
    assert_eq!(pieces.len(), lines / BLOCK_LINES + 1);
    assert!(pieces[0].starts_with("<chat>\n"));
    for piece in &pieces[..pieces.len() - 1] {
        let body = piece.strip_prefix("<chat>\n").unwrap_or(piece);
        assert_eq!(body.lines().count(), BLOCK_LINES, "{piece:?}");
        assert!(piece.ends_with('\n'));
    }
    assert!(pieces.last().unwrap().ends_with("</chat>"));
    // A cut depends only on what is before it: the next view keeps them.
    add(&mut memory, &store, 203);
    drain(&mut memory, &store);
    let next = render_view(&memory, &store).text;
    let cuts = block_cuts(&view);
    assert_eq!(block_cuts(&next)[..cuts.len()], cuts[..]);
}

/// Spec 4: the task texts verbatim, the ruler is 512 dashes, and an over-long
/// reply gets "Too long" with its first 512 bytes and the LIMIT mark.
#[test]
fn compaction_tasks_carry_the_ruler_and_the_too_long_retry() {
    assert_eq!(RULER.len(), NODE);
    assert!(RULER.bytes().all(|b| b == b'-'));
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for k in 0..4 {
        add(&mut memory, &store, k);
    }
    let work = memory.pump(&store);
    let Work::Model { node } = work[2].clone() else { panic!() };
    let request = compact_request(&memory, &store, node, "SYSTEM".into()).unwrap();
    assert_eq!(
        request.step,
        format!(
            "Compaction: compress message 2 into one line of at most 512 bytes\n\
             (about 70 words), the length of this ruler:\n{RULER}\n<input>\n\
             echo: message 2 {}\n</input>",
            "x".repeat(700)
        )
    );
    for w in work {
        if let Work::Model { node } = w {
            store.nodes.borrow_mut().insert(node, summary(node));
            memory.complete(node, &summary(node)).unwrap();
        }
    }
    let work = memory.pump(&store);
    let merge = work
        .iter()
        .find_map(|w| match w {
            Work::Model { node } => Some(*node),
            Work::Free { .. } => None,
        })
        .unwrap();
    let (a, b) = merge.children().unwrap();
    let request = compact_request(&memory, &store, merge, "SYSTEM".into()).unwrap();
    let line = |n: NodeId| view_line(n, store.node(n).as_deref());
    assert_eq!(
        request.step,
        format!(
            "Compaction: merge lines {} and {}, adjacent, into one line of at most\n\
             512 bytes (about 70 words), the length of this ruler:\n{RULER}\n\
             <chat> may hold their messages, {} to {}, in more detail: take details\n\
             of them from there too.\n<input>\n{}\n{}\n</input>",
            a.name(),
            b.name(),
            merge.start(),
            merge.end() - 1,
            line(a),
            line(b)
        )
    );
    let long = "y".repeat(600);
    let SizeCheck::Retry(retry) = size_check(&[long.clone()]) else { panic!() };
    assert_eq!(
        retry,
        format!(
            "Too long: your line is 600 bytes, over the 512-byte limit. Write\n\
             the whole line again for the same <input>, cutting just enough of the\n\
             least valuable items to fit before this cut:\n{}| ← LIMIT",
            "y".repeat(512)
        )
    );
    // A reply that copies an id+n| head loses it.
    assert_eq!(
        size_check(&["12+4|user: keep it".into()]),
        SizeCheck::Accept("user: keep it".into())
    );
}
