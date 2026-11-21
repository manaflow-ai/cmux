//! Cards (decisions 253, 254): made by one record, patched by later ones, their facts folded here
//! and their records listed raw.
#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::indexing_slicing,
    clippy::arithmetic_side_effects,
    reason = "deterministic inputs and assertions"
)]
use super::*;

fn mux(seq: u64, kind: &str, msg: &str) -> String {
    format!(r#"{{"seq":{seq},"at":1000,"dir":"mux","kind":"{kind}","msg":{msg}}}"#)
}
/// Each line at place `100 * seq`, so a listed record names its line.
pub(super) fn run(state: &mut State, lines: &[(u64, String)]) -> Vec<Op> {
    let mut ops = Vec::new();
    for (seq, line) in lines {
        ops.extend(translate(state, Harness::V1, seq * 100, 1, line.as_bytes()).unwrap());
    }
    assert_eq!(state.line_failures(), (0, 0));
    ops
}
fn line(seq: u64, kind: &str, msg: &str) -> (u64, String) {
    (seq, mux(seq, kind, msg))
}
/// Every card row and patch, in order: whether it is a patch, and the row.
fn cards(ops: &[Op]) -> Vec<(bool, OwnedRow)> {
    ops.iter()
        .filter_map(|op| match &op.change {
            Change::Row(row) if row.kind == RowKind::Card && !row.open => {
                Some((false, row.clone()))
            }
            Change::Patch(row) if row.kind == RowKind::Card => Some((true, row.clone())),
            _ => None,
        })
        .collect()
}
fn last(ops: &[Op]) -> OwnedRow {
    cards(ops).pop().expect("a card row").1
}
/// The places a row's `records` body lists, the last such body before each write.
fn records(ops: &[Op], id: u64) -> Vec<u64> {
    ops.iter()
        .filter_map(|op| match &op.change {
            Change::Body {
                id: of,
                field: BodyField::Records,
                source: BodySource::Records(lines),
                ..
            } if *of == id => Some(lines.iter().map(|line| line.place).collect()),
            _ => None,
        })
        .next_back()
        .unwrap_or_default()
}
/// A row's raw fields: body key, line place, `msg` key and cap.
fn raw_fields(ops: &[Op], id: u64) -> Vec<(&'static str, u64, &'static str, usize)> {
    ops.iter()
        .filter_map(|op| match &op.change {
            Change::Body {
                id: of,
                field: BodyField::Card(name),
                source: BodySource::RawField { place, key, cap, .. },
                ..
            } if *of == id => Some((*name, *place, *key, *cap)),
            _ => None,
        })
        .collect()
}
fn notices(ops: &[Op]) -> Vec<String> {
    ops.iter()
        .filter_map(|op| match &op.change {
            Change::Row(row) if row.kind == RowKind::Notice && !row.open => {
                row.fields.get("notice").cloned()
            }
            _ => None,
        })
        .collect()
}
const PAUSED: &str = r#"{"peer":"chat-b","peerName":"Builder","reason":"taken_over","count":0,"windowSecs":600,"promptId":"p"}"#;
fn held(prompt: &str) -> String {
    format!(
        r#"{{"from":"chat-b","fromName":"Builder","to":"chat-a","promptId":"{prompt}","text":"hi","prompt":[]}}"#
    )
}

#[test]
fn an_agent_pair_card_folds_its_held_items_and_lists_what_it_still_holds() {
    let mut state = State::default();
    let ops = run(&mut state, &[line(1, "agent_pair_paused", PAUSED)]);
    let card = last(&ops);
    assert!(!card.open && card.group.is_none());
    assert_eq!(card.fields["card"], "\"agentPair\"");
    // `taken_over` reads as the view reads it.
    assert_eq!(card.fields["reason"], "\"alternating\"");
    assert_eq!(card.fields["windowSecs"], "600");
    assert_eq!(card.fields["held"], "0");
    assert_eq!(records(&ops, card.id), [100]);
    assert_eq!(
        raw_fields(&ops, card.id),
        [("peer", 100, "peer", 256), ("peerName", 100, "peerName", 256)]
    );
    let ops = run(
        &mut state,
        &[
            line(2, "agent_pair_held", &held("m1")),
            line(3, "agent_pair_held", &held("m2")),
            // Sent again: listed once.
            line(4, "agent_pair_held", &held("m1")),
        ],
    );
    let patches = cards(&ops);
    assert_eq!(patches.len(), 2);
    assert!(patches.iter().all(|(patch, row)| *patch && row.id == card.id));
    assert_eq!(patches[1].1.rev, 3);
    assert_eq!(patches[1].1.fields["held"], "2");
    assert_eq!(records(&ops, card.id), [100, 200, 300]);
    // A release takes its item off the list; a release of one never listed still counts.
    let ops = run(
        &mut state,
        &[
            line(5, "agent_pair_released", r#"{"promptId":"m1","peer":"chat-b"}"#),
            line(6, "agent_pair_dropped", r#"{"promptId":"zz","peer":"chat-b","error":"x"}"#),
        ],
    );
    let row = last(&ops);
    assert_eq!((row.fields["released"].as_str(), row.fields["dropped"].as_str()), ("1", "1"));
    assert_eq!(row.fields["held"], "1");
    assert_eq!(records(&ops, card.id), [100, 300]);
    // Resumed with an item still held: kept, and its release decides it.
    let ops = run(
        &mut state,
        &[line(7, "agent_pair_resumed", r#"{"peer":"chat-b","by":"person","delivered":1}"#)],
    );
    assert_eq!(last(&ops).fields["resumed"], "true");
    run(&mut state, &[line(8, "agent_pair_released", r#"{"promptId":"m2","peer":"chat-b"}"#)]);
    assert!(state.cards.is_empty(), "decided: its key leaves");
    // A record for a pair no longer held is a notice row of its own, counted.
    let ops = run(&mut state, &[line(9, "agent_pair_held", &held("m3"))]);
    assert_eq!(notices(&ops), ["\"agent_pair_held\""]);
    assert_eq!(state.counters().orphan_records, 1);
}

#[test]
fn a_pause_after_a_resume_opens_a_new_card_that_takes_what_is_held() {
    let mut state = State::default();
    let ops = run(
        &mut state,
        &[
            line(1, "agent_pair_paused", PAUSED),
            line(2, "agent_pair_held", &held("m1")),
            line(3, "agent_pair_resumed", r#"{"peer":"chat-b"}"#),
            line(4, "agent_pair_paused", &PAUSED.replace("taken_over", "cap")),
        ],
    );
    let rows = cards(&ops);
    let first = rows[0].1.id;
    let (patch, old) = &rows[rows.len() - 2];
    assert!(*patch && old.id == first && old.fields["held"] == "0");
    let new = &rows[rows.len() - 1].1;
    assert!(new.id != first);
    assert_eq!(new.fields["reason"], "\"cap\"");
    assert_eq!(new.fields["held"], "1");
    assert_eq!(records(&ops, new.id), [400, 200]);
    // A peer with no id is refused: no row, counted.
    let ops = run(&mut state, &[line(5, "agent_pair_paused", r#"{"peer":"","reason":"cap"}"#)]);
    assert!(cards(&ops).is_empty());
    assert_eq!(state.counters().refused_records, 1);
}

#[test]
fn a_memory_offer_settles_each_fact_once_and_is_decided_when_none_is_left() {
    let mut state = State::default();
    let offer = r#"{"offerId":"o1","file":" notes.md ","facts":[" a ","b","a","c","d"],"heading":null,"created":true}"#;
    let ops = run(&mut state, &[line(1, "memory_offer", offer)]);
    let card = last(&ops);
    assert_eq!(card.fields["card"], "\"memoryOffer\"");
    // Trimmed, deduped, the first three.
    assert_eq!(card.fields["facts"], "3");
    assert_eq!(card.fields["created"], "true");
    assert_eq!(raw_fields(&ops, card.id), [("file", 100, "file", 512)]);
    let ops = run(
        &mut state,
        &[line(
            2,
            "memory_resolved",
            r#"{"offerId":"o1","file":"notes.md","accepted":["a","x"],"dismissed":["a","c"]}"#,
        )],
    );
    let row = last(&ops);
    assert_eq!((row.fields["accepted"].as_str(), row.fields["dismissed"].as_str()), ("[0]", "[2]"));
    assert_eq!(state.cards.len(), 1);
    run(
        &mut state,
        &[line(3, "memory_resolved", r#"{"offerId":"o1","accepted":[],"dismissed":["b"]}"#)],
    );
    assert!(state.cards.is_empty(), "every fact settled");
    // An offer its parser refuses (no facts) writes nothing; a resolution with no card is a notice.
    let ops = run(
        &mut state,
        &[
            line(4, "memory_offer", r#"{"offerId":"o2","file":"x","facts":[" "]}"#),
            line(5, "memory_resolved", r#"{"offerId":"o9","accepted":["a"]}"#),
        ],
    );
    assert!(cards(&ops).is_empty());
    assert_eq!(notices(&ops), ["\"memory_resolved\""]);
    assert_eq!(state.counters().refused_records, 1);
}

#[test]
fn a_coach_offer_opens_its_card_and_the_rewrite_patches_it() {
    let mut state = State::default();
    let ops = run(&mut state, &[line(1, "coach_offer", r#"{"coachId":"k1","corrections":2}"#)]);
    let card = last(&ops);
    assert_eq!(card.fields["card"], "\"promptCoach\"");
    assert!(!card.fields.contains_key("corrections"), "offered: no rewrite yet");
    let coach = r#"{"coachId":"k1","firstPrompt":"fix it","rewrite":"\nFix the build.\n","corrections":2.7}"#;
    let ops = run(&mut state, &[line(2, "coach", coach)]);
    let (patch, row) = cards(&ops).pop().unwrap();
    assert!(patch && row.id == card.id);
    assert_eq!(row.fields["corrections"], "2");
    assert_eq!(records(&ops, card.id), [100, 200]);
    assert!(state.cards.is_empty());
    // A rewrite whose offer is not held writes its card whole; a blank rewrite is refused.
    let ops = run(
        &mut state,
        &[
            line(3, "coach", &coach.replace("k1", "k2")),
            line(4, "coach", r#"{"coachId":"k3","rewrite":"  "}"#),
        ],
    );
    let rows = cards(&ops);
    assert_eq!(rows.len(), 1);
    assert!(!rows[0].0);
    assert_eq!(state.counters().refused_records, 1);
    assert!(state.cards.is_empty());
}

#[test]
fn preset_requests_join_one_card_until_a_decision_and_the_next_opens_another() {
    let mut state = State::default();
    let ask = r#"{"preset":"nightly","digest":"d1","harness":"claude","model":null,"effort":null,"policy":{"allow":["x"]},"host":"h","description":null}"#;
    let ops = run(
        &mut state,
        &[line(1, "preset_approval_request", ask), line(2, "preset_approval_request", ask)],
    );
    let rows = cards(&ops);
    let card = &rows[0].1;
    assert_eq!(card.fields["card"], "\"presetApproval\"");
    assert!(rows[1].0 && rows[1].1.id == card.id);
    assert_eq!(rows[1].1.fields["requests"], "2");
    // The newest ask; the card keeps its first time.
    assert_eq!(records(&ops, card.id), [200]);
    let ops = run(
        &mut state,
        &[
            line(
                3,
                "preset_approval_decision",
                r#"{"preset":"nightly","digest":"d1","outcome":"approved"}"#,
            ),
            line(4, "preset_approval_request", ask),
        ],
    );
    let rows = cards(&ops);
    assert_eq!(rows[0].1.fields["outcome"], "\"approved\"");
    assert_eq!(raw_fields(&ops, card.id), [("preset", 200, "preset", 128)]);
    assert!(!rows[1].0 && rows[1].1.id != card.id, "a new card");
    // A request missing its policy is refused; a decision with no open card is a notice.
    let ops = run(
        &mut state,
        &[
            line(5, "preset_approval_request", r#"{"preset":"p","digest":"d","harness":"claude"}"#),
            line(
                6,
                "preset_approval_decision",
                r#"{"preset":"other","digest":"d","outcome":"declined"}"#,
            ),
        ],
    );
    assert_eq!(notices(&ops), ["\"preset_approval_decision\""]);
    assert_eq!(state.counters().refused_records, 1);
}

#[test]
fn a_groups_offers_share_a_card_and_each_decision_marks_its_offer() {
    let mut state = State::default();
    let offer = |id: &str| {
        format!(
            r#"{{"offerId":"{id}","title":"Task {id}","prompt":"Do {id}","cwd":"/w","worktree":true,"groupId":"g1"}}"#
        )
    };
    let ops = run(
        &mut state,
        &[
            line(1, "session_offer", &offer("a")),
            line(2, "session_offer", &offer("b")),
            line(
                3,
                "session_offer_decision",
                r#"{"offerId":"a","outcome":"accepted","childSessionId":"child-1"}"#,
            ),
            line(4, "session_offer_decision", r#"{"offerId":"b","outcome":"dismissed"}"#),
        ],
    );
    let row = last(&ops);
    assert_eq!(row.fields["card"], "\"sessionOffer\"");
    assert_eq!(
        row.fields["offers"],
        r#"[{"decision":2,"offer":0,"outcome":"accepted"},{"offer":1,"outcome":"dismissed"}]"#
    );
    assert_eq!(records(&ops, row.id), [100, 200, 300]);
    assert_eq!(cards(&ops).iter().filter(|(patch, _)| !patch).count(), 1, "one card");
    // A single offer is decided with its outcome; an offer missing its prompt is refused.
    let ops = run(
        &mut state,
        &[
            line(5, "session_offer", r#"{"offerId":"s","title":"T","prompt":"P","cwd":"/w"}"#),
            line(6, "session_offer_decision", r#"{"offerId":"s","outcome":"here"}"#),
            line(7, "session_offer", r#"{"offerId":"t","title":"T","cwd":"/w"}"#),
        ],
    );
    assert_eq!(last(&ops).fields["offers"], r#"[{"offer":0,"outcome":"here"}]"#);
    assert_eq!(state.cards.len(), 1, "the group's card stays; the single one left");
    assert_eq!(state.counters().refused_records, 1);
}

#[test]
fn a_plan_build_in_worktrees_opens_its_card_and_the_kept_build_decides_it() {
    let mut state = State::default();
    let started = r#"{"event":"started","buildId":"build-1","target":"compare","permissionId":"p","builds":[{"sessionId":"s1","name":"A","harness":"claude"}],"failed":[]}"#;
    let ops = run(
        &mut state,
        &[
            line(1, "plan_build", started),
            line(
                2,
                "plan_build",
                &started.replace("compare", "here").replace("build-1", "build-2"),
            ),
            line(
                3,
                "plan_build",
                r#"{"event":"kept","buildId":"build-1","keptSessionId":"s1","archived":[]}"#,
            ),
        ],
    );
    let rows = cards(&ops);
    assert_eq!(rows.len(), 2);
    assert_eq!(rows[0].1.fields["card"], "\"plan_build\"");
    assert!(rows[1].0 && rows[1].1.fields["kept"] == "true");
    assert_eq!(records(&ops, rows[0].1.id), [100, 300]);
    assert_eq!(state.counters().refused_records, 1, "a build here writes no card");
    assert!(state.cards.is_empty());
}

#[test]
fn past_its_cap_the_oldest_card_of_a_kind_leaves_and_every_card_fits_the_budget() {
    let mut state = State::default();
    let lines: Vec<_> = (1..=5)
        .map(|n| line(n, "agent_pair_paused", &PAUSED.replace("chat-b", &format!("peer-{n}"))))
        .collect();
    run(&mut state, &lines);
    assert_eq!(state.cards.len(), 4);
    assert_eq!(state.counters().evicted_cards, 1);
    // Its later record is a notice of its own; the newest pause got its card.
    let ops = run(&mut state, &[line(6, "agent_pair_resumed", r#"{"peer":"peer-1"}"#)]);
    assert_eq!(notices(&ops), ["\"agent_pair_resumed\""]);
    // Every kind at its caps, each pair at its list: within the budget, and the checkpoint takes it.
    let mut state = full_cards();
    // 4 pairs, 16 memory offers, 16 presets, 8 coaches, 8 offer groups, 4 builds: none pushed out.
    assert_eq!(state.cards.len(), 56);
    assert!(state.card_bytes() <= cards::MAX_CARD_BYTES, "{}", state.card_bytes());
    let saved = state.checkpoint().unwrap();
    assert_eq!(saved.restore().unwrap().cards, state.cards);
    let _ = &mut state;
}

/// Every card kind held at its cap, with every list at its longest.
pub(super) fn full_cards() -> State {
    let mut state = State::default();
    run(&mut state, &full_card_lines(0));
    state
}

/// The lines that hold every card kind at its cap, numbered after `from`.
pub(super) fn full_card_lines(from: u64) -> Vec<(u64, String)> {
    let mut seq = from;
    let mut next = || {
        seq += 1;
        seq
    };
    let mut lines = Vec::new();
    for pair in 0..4 {
        let peer = format!("peer-{pair}");
        lines.push(line(next(), "agent_pair_paused", &PAUSED.replace("chat-b", &peer)));
        for item in 0..25 {
            let held = held(&format!("m{item}")).replace("chat-b", &peer);
            lines.push(line(next(), "agent_pair_held", &held));
        }
    }
    for offer in 0..16 {
        let msg = format!(r#"{{"offerId":"o{offer}","file":"f","facts":["a","b","c"]}}"#);
        lines.push(line(next(), "memory_offer", &msg));
        let ask =
            format!(r#"{{"preset":"p{offer}","digest":"d","harness":"claude","policy":"x"}}"#);
        lines.push(line(next(), "preset_approval_request", &ask));
    }
    for coach in 0..8 {
        lines.push(line(next(), "coach_offer", &format!(r#"{{"coachId":"k{coach}"}}"#)));
        for offer in 0..6 {
            let msg = format!(
                r#"{{"offerId":"g{coach}-{offer}","title":"T","prompt":"P","cwd":"/w","groupId":"g{coach}"}}"#
            );
            lines.push(line(next(), "session_offer", &msg));
            let decision = format!(
                r#"{{"offerId":"g{coach}-{offer}","outcome":"accepted","childSessionId":"c"}}"#
            );
            lines.push(line(next(), "session_offer_decision", &decision));
        }
    }
    for build in 0..4 {
        let started = format!(
            r#"{{"event":"started","buildId":"b{build}","target":"worktree","builds":[{{"sessionId":"s"}}]}}"#
        );
        lines.push(line(next(), "plan_build", &started));
    }
    lines
}
