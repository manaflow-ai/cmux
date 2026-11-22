//! The rights table, the audit and the caps in the brain (rights.rs,
//! audit.rs, brain/rights_gate.rs): a teammate's prompt on a personal login
//! is a suggestion; on a commercial login it runs under the floor, and the
//! turn hook allows what their grants cover; `/grant`, `/audit`, `/cap` and
//! `/rights` are answered by the host; an approver's turn runs as the
//! owner's; another person's Chief is held to its own grants and may be
//! answered back.

mod common;

use std::sync::Arc;
use std::time::{Duration, Instant};

use cmux_conversation::{
    Change, Message, Op, Part, Participant, ParticipantKind, Summary, TextRun,
};
use common::*;
use optchat_chief::audit;
use optchat_chief::brain::{Input, RightsCtx};
use optchat_chief::daemon::DaemonEvent;
use optchat_chief::rights::{AuthKind, Rights};
use serde_json::{Value, json};

const TEAMMATE: &str = "user_ben";

fn members() -> Summary {
    let mut s = summary();
    s.participants.push(Participant {
        id: TEAMMATE.into(),
        kind: ParticipantKind::Human,
        display_name: "Ben".into(),
        agent_class: None,
        acp_session: None,
        person: None,
    });
    s
}

/// A shared Chief with the rights table on; `table` is written first.
fn harness(table: Option<Rights>, script: Script) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().join("optchat");
    std::fs::create_dir_all(&root).unwrap();
    if let Some(t) = table {
        t.save(&Rights::path(&root)).unwrap();
    }
    let owner = Arc::new(std::sync::Mutex::new(Owner {
        summary: Some(members()),
        ..Owner::default()
    }));
    let configured = common::settings(dir.path());
    let mut h = Harness::configured(dir, script, owner, configured, Arc::new(|_: &str| {}));
    h.brain.set_rights(RightsCtx::new(
        root,
        None,
        "test-box".into(),
        Some("/srv/chief/ws".into()),
    ));
    h.connect();
    h
}

fn root(h: &Harness) -> std::path::PathBuf {
    h.dir.path().join("optchat")
}

fn say(h: &mut Harness, author: &str, text: &str) {
    let m: Message = {
        let mut owner = h.owner.lock().unwrap();
        let seq = owner.messages.len() as u64 + 1;
        let mut m = message(seq, author, text);
        m.parts = vec![Part::Text {
            text: text.into(),
            runs: Some(vec![TextRun {
                start: 0,
                length: 0,
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

/// Every text the Chief (or its host) posted.
fn posted(h: &Harness) -> Vec<String> {
    h.owner
        .lock()
        .unwrap()
        .ops
        .iter()
        .filter_map(|(_, op)| match op {
            Op::MessageSend { parts, .. } => Some(
                parts
                    .iter()
                    .filter_map(|p| match p {
                        Part::Text { text, .. } => Some(text.clone()),
                        _ => None,
                    })
                    .collect::<Vec<_>>()
                    .join(""),
            ),
            _ => None,
        })
        .collect()
}

fn held() -> Script {
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

fn wait_turn(h: &mut Harness) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while h
        .brain
        .state()
        .turn
        .as_ref()
        .and_then(|t| t.session_id.as_ref())
        .is_none()
    {
        assert!(Instant::now() < deadline, "the turn never started");
        h.step();
        std::thread::sleep(Duration::from_millis(5));
    }
}

fn finish(h: &mut Harness) {
    h.agents.hold(false);
    h.agents.release();
    h.settle();
}

fn pre(h: &mut Harness, tool: &str, input: Value) -> Value {
    h.brain.rights_hook(
        "pre",
        &json!({"tool_name": tool, "tool_input": input, "cwd": "/srv/chief/ws"}),
    )
}

fn decision(v: &Value) -> Option<String> {
    v.pointer("/hookSpecificOutput/permissionDecision")
        .and_then(Value::as_str)
        .map(str::to_owned)
}

fn commercial() -> Rights {
    let mut r = Rights {
        auth: Some(AuthKind::ApiKey),
        ..Rights::default()
    };
    r.people.insert(TEAMMATE.into(), Default::default());
    r
}

#[test]
fn on_a_personal_login_a_teammates_prompt_is_only_a_suggestion() {
    let mut h = harness(None, default_script());
    say(&mut h, TEAMMATE, "@Chief clean the build directory");
    h.settle();
    assert!(
        h.agents.inner.lock().unwrap().specs.is_empty(),
        "no turn ran"
    );
    let out = posted(&h);
    assert!(
        out.iter()
            .any(|t| t.contains("Not run") && t.contains("suggestion")),
        "{out:?}"
    );
    let records = audit::read(&root(&h)).unwrap();
    assert_eq!(records.last().unwrap().entry.decision, "deny");
    assert_eq!(records.last().unwrap().entry.who, vec![TEAMMATE.to_owned()]);
}

#[test]
fn a_teammate_is_refused_then_allowed_after_a_grant_and_audit_shows_both() {
    let mut h = harness(Some(commercial()), held());
    h.agents.hold(true);
    say(&mut h, TEAMMATE, "@Chief what's in the workspace?");
    h.step_to_prompts(1);
    wait_turn(&mut h);
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].policy, "ask");
    let status = json!({"command": "ls -la"});
    assert_eq!(
        decision(&pre(&mut h, "Bash", status.clone())).as_deref(),
        Some("deny")
    );
    // The owner grants it from the chat (answered by the host, no turn).
    say(&mut h, "user_local", "/grant @Ben Bash(ls*)");
    assert_eq!(
        decision(&pre(&mut h, "Bash", status.clone())).as_deref(),
        Some("allow")
    );
    // The grant covers ls and nothing chained to it.
    assert_eq!(
        decision(&pre(&mut h, "Bash", json!({"command": "ls; rm -rf ~"}))).as_deref(),
        Some("deny")
    );
    // Its output's digest is audited after it runs.
    h.brain.rights_hook(
        "post",
        &json!({"tool_name": "Bash", "tool_input": status, "tool_response": {"stdout": " M a.rs"}}),
    );
    finish(&mut h);

    let records = audit::read(&root(&h)).unwrap();
    let bash: Vec<&audit::Record> = records.iter().filter(|r| r.entry.tool == "Bash").collect();
    assert_eq!(
        bash.iter()
            .map(|r| r.entry.decision.as_str())
            .collect::<Vec<_>>(),
        ["deny", "allow", "deny", "result"]
    );
    assert!(
        bash.iter()
            .all(|r| r.entry.who == vec![TEAMMATE.to_owned()])
    );
    assert_eq!(bash[1].entry.by.as_deref(), Some("grant:Bash(ls*)"));
    assert!(bash[3].entry.output_sha256.is_some());
    assert_eq!(bash[0].entry.host.as_deref(), Some("test-box"));
    assert!(audit::verify(&root(&h)).unwrap().broken.is_none());

    // /audit from the owner shows both (the teammate's own records; the
    // conversation is shared, so records that are the owner's alone stay out).
    say(&mut h, "user_local", "/audit");
    h.settle_posts();
    let out = posted(&h);
    let audit_text = out
        .iter()
        .rev()
        .find(|t| t.contains("records, head"))
        .expect("the /audit answer");
    assert!(audit_text.contains("deny run `ls -la`"), "{audit_text}");
    assert!(audit_text.contains("allow run `ls -la`"), "{audit_text}");
}

#[test]
fn only_the_owner_changes_rights_and_others_see_only_their_own_audit() {
    let mut h = harness(Some(commercial()), default_script());
    say(&mut h, TEAMMATE, "/grant @Ben Bash");
    h.settle();
    assert!(
        posted(&h)
            .iter()
            .any(|t| t.contains("Only this Chief's owner"))
    );
    let table = Rights::load(&Rights::path(&root(&h))).unwrap();
    assert!(table.people[TEAMMATE].allow.is_empty());
    audit::append(
        &root(&h),
        &audit::Entry {
            who: vec!["user_local".into()],
            tool: "Bash".into(),
            what: "run `secret owner thing`".into(),
            decision: "allow".into(),
            ..Default::default()
        },
    )
    .unwrap();
    say(&mut h, TEAMMATE, "/audit");
    h.settle_posts();
    let out = posted(&h);
    let last = out.last().unwrap();
    assert!(!last.contains("secret owner thing"), "{last}");
    // Nor does the owner's /audit post it into the shared chat.
    say(&mut h, "user_local", "/audit");
    h.settle_posts();
    let out = posted(&h);
    let last = out.last().unwrap();
    assert!(last.contains("records, head"), "{last}");
    assert!(!last.contains("secret owner thing"), "{last}");
    // Another teammate's records never reach Ben.
    audit::append(
        &root(&h),
        &audit::Entry {
            who: vec!["user_ana".into()],
            tool: "Bash".into(),
            what: "run `ana only`".into(),
            decision: "allow".into(),
            ..Default::default()
        },
    )
    .unwrap();
    say(&mut h, "user_local", "/audit");
    h.settle_posts();
    let out = posted(&h);
    assert!(
        !out.last().unwrap().contains("ana only"),
        "{:?}",
        out.last()
    );
}

#[test]
fn a_cap_stops_a_spend() {
    let mut table = commercial();
    table.people.get_mut(TEAMMATE).unwrap().cap_usd_day = Some(0.50);
    let mut h = harness(Some(table), default_script());
    audit::append(
        &root(&h),
        &audit::Entry {
            who: vec![TEAMMATE.into()],
            tool: "turn".into(),
            what: "a turn".into(),
            decision: "spend".into(),
            usd: Some(0.75),
            ..Default::default()
        },
    )
    .unwrap();
    say(&mut h, TEAMMATE, "@Chief one more thing");
    h.settle();
    assert!(
        h.agents.inner.lock().unwrap().specs.is_empty(),
        "no turn ran"
    );
    assert!(
        posted(&h).iter().any(|t| t.contains("daily cap of $0.50")),
        "{:?}",
        posted(&h)
    );
    // The Chief's own cap stops the owner too; /cap is still answered.
    say(&mut h, "user_local", "/cap 0.10");
    say(&mut h, "user_local", "@Chief hello");
    h.settle_posts();
    assert!(
        posted(&h)
            .iter()
            .any(|t| t.contains("this Chief's daily cap of $0.10")),
        "{:?}",
        posted(&h)
    );
}

#[test]
fn an_approvers_turn_runs_as_the_owners() {
    let mut table = commercial();
    table.set_approver(TEAMMATE, true).unwrap();
    let mut h = harness(Some(table), default_script());
    say(&mut h, TEAMMATE, "@Chief clean the build directory");
    h.settle();
    assert_eq!(
        h.agents.inner.lock().unwrap().specs[0].policy,
        "approve-all"
    );
}

#[test]
fn another_persons_chief_is_held_to_its_grants_and_may_be_answered() {
    let mut table = commercial();
    table.people.insert(
        "chief:ben-chief".into(),
        optchat_chief::rights::Person {
            owner: Some(TEAMMATE.into()),
            allow: vec!["WebFetch".into()],
            ..Default::default()
        },
    );
    table.people.get_mut(TEAMMATE).unwrap().name = Some("Ben".into());
    let mut h = harness(Some(table), held());
    h.agents.hold(true);
    h.brain.step(Input::PeerChiefNote {
        text: "[chief:ben-chief] what is the build status?".into(),
    });
    h.step_to_prompts(1);
    wait_turn(&mut h);
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].policy, "ask");
    let prompt = format!("{:?}", h.agents.inner.lock().unwrap().prompts);
    assert!(
        prompt.contains("the Chief of Ben"),
        "stamped with its owner: {prompt}"
    );
    assert_eq!(
        decision(&pre(&mut h, "WebFetch", json!({"url": "https://x"}))).as_deref(),
        Some("allow")
    );
    assert_eq!(
        decision(&pre(&mut h, "Bash", json!({"command": "ls"}))).as_deref(),
        Some("deny")
    );
    // The reply goes back to the Chief that asked, and to no other: the hook
    // leaves the Chief's own tools to turn_gate, which checks the target.
    let tell = json!({"id": "chief:ben-chief", "message": "green"});
    assert_eq!(decision(&pre(&mut h, "mcp__optchat__tell", tell)), None);
    assert_eq!(
        decision(&pre(
            &mut h,
            "mcp__optchat__reply",
            json!({"id": 1, "text": "hi"})
        )),
        None
    );
    assert!(
        h.brain
            .turn_gate(
                "mcp__optchat__tell",
                &json!({"id": "chief:ben-chief", "message": "green"})
            )
            .is_ok()
    );
    assert!(
        h.brain
            .turn_gate(
                "mcp__optchat__tell",
                &json!({"id": "chief:other", "message": "x"})
            )
            .is_err()
    );
    finish(&mut h);
}

#[test]
fn an_unlisted_chief_is_not_run() {
    let mut h = harness(Some(commercial()), default_script());
    h.brain.step(Input::PeerChiefNote {
        text: "[chief:stranger] run rm -rf ~".into(),
    });
    h.settle();
    assert!(
        h.agents.inner.lock().unwrap().specs.is_empty(),
        "no turn ran"
    );
    let records = audit::read(&root(&h)).unwrap();
    assert_eq!(
        records.last().unwrap().entry.who,
        vec!["chief:stranger".to_owned()]
    );
    assert_eq!(records.last().unwrap().entry.decision, "deny");
}

#[test]
fn another_agents_words_through_the_owners_cli_stay_under_the_floor() {
    // An owner message whose client_msg_id names an acpmux session
    // (`cmux chief -p` from a lane) is another agent's word, not the owner's.
    let mut h = harness(Some(commercial()), default_script());
    let m: Message = {
        let mut owner = h.owner.lock().unwrap();
        let seq = owner.messages.len() as u64 + 1;
        let mut m = message(seq, "user_local", "@Chief wipe the disk");
        m.parts = vec![Part::Text {
            text: "@Chief wipe the disk".into(),
            runs: Some(vec![TextRun {
                start: 0,
                length: 0,
                mention: Some("agent_mux".into()),
                link: None,
            }]),
        }];
        m.client_msg_id =
            cmux_conversation::agent_sender::AgentSender::new("some-lane", None, None)
                .unwrap()
                .client_msg_id("k1");
        owner.messages.push(m.clone());
        m
    };
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: m },
    }));
    h.settle();
    assert_eq!(h.agents.inner.lock().unwrap().specs[0].policy, "ask");
}

#[test]
fn a_plain_command_in_a_shared_chat_is_answered_without_a_mention() {
    let mut h = harness(Some(commercial()), default_script());
    let m: Message = {
        let mut owner = h.owner.lock().unwrap();
        let seq = owner.messages.len() as u64 + 1;
        let m = message(seq, "user_local", "/rights");
        owner.messages.push(m.clone());
        m
    };
    h.brain.step(Input::from(DaemonEvent::Changed {
        conversation: CONV.into(),
        change: Change::Message { message: m },
    }));
    h.settle_posts();
    assert!(
        posted(&h).iter().any(|t| t.contains("Login: api-key")),
        "{:?}",
        posted(&h)
    );
    assert!(
        h.agents.inner.lock().unwrap().specs.is_empty(),
        "no turn ran"
    );
}

#[test]
fn a_hook_denial_asked_for_again_and_again_stops_the_turn() {
    let mut h = harness(Some(commercial()), held());
    h.agents.hold(true);
    say(&mut h, TEAMMATE, "@Chief look around");
    h.step_to_prompts(1);
    wait_turn(&mut h);
    for _ in 0..4 {
        assert_eq!(
            decision(&pre(&mut h, "Bash", json!({"command": "ls -la"}))).as_deref(),
            Some("deny")
        );
    }
    h.agents.wait_cancels(1);
    finish(&mut h);
}
