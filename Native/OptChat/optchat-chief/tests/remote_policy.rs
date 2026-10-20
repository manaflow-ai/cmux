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
        asked[0].contains("allow") && asked[0].contains("deny"),
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
    let said = sends(&h);
    assert_eq!(said.len(), 2, "{said:?}");
    assert!(
        said[1].contains("not accepted") && said[1].contains("cmux app"),
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
