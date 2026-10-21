//! Which Chief turns wait for approvals, and how (Leo, 2026-10-20). The
//! owner's own turns never ask: a `cmux chief` CLI message on this Mac, a
//! turn that reads the Home workspace, and by default a turn from the
//! owner's paired phone. "Ask before acting on requests from other devices"
//! (`remote.ask`) and "Ask before acting on what Home shows" (`home.ask`)
//! turn those gates on; another participant's turn always asks, unless
//! "Auto-approve everything the Chief does" (`approvals.autoApproveAll`) is
//! on, which only the owner turns on, outside such a turn. In a gated
//! turn the Chief's own tools never wait, a stop ends the turn, a denied
//! request is not asked again, a newer message leaves a pending approval
//! alone, and the approval is a readable card, not a JSON dump.

mod common;

use std::collections::BTreeMap;
use std::sync::Arc;
use std::sync::mpsc::channel;
use std::time::{Duration, Instant};

use cmux_conversation::{Change, Message, Op, Origin, Part, Participant, ParticipantKind, Summary};
use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::Input;
use optchat_chief::daemon::DaemonEvent;
use serde_json::{Value, json};

const DEVICE: &str = "remote_inst_1";

fn paired() -> Summary {
    let mut s = summary();
    s.participants.push(Participant {
        id: DEVICE.into(),
        kind: ParticipantKind::Human,
        display_name: "Leo's iPhone".into(),
        agent_class: None,
        acp_session: None,
        person: Some("user_local".into()),
    });
    s
}

/// A Chief whose `settings.json` holds `settings` (None: no file), with a
/// Home view (a CLI that is not there: the block says it is unavailable,
/// as the host's real reader would) when `home` is set.
fn harness(settings: Option<Value>, home: bool, script: Script) -> Harness {
    harness_with(settings, home, paired(), script)
}

/// [`harness`] in a conversation with `summary`'s participants.
fn harness_with(settings: Option<Value>, home: bool, summary: Summary, script: Script) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    if let Some(settings) = settings {
        std::fs::write(dir.path().join("settings.json"), settings.to_string()).unwrap();
    }
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(summary),
        ..Owner::default()
    }));
    let home_view = home.then(|| optchat_chief::home_view::HomeView {
        cli: dir.path().join("no-such-cmux-tui"),
        env: BTreeMap::new(),
    });
    let configured = optchat_chief::brain::Settings {
        home_view,
        ..settings_for(dir.path())
    };
    let mut h = Harness::configured(dir, script, owner, configured, Arc::new(|_: &str| {}));
    h.connect();
    h
}

fn settings_for(dir: &std::path::Path) -> optchat_chief::brain::Settings {
    common::settings(dir)
}

/// The gate on: a paired device's turn asks.
fn gated(script: Script) -> Harness {
    harness(Some(json!({"remote": {"ask": true}})), false, script)
}

fn deliver(h: &mut Harness, remote: bool, text: &str) {
    let m: Message = {
        let mut owner = h.owner.lock().unwrap();
        let seq = owner.messages.len() as u64 + 1;
        let mut m = message(seq, if remote { DEVICE } else { "user_local" }, text);
        if remote {
            m.origin = Some(Origin::Remote {
                install: "inst_1".into(),
            });
        }
        owner.messages.push(m.clone());
        m
    };
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: m },
    }));
}

fn started() -> Script {
    Box::new(|turn, _| {
        if turn == 0 {
            vec![json!({"dir": "mux", "kind": "turn_started", "msg": {}})]
        } else {
            vec![
                json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
                update(
                    "agent_message_chunk",
                    json!({"content": {"type": "text", "text": "done"}}),
                ),
                json!({"dir": "mux", "kind": "turn_end", "msg": {"stopReason": "end_turn"}}),
            ]
        }
    })
}

fn wait_session(h: &mut Harness) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while h
        .brain
        .state()
        .turn
        .as_ref()
        .and_then(|t| t.session_id.clone())
        .is_none()
    {
        assert!(Instant::now() < deadline, "the turn never started");
        h.step();
    }
}

/// A turn held at the fake agent, from a paired device (`remote`) or this Mac.
fn running(h: &mut Harness, remote: bool, text: &str) {
    h.agents.hold(true);
    deliver(h, remote, text);
    h.step();
    h.agents.wait_prompts(1);
    wait_session(h);
}

fn finish(h: &mut Harness) {
    h.agents.hold(false);
    h.agents.release();
    h.settle();
}

fn permission(id: &str, tool: &str, input: Value) -> Input {
    permission_in("s1", id, tool, input)
}

fn permission_in(session: &str, id: &str, tool: &str, input: Value) -> Input {
    Input::from(AgentEvent::Permission {
        session_id: session.into(),
        permission_id: id.into(),
        request: json!({
            "toolCall": {"toolCallId": format!("t-{id}"), "title": tool, "rawInput": input,
                         "_meta": {"claude": {"tool": tool}}},
            "options": [
                {"optionId": "allow_always", "name": "Always", "kind": "allow_always"},
                {"optionId": "allow", "name": "Allow", "kind": "allow_once"},
                {"optionId": "reject", "name": "Reject", "kind": "reject_once"}
            ]
        }),
    })
}

fn responses(h: &Harness) -> Vec<(String, String, Option<String>)> {
    h.agents.inner.lock().unwrap().responses.clone()
}

fn answered(h: &Harness, permission: &str) -> Option<Option<String>> {
    responses(h)
        .into_iter()
        .find(|r| r.1 == permission)
        .map(|r| r.2)
}

/// The approval messages the Chief posted: every send that is not a turn
/// reply (`approval:` keys), with its parts.
fn approvals(h: &Harness) -> Vec<Vec<Part>> {
    h.owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter(|(key, _)| key.starts_with("approval:"))
        .filter_map(|(_, op)| match op {
            Op::MessageSend { parts, .. } => Some(parts.clone()),
            _ => None,
        })
        .collect()
}

/// The first item of approval card `k` the Chief posted.
fn card(h: &Harness, k: usize) -> cmux_conversation::Question {
    match &approvals(h)[k][0] {
        Part::Question(q) => q.clone(),
        other => panic!("the approval is a question card: {other:?}"),
    }
}

/// `card` answered with `option` by `participant`, as the owner stamps it,
/// on the Chief's message in `conversation`.
fn answer(
    h: &mut Harness,
    conversation: &str,
    card: &cmux_conversation::Question,
    option: &str,
    participant: &str,
) {
    let mut answered = card.clone();
    answered.state = cmux_conversation::QuestionState::Answered {
        answer: cmux_conversation::QuestionAnswer {
            selections: BTreeMap::from([(
                "approval".to_owned(),
                cmux_conversation::QuestionSelection {
                    option_ids: vec![option.into()],
                    other: None,
                },
            )]),
            respondent: Some(cmux_conversation::Respondent {
                participant: participant.into(),
                display_name: participant.into(),
                device: None,
                remote: false,
            }),
            answered_at: None,
        },
    };
    let mut posted = message(90, "agent_mux", "");
    posted.conversation = conversation.into();
    posted.parts = vec![Part::Question(answered)];
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: conversation.into(),
        change: Change::MessageUpdated { message: posted },
    }));
}

fn owner_stop(h: &mut Harness) {
    let (reply, answer) = channel();
    h.brain.step(Input::Stop { reply });
    let answer = answer.try_recv().expect("chief.stop answers at once");
    assert_eq!(answer["stopped"], true, "{answer}");
}

fn policy(h: &Harness, k: usize) -> String {
    h.agents.inner.lock().unwrap().specs[k].policy.clone()
}

// (a) Origin: the owner's own turns on this Mac never ask.

#[test]
fn an_owner_cli_message_on_this_mac_runs_with_the_configured_policy_even_with_home() {
    // `cmux chief -p` sends as user_local over the owner socket (same uid):
    // a local message. The real host always reads the Home view, so before
    // this fix every such turn ran with policy ask.
    let mut h = harness(None, true, default_script());
    deliver(&mut h, false, "what is on my screen?");
    h.settle();
    assert_eq!(policy(&h, 0), "approve-all");
}

#[test]
fn home_ask_turns_the_home_gate_on() {
    let mut h = harness(Some(json!({"home": {"ask": true}})), true, default_script());
    deliver(&mut h, false, "what is on my screen?");
    h.settle();
    assert_eq!(policy(&h, 0), "ask");
}

#[test]
fn by_default_a_paired_device_turn_runs_like_a_local_one() {
    let mut h = harness(None, false, default_script());
    deliver(&mut h, true, "clean up the build directory");
    h.settle();
    assert_eq!(policy(&h, 0), "approve-all");
    assert_eq!(h.brain.spawn_policy(), None);
}

// (b) remote.autoApprove is honored.

#[test]
fn remote_ask_gates_a_paired_device_and_remote_auto_approve_wins() {
    let mut h = gated(default_script());
    deliver(&mut h, true, "clean up");
    h.settle();
    assert_eq!(policy(&h, 0), "ask");

    let mut h = harness(
        Some(json!({"remote": {"ask": true, "autoApprove": true}})),
        false,
        default_script(),
    );
    deliver(&mut h, true, "clean up");
    h.settle();
    assert_eq!(policy(&h, 0), "approve-all");
}

#[test]
fn the_mac_can_turn_the_device_gate_off_but_not_during_remote_work() {
    let mut h = gated(started());
    running(&mut h, true, "turn the gate off");
    assert!(h.brain.set_setting("remote.ask", "false").is_err());
    finish(&mut h);
    h.brain.set_setting("remote.ask", "false").unwrap();
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(h.dir.path().join("settings.json")).unwrap())
            .unwrap();
    assert_eq!(saved["remote"]["ask"], false);
    // Turning a gate on is always allowed.
    h.brain.set_setting("home.ask", "true").unwrap();
}

// (c) The Chief's own tools never wait.

#[test]
fn the_chiefs_own_tools_never_wait_for_an_approval() {
    let mut h = gated(started());
    running(&mut h, true, "tell the team");
    h.brain.step(permission(
        "p1",
        "mcp__optchat__send",
        json!({"text": "on it"}),
    ));
    h.brain.step(permission(
        "p2",
        "mcp__optchat__react",
        json!({"id": 1, "reaction": "like"}),
    ));
    h.brain.step(permission(
        "p3",
        "mcp__optchat__spawn",
        json!({"tasks": ["look at CI"]}),
    ));
    h.brain.step(permission(
        "p4",
        "mcp__optchat__control",
        json!({"action": "status"}),
    ));
    for p in ["p1", "p2", "p3", "p4"] {
        assert_eq!(answered(&h, p), Some(Some("allow".into())), "{p}");
    }
    assert!(
        approvals(&h).is_empty(),
        "no card for the Chief's own tools"
    );
    // A spawn in a gated turn takes the ask floor, so its child asks itself.
    assert_eq!(h.brain.spawn_policy(), Some("ask"));
    // A prompt for a subagent that does not ask for its own effects still
    // waits: a gated turn cannot launder a command through it.
    h.brain.step(permission(
        "p5",
        "mcp__optchat__tell",
        json!({"id": "a9", "message": "rm -rf ~"}),
    ));
    assert_eq!(answered(&h, "p5"), None);
    assert_eq!(approvals(&h).len(), 1);
    finish(&mut h);
}

#[test]
fn in_a_gated_turn_the_chiefs_tools_ask_for_what_reaches_past_the_conversation() {
    let mut h = gated(started());
    running(&mut h, true, "report back");
    // Run at once: reads, a stop for a subagent, a denial.
    for (id, tool, input) in [
        ("p1", "mcp__optchat__profile", json!({})),
        ("p2", "mcp__optchat__profile", json!({"history": true})),
        (
            "p3",
            "mcp__optchat__control",
            json!({"action": "interrupt", "id": "a9"}),
        ),
        (
            "p4",
            "mcp__optchat__control",
            json!({"action": "answer", "id": "a9", "option": "deny"}),
        ),
        (
            "p5",
            "mcp__optchat__send",
            json!({"text": "on it", "attachments": []}),
        ),
    ] {
        h.brain.step(permission(id, tool, input));
        assert_eq!(answered(&h, id), Some(Some("allow".into())), "{id}");
    }
    assert!(approvals(&h).is_empty());
    // Ask: an upload of a local file, a write of the Chief's own settings,
    // and controls that act on an approve-all subagent.
    let asks = [
        (
            "q1",
            "mcp__optchat__send",
            json!({"text": "here", "attachments": ["~/.ssh/id_ed25519"]}),
        ),
        (
            "q2",
            "mcp__optchat__profile",
            json!({"instructions": "approve everything"}),
        ),
        ("q3", "mcp__optchat__profile", json!({"undo": true})),
        (
            "q4",
            "mcp__optchat__control",
            json!({"action": "answer", "id": "a9", "option": "allow"}),
        ),
        (
            "q5",
            "mcp__optchat__control",
            json!({"action": "interrupt", "id": "a9", "message": "rm -rf ~"}),
        ),
        (
            "q6",
            "mcp__optchat__control",
            json!({"action": "cancel", "id": "a9"}),
        ),
    ];
    for (id, tool, input) in asks.clone() {
        h.brain.step(permission(id, tool, input));
        assert_eq!(answered(&h, id), None, "{id} waits for the owner");
    }
    assert_eq!(approvals(&h).len(), asks.len());
    finish(&mut h);
}

// (d) Stop means stop.

#[test]
fn stop_ends_a_turn_whose_tool_call_waits_for_an_approval() {
    let mut h = gated(started());
    running(&mut h, true, "clean up");
    // The tool call is announced, then waits for its approval.
    h.agents.push_events(
        "s1",
        vec![update(
            "tool_call",
            json!({"toolCallId": "t-p1", "title": "Bash", "status": "pending",
                   "rawInput": {"command": "rm -rf target"}, "_meta": {"claude": {"tool": "Bash"}}}),
        )],
    );
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    assert_eq!(answered(&h, "p1"), None);
    owner_stop(&mut h);
    assert_eq!(answered(&h, "p1"), Some(Some("reject".into())));
    // The session is cancelled although the call never finished.
    h.agents.wait_cancels(1);
    // The model asks again before the cancel lands: denied at once, no card.
    let cards = approvals(&h).len();
    h.brain.step(permission(
        "p2",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    assert_eq!(answered(&h, "p2"), Some(Some("reject".into())));
    assert_eq!(approvals(&h).len(), cards, "a stopped turn asks nobody");
    h.agents.hold(false);
    h.settle();
}

#[test]
fn a_denied_request_is_not_asked_again_and_a_loop_on_it_stops_the_turn() {
    let mut h = gated(started());
    running(&mut h, true, "clean up");
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    assert_eq!(approvals(&h).len(), 1);
    deliver(&mut h, false, "deny");
    assert_eq!(answered(&h, "p1"), Some(Some("reject".into())));
    // The same request again: denied at once, never a second card.
    for k in 2..=4 {
        let id = format!("p{k}");
        h.brain
            .step(permission(&id, "Bash", json!({"command": "rm -rf target"})));
        assert_eq!(answered(&h, &id), Some(Some("reject".into())), "{id}");
    }
    assert_eq!(approvals(&h).len(), 1, "one card for one request");
    // Three repeats stop the turn: the session is cancelled, and anything
    // it asks for after that is denied at once.
    h.agents.wait_cancels(1);
    h.brain
        .step(permission("p9", "Bash", json!({"command": "ls"})));
    assert_eq!(answered(&h, "p9"), Some(Some("reject".into())));
    assert_eq!(approvals(&h).len(), 1);
    h.agents.hold(false);
    h.settle();
    // The turn says why it stopped, in one line.
    let ops = format!("{:?}", h.owner.lock().unwrap().ops);
    assert!(
        ops.contains("I stopped: I kept asking to run `rm -rf target` after you denied it."),
        "{ops}"
    );
}

#[test]
fn a_cut_or_multi_line_command_shows_so_and_the_text_form_carries_the_arguments() {
    let mut h = gated(started());
    running(&mut h, true, "clean up");
    let long = format!("echo ok\nrm -rf ~ # {}", "x".repeat(200));
    h.brain
        .step(permission("p1", "Bash", json!({"command": long})));
    h.brain.step(permission(
        "p2",
        "Bash",
        json!({"command": "echo `whoami`"}),
    ));
    let prompt = card(&h, 0).items[0].prompt.clone();
    assert!(prompt.contains("echo ok \u{23ce} rm -rf ~"), "{prompt}");
    assert!(prompt.contains("\u{2026} (cut)"), "{prompt}");
    assert_eq!(
        card(&h, 1).items[0].prompt,
        "Allow Chief to run `` echo `whoami` ``?"
    );
    // The text form (for a client without cards) has the arguments too.
    let ops = h.owner.lock().unwrap().ops.clone();
    let plain = format!("{ops:?}");
    assert!(plain.contains("whoami"), "{plain}");
    finish(&mut h);
}

#[test]
fn a_gate_cannot_be_loosened_during_a_turn_that_asks() {
    let mut h = harness(Some(json!({"home": {"ask": true}})), true, started());
    running(&mut h, false, "what is on my screen?");
    assert!(h.brain.set_setting("home.ask", "false").is_err());
    assert!(h.brain.set_setting("remote.autoApprove", "true").is_err());
    finish(&mut h);
    h.brain.set_setting("home.ask", "false").unwrap();
}

// (e) A readable card that a newer message leaves alone.

#[test]
fn a_newer_message_leaves_a_pending_approval_alone() {
    let mut h = gated(started());
    running(&mut h, true, "clean up");
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    deliver(&mut h, false, "also check the logs");
    assert_eq!(answered(&h, "p1"), None, "only Allow or Deny answers it");
    deliver(&mut h, false, "allow");
    assert_eq!(answered(&h, "p1"), Some(Some("allow".into())));
    finish(&mut h);
}

#[test]
fn the_approval_is_a_readable_card_with_allow_and_deny() {
    let mut h = gated(started());
    running(&mut h, true, "clean up");
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    let cards = approvals(&h);
    assert_eq!(cards.len(), 1);
    let Part::Question(card) = &cards[0][0] else {
        panic!("the approval is a question card: {:?}", cards[0]);
    };
    let item = &card.items[0];
    assert_eq!(item.prompt, "Allow Chief to run `rm -rf target`?");
    assert!(!item.prompt.contains('{'), "no JSON in the card's line");
    let labels: Vec<&str> = item.options.iter().map(|o| o.label.as_str()).collect();
    assert_eq!(labels, ["Allow once", "Deny"]);
    let why = item.options[0].detail.as_deref().unwrap_or_default();
    assert!(why.contains("Leo's iPhone"), "{why}");
    let args = item.options[0].preview.as_ref().map(|p| p.text.clone());
    assert!(
        args.as_deref().is_some_and(|a| a.contains("rm -rf target")),
        "{args:?}"
    );
    assert_eq!(card.permission.as_deref(), Some("p1"));

    // The owner clicks Allow once: the owner stamps the answer on the card.
    let mut answered_card = card.clone();
    answered_card.state = cmux_conversation::QuestionState::Answered {
        answer: cmux_conversation::QuestionAnswer {
            selections: BTreeMap::from([(
                "approval".to_owned(),
                cmux_conversation::QuestionSelection {
                    option_ids: vec!["allow".into()],
                    other: None,
                },
            )]),
            respondent: Some(cmux_conversation::Respondent {
                participant: "user_local".into(),
                display_name: "Leo".into(),
                device: None,
                remote: false,
            }),
            answered_at: None,
        },
    };
    let mut posted = message(90, "agent_mux", "");
    posted.parts = vec![Part::Question(answered_card)];
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::MessageUpdated { message: posted },
    }));
    assert_eq!(answered(&h, "p1"), Some(Some("allow".into())));
    finish(&mut h);
}

#[test]
fn another_participants_answer_to_a_card_asks_the_owner_again() {
    let mut h = gated(started());
    running(&mut h, true, "clean up");
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    let first = card(&h, 0);
    answer(&mut h, CONV, &first, "allow", "user_bob");
    assert_eq!(answered(&h, "p1"), None, "only the owner approves");
    // The answered card is closed, so the owner gets a fresh one.
    assert_eq!(approvals(&h).len(), 2);
    let again = card(&h, 1);
    assert_eq!(again.permission.as_deref(), Some("p1"));
    // An answer on a card in another conversation does not count.
    answer(&mut h, "conv_other", &again, "allow", "user_local");
    assert_eq!(answered(&h, "p1"), None);
    answer(&mut h, CONV, &again, "deny", "user_local");
    assert_eq!(answered(&h, "p1"), Some(Some("reject".into())));
    finish(&mut h);
}

#[test]
fn a_card_in_a_side_conversation_is_answered_there() {
    let dir = tempfile::tempdir().unwrap();
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(paired()),
        ..Owner::default()
    }));
    let mut configured = settings_for(dir.path());
    configured.membership.local_side = true;
    let mut h = Harness::configured(dir, started(), owner, configured, Arc::new(|_: &str| {}));
    h.connect();
    // Bob is not the owner: his DM's turn asks.
    h.add_side("dm_bob", "user_bob");
    h.agents.hold(true);
    let m = h.post_side("dm_bob", "user_bob", "clean up");
    h.wake(&[("dm_bob", m.seq)]);
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    let session = h
        .brain
        .state()
        .turn
        .as_ref()
        .and_then(|t| t.session_id.clone())
        .unwrap();
    h.brain.step(permission_in(
        &session,
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    let sent = h.owner.lock().unwrap().stores["dm_bob"].ops.clone();
    let posted = sent
        .iter()
        .find_map(|(key, op)| match op {
            Op::MessageSend { parts, .. } if key.starts_with("approval:") => match &parts[0] {
                Part::Question(q) => Some(q.clone()),
                _ => None,
            },
            _ => None,
        })
        .expect("the card is posted in Bob's DM");
    answer(&mut h, "dm_bob", &posted, "allow", "user_local");
    assert_eq!(answered(&h, "p1"), Some(Some("allow".into())));
    finish(&mut h);
}

/// Runs the outbox's paced sends due within a few seconds, so posts queued
/// behind the agent gap are sent.
fn flush_paced(h: &mut Harness, sends: usize) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while approvals(h).len() < sends && Instant::now() < deadline {
        let Some(at) = h.brain.next_timer() else {
            break;
        };
        std::thread::sleep(at.saturating_duration_since(Instant::now()));
        h.brain.on_timer();
    }
}

// (e) An answer acpmux refuses never leaves the turn waiting with nobody
// asked: acpmux takes an allow only with the person's proof, which the
// Chief's own connection never has (2026-10-20: a refused Home "allow" was
// dropped and the turn waited until someone denied it by hand).

#[test]
fn an_allow_acpmux_refuses_keeps_the_approval_with_a_fresh_card() {
    let mut h = gated(started());
    h.agents.inner.lock().unwrap().refuse_allows = true;
    running(&mut h, true, "clean up");
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    let first = card(&h, 0);
    // The card answered on the phone, without the person's proof.
    answer(&mut h, CONV, &first, "allow", "user_local");
    assert_eq!(answered(&h, "p1"), None, "acpmux refused the allow");
    flush_paced(&mut h, 2);
    assert_eq!(approvals(&h).len(), 2, "a fresh card for the kept approval");
    let again = card(&h, 1);
    assert_eq!(again.permission.as_deref(), Some("p1"));
    // The kept approval still takes a deny.
    answer(&mut h, CONV, &again, "deny", "user_local");
    assert_eq!(answered(&h, "p1"), Some(Some("reject".into())));
    finish(&mut h);
}

#[test]
fn an_approval_the_app_already_answered_is_settled() {
    let mut h = gated(started());
    running(&mut h, true, "clean up");
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    let first = card(&h, 0);
    // The Mac app answered acpmux as the person before it answered the card.
    h.agents.inner.lock().unwrap().settled.push("p1".into());
    answer(&mut h, CONV, &first, "allow", "user_local");
    flush_paced(&mut h, 2);
    assert_eq!(approvals(&h).len(), 1, "no fresh card: it is settled");
    // Nothing is left to answer: a chat deny answers nothing.
    deliver(&mut h, false, "deny");
    assert_eq!(answered(&h, "p1"), None);
    assert_eq!(approvals(&h).len(), 1);
    finish(&mut h);
}

#[test]
fn a_refused_allow_of_the_chiefs_own_tool_asks_the_person() {
    let mut h = gated(started());
    h.agents.inner.lock().unwrap().refuse_allows = true;
    running(&mut h, true, "clean up");
    h.brain
        .step(permission("p1", "mcp__optchat__stop", json!({})));
    assert_eq!(answered(&h, "p1"), None);
    assert_eq!(approvals(&h).len(), 1, "asked as a card, not left waiting");
    assert_eq!(card(&h, 0).permission.as_deref(), Some("p1"));
    finish(&mut h);
}

// (f) approvals.autoApproveAll: no turn asks; only the owner turns it on.

const TEAMMATE: &str = "user_teammate";

/// A shared Chief: the paired device and a teammate (another person).
fn shared() -> Summary {
    let mut s = paired();
    s.participants.push(Participant {
        id: TEAMMATE.into(),
        kind: ParticipantKind::Human,
        display_name: "Teammate".into(),
        agent_class: None,
        acp_session: None,
        person: None,
    });
    s
}

/// A message of `author` that mentions the Chief (a group conversation).
fn deliver_mention(h: &mut Harness, author: &str, text: &str) {
    let m = {
        let mut owner = h.owner.lock().unwrap();
        let seq = owner.messages.len() as u64 + 1;
        let mut m = message(seq, author, text);
        m.parts = vec![Part::Text {
            text: text.into(),
            runs: Some(vec![cmux_conversation::TextRun {
                start: 0,
                length: text.encode_utf16().count() as u32,
                mention: Some("agent_mux".into()),
                link: None,
            }]),
        }];
        owner.messages.push(m.clone());
        m
    };
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: m },
    }));
}

/// A held turn the teammate started.
fn teammate_running(h: &mut Harness, text: &str) {
    h.agents.hold(true);
    deliver_mention(h, TEAMMATE, text);
    h.step();
    h.agents.wait_prompts(1);
    wait_session(h);
}

fn saved(h: &Harness) -> Value {
    std::fs::read_to_string(h.dir.path().join("settings.json"))
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or(Value::Null)
}

#[test]
fn auto_approve_all_is_off_by_default_and_a_teammates_turn_still_asks() {
    assert!(!optchat_chief::chief_settings::ChiefSettings::default().auto_approve_all);
    let mut h = harness_with(None, false, shared(), started());
    assert!(!h.brain.auto_approve_all());
    teammate_running(&mut h, "@Chief clean the build directory");
    assert_eq!(policy(&h, 0), "ask");
    finish(&mut h);
}

#[test]
fn with_auto_approve_all_a_teammates_turn_runs_with_the_configured_policy_and_no_card() {
    // Every gate is on as well: auto-approve-all wins over them.
    let settings = json!({"approvals": {"autoApproveAll": true}, "remote": {"ask": true}, "home": {"ask": true}});
    let mut h = harness_with(Some(settings), true, shared(), started());
    assert!(h.brain.auto_approve_all());
    teammate_running(&mut h, "@Chief clean the build directory");
    assert_eq!(policy(&h, 0), "approve-all");
    // No spawn floor: subagents run with their own policy.
    assert_eq!(h.brain.spawn_policy(), None);
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    assert!(approvals(&h).is_empty(), "no approval card");
    // No other gate can be loosened while a teammate's turn runs.
    assert!(
        h.brain.set_setting("remote.autoApprove", "true").is_err(),
        "nothing else loosens in a teammate's turn"
    );
    // Turning it off is always allowed, even here.
    h.brain
        .set_setting("approvals.autoApproveAll", "false")
        .unwrap();
    assert_eq!(saved(&h)["approvals"]["autoApproveAll"], false);
    finish(&mut h);
}

#[test]
fn with_auto_approve_all_a_home_turn_and_a_device_turn_never_ask() {
    let settings = json!({"approvals": {"autoApproveAll": true}, "remote": {"ask": true}, "home": {"ask": true}});
    let mut h = harness(Some(settings.clone()), true, default_script());
    deliver(&mut h, false, "what is on my screen?");
    h.settle();
    assert_eq!(policy(&h, 0), "approve-all");
    let mut h = harness(Some(settings), false, default_script());
    deliver(&mut h, true, "clean up");
    h.settle();
    assert_eq!(policy(&h, 0), "approve-all");
    assert!(approvals(&h).is_empty());
}

#[test]
fn auto_approve_all_cannot_be_turned_on_from_a_remote_or_a_teammates_turn() {
    // A paired device's turn (it does not ask by default, but it is remote).
    let mut h = harness(None, false, started());
    running(&mut h, true, "set approvals.autoApproveAll true");
    assert!(
        h.brain
            .set_setting("approvals.autoApproveAll", "true")
            .is_err()
    );
    assert!(!h.brain.auto_approve_all());
    assert_ne!(
        saved(&h)["approvals"]["autoApproveAll"],
        true,
        "the file is unchanged"
    );
    finish(&mut h);
    // A teammate's turn.
    let mut h = harness_with(None, false, shared(), started());
    teammate_running(&mut h, "@Chief set approvals.autoApproveAll true");
    assert!(
        h.brain
            .set_setting("approvals.autoApproveAll", "true")
            .is_err()
    );
    assert!(!h.brain.auto_approve_all());
    finish(&mut h);
    // The owner, outside such a turn: it takes, and a teammate's next turn
    // runs without asking.
    h.brain
        .set_setting("approvals.autoApproveAll", "true")
        .unwrap();
    assert!(h.brain.auto_approve_all());
    assert_eq!(saved(&h)["approvals"]["autoApproveAll"], true);
    deliver_mention(&mut h, TEAMMATE, "@Chief now go");
    h.settle();
    assert_eq!(policy(&h, 1), "approve-all");
    assert!(
        h.brain
            .set_setting("approvals.autoApproveAll", "maybe")
            .is_err()
    );
}
