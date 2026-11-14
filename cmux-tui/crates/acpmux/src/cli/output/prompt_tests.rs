use super::*;
use crate::config::{Config, HarnessProfile, PermissionPolicy, StoreMode};
use std::collections::BTreeMap;

/// A hub with the fake agent behind a real Unix socket, and a client.
async fn daemon() -> (Arc<crate::hub::Hub>, Arc<Client>, cmux_unix_socket::TestDir) {
    daemon_with_env(BTreeMap::new()).await
}

/// `daemon` with extra environment for the fake agent.
async fn daemon_with_env(
    env: BTreeMap<String, String>,
) -> (Arc<crate::hub::Hub>, Arc<Client>, cmux_unix_socket::TestDir) {
    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut harnesses = BTreeMap::new();
    harnesses.insert(
        "fake".to_owned(),
        HarnessProfile {
            kind: Default::default(),
            argv: vec!["python3".into(), fake.into()],
            env,
            description: None,
            fallback: None,
            family: None,
            models: vec![],
            model: None,
            effort: None,
            policy: None,
        },
    );
    let mut cfg = Config { harnesses, default_harness: Some("fake".into()), ..Default::default() };
    cfg.store.mode = StoreMode::Memory;
    cfg.permission_policy = PermissionPolicy::ApproveAll;
    let store = crate::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = crate::hub::Hub::new(cfg, store);
    // The shared helper keeps the socket path under sun_path whatever
    // $TMPDIR is (104 bytes on macOS).
    let dir = cmux_unix_socket::short_test_dir("acpmux-q");
    let path = dir.path().join("d.sock");
    let listener = crate::server::bind_unix(&path).await.unwrap();
    tokio::spawn(crate::server::serve_unix(hub.clone(), listener));
    let client = Client::connect(&path).await.unwrap();
    (hub, client, dir)
}

/// `acpmux send --supersede KEY`: the same sender's queued prompt under KEY is replaced, and
/// the sender is told how many.
#[tokio::test]
async fn a_send_with_supersede_replaces_the_senders_queued_prompt_under_that_key() {
    let (hub, client, dir) = daemon().await;
    let s = client
        .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let keyed = |key: &str| {
        let mut p = PromptId::new(None);
        p.from_agent = Some("lane-a".into());
        p.supersede = Some(key.into());
        p
    };
    // "slow" streams for about a second, so the two after it queue.
    queue_prompt(client.clone(), &id, "slow", false, None, &PromptId::new(None)).await.unwrap();
    let old = keyed("cause-1b");
    let first = queue_prompt(client.clone(), &id, "order", false, None, &old).await.unwrap();
    assert_eq!(first["queued"], true, "{first}");
    assert_eq!(sent_lines(&first, true), ["queued", "replaced 0 queued"]);
    let new = keyed("cause-1b");
    let second = queue_prompt(client.clone(), &id, "correction", false, None, &new).await.unwrap();
    assert_eq!(second["replaced"], 1, "{second}");
    assert_eq!(second["replacedPromptIds"], json!([old.id]), "{second}");
    assert_eq!(sent_lines(&second, true), ["queued", "replaced 1 queued"]);
    // Without --supersede the output is as before.
    assert_eq!(sent_lines(&second, false), ["queued"]);
    let removed = hub
        .events(&id, 0, 1000)
        .unwrap()
        .into_iter()
        .filter(|e| e.kind == "queue_removed")
        .map(|e| e.msg)
        .collect::<Vec<_>>();
    assert_eq!(removed.len(), 1, "{removed:?}");
    assert_eq!(removed[0]["promptId"], old.id.as_str());
    assert_eq!(removed[0]["reason"], "superseded");
    drop(dir);
}

/// A daemon that predates the key says nothing about it: the count is unknown, not 0.
#[test]
fn an_unreported_count_is_unknown() {
    let lines = sent_lines(&json!({"queued": true}), true);
    assert_eq!(lines[0], "queued");
    assert!(lines[1].starts_with("replaced ? queued"), "{lines:?}");
}

#[test]
fn a_supersede_key_goes_in_the_prompts_meta() {
    let mut p = PromptId::new(None);
    assert!(p.params("s", "t", false, None).pointer("/_meta/acpmux/supersede").is_none());
    p.supersede = Some("k".into());
    let params = p.params("s", "t", false, None);
    assert_eq!(params.pointer("/_meta/acpmux/supersede"), Some(&json!("k")));
}

#[test]
fn a_class_goes_in_the_prompts_meta() {
    let mut p = PromptId::new(None);
    assert!(p.params("s", "t", false, None).pointer("/_meta/acpmux/class").is_none());
    p.class = Some("block".into());
    let params = p.params("s", "t", false, None);
    assert_eq!(params.pointer("/_meta/acpmux/class"), Some(&json!("block")));
}

#[tokio::test]
async fn queue_prompt_returns_on_acceptance_while_the_turn_runs() {
    let (hub, client, dir) = daemon().await;
    let s = client
        .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let prompt = PromptId::new(None);
    // "slow" streams for about a second; acceptance comes first.
    let accepted = queue_prompt(client.clone(), &id, "slow", false, None, &prompt).await.unwrap();
    assert_eq!(accepted["promptId"], prompt.id.as_str());
    let session = hub.resolve(&id).unwrap();
    assert!(session.turn().is_some(), "the turn should still be running");
    // The same id again is answered by the first run, not a second turn.
    let again = PromptId { resend: true, ..prompt.clone() };
    let dup = queue_prompt(client.clone(), &id, "slow", false, None, &again).await.unwrap();
    assert_eq!(dup["duplicate"], true);
    let user_messages =
        hub.events(&id, 0, 1000).unwrap().iter().filter(|e| e.kind == "user_message").count();
    assert_eq!(user_messages, 1);
    drop(dir);
}

/// A send queued behind another client's running turn hears that turn's words too: its reply
/// is its own turn's only, empty when its turn says nothing (`send -q`, `--json`, `run`).
/// Before, it was the running turn's text.
#[tokio::test]
async fn a_queued_sends_reply_is_its_own_turns_not_the_turn_before_it() {
    let (hub, client, dir) = daemon().await;
    let s = client
        .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    // "slow" streams "tick0 tick1 tick2" for about a second.
    queue_prompt(client.clone(), &id, "slow", false, None, &PromptId::new(None)).await.unwrap();
    let path = dir.path().join("d.sock");
    let other = Client::connect(&path).await.unwrap();
    let opts = CollectOpts {
        timeout: Some(20),
        deadline: None,
        on_permission: OnPermission::Deny,
        stall_secs: 0,
        retries: 0,
        steer: false,
    };
    let quiet = PromptId::new(None);
    let got = collect_reply(other, &id, "quiet-tool", opts, &quiet).await.unwrap();
    assert!(!got.reply.contains("tick"), "the turn before's words: {:?}", got.reply);
    assert_eq!(got.reply, "", "its own turn said nothing");
    let session = hub.resolve(&id).unwrap();
    assert_eq!(session.meta().turn_count, 2);
    drop(dir);
}

/// A reply holds at most `hub::MAX_PAGE_BYTES` of a chat's history: the CLI reads on through
/// the older pages for the replies it asked for, past 12 MB of tool output.
#[tokio::test]
async fn the_last_reply_is_found_behind_more_than_a_page_of_output() {
    let (hub, client, dir) = daemon().await;
    let s = client
        .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    let update = |update: Value| json!({"jsonrpc": "2.0", "method": method::SESSION_UPDATE, "params": {"sessionId": "agent-1", "update": update}});
    let text = |text: String| json!({"type": "text", "text": text});
    hub.append(
        &session,
        "in",
        "agent_message_chunk",
        update(
            json!({"sessionUpdate": "agent_message_chunk", "content": text("the reply".into())}),
        ),
    );
    for n in 0..12 {
        hub.append(
                &session,
                "in",
                "tool_call_update",
                update(json!({"sessionUpdate": "tool_call_update", "toolCallId": format!("call-{n}"),
                    "status": "completed", "content": [{"type": "content", "content": text("x".repeat(1 << 20))}]})),
            );
    }
    assert_eq!(last_replies(&client, &id, 1).await.unwrap(), vec!["the reply".to_owned()]);
    // `session tail --since`: every event after the cursor, through the newest.
    let after = events_after(&client, &id, 0, 100000).await.unwrap();
    assert_eq!(after.last().unwrap()["seq"], session.meta().last_seq);
    assert!(after.len() > 13, "{} events", after.len());
    drop(dir);
}

/// A prompt to a session whose agent must start again (it died, or the daemon restarted)
/// is acknowledged when acpmux records it, before the agent has started (P1 v2).
#[tokio::test]
async fn a_prompt_is_accepted_when_recorded_before_the_agent_starts() {
    let gate = std::path::PathBuf::from("/tmp")
        .join(format!("acpmux-gate-{}", &uuid::Uuid::now_v7().simple().to_string()[20..]));
    std::fs::write(&gate, b"").unwrap();
    let env = BTreeMap::from([("FAKE_START_GATE".to_owned(), gate.to_string_lossy().into_owned())]);
    let (hub, client, dir) = daemon_with_env(env).await;
    let s = client
        .request(method::SESSION_NEW, json!({"cwd": std::env::temp_dir(), "mcpServers": []}))
        .await
        .unwrap();
    let id = s["sessionId"].as_str().unwrap().to_owned();
    let session = hub.resolve(&id).unwrap();
    // The agent is gone; its next start waits on the gate.
    hub.detach_child(&session).await;
    std::fs::remove_file(&gate).unwrap();
    let prompt = PromptId::new(None);
    let accepted = tokio::time::timeout(
        std::time::Duration::from_secs(10),
        queue_prompt(client.clone(), &id, "hello", false, None, &prompt),
    )
    .await
    .expect("accepted while the agent is still starting")
    .unwrap();
    assert_eq!(accepted["promptId"], prompt.id.as_str());
    let kinds: Vec<String> =
        hub.events(&id, 0, 1000).unwrap().iter().map(|e| e.kind.clone()).collect();
    assert!(kinds.iter().any(|k| k == "user_message"), "recorded: {kinds:?}");
    // Let the agent start; the turn completes.
    std::fs::write(&gate, b"").unwrap();
    for _ in 0..200 {
        if hub.events(&id, 0, 1000).unwrap().iter().any(|e| e.kind == "turn_result") {
            break;
        }
        tokio::time::sleep(std::time::Duration::from_millis(50)).await;
    }
    let _ = std::fs::remove_file(&gate);
    drop(dir);
}

#[test]
fn a_turns_reply_is_none_when_the_log_holds_no_start_of_it() {
    let ev = |seq: u64, kind: &str| json!({"seq": seq, "dir": "mux", "kind": kind, "msg": {"turnId": "t1"}});
    assert_eq!(reply_of_turn(&[ev(1, "turn_result")], "t1"), None, "cut off");
    let whole = [ev(1, "turn_started"), ev(2, "turn_result")];
    assert_eq!(reply_of_turn(&whole, "t1"), Some(String::new()), "it said nothing");
}
