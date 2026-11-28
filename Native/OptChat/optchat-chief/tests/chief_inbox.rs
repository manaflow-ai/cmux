//! One stable acpmux session per Chief on this Mac (`Settings::chief_inbox`,
//! brain/chief_inbox.rs): a listed session on acpmux's `chief` harness
//! (`cmux chief acp`) that relays a message into this Chief's own
//! conversation, so another Chief (Chief, Codex Chief, Hybrid Chief) or a
//! lane reaches it with #30082's `acpmux_send`.

mod common;

use std::sync::{Arc, Mutex};

use common::*;
use optchat_chief::acpmux::AgentEvent;
use optchat_chief::brain::{Input, Settings};

fn harness(inbox: Option<&str>) -> Harness {
    harness_as(inbox, "agent_codex")
}

fn harness_as(inbox: Option<&str>, participant: &str) -> Harness {
    let dir = tempfile::tempdir().unwrap();
    let s = Settings {
        chief_inbox: inbox.map(str::to_owned),
        membership: optchat_chief::membership::Membership {
            participant: participant.to_owned(),
            ..Default::default()
        },
        ..settings(dir.path())
    };
    let owner = Arc::new(Mutex::new(Owner {
        summary: Some(summary()),
        ..Owner::default()
    }));
    Harness::configured(dir, default_script(), owner, s, Arc::new(|_: &str| {}))
}

fn inbox_specs(h: &Harness) -> Vec<optchat_chief::acpmux::SessionSpec> {
    h.agents
        .inner
        .lock()
        .unwrap()
        .specs
        .iter()
        .filter(|s| s.harness == "chief")
        .cloned()
        .collect()
}

#[test]
fn a_chief_gets_one_listed_session_on_the_chief_harness_that_relays_into_its_chat() {
    let mut h = harness(Some("Codex Chief"));
    h.connect();
    let specs = inbox_specs(&h);
    assert_eq!(specs.len(), 1, "{specs:?}");
    let spec = &specs[0];
    assert_eq!(spec.name, "chief-codex-chief");
    let participant = "agent_codex".to_owned();
    // The relay (`cmux chief acp`) posts into this Chief's conversation.
    assert_eq!(
        spec.env.get("CMUX_CHIEF_PARTICIPANT"),
        Some(&participant),
        "{spec:?}"
    );
    assert_eq!(
        spec.tags
            .get(cmux_chief::rules::LABEL_TAG)
            .map(String::as_str),
        Some("Codex Chief")
    );
    assert_eq!(
        spec.tags.get("cmux.chief.inbox"),
        Some(&participant),
        "{spec:?}"
    );
    // Not one of the Chief's own turn or compactor sessions, which acpmux
    // and the app keep out of the agents a person sees.
    assert!(!spec.tags.contains_key("cmux.chief"), "{spec:?}");
    assert_eq!(spec.policy, "ask");
}

#[test]
fn the_session_is_made_once_and_kept_when_acpmux_lists_it() {
    // The default Chief's session is `chief`, whatever its localized name.
    let mut h = harness_as(Some("Chef"), "agent_mux");
    let listed: cmux_chief::acp::SessionSummary = serde_json::from_value(serde_json::json!({
        "sessionId": "s-inbox", "name": "chief", "status": "idle", "harness": "chief"
    }))
    .unwrap();
    h.brain.step(Input::from(AgentEvent::Up(vec![listed])));
    assert!(inbox_specs(&h).is_empty(), "{:?}", inbox_specs(&h));
}

#[test]
fn a_chief_without_the_setting_makes_none() {
    let mut h = harness(None);
    h.connect();
    assert!(inbox_specs(&h).is_empty());
}
