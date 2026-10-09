use std::cell::RefCell;
use std::collections::HashMap;

use optchat_core::*;

/// A host in memory: messages and node texts.
#[derive(Default)]
struct Mem {
    messages: RefCell<Vec<(Kind, String)>>,
    nodes: RefCell<HashMap<NodeId, String>>,
}

impl Mem {
    /// The host stores (and fsyncs) a message before it tells the core.
    fn push(&self, kind: Kind, text: impl Into<String>) {
        self.messages.borrow_mut().push((kind, text.into()));
    }
}

impl Store for Mem {
    fn message(&self, i: u64) -> (Kind, String) {
        self.messages.borrow()[i as usize].clone()
    }
    fn node(&self, id: NodeId) -> Option<String> {
        self.nodes.borrow().get(&id).cloned()
    }
}

/// A deterministic stand-in for the compactor model: summaries of realistic size.
fn fake_summary(node: NodeId) -> String {
    let base = format!("sum {}: ", node.name());
    let len = if node.l == 0 {
        240
    } else {
        300 + (node.l as usize * 20).min(180)
    };
    let mut s = base;
    while s.len() < len {
        s.push_str("item; ");
    }
    s.truncate(len);
    s
}

/// A small xorshift, so the test needs no dependency.
struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        self.0
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn message(rng: &mut Rng) -> (Kind, String) {
    let kind = [Kind::User, Kind::Talk, Kind::Tool, Kind::Echo][rng.below(4) as usize];
    let len = match rng.below(10) {
        0..=4 => 20 + rng.below(300),   // short: a free level-0 node
        5..=8 => 600 + rng.below(3000), // needs a summary
        _ => 10_000 + rng.below(20_000),
    } as usize;
    (kind, "x".repeat(len))
}

/// Runs every job the pump hands out until nothing is left, checking the
/// compactor never sees a placeholder line (rule 3).
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
                    let request = compact_request(
                        memory,
                        store,
                        node,
                        CompactPrompt::default().text("Chief"),
                    )
                    .unwrap();
                    assert!(
                        !request.context.contains(PLACEHOLDER),
                        "compactor saw an unbuilt line for {}",
                        node.name()
                    );
                    let text = fake_summary(node);
                    store.nodes.borrow_mut().insert(node, text.clone());
                    memory.complete(node, &text).unwrap();
                }
            }
        }
    }
}

fn assert_tiles(memory: &Memory) {
    let mut next = 0;
    for part in memory.view() {
        assert_eq!(part.start(), next, "view parts must tile [0, T)");
        assert_eq!(part.start() % part.n(), 0, "parts are aligned");
        next = part.end();
    }
    assert_eq!(next, memory.len());
}

/// Every part of `before` is still in `after` or inside a part of it: the view never splits.
fn assert_never_split(before: &[NodeId], after: &[NodeId]) {
    for old in before {
        let covering = after
            .iter()
            .find(|p| p.start() <= old.start() && old.end() <= p.end())
            .expect("covered");
        assert!(
            covering.l >= old.l,
            "{} was split into {}",
            old.name(),
            covering.name()
        );
    }
}

#[test]
fn long_chat_keeps_every_view_rule_and_a_stable_prefix() {
    let budget = 40_000;
    let mut rng = Rng(0x9e3779b97f4a7c15);
    let store = Mem::default();
    let mut memory = Memory::new(budget);
    let mut previous: Option<String> = None;
    let mut shared_total = 0usize;
    let mut size_total = 0usize;
    for step in 0..6_000u64 {
        let before = memory.view().to_vec();
        let (kind, text) = message(&mut rng);
        store.push(kind, text);
        assert_eq!(memory.append(), step);
        drain(&mut memory, &store);
        assert!(memory.settled(), "the fake compactor keeps up");
        assert_tiles(&memory);
        assert_never_split(&before, memory.view());
        // Spec 3.2: the view passes the budget by at most the lines built
        // since the last message; the next message merges it down.
        assert!(
            memory.view_size() <= budget + NODE,
            "over budget at {step}: {}",
            memory.view_size()
        );
        let rendered = render_view(&memory, &store).text;
        if let Some(prev) = &previous {
            if step > 3_000 {
                shared_total += prev
                    .bytes()
                    .zip(rendered.bytes())
                    .take_while(|(a, b)| a == b)
                    .count();
                size_total += rendered.len();
            }
        }
        previous = Some(rendered);
    }
    let shared = shared_total as f64 / size_total as f64;
    assert!(
        shared > 0.5,
        "consecutive views should share most of their prefix, shared {shared:.2}"
    );
}

#[test]
fn free_nodes_keep_short_messages_verbatim() {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    store.push(Kind::User, "keep CSV and add JSON");
    memory.append();
    let work = memory.pump(&store);
    assert_eq!(
        work,
        vec![Work::Free {
            node: NodeId::new(0, 0),
            text: "user: keep CSV and add JSON".into()
        }]
    );
    for w in work {
        if let Work::Free { node, text } = w {
            store.nodes.borrow_mut().insert(node, text);
        }
    }
    store.push(Kind::Talk, "done");
    memory.append();
    let work = memory.pump(&store);
    // message 1 is free, then the pair (0,1) merges free into node (1,0).
    assert_eq!(
        work,
        vec![
            Work::Free {
                node: NodeId::new(0, 1),
                text: "talk: done".into()
            },
            Work::Free {
                node: NodeId::new(1, 0),
                text: "user: keep CSV and add JSON\ntalk: done".into()
            },
        ]
    );
}

#[test]
fn zoom_opens_lines_and_messages() {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for text in ["a\nb", "c", "d", "e"] {
        store.push(Kind::User, text);
        memory.append();
    }
    drain(&mut memory, &store);
    assert_eq!(zoom(&memory, &store, 0, 1).unwrap(), "0+0|user: a\nb");
    assert_eq!(
        zoom(&memory, &store, 0, 2).unwrap(),
        "0+1|user: a b\n1+1|user: c"
    );
    assert_eq!(
        zoom(&memory, &store, 0, 4).unwrap(),
        "0+2|user: a b user: c\n2+2|user: d user: e"
    );
    assert_eq!(
        zoom(&memory, &store, 1, 2).unwrap_err().to_string(),
        "No line 1+2."
    );
    assert_eq!(
        zoom(&memory, &store, 0, 8).unwrap_err().to_string(),
        "No line 0+8."
    );
    assert_eq!(
        zoom(&memory, &store, 0, 3).unwrap_err().to_string(),
        "No line 0+3."
    );
}

/// A turn's view is recorded by its parts: rendering those parts later,
/// after the chat moved on and the view merged, gives the turn's bytes back.
#[test]
fn a_past_view_renders_again_from_its_parts() {
    let mut rng = Rng(11);
    let store = Mem::default();
    let mut memory = Memory::new(20_000);
    let mut snapshots = Vec::new();
    for k in 0..1_500 {
        let (kind, text) = message(&mut rng);
        store.push(kind, text);
        memory.append();
        drain(&mut memory, &store);
        if k % 300 == 299 {
            let view = render_view(&memory, &store);
            assert_eq!(view.parts, memory.view());
            snapshots.push(view);
        }
    }
    for old in &snapshots {
        let again = render_parts(&old.parts, &store);
        assert_eq!(again.text, old.text);
        assert_eq!(again.marks, old.marks);
    }
    assert_ne!(snapshots[0].parts, memory.view(), "the view moved on");
}

#[test]
fn render_puts_marks_on_line_ends_before_each_limit() {
    let mut rng = Rng(7);
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for _ in 0..3_000 {
        let (kind, text) = message(&mut rng);
        store.push(kind, text);
        memory.append();
        drain(&mut memory, &store);
    }
    let view = render_view(&memory, &store);
    assert!(view.text.starts_with("<chat>\n") && view.text.ends_with("</chat>"));
    assert_eq!(view.marks.len(), 3, "a full view has all three marks");
    for (mark, limit) in view.marks.iter().zip(MARKS) {
        assert_eq!(&view.text[mark - 1..*mark], "\n", "a mark ends a line");
        assert!(view.text[..*mark].chars().count() <= limit);
    }
    let small = Memory::new(VIEW);
    assert!(
        render_view(&small, &store).marks.is_empty(),
        "marks past the end are skipped"
    );
}

#[test]
fn size_loop_retries_with_the_cut_and_keeps_the_shortest() {
    let long = "é".repeat(300); // 600 bytes
    match size_check(std::slice::from_ref(&long)) {
        SizeCheck::Retry(msg) => {
            assert!(msg
                .starts_with("Too long: your line is 600 bytes, over the 512-byte limit. Write\n"));
            assert!(msg.ends_with("| ← LIMIT"));
            assert_eq!(cut_at_bytes(&long, 512).len(), 512);
        }
        other => panic!("expected a retry, got {other:?}"),
    }
    assert_eq!(
        cut_at_bytes(&long, 511).len(),
        510,
        "never splits a character"
    );
    let tries: Vec<String> = (0..TRIES).map(|k| "z".repeat(530 - k)).collect();
    assert_eq!(
        size_check(&tries),
        SizeCheck::Accept("z".repeat(530 - (TRIES - 1)))
    );
    assert_eq!(
        size_check(&["  fits  ".into()]),
        SizeCheck::Accept("fits".into())
    );
    assert_eq!(size_check(&["   ".into()]), SizeCheck::Fail);
}

#[test]
fn compactor_prompt_is_selectable_and_defaults_to_taelins() {
    assert_eq!(CompactPrompt::default(), CompactPrompt::Taelin);
    let taelin = CompactPrompt::Taelin.text("Chief");
    assert!(taelin.starts_with(
        "You are Chief, an AI agent that works for one user in a single chat that never\nends."
    ));
    assert!(
        taelin.contains("\n# Compactions\n"),
        "one prompt for turns and compactions"
    );
    assert!(!taelin.contains("{agent}"), "every placeholder is filled");
    assert_eq!(
        taelin,
        CompactPrompt::Taelin.text("Chief"),
        "byte-identical across calls"
    );
    let cmux = CompactPrompt::Cmux.text("Chief");
    assert!(cmux.starts_with(&taelin), "ours extends Taelin's");
    assert!(cmux.contains("Never copy a secret into a line"));
    assert_eq!(
        CompactPrompt::Custom("Summarize for {agent}.".into()).text("Ada"),
        "Summarize for Ada."
    );
    assert_eq!(CompactPrompt::Cmux.name(), "cmux");
}

#[test]
fn zoom_refuses_addresses_whose_end_overflows() {
    // Audit round 1: `id + n` wrapped past u64::MAX, so the bounds check
    // passed and the store was asked for a message that does not exist.
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for text in ["a", "b"] {
        store.push(Kind::User, text);
        memory.append();
    }
    drain(&mut memory, &store);
    for (id, n) in [(u64::MAX, 1), (u64::MAX - 1, 2), (1 << 63, 1 << 63)] {
        assert_eq!(
            zoom(&memory, &store, id, n).unwrap_err().to_string(),
            format!("No line {id}+{n}.")
        );
    }
}

#[test]
fn cache_pieces_cut_any_text_at_the_marks_and_join_back() {
    let line = format!("{}\n", "y".repeat(99));
    let text: String = std::iter::repeat_n(line.as_str(), 1_200).collect();
    let pieces = cache_pieces(&text);
    assert_eq!(pieces.len(), 4);
    assert_eq!(pieces.concat(), text);
    assert_eq!(pieces[0].chars().count(), 50_000);
    assert_eq!(cache_marks(&text), vec![50_000, 80_000, 100_000]);
    assert_eq!(cache_pieces("short\n"), vec!["short\n"]);
}

/// A store whose message reads fail from `from` on.
struct Failing {
    inner: Mem,
    from: u64,
    failed: std::cell::Cell<bool>,
}

impl Store for Failing {
    fn message(&self, i: u64) -> (Kind, String) {
        if i >= self.from {
            self.failed.set(true);
            return (Kind::Note, String::new());
        }
        self.inner.message(i)
    }
    fn node(&self, id: NodeId) -> Option<String> {
        self.inner.node(id)
    }
    fn failed(&self) -> bool {
        self.failed.get()
    }
}

#[test]
fn a_failed_read_builds_and_starts_nothing() {
    let store = Failing {
        inner: Mem::default(),
        from: 1,
        failed: std::cell::Cell::new(false),
    };
    let mut memory = Memory::new(VIEW);
    for text in ["first", "second"] {
        store.inner.push(Kind::User, text);
        memory.append();
    }
    let work = memory.pump(&store);
    assert_eq!(
        work,
        vec![Work::Free {
            node: NodeId::new(0, 0),
            text: "user: first".into()
        }],
        "message 1 failed to read: no stand-in node, nothing busy"
    );
    assert!(!memory.is_built(NodeId::new(0, 1)));
    assert_eq!(memory.busy().count(), 0);
    // The read works again: the next pump builds it from the real message.
    store.failed.set(false);
    let store = Failing {
        from: u64::MAX,
        ..store
    };
    let work = memory.pump(&store);
    assert!(work.contains(&Work::Free {
        node: NodeId::new(0, 1),
        text: "user: second".into()
    }));
}

/// Audit round 2: a paste or tool input larger than the compactor model's
/// context failed its node on every try, and under rule 3 every later
/// level-0 node and every turn waited forever. The call shows the head and
/// tail only (the log keeps the message whole), and the line says so.
#[test]
fn a_huge_message_is_cut_for_its_summary_call_only_and_the_line_says_so() {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    let total = STEP_MESSAGE * 3;
    let huge = format!("HEAD{}TAIL", "é".repeat(total - 8));
    store.push(Kind::User, huge.clone());
    memory.append();
    let request = compact_request(
        &memory,
        &store,
        NodeId::new(0, 0),
        CompactPrompt::default().text("Chief"),
    )
    .unwrap();
    assert_eq!(store.message(0).1, huge, "the log keeps the message whole");
    assert!(
        request.step.chars().count() < STEP_MESSAGE + 2_000,
        "the call shows at most STEP_MESSAGE characters of it"
    );
    assert!(request.step.contains("user: HEAD") && request.step.ends_with("TAIL\n</input>"));
    let cut = total - STEP_MESSAGE;
    let prefix = request.cut.clone().expect("the request says it is cut");
    assert!(prefix.contains(&cut.to_string()) && prefix.contains(&total.to_string()));
    assert!(
        request.step.contains(&prefix),
        "the model is told the line's start"
    );
    let line = finish_line(&request, "user: pasted a long log");
    assert_eq!(line, format!("{prefix}user: pasted a long log"));
    assert_eq!(finish_line(&request, &line), line, "never twice");
    // A message that fits is shown whole and its line is the model's own.
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    store.push(Kind::Tool, "w".repeat(STEP_MESSAGE));
    memory.append();
    let whole = compact_request(&memory, &store, NodeId::new(0, 0), String::new()).unwrap();
    assert_eq!(whole.cut, None);
    assert!(whole
        .step
        .ends_with(&format!("{}\n</input>", "w".repeat(STEP_MESSAGE))));
    assert_eq!(finish_line(&whole, "tool: x"), "tool: x");
}

// Audit round 3, m1: a cut message's line must fit with its prefix, so the
// size loop measures the reply against the reduced room, not NODE.
#[test]
fn the_size_loop_measures_a_cut_line_against_its_reduced_room() {
    let room = 450;
    let reply = "x".repeat(480);
    match size_check_in(std::slice::from_ref(&reply), room) {
        SizeCheck::Retry(text) => assert!(
            text.starts_with("Too long: your line is 480 bytes, over the 450-byte limit."),
            "{text}"
        ),
        other => panic!("{other:?}"),
    }
    assert_eq!(
        size_check_in(&["y".repeat(450)], room),
        SizeCheck::Accept("y".repeat(450))
    );
    assert_eq!(
        size_check(&["z".repeat(480)]),
        SizeCheck::Accept("z".repeat(480))
    );
}

#[test]
fn a_cut_request_knows_its_room() {
    let store = Mem::default();
    let total = STEP_MESSAGE * 2;
    store.push(Kind::Echo, "e".repeat(total));
    let mut memory = Memory::new(VIEW);
    memory.append();
    let request = compact_request(&memory, &store, NodeId::new(0, 0), "S".into()).unwrap();
    let prefix = request.cut.clone().unwrap();
    assert_eq!(request.room(), NODE - prefix.len());
    let line = finish_line(&request, &"w".repeat(request.room()));
    assert_eq!(
        line.len(),
        NODE,
        "a line that uses all its room fits exactly"
    );
}

/// `drain` for a lazy memory: completions go through `complete_in`.
fn drain_in(memory: &mut Memory, store: &Mem) {
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
                    let text = fake_summary(node);
                    store.nodes.borrow_mut().insert(node, text.clone());
                    memory.complete_in(node, &text, store).unwrap();
                }
            }
        }
    }
}

/// The nodes at or above each level's `low` of a checkpoint: what a host
/// reads by key range at start, instead of every node.
fn frontier(store: &Mem, checkpoint: &Checkpoint) -> Vec<(NodeId, usize)> {
    store
        .nodes
        .borrow()
        .iter()
        .filter(|(id, _)| id.i >= checkpoint.low.get(id.l as usize).copied().unwrap_or(0))
        .map(|(id, t)| (*id, t.len()))
        .collect()
}

#[test]
fn a_resumed_memory_is_the_live_one_and_keeps_only_the_views_sizes() {
    let mut rng = Rng(11);
    let store = Mem::default();
    let mut live = Memory::new(20_000);
    for _ in 0..3_000 {
        let (kind, text) = message(&mut rng);
        store.push(kind, text);
        live.append();
        drain(&mut live, &store);
    }
    let checkpoint = live.checkpoint();
    let from = frontier(&store, &checkpoint);
    // Nothing near 2T nodes is read: only the out-of-order tail.
    assert!(from.len() < 64, "{} frontier nodes", from.len());
    let mut lazy = Memory::resume(&checkpoint, live.len(), from, 20_000, &store).unwrap();
    assert!(lazy.is_lazy());
    assert_eq!(lazy.view(), live.view());
    assert_eq!(lazy.view_size(), live.view_size());
    // Both go on with the same messages and builds and stay equal.
    for _ in 0..1_000 {
        let (kind, text) = message(&mut rng);
        store.push(kind, text);
        live.append();
        drain(&mut live, &store);
        lazy.append_in(&store);
        drain_in(&mut lazy, &store);
        assert_eq!(lazy.view(), live.view());
        assert_eq!(lazy.view_size(), live.view_size());
        assert_eq!(lazy.settled(), live.settled());
    }
    assert_tiles(&lazy);
}

#[test]
fn a_stale_checkpoint_keeps_its_view_and_folds_only_the_tail() {
    let mut rng = Rng(5);
    let store = Mem::default();
    let mut live = Memory::new(20_000);
    let mut checkpoint = None;
    for step in 0..2_500 {
        let (kind, text) = message(&mut rng);
        store.push(kind, text);
        live.append();
        drain(&mut live, &store);
        if step == 2_200 {
            checkpoint = Some(live.checkpoint());
        }
    }
    let checkpoint = checkpoint.unwrap();
    let from = frontier(&store, &checkpoint);
    let resumed = Memory::resume(&checkpoint, live.len(), from, 20_000, &store).unwrap();
    assert_eq!(resumed.len(), live.len());
    assert_tiles(&resumed);
    // Spec 3.2: the saved view is kept, never refit: the tail only appends
    // and merges in batches, as the live memory did.
    assert_never_split(&checkpoint.view, resumed.view());
    assert!(resumed.view_size() <= 20_000 + NODE);
}

#[test]
fn a_checkpoint_that_does_not_fit_the_store_is_refused() {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for n in 0..8 {
        store.push(Kind::User, format!("m{n}"));
        memory.append();
        drain(&mut memory, &store);
    }
    let good = memory.checkpoint();
    // More messages than the store holds.
    assert!(Memory::resume(&good, 4, Vec::new(), VIEW, &store).is_none());
    // A gap in the view.
    let mut gap = good.clone();
    gap.view.remove(1);
    assert!(Memory::resume(&gap, 8, Vec::new(), VIEW, &store).is_none());
    // A merged part the store does not have.
    let missing = Checkpoint {
        t: 8,
        low: vec![8],
        view: vec![NodeId::new(3, 0)],
        ..Checkpoint::default()
    };
    assert!(Memory::resume(&missing, 8, Vec::new(), VIEW, &store).is_none());
}

/// Audit major 1 (fixed by e46860e1a8bc, which checks built before it stores
/// a size): a second `complete` for a node, with a text of another length,
/// changes no size, so `view_size` stays the sum of the view's lines.
#[test]
fn a_second_complete_changes_no_size() {
    let mut memory = Memory::new(VIEW);
    let store = Mem::default();
    store.push(Kind::Echo, "z".repeat(5_000));
    memory.append();
    assert_eq!(
        memory.pump(&store),
        vec![Work::Model {
            node: NodeId::new(0, 0)
        }]
    );
    let text = fake_summary(NodeId::new(0, 0));
    store
        .nodes
        .borrow_mut()
        .insert(NodeId::new(0, 0), text.clone());
    memory.complete(NodeId::new(0, 0), &text).unwrap();
    let size = memory.view_size();
    assert_eq!(size, text.len());
    let _ = memory.complete(NodeId::new(0, 0), "a much shorter line");
    assert_eq!(
        memory.view_size(),
        size,
        "a second complete changed view_size"
    );
    for _ in 0..40 {
        store.push(Kind::Echo, "z".repeat(5_000));
        memory.append();
    }
    drain(&mut memory, &store);
    let lines: usize = memory
        .view()
        .iter()
        .map(|p| store.node(*p).unwrap().len())
        .sum();
    assert_eq!(
        memory.view_size(),
        lines,
        "view_size is the sum of the view's lines"
    );
}

/// Audit major 3: `complete` writes only a node whose model call is running.
/// A node `pump` never handed out (here past the end of the log) or one
/// completed already is refused, and nothing becomes built: a later message
/// at that id would otherwise count as summarized by an unrelated text.
#[test]
fn a_complete_for_a_node_with_no_call_running_is_refused() {
    let mut memory = Memory::new(VIEW);
    let store = Mem::default();
    store.push(Kind::User, "hi");
    memory.append();
    assert!(memory.complete(NodeId::new(0, 5), "made up").is_err());
    assert!(
        !memory.is_built(NodeId::new(0, 5)),
        "a node no call ran for became built"
    );
    assert!(memory.complete(NodeId::new(2, 0), "made up").is_err());
    assert!(!memory.is_built(NodeId::new(2, 0)));
}

/// Audit major 3: a compactor call for a node whose child or context line is
/// built but missing from the store is refused, never sent with an empty
/// line (the node the model wrote from it would be wrong for good).
#[test]
fn a_compactor_call_with_a_missing_line_is_refused() {
    let mut memory = Memory::new(VIEW);
    let store = Mem::default();
    for _ in 0..4 {
        store.push(Kind::Echo, "z".repeat(5_000));
        memory.append();
    }
    drain(&mut memory, &store);
    assert!(memory.is_built(NodeId::new(1, 0)));
    // A merge whose child text is gone.
    store.nodes.borrow_mut().remove(&NodeId::new(0, 1));
    let merge = compact_request(&memory, &store, NodeId::new(1, 0), String::new());
    assert_eq!(merge.err(), Some(MissingNode(NodeId::new(0, 1))));
    // A level-0 call whose context (a view line before it) is gone.
    store.push(Kind::Echo, "z".repeat(5_000));
    memory.append();
    let gone = memory.view()[0];
    store.nodes.borrow_mut().remove(&gone);
    let leaf = compact_request(&memory, &store, NodeId::new(0, 4), String::new());
    assert_eq!(leaf.err(), Some(MissingNode(gone)));
}

/// Compactor width (hq-6d gap 3c): a burst of long messages (an import, a
/// tool-heavy turn) starts 64 model calls at once, as the reference client
/// does (64 jobs, 64 leaves ahead), not 8.
#[test]
fn a_burst_of_long_messages_starts_64_compactions_at_once() {
    let store = Mem::default();
    let mut memory = Memory::new(VIEW);
    for k in 0..100 {
        store.push(Kind::Echo, format!("message {k} {}", "x".repeat(700)));
        memory.append();
    }
    let models = memory
        .pump(&store)
        .iter()
        .filter(|w| matches!(w, Work::Model { .. }))
        .count();
    assert_eq!(models, 64);
    assert_eq!(memory.busy().count(), 64);
}
