//! An agent's `acpmux send` that waits for its reply steers into a running turn and answers with
//! that turn's reply (`steer_reply.rs`). Leo, 2026-10-25: "I don't know why these things are
//! queued up." He saw "11 more queued" over the composer: every waiting send queued.
//!
//! The person's turn waits on a FIFO gate (`tests/fake_agent.py` "gate:"), so each test decides
//! when it ends.

use crate::cli::output::prompt_tests::daemon_with_env;
use crate::cli::output::{CollectOpts, OnPermission, PromptId, collect_reply, queue_prompt};
use crate::client::Client;
use crate::rpc::method;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::Duration;

fn fifo(dir: &Path) -> PathBuf {
    let path = dir.join("gate");
    let c = std::ffi::CString::new(path.as_os_str().as_encoded_bytes()).unwrap();
    // SAFETY: a valid NUL-terminated path.
    assert_eq!(unsafe { libc::mkfifo(c.as_ptr(), 0o600) }, 0);
    path
}

fn open_gate(gate: &Path) {
    std::fs::OpenOptions::new().write(true).open(gate).unwrap().write_all(b"go").unwrap();
}

/// A session whose agent steers as Claude Code does (`steering`) or does not steer, with a turn
/// of the person's running in it behind a gate.
struct Busy {
    hub: Arc<crate::hub::Hub>,
    id: String,
    gate: PathBuf,
    _person: Arc<Client>,
    dir: cmux_unix_socket::TestDir,
}

impl Busy {
    /// A connection of its own: each send takes its connection's notifications.
    async fn client(&self) -> Arc<Client> {
        Client::connect(&self.dir.path().join("d.sock")).await.unwrap()
    }
}

async fn busy(steering: bool) -> Busy {
    let env = if steering {
        BTreeMap::from([("FAKE_CLAUDE_STEER".to_owned(), "1".to_owned())])
    } else {
        BTreeMap::new()
    };
    let (hub, person, dir) = daemon_with_env(env).await;
    let s = person
        .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let gate = fifo(dir.path());
    let text = format!("gate: {}", gate.display());
    queue_prompt(person.clone(), &id, &text, false, None, &PromptId::new(None)).await.unwrap();
    Busy { hub, id, gate, _person: person, dir }
}

fn from_lane() -> PromptId {
    let mut prompt = PromptId::new(None);
    prompt.from_agent = Some("lane-a".into());
    prompt
}

fn opts(steer: bool) -> CollectOpts {
    CollectOpts {
        timeout: Some(60),
        on_permission: OnPermission::Wait,
        stall_secs: 0,
        retries: 0,
        steer,
    }
}

/// The record `kind` of prompt `prompt_id`, within 10 s.
async fn record(b: &Busy, kind: &str, prompt_id: &str) -> Value {
    for _ in 0..200 {
        let events = b.hub.events(&b.id, 0, 1000).unwrap();
        if let Some(e) = events.iter().find(|e| e.kind == kind && e.msg["promptId"] == prompt_id) {
            return e.msg.clone();
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("no {kind} record for {prompt_id}");
}

/// Whether the agent wrote `text` into the chat, within 10 s.
async fn agent_said(b: &Busy, text: &str) {
    for _ in 0..200 {
        let events = b.hub.events(&b.id, 0, 1000).unwrap();
        if events.iter().any(|e| e.dir == "in" && e.msg.to_string().contains(text)) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("the agent never said {text:?}");
}

#[tokio::test]
async fn an_agents_waiting_send_steers_and_answers_with_the_turns_final_reply() {
    let b = busy(true).await;
    let prompt = from_lane();
    let (agent, id, p) = (b.client().await, b.id.clone(), prompt.clone());
    let send =
        tokio::spawn(
            async move { collect_reply(agent, &id, "rebase first", opts(true), &p).await },
        );
    // Into the running turn, not the queue.
    let sent = record(&b, "user_message", &prompt.id).await;
    assert_eq!(sent["steer"], true, "{sent}");
    // The agent read it ("steered") and its turn runs on: the send waits for the turn's end.
    agent_said(&b, "steer: rebase first").await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!send.is_finished(), "the send answered before the turn it steered into ended");
    open_gate(&b.gate);
    let r = tokio::time::timeout(Duration::from_secs(10), send).await.unwrap().unwrap().unwrap();
    assert_eq!(r.stop_reason, "end_turn");
    assert!(r.reply.contains("after-gate"), "the turn's final reply, got {:?}", r.reply);
    let events = b.hub.events(&b.id, 0, 1000).unwrap();
    assert!(!events.iter().any(|e| e.kind == "queued" && e.msg["promptId"] == prompt.id.as_str()));
}

/// The streaming send (no `--quiet`) waits for the turn's end the same way.
#[tokio::test]
async fn an_agents_streaming_send_waits_for_the_end_of_the_turn_it_steered_into() {
    let b = busy(true).await;
    let prompt = from_lane();
    let (agent, id, p) = (b.client().await, b.id.clone(), prompt.clone());
    let send = tokio::spawn(async move {
        crate::cli::output::stream_prompt(
            agent,
            &id,
            "rebase first",
            true,
            true,
            false,
            opts(true),
            false,
            &p,
        )
        .await
    });
    agent_said(&b, "steer: rebase first").await;
    tokio::time::sleep(Duration::from_millis(500)).await;
    assert!(!send.is_finished(), "the send answered before the turn it steered into ended");
    open_gate(&b.gate);
    tokio::time::timeout(Duration::from_secs(10), send).await.unwrap().unwrap().unwrap();
}

/// An agent that does not steer gets it after the turn, as before, and its `queued` record names
/// the sender (`fromAgent`), so the chat draws it as a received message.
#[tokio::test]
async fn to_an_agent_that_does_not_steer_an_agents_send_queues_named() {
    let b = busy(false).await;
    let prompt = from_lane();
    let (agent, id, p) = (b.client().await, b.id.clone(), prompt.clone());
    let send =
        tokio::spawn(
            async move { collect_reply(agent, &id, "rebase first", opts(true), &p).await },
        );
    let queued = record(&b, "queued", &prompt.id).await;
    assert_eq!(queued["fromAgent"], "lane-a", "{queued}");
    open_gate(&b.gate);
    let r = tokio::time::timeout(Duration::from_secs(10), send).await.unwrap().unwrap().unwrap();
    assert!(r.reply.contains("rebase first"), "its own turn's reply, got {:?}", r.reply);
}

/// `--no-steer` queues an agent's send behind the turn even when its agent steers; the person's
/// waiting send (never steered) queues the same way.
#[tokio::test]
async fn a_no_steer_send_queues_behind_a_turn_that_could_take_it() {
    let b = busy(true).await;
    let prompt = from_lane();
    let (agent, id, p) = (b.client().await, b.id.clone(), prompt.clone());
    let send =
        tokio::spawn(
            async move { collect_reply(agent, &id, "rebase first", opts(false), &p).await },
        );
    let queued = record(&b, "queued", &prompt.id).await;
    assert_eq!(queued["fromAgent"], "lane-a", "{queued}");
    open_gate(&b.gate);
    let r = tokio::time::timeout(Duration::from_secs(10), send).await.unwrap().unwrap().unwrap();
    assert!(r.reply.contains("rebase first"), "its own turn's reply, got {:?}", r.reply);
    // The person's send that waits queues behind a turn too, unnamed.
    let person = PromptId::new(None);
    let text = format!("gate: {}", b.gate.display());
    queue_prompt(b.client().await, &b.id, &text, false, None, &person).await.unwrap();
    record(&b, "user_message", &person.id).await;
    let mine = PromptId::new(None);
    let (client, id, p) = (b.client().await, b.id.clone(), mine.clone());
    let send =
        tokio::spawn(async move { collect_reply(client, &id, "mine", opts(false), &p).await });
    let queued = record(&b, "queued", &mine.id).await;
    assert!(queued.get("fromAgent").is_none(), "{queued}");
    open_gate(&b.gate);
    let r = tokio::time::timeout(Duration::from_secs(10), send).await.unwrap().unwrap().unwrap();
    assert!(r.reply.contains("mine"), "its own turn's reply, got {:?}", r.reply);
}
