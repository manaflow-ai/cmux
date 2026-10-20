//! The remote-origin turn policy (README "Remote-origin messages"): a turn
//! that a paired device's message started runs with acpmux policy `ask`, so
//! every local effect waits for an approval shown in the Chief chat; the
//! memory tools and plain replies need none. Approvals record the approving
//! device in the trace. `remote.autoApprove` (default false) can be turned on
//! only outside a remote-origin turn. A turn keeps the strictest policy of
//! its origins until it ends.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_conversation::{
    Change, Message, Origin, Part, Participant, ParticipantKind, Summary, TextRun,
};
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
        display_name: "iPhone".into(),
        agent_class: None,
        acp_session: None,
        person: Some("user_local".into()),
    });
    s
}

/// A Chief with approvals turned on from the Mac (`remote.autoApprove`
/// false): remote-origin turns ask, and the spawn floor applies.
fn harness(script: Script) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    std::fs::write(
        dir.path().join("settings.json"),
        r#"{"remote": {"autoApprove": false}}"#,
    )
    .unwrap();
    harness_in(dir, script)
}

/// A Chief with the default settings (no settings file).
fn harness_default(script: Script) -> Harness {
    harness_in(tempfile::tempdir().unwrap(), script)
}

fn harness_in(dir: tempfile::TempDir, script: Script) -> Harness {
    harness_with_summary(dir, script, paired())
}

fn harness_with_summary(dir: tempfile::TempDir, script: Script, summary: Summary) -> Harness {
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(summary),
        ..Owner::default()
    }));
    let mut h = Harness::in_dir(dir, script, owner);
    h.connect();
    h
}

fn deliver_mention(h: &mut Harness, author: &str, text: &str) {
    let m = {
        let mut owner = h.owner.lock().unwrap();
        let seq = owner.messages.len() as u64 + 1;
        let mut m = message(seq, author, text);
        m.parts = vec![Part::Text {
            text: text.into(),
            runs: Some(vec![TextRun {
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

/// A message as the subscription delivers it; `remote` stamps the relay's
/// origin of the paired device.
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

/// Steps the brain until the running turn's session id is known.
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

fn permission(id: &str, tool: &str, input: Value) -> Input {
    permission_of("s1", id, tool, input)
}

fn permission_of(session: &str, id: &str, tool: &str, input: Value) -> Input {
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

fn sends(h: &Harness) -> Vec<String> {
    h.owner
        .lock()
        .unwrap()
        .sends()
        .into_iter()
        .map(|(_, text)| text)
        .collect()
}

fn traces(h: &Harness) -> Vec<Value> {
    let dir = h.dir.path().join("traces");
    let mut out = Vec::new();
    for entry in std::fs::read_dir(&dir).into_iter().flatten().flatten() {
        let text = std::fs::read_to_string(entry.path()).unwrap();
        out.extend(
            text.lines()
                .map(|l| serde_json::from_str::<Value>(l).unwrap()),
        );
    }
    out
}

#[test]
fn a_local_turn_keeps_its_policy() {
    let mut h = harness(default_script());
    deliver(&mut h, false, "hello");
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert_eq!(inner.specs[0].policy, "approve-all");
}

#[test]
fn a_non_owner_turn_asks_and_only_the_owner_may_approve_it() {
    let mut s = paired();
    s.participants.push(Participant {
        id: "user_teammate".into(),
        kind: ParticipantKind::Human,
        display_name: "Teammate".into(),
        agent_class: None,
        acp_session: None,
        person: None,
    });
    let mut h = harness_with_summary(tempfile::tempdir().unwrap(), started(), s);
    h.agents.hold(true);
    deliver_mention(&mut h, "user_teammate", "@Chief clean the build directory");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].policy, "ask");

    h.brain.step(permission(
        "p-owner",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    deliver_mention(&mut h, "user_teammate", "allow");
    assert!(
        !h.agents
            .inner
            .lock()
            .unwrap()
            .responses
            .iter()
            .any(|r| r.1 == "p-owner"),
        "a teammate cannot approve effects on the owner's Mac"
    );
    deliver_mention(&mut h, "user_local", "allow");
    assert!(h.agents.inner.lock().unwrap().responses.contains(&(
        "s1".into(),
        "p-owner".into(),
        Some("allow".into())
    )));
    h.agents.hold(false);
    h.agents.release();
    h.settle();
}

#[test]
fn ambient_home_terminal_text_makes_the_turn_ask() {
    use std::collections::BTreeMap;
    use std::os::unix::fs::PermissionsExt;

    let dir = tempfile::tempdir().unwrap();
    let cli = dir.path().join("cmux-home-fixture");
    let snapshot = dir.path().join("snapshot.json");
    std::fs::write(
        &snapshot,
        json!({
            "workspaces": [{"id": "ws_home", "extra": {"kind": "home"}}],
            "screens": [{"id": "screen_home", "workspace_id": "ws_home", "focused": true,
                         "layout": {"root": {"pane_ids": ["pane_right"]}}}],
            "panes": [{"id": "pane_right", "screen_id": "screen_home", "focused": true}],
            "tabs": [{"id": "tab_term", "pane_id": "pane_right", "index": 0, "focused": true,
                      "content_kind": "terminal", "content_id": "term_untrusted"}],
            "terminals": [{"id": "term_untrusted", "title": "build", "running": true}],
            "browsers": [], "agents": []
        })
        .to_string(),
    )
    .unwrap();
    std::fs::write(
        &cli,
        format!(
            "#!/bin/sh\ncase \"$*\" in\n  '--json session current snapshot') cat '{}' ;;\n  *) printf '%s\\n' '{{\"text\":\"untrusted terminal text\"}}' ;;\nesac\n",
            snapshot.display()
        ),
    )
    .unwrap();
    std::fs::set_permissions(&cli, std::fs::Permissions::from_mode(0o755)).unwrap();
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(paired()),
        ..Owner::default()
    }));
    let configured = optchat_chief::brain::Settings {
        home_view: Some(optchat_chief::home_view::HomeView {
            cli,
            env: BTreeMap::new(),
        }),
        ..settings(dir.path())
    };
    let mut h = Harness::configured(
        dir,
        default_script(),
        owner,
        configured,
        Arc::new(|_: &str| {}),
    );
    h.connect();
    deliver(&mut h, false, "hello");
    h.settle();
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].policy, "ask");
}

#[test]
fn a_remote_turn_cannot_run_a_shell_without_an_approval() {
    let mut h = harness(started());
    h.agents.hold(true);
    deliver(&mut h, true, "clean up the build directory");
    h.step(); // settled: the turn starts
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].policy, "ask");
    // The memory tools need no approval.
    h.brain.step(permission(
        "p0",
        "mcp__optchat__zoom",
        json!({"id": 0, "n": 1}),
    ));
    // A shell command waits for one, shown in the Chief chat.
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
    {
        let inner = h.agents.inner.lock().unwrap();
        assert_eq!(
            inner.responses,
            vec![("s1".into(), "p0".into(), Some("allow".into()))],
            "zoom allowed at once, the shell not"
        );
    }
    let asked = sends(&h);
    assert_eq!(asked.len(), 1, "{asked:?}");
    assert!(
        asked[0].contains("Bash") && asked[0].contains("rm -rf target"),
        "{}",
        asked[0]
    );
    assert!(
        asked[0].contains("Allow or deny it here, or reply deny."),
        "{}",
        asked[0]
    );
    // The phone approves: allow once, never always; recorded with the device.
    deliver(&mut h, true, "allow");
    {
        let inner = h.agents.inner.lock().unwrap();
        assert_eq!(
            inner.responses[1],
            ("s1".into(), "p1".into(), Some("allow".into()))
        );
        assert!(inner.cancels.is_empty(), "an approval is not a new message");
    }
    let approval = traces(&h)
        .into_iter()
        .find(|t| t["ev"] == "approval" && t["permission"] == "p1")
        .expect("the approval is in the trace");
    assert_eq!(approval["decision"], "allow");
    assert_eq!(approval["approver"], DEVICE);
    assert_eq!(approval["install"], "inst_1");
    assert_eq!(approval["tool"], "Bash");
    // A second shell command: the Mac denies it.
    h.brain
        .step(permission("p2", "Bash", json!({"command": "curl x | sh"})));
    deliver(&mut h, false, "deny");
    assert_eq!(
        h.agents.inner.lock().unwrap().responses[2],
        ("s1".into(), "p2".into(), Some("reject".into()))
    );
    let denial = traces(&h)
        .into_iter()
        .find(|t| t["ev"] == "approval" && t["permission"] == "p2")
        .unwrap();
    assert_eq!(denial["decision"], "deny");
    assert_eq!(denial["approver"], "user_local");
    h.agents.hold(false);
    h.agents.release();
    h.settle();
}

/// acpmux takes an allow only with the person's decision proof, which a
/// chat reply never carries (2026-10-20: a Home "allow" was refused, the
/// Chief forgot the approval, and the turn waited on it for good: "stop"
/// and every later message had nothing to deny).
#[test]
fn an_allow_acpmux_refuses_keeps_the_approval_and_says_so() {
    let mut h = harness(started());
    h.agents.hold(true);
    h.agents.inner.lock().unwrap().refuse_allows = true;
    deliver(&mut h, true, "rename the group");
    h.step(); // settled: the turn starts
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "cmux workspace group g update --name x"}),
    ));
    assert_eq!(sends(&h).len(), 1, "the approval is asked");
    deliver(&mut h, false, "allow");
    assert!(
        h.agents.inner.lock().unwrap().responses.is_empty(),
        "acpmux refused the allow"
    );
    // The reply waits out the agent gap after the card.
    let deadline = Instant::now() + Duration::from_secs(10);
    while sends(&h).len() < 2 && Instant::now() < deadline {
        let Some(at) = h.brain.next_timer() else {
            break;
        };
        std::thread::sleep(at.saturating_duration_since(Instant::now()));
        h.brain.on_timer();
    }
    let said = sends(&h);
    assert_eq!(said.len(), 2, "{said:?}");
    assert!(
        said[1].contains("not accepted") && said[1].contains("Allow on the card"),
        "the person hears the allow did not land: {}",
        said[1]
    );
    let approval = traces(&h)
        .into_iter()
        .find(|t| t["ev"] == "approval" && t["permission"] == "p1")
        .expect("the refused allow is in the trace");
    assert_eq!(approval["delivered"], false);
    // A newer message still denies the held approval, so the turn moves on.
    deliver(&mut h, false, "stop");
    assert_eq!(
        h.agents.inner.lock().unwrap().responses,
        vec![("s1".into(), "p1".into(), Some("reject".into()))],
        "the approval was kept, and the newer message denied it"
    );
    h.agents.hold(false);
    h.agents.release();
    h.settle();
}

/// The asked approval's message: its one question part.
fn asked_card(h: &Harness) -> (String, cmux_conversation::Question) {
    let owner = h.owner.lock().unwrap();
    owner
        .messages
        .iter()
        .rev()
        .find_map(|m| match m.parts.first() {
            Some(Part::Question(q)) => Some((m.id.clone(), q.clone())),
            _ => None,
        })
        .expect("an approval card was posted")
}

/// The card answered by the Mac user with `option`, as the owner delivers it.
fn answer_card(h: &mut Harness, option: &str) {
    use cmux_conversation::{QuestionAnswer, QuestionSelection, QuestionState, Respondent};
    let m = {
        let mut owner = h.owner.lock().unwrap();
        let m = owner
            .messages
            .iter_mut()
            .rev()
            .find(|m| matches!(m.parts.first(), Some(Part::Question(_))))
            .unwrap();
        if let Some(Part::Question(q)) = m.parts.first_mut() {
            q.state = QuestionState::Answered {
                answer: QuestionAnswer {
                    selections: [(
                        "approval".to_owned(),
                        QuestionSelection {
                            option_ids: vec![option.to_owned()],
                            other: None,
                        },
                    )]
                    .into(),
                    respondent: Some(Respondent {
                        participant: "user_local".into(),
                        display_name: "Me".into(),
                        device: None,
                        remote: false,
                    }),
                    answered_at: Some("2026-10-20T14:00:00.000Z".into()),
                },
            };
        }
        m.clone()
    };
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::MessageUpdated { message: m },
    }));
}

/// Starts a remote turn that asks for one shell command (p1).
fn asking(h: &mut Harness) {
    h.agents.hold(true);
    deliver(h, true, "clean up");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(h);
    h.brain.step(permission(
        "p1",
        "Bash",
        json!({"command": "rm -rf target"}),
    ));
}

fn finish(h: &mut Harness) {
    h.agents.hold(false);
    h.agents.release();
    h.settle();
}

#[test]
fn an_approval_is_asked_as_a_card() {
    use cmux_conversation::{QuestionHarness, QuestionState};
    let mut h = harness(started());
    asking(&mut h);
    let (_, q) = asked_card(&h);
    assert_eq!(q.harness, QuestionHarness::Chief);
    assert_eq!(q.session, "s1");
    assert_eq!(q.permission.as_deref(), Some("p1"));
    assert_eq!(q.agent, None);
    assert_eq!(q.state, QuestionState::Pending);
    assert_eq!(q.items.len(), 1);
    let item = &q.items[0];
    assert_eq!(item.id, "approval");
    assert_eq!(item.header.as_deref(), Some("Approval"));
    assert!(!item.multi_select && !item.allows_other);
    let options: Vec<_> = item
        .options
        .iter()
        .map(|o| (o.id.as_str(), o.label.as_str()))
        .collect();
    assert_eq!(options, vec![("allow", "Allow"), ("deny", "Deny")]);
    assert!(item.prompt.contains("Bash") && item.prompt.contains("rm -rf target"));
    assert!(item.prompt.len() <= cmux_conversation::MAX_QUESTION_TEXT_BYTES);
    finish(&mut h);
}

#[test]
fn a_long_input_is_cut_to_fit_the_card() {
    let mut h = harness(started());
    h.agents.hold(true);
    deliver(&mut h, true, "clean up");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    let long = "é".repeat(3000);
    h.brain
        .step(permission("p1", "Bash", json!({"command": long})));
    let (_, q) = asked_card(&h);
    let prompt = &q.items[0].prompt;
    assert!(
        prompt.len() <= cmux_conversation::MAX_QUESTION_TEXT_BYTES,
        "{}",
        prompt.len()
    );
    assert!(prompt.ends_with("Allow or deny it here, or reply deny."));
    finish(&mut h);
}

#[test]
fn deny_on_the_card_rejects_the_permission() {
    let mut h = harness(started());
    asking(&mut h);
    answer_card(&mut h, "deny");
    assert_eq!(
        h.agents.inner.lock().unwrap().responses,
        vec![("s1".into(), "p1".into(), Some("reject".into()))]
    );
    // Settled: a later chat "allow" answers nothing.
    deliver(&mut h, false, "allow");
    assert_eq!(h.agents.inner.lock().unwrap().responses.len(), 1);
    finish(&mut h);
}

#[test]
fn allow_on_the_card_is_the_apps_answer_and_the_chief_does_not_allow() {
    let mut h = harness(started());
    h.agents.inner.lock().unwrap().refuse_allows = true;
    asking(&mut h);
    // The Mac app answered acpmux with the person's proof before the card.
    h.agents.inner.lock().unwrap().settled.push("p1".into());
    answer_card(&mut h, "allow");
    assert!(
        h.agents.inner.lock().unwrap().responses.is_empty(),
        "the app answered acpmux; the Chief's answer lands nowhere"
    );
    let approval = traces(&h)
        .into_iter()
        .rfind(|t| t["ev"] == "approval" && t["permission"] == "p1")
        .expect("the card's allow is in the trace");
    assert_eq!(approval["decision"], "allow");
    assert_eq!(approval["approver"], "user_local");
    assert_eq!(approval["delivered"], true);
    // The pending is gone: a newer message denies nothing.
    deliver(&mut h, false, "something else");
    assert!(h.agents.inner.lock().unwrap().responses.is_empty());
    assert_eq!(
        sends(&h).len(),
        1,
        "no 'not accepted' reply: {:?}",
        sends(&h)
    );
    finish(&mut h);
}

/// A card answered Allow without the person's proof (a paired device,
/// another person): acpmux still holds the request, so the approval stays,
/// the person hears why, and a newer message still denies it.
#[test]
fn an_allow_on_the_card_acpmux_refuses_keeps_the_approval() {
    let mut h = harness(started());
    h.agents.inner.lock().unwrap().refuse_allows = true;
    asking(&mut h);
    answer_card(&mut h, "allow");
    assert!(h.agents.inner.lock().unwrap().responses.is_empty());
    // The reply waits out the agent gap after the card.
    let deadline = Instant::now() + Duration::from_secs(10);
    while sends(&h).len() < 2 && Instant::now() < deadline {
        let Some(at) = h.brain.next_timer() else {
            break;
        };
        std::thread::sleep(at.saturating_duration_since(Instant::now()));
        h.brain.on_timer();
    }
    let said = sends(&h);
    assert_eq!(said.len(), 2, "{said:?}");
    assert!(said[1].contains("not accepted"), "{}", said[1]);
    deliver(&mut h, false, "never mind");
    assert_eq!(
        h.agents.inner.lock().unwrap().responses,
        vec![("s1".into(), "p1".into(), Some("reject".into()))],
        "the kept approval was denied by the newer message"
    );
    finish(&mut h);
}

#[test]
fn a_chat_deny_cancels_the_card() {
    use cmux_conversation::{Op, QuestionState};
    let mut h = harness(started());
    asking(&mut h);
    let (id, card) = asked_card(&h);
    deliver(&mut h, false, "deny");
    let edits: Vec<_> = h
        .owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter_map(|(_, op)| match op {
            Op::MessageEdit { message_id, parts } => Some((message_id.clone(), parts.clone())),
            _ => None,
        })
        .collect();
    assert_eq!(edits.len(), 1, "{edits:?}");
    assert_eq!(edits[0].0, id);
    let cancelled = cmux_conversation::Question {
        state: QuestionState::Cancelled,
        ..card
    };
    assert_eq!(edits[0].1, vec![Part::Question(cancelled)]);
    finish(&mut h);
}

/// acpmux refuses the Chief's allow of a memory tool too (2026-10-20: the
/// turn waited on mcp__optchat__version and nobody was asked): the Chief
/// denies it so the turn goes on, and asks nothing.
#[test]
fn a_refused_memory_tool_allow_is_denied_and_nothing_is_asked() {
    let mut h = harness(started());
    h.agents.inner.lock().unwrap().refuse_allows = true;
    h.agents.hold(true);
    deliver(&mut h, true, "what did we say yesterday");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    h.brain.step(permission(
        "p0",
        "mcp__optchat__zoom",
        json!({"id": 0, "n": 1}),
    ));
    assert_eq!(
        h.agents.inner.lock().unwrap().responses,
        vec![("s1".into(), "p0".into(), Some("reject".into()))]
    );
    assert!(sends(&h).is_empty(), "{:?}", sends(&h));
    finish(&mut h);
}

#[test]
fn the_card_says_why_the_turn_asks() {
    let mut h = harness(started());
    asking(&mut h);
    let (_, q) = asked_card(&h);
    assert!(
        q.items[0]
            .prompt
            .contains("this turn started from a paired device"),
        "{}",
        q.items[0].prompt
    );
    finish(&mut h);
}

#[test]
fn a_local_ambient_turn_does_not_claim_a_paired_device() {
    use optchat_chief::approval::{AskReason, Pending, question};
    let pending = Pending {
        session_id: "s1".into(),
        permission_id: "p1".into(),
        tool: "Bash".into(),
        request: json!({"toolCall": {"rawInput": {"command": "ls"}}}),
        child: None,
        conversation: None,
    };
    let ambient = question(&pending, AskReason::Ambient);
    assert!(ambient.contains("Home terminals"), "{ambient}");
    assert!(!ambient.contains("paired device"), "{ambient}");
    let unknown = question(&pending, AskReason::Unknown);
    assert!(
        unknown.contains("this turn needs approval for local effects"),
        "{unknown}"
    );
}

#[test]
fn a_remote_message_cannot_turn_on_remote_auto_approve() {
    let mut h = harness(started());
    h.agents.hold(true);
    deliver(&mut h, true, "set remote.autoApprove true");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    // During a remote-origin turn the setting cannot be turned on, whatever
    // asks (an approved shell command reaches the host the same way).
    assert!(h.brain.set_setting("remote.autoApprove", "true").is_err());
    assert!(!h.brain.remote_auto_approve());
    let kept: Value =
        serde_json::from_str(&std::fs::read_to_string(h.dir.path().join("settings.json")).unwrap())
            .unwrap();
    assert_eq!(
        kept["remote"]["autoApprove"], false,
        "the file is unchanged"
    );
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    // From the Mac, outside a remote turn, it can; a later remote turn then
    // runs with the configured policy.
    h.brain.set_setting("remote.autoApprove", "true").unwrap();
    assert!(h.brain.remote_auto_approve());
    let saved: Value =
        serde_json::from_str(&std::fs::read_to_string(h.dir.path().join("settings.json")).unwrap())
            .unwrap();
    assert_eq!(saved["remote"]["autoApprove"], true);
    deliver(&mut h, true, "now go");
    h.settle();
    assert_eq!(
        h.agents.inner.lock().unwrap().specs[1].policy,
        "approve-all"
    );
    // Turning it off is always allowed; unknown keys are refused.
    h.brain.set_setting("remote.autoApprove", "false").unwrap();
    assert!(h.brain.set_setting("remote.other", "true").is_err());
}

#[test]
fn a_mixed_origin_turn_stays_ask() {
    let mut h = harness(started());
    h.agents.inner.lock().unwrap().steering = true;
    h.agents.hold(true);
    deliver(&mut h, true, "deploy the site");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    // A local message mid-turn is steered in (never a stop); the turn keeps
    // the remote turn's policy.
    deliver(&mut h, false, "and tell me when done");
    h.agents.wait_steers(1);
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    let inner = h.agents.inner.lock().unwrap();
    assert!(inner.cancels.is_empty());
    assert_eq!(inner.specs.len(), 1);
    assert_eq!(inner.specs[0].policy, "ask");
}

/// A child that an approved spawn of an `ask` turn started: the `chief
/// agents spawn` CLI tags it `optchat.policy=ask` and gives it policy `ask`
/// whatever `--policy` says, because the host's spawn floor is `ask`.
fn ask_child(status: &str) -> cmux_chief::acp::SessionSummary {
    serde_json::from_value(json!({
        "sessionId": "c1", "name": "a1", "status": status, "harness": "claude-sr",
        "tags": {"mux.parent": optchat_chief::brain::PARENT, "optchat.policy": "ask"}
    }))
    .unwrap()
}

#[test]
fn a_child_spawned_from_an_ask_turn_asks_too() {
    use optchat_chief::agents::{apply_floor, cli_may_answer};
    // The CLI: the host's floor wins over --policy and MUX_POLICY.
    assert_eq!(apply_floor("approve-all", Some("ask")), "ask");
    assert_eq!(apply_floor("approve-all", None), "approve-all");
    let mut h = harness(started());
    assert_eq!(
        h.brain.spawn_policy(),
        None,
        "a local Chief spawns as before"
    );
    h.agents.hold(true);
    deliver(&mut h, true, "start an agent that cleans the cache");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    assert_eq!(h.brain.spawn_policy(), Some("ask"));
    // The approved spawn's child appears; then the turn ends.
    h.brain
        .step(Input::from(AgentEvent::SessionChanged(ask_child(
            "running",
        ))));
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    // Transitively: while an ask child runs, anything it (or anyone) spawns
    // asks too, and remote.autoApprove cannot be turned on.
    assert_eq!(h.brain.spawn_policy(), Some("ask"));
    assert!(h.brain.set_setting("remote.autoApprove", "true").is_err());
    // The child's shell call waits for a person, asked in the Chief chat
    // with the child's id.
    let before = sends(&h).len();
    h.brain.step(permission_of(
        "c1",
        "p9",
        "Bash",
        json!({"command": "rm -rf ~/.cache"}),
    ));
    assert!(
        !h.agents
            .inner
            .lock()
            .unwrap()
            .responses
            .iter()
            .any(|r| r.1 == "p9"),
        "the child's shell call waits"
    );
    let asked = sends(&h);
    assert_eq!(asked.len(), before + 1, "{asked:?}");
    let question = asked.last().unwrap();
    assert!(
        question.contains("a1") && question.contains("rm -rf ~/.cache"),
        "{question}"
    );
    // The Chief's own `agents allow` cannot answer it; a person does.
    assert!(cli_may_answer(&ask_child("running"), &serde_json::json!({})).is_err());
    deliver(&mut h, false, "allow");
    assert!(h.agents.inner.lock().unwrap().responses.contains(&(
        "c1".into(),
        "p9".into(),
        Some("allow".into())
    )));
    let approval = traces(&h)
        .into_iter()
        .find(|t| t["ev"] == "approval" && t["permission"] == "p9")
        .unwrap();
    assert_eq!(approval["child"], "a1");
    assert_eq!(approval["approver"], "user_local");
    // Once the ask child is gone, spawns follow the configured policy again.
    h.brain
        .step(Input::from(AgentEvent::SessionChanged(ask_child("closed"))));
    assert_eq!(h.brain.spawn_policy(), None);
}

/// Security floor for section 9's host-served `spawn`: a subagent spawned
/// during a remote-origin (ask) turn runs with policy ask and carries
/// `optchat.policy=ask`; its shell call waits for a person, asked in the
/// Chief chat with its id; and while it runs, the floor stays ask.
#[test]
fn a_subagent_spawned_during_a_remote_turn_asks_too() {
    use optchat_chief::subagents::{Spawner, SubagentSettings};
    use optchat_chief::tools::Orchestrator;
    let mut h = harness(started());
    h.agents.hold(true);
    deliver(&mut h, true, "spawn a subagent that cleans the cache");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    assert_eq!(h.brain.spawn_policy(), Some("ask"));
    let spawner = Arc::new(Spawner::new(
        h.chat.clone(),
        h.agents.clone(),
        SubagentSettings {
            harness: "claude-sr".into(),
            policy: "approve-all".into(),
            model: None,
            effort: None,
            preset: Some("optchat-sub-h0me".into()),
            cwd: h.dir.path().join("subagent"),
            prefix: "optchat-sub-h0me".into(),
            parent: optchat_chief::brain::PARENT.into(),
            claude_md: None,
        },
        h.tx.clone(),
        Arc::new(|_: &str| {}),
    ));
    let worker = {
        let spawner = spawner.clone();
        std::thread::spawn(move || spawner.spawn(vec!["clean the cache".into()], None))
    };
    while !worker.is_finished() {
        if let Ok(input) = h.rx.recv_timeout(Duration::from_millis(20)) {
            h.brain.step(input);
        }
    }
    while let Ok(input) = h.rx.recv_timeout(Duration::from_millis(50)) {
        h.brain.step(input);
    }
    assert!(worker.join().unwrap().is_ok());
    let (session, spec) = {
        let agents = h.agents.inner.lock().unwrap();
        let k = agents
            .specs
            .iter()
            .position(|s| s.tags.contains_key("optchat.subagent"))
            .expect("the subagent session");
        (format!("s{}", k + 1), agents.specs[k].clone())
    };
    assert_eq!(spec.policy, "ask", "the floor wins over approve-all");
    assert_eq!(
        spec.tags.get("optchat.policy").map(String::as_str),
        Some("ask")
    );
    let before = sends(&h).len();
    h.brain.step(permission_of(
        &session,
        "p7",
        "Bash",
        json!({"command": "rm -rf ~/.cache"}),
    ));
    assert!(
        !h.agents
            .inner
            .lock()
            .unwrap()
            .responses
            .iter()
            .any(|r| r.1 == "p7"),
        "the subagent's shell call waits"
    );
    let asked = sends(&h);
    assert_eq!(asked.len(), before + 1, "{asked:?}");
    assert!(asked.last().unwrap().contains("a1"), "{asked:?}");
    // The turn ends; the running ask subagent keeps the floor at ask.
    h.agents.hold(false);
    h.agents.release();
    h.settle();
    assert_eq!(h.brain.spawn_policy(), Some("ask"));
}

#[test]
fn by_default_a_remote_turn_asks_and_keeps_the_spawn_floor() {
    let mut h = harness_default(started());
    h.agents.hold(true);
    deliver(&mut h, true, "clean up the build directory");
    h.step();
    h.agents.wait_prompts(1);
    wait_session(&mut h);
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].policy, "ask");
    assert_eq!(h.brain.spawn_policy(), Some("ask"));
    h.agents.hold(false);
    h.agents.release();
    h.settle();
}
