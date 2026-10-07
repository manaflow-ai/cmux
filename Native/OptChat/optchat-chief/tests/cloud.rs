//! The cloud conversation source (brains/DESIGN-cmux-lawrence.md in the
//! OptChat lab): the brain answers the chief's cloud main conversation
//! through the daemon's `cloud-conversations-v1` proxy, as the chief
//! principal, with a chief token minted from the brain host's install key.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::mpsc::channel;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_conversation::{Change, Op, Part};
use optchat_chief::cloud::auth::{
    Http, InstallFile, InstallTokens, Lease, TokenSource, challenge_message, verify,
};
use optchat_chief::cloud::events::{CloudSignal, map_event};
use optchat_chief::cloud::idmap::{to_brain, to_cloud};
use optchat_chief::cloud::link::{CloudLinkConfig, spawn_cloud_link};
use optchat_chief::cloud::port::{CloudPort, HISTORY_LIMIT, SNAPSHOT_TAIL};
use optchat_chief::cloud::wire::Rpc;
use optchat_chief::daemon::{ConversationPort, DaemonEvent, MuxWake, OpError};
use serde_json::{Value, json};

const CHIEF: &str = "agent_01CHIEF";
const OWNER: &str = "user_01LAWRENCE";
const CONV: &str = "conv_01MAIN";

fn cloud_summary(seq: u64) -> Value {
    json!({
        "id": CONV, "owner": "cloud", "kind": "chief", "title": "Chief", "last_seq": seq, "rev": 4,
        "created_at": "2026-10-05T00:00:00.000Z", "updated_at": "2026-10-05T00:00:00.000Z",
        "participants": [
            {"id": OWNER, "kind": "human", "display_name": "Lawrence"},
            {"id": CHIEF, "kind": "agent", "agent_class": "mux", "owner_user": OWNER, "display_name": "Chief"}
        ],
        "read_cursors": {CHIEF: 1, OWNER: 2}
    })
}

fn cloud_message(seq: u64, author: &str, text: &str) -> Value {
    json!({"id": format!("msg_{seq}"), "conversation": CONV, "seq": seq, "client_msg_id": format!("c{seq}"),
        "author": author, "parts": [{"type": "text", "text": text}],
        "created_at": "2026-10-05T00:00:00.000Z", "reactions": []})
}

// ---------------------------------------------------------------- ids

#[test]
fn the_chief_id_is_agent_mux_inside_the_brain_and_back_outside() {
    let mut v = cloud_summary(2);
    v["last_message"] = json!({
        "id": "m", "conversation": CONV, "seq": 2, "client_msg_id": "k", "author": CHIEF,
        "parts": [{"type": "text", "text": format!("I am {CHIEF}"), "runs": [{"start": 0, "length": 1, "mention": CHIEF}]}],
        "created_at": "x", "reactions": []
    });
    to_brain(&mut v, CHIEF);
    assert_eq!(v["participants"][1]["id"], "agent_mux");
    assert_eq!(v["read_cursors"]["agent_mux"], 1);
    assert!(v["read_cursors"].get(CHIEF).is_none());
    assert_eq!(v["last_message"]["author"], "agent_mux");
    assert_eq!(
        v["last_message"]["parts"][0]["runs"][0]["mention"],
        "agent_mux"
    );
    // Text is never rewritten.
    assert_eq!(
        v["last_message"]["parts"][0]["text"],
        format!("I am {CHIEF}")
    );
    // The owner keeps its own id.
    assert_eq!(v["participants"][0]["id"], OWNER);
    to_cloud(&mut v, CHIEF);
    assert_eq!(v["participants"][1]["id"], CHIEF);
    assert_eq!(v["read_cursors"][CHIEF], 1);
}

// ---------------------------------------------------------------- port

#[derive(Default, Clone)]
struct FakeRpc {
    calls: Arc<Mutex<Vec<(String, Value)>>>,
    replies: Arc<Mutex<Vec<Result<Value, OpError>>>>,
}

impl Rpc for FakeRpc {
    fn call(&mut self, cmd: &str, params: Value) -> Result<Value, OpError> {
        self.calls.lock().unwrap().push((cmd.to_owned(), params));
        self.replies.lock().unwrap().remove(0)
    }
}

#[test]
fn the_port_reads_and_writes_through_the_cloud_commands() {
    let rpc = FakeRpc::default();
    rpc.replies.lock().unwrap().extend([
        Ok(json!({"conversation": cloud_summary(2), "messages": [cloud_message(1, OWNER, "hi"), cloud_message(2, CHIEF, "hello")], "rev": 4, "seq": 9})),
        Ok(json!({"messages": [cloud_message(1, OWNER, "hi")], "has_more": false})),
        Ok(json!({"value": {}, "rev": 5, "replayed": false, "change": {"kind": "read-cursor", "participant": CHIEF, "seq": 2}})),
        Ok(json!({"value": {}, "rev": 6, "replayed": false})),
    ]);
    let mut port = CloudPort::new(rpc.clone(), CHIEF.into());
    let (summary, messages) = port.snapshot(CONV, 500).unwrap();
    assert_eq!(summary.read_cursors.get("agent_mux"), Some(&1));
    assert_eq!(messages[1].author, "agent_mux");
    let older = port.history(CONV, 2, 500).unwrap();
    assert_eq!(older.len(), 1);
    let change = port
        .op(CONV, "cursor:agent_mux:2", &Op::ReadCursorSet { seq: 2 })
        .unwrap();
    assert!(
        matches!(change, Some(Change::ReadCursor { ref participant, seq: 2 }) if participant == "agent_mux")
    );
    port.op(
        CONV,
        "turn:optchat:3:1",
        &Op::MessageSend {
            client_msg_id: "turn:optchat:3:1".into(),
            parts: vec![Part::Text {
                text: "ok".into(),
                runs: None,
            }],
            reply_to: None,
        },
    )
    .unwrap();
    // Typing has no cloud frame yet: a no-op, nothing sent.
    port.typing(CONV, true).unwrap();
    let calls = rpc.calls.lock().unwrap();
    assert_eq!(calls.len(), 4);
    assert_eq!(calls[0].0, "cloud-conversation-snapshot");
    assert_eq!(
        calls[0].1,
        json!({"conversation": CONV, "tail": SNAPSHOT_TAIL})
    );
    assert_eq!(calls[1].0, "cloud-conversation-history");
    assert_eq!(
        calls[1].1,
        json!({"conversation": CONV, "before_seq": 2, "limit": HISTORY_LIMIT})
    );
    assert_eq!(calls[2].0, "cloud-conversation-op");
    assert_eq!(
        calls[2].1,
        json!({"conversation": CONV, "idempotency_key": "cursor:agent_mux:2", "op": {"kind": "read_cursor.set", "seq": 2}})
    );
    assert_eq!(calls[3].1["op"]["kind"], "message.send");
    assert_eq!(calls[3].1["op"]["client_msg_id"], "turn:optchat:3:1");
    assert_eq!(calls[3].1["idempotency_key"], "turn:optchat:3:1");
}

#[test]
fn owner_rejects_keep_their_reason_and_cloud_outages_are_transport_errors() {
    use optchat_chief::cloud::wire::reply_error;
    let rejected = json!({"id": 1, "ok": false, "error": "refused", "error_code": "cloud_conversation_rejected", "reason": "agent_rate", "retryable": true});
    assert!(matches!(reply_error(&rejected), OpError::Rejected(r) if r.contains("agent_rate")));
    for code in [
        "cloud_unavailable",
        "cloud_unauthenticated",
        "cloud_session_expired",
        "cloud_signed_out",
    ] {
        let reply = json!({"id": 1, "ok": false, "error": "x", "error_code": code, "reason": "r", "retryable": true});
        assert!(
            matches!(reply_error(&reply), OpError::Transport(_)),
            "{code}"
        );
    }
    let plain = json!({"id": 1, "ok": false, "error": "bad request: tail"});
    assert!(matches!(reply_error(&plain), OpError::Rejected(_)));
}

// ---------------------------------------------------------------- events

#[test]
fn cloud_events_become_brain_changes() {
    let changed = json!({"event": "cloud-conversation-changed", "conversation": CONV, "rev": 5, "seq": 10, "transaction": "tx",
        "change": {"kind": "message", "message": cloud_message(3, CHIEF, "x")}, "account": OWNER});
    match map_event(&changed, CONV, CHIEF) {
        Some(CloudSignal::Changed(Change::Message { message })) => {
            assert_eq!(message.author, "agent_mux")
        }
        _ => panic!("expected a message change"),
    }
    let other = json!({"event": "cloud-conversation-changed", "conversation": "conv_other", "rev": 1, "seq": 1, "transaction": "t",
        "change": {"kind": "message", "message": cloud_message(1, OWNER, "x")}});
    assert!(map_event(&other, CONV, CHIEF).is_none());
    let resynced = json!({"event": "cloud-conversation-resynced", "conversation": CONV, "rev": 4, "seq": 9,
        "summary": cloud_summary(2), "messages": [cloud_message(2, OWNER, "x")]});
    match map_event(&resynced, CONV, CHIEF) {
        Some(CloudSignal::Resynced { summary, messages }) => {
            assert!(summary.participants.iter().any(|p| p.id == "agent_mux"));
            assert_eq!(messages.len(), 1);
        }
        _ => panic!("expected a resync"),
    }
    let live = json!({"event": "cloud-subscription-state", "scope": "conversation", "conversation": CONV, "state": "live"});
    assert!(matches!(
        map_event(&live, CONV, CHIEF),
        Some(CloudSignal::State { live: true, .. })
    ));
    let down = json!({"event": "cloud-subscription-state", "scope": "conversation", "conversation": CONV, "state": "disconnected", "reason": "unauthenticated"});
    assert!(matches!(
        map_event(&down, CONV, CHIEF),
        Some(CloudSignal::State { live: false, .. })
    ));
    let inbox =
        json!({"event": "cloud-subscription-state", "scope": "inbox", "state": "disconnected"});
    assert!(map_event(&inbox, CONV, CHIEF).is_none());
    let needed = json!({"event": "cloud-session-needed", "reason": "expiring", "expires_at": 1});
    assert!(
        matches!(map_event(&needed, CONV, CHIEF), Some(CloudSignal::SessionNeeded(r)) if r == "expiring")
    );
    // A part type this brain does not know (an image) does not lose the message.
    let mut image = cloud_message(4, OWNER, "look");
    image["parts"]
        .as_array_mut()
        .unwrap()
        .push(json!({"type": "image", "asset": "a1"}));
    let ev = json!({"event": "cloud-conversation-changed", "conversation": CONV, "rev": 6, "seq": 11, "transaction": "t",
        "change": {"kind": "message", "message": image}});
    match map_event(&ev, CONV, CHIEF) {
        Some(CloudSignal::Changed(Change::Message { message })) => {
            assert_eq!(message.parts.len(), 1)
        }
        _ => panic!("expected the message without the unknown part"),
    }
}

// ---------------------------------------------------------------- auth

#[test]
fn the_install_key_signs_challenges_the_backend_verifies() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("cloud").join("install.json");
    let file = InstallFile::generate("https://api.example.test").unwrap();
    file.save(&path).unwrap();
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(&path).unwrap().permissions().mode();
    assert_eq!(mode & 0o777, 0o600);
    let loaded = InstallFile::load(&path).unwrap();
    let jwk = &loaded.public_jwk;
    assert_eq!(
        (jwk["kty"].as_str(), jwk["crv"].as_str()),
        (Some("EC"), Some("P-256"))
    );
    assert!(
        jwk.get("d").is_none(),
        "the public JWK never carries the private key"
    );
    let message = challenge_message("staging", "inst_1", "nonce-1");
    assert_eq!(message, "cmux-auth-v1\nstaging\ninst_1\nnonce-1");
    let sig = loaded.sign(&message).unwrap();
    assert!(verify(jwk, &message, &sig));
    assert!(!verify(jwk, "cmux-auth-v1\nstaging\ninst_1\nother", &sig));
    let params = loaded.register_params("Chief brain", "cmux-lawrence");
    assert_eq!(params["kind"], "cli");
    assert_eq!(params["public_jwk"], *jwk);
}

struct FakeHttp {
    calls: Mutex<Vec<(String, Value, Option<String>)>>,
    env: &'static str,
}

impl Http for FakeHttp {
    fn post(&self, url: &str, body: &Value, bearer: Option<&str>) -> Result<Value, String> {
        self.calls
            .lock()
            .unwrap()
            .push((url.to_owned(), body.clone(), bearer.map(str::to_owned)));
        if url.ends_with("/v1/auth/challenge") {
            Ok(
                json!({"install": body["install"], "nonce": "n-1", "expires_at": 1, "message_prefix": format!("cmux-auth-v1\n{}\n{}\n", self.env, body["install"].as_str().unwrap())}),
            )
        } else if url.ends_with("/v1/auth/token") {
            Ok(
                json!({"access_token": "jwt-1", "token_type": "Bearer", "expires_at": 1_900_000_000_000u64, "user": body["user"], "team": "team_1", "install": body["install"], "grant": "grant_1"}),
            )
        } else {
            Err(format!("unexpected {url}"))
        }
    }
}

#[test]
fn a_chief_token_is_minted_by_challenge_and_signature() {
    let mut file = InstallFile::generate("https://api.example.test").unwrap();
    file.install = Some("inst_1".into());
    file.user = Some(OWNER.into());
    file.chief = Some(CHIEF.into());
    let http = Arc::new(FakeHttp {
        calls: Mutex::new(Vec::new()),
        env: "staging",
    });
    let tokens = InstallTokens::new(file.clone(), http.clone());
    let lease: Lease = tokens.mint(Some(CHIEF)).unwrap();
    assert_eq!(lease.access_token, "jwt-1");
    assert_eq!(lease.api_base_url, "https://api.example.test");
    assert_eq!(lease.expires_at, 1_900_000_000_000);
    let calls = http.calls.lock().unwrap();
    assert_eq!(calls[0].0, "https://api.example.test/v1/auth/challenge");
    assert_eq!(calls[0].1, json!({"user": OWNER, "install": "inst_1"}));
    let token = &calls[1].1;
    assert_eq!(token["agent"], CHIEF);
    assert_eq!(token["nonce"], "n-1");
    let message = challenge_message("staging", "inst_1", "n-1");
    assert!(verify(
        &file.public_jwk,
        &message,
        token["signature"].as_str().unwrap()
    ));
    // Without an agent the token is the install's own (chief.list, chief.create).
    drop(calls);
    tokens.mint(None).unwrap();
    assert!(http.calls.lock().unwrap()[3].1.get("agent").is_none());
}

// ---------------------------------------------------------------- link

/// A fake cmux-tui daemon with `cloud-conversations-v1`.
fn serve_cloud(
    listener: UnixListener,
    requests: Arc<Mutex<Vec<Value>>>,
    subscribers: Arc<Mutex<Vec<UnixStream>>>,
) {
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let (requests, subscribers) = (requests.clone(), subscribers.clone());
            std::thread::spawn(move || {
                let mut out = conn.try_clone().unwrap();
                for line in BufReader::new(conn.try_clone().unwrap()).lines() {
                    let Ok(line) = line else { return };
                    let req: Value = serde_json::from_str(&line).unwrap();
                    requests.lock().unwrap().push(req.clone());
                    let data = match req["cmd"].as_str().unwrap() {
                        "identify" => json!({"app": "cmux", "version": "test", "protocol": 12,
                            "capabilities": ["local-conversations-v1", "cloud-conversations-v1"]}),
                        "cloud-session-set" => {
                            json!({"state": "active", "api_base_url": req["api_base_url"], "expires_at": req["expires_at"]})
                        }
                        "subscribe" => {
                            subscribers.lock().unwrap().push(conn.try_clone().unwrap());
                            json!({})
                        }
                        "cloud-conversation-subscribe" => {
                            json!({"conversation": req["conversation"], "state": "connecting"})
                        }
                        "cloud-mux-subscribe" => json!({"state": "connecting"}),
                        "cloud-conversation-snapshot" => {
                            json!({"conversation": cloud_summary(1), "messages": [cloud_message(1, OWNER, "hi")], "rev": 4, "seq": 9})
                        }
                        "cloud-conversation-op" => {
                            json!({"value": {}, "rev": 5, "replayed": false})
                        }
                        _ => json!({}),
                    };
                    let _ = writeln!(
                        out,
                        "{}",
                        json!({"id": req["id"], "ok": true, "data": data})
                    );
                }
            });
        }
    });
}

struct CountingTokens(Mutex<u32>);

impl TokenSource for CountingTokens {
    fn mint(&self, agent: Option<&str>) -> Result<Lease, String> {
        assert_eq!(agent, Some(CHIEF));
        let mut n = self.0.lock().unwrap();
        *n += 1;
        Ok(Lease {
            api_base_url: "https://api.example.test".into(),
            access_token: format!("jwt-{n}"),
            expires_at: 4_000_000_000_000,
        })
    }
}

#[test]
fn the_cloud_link_leases_the_chief_token_subscribes_and_answers() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("daemon.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    let subscribers = Arc::new(Mutex::new(Vec::new()));
    serve_cloud(
        UnixListener::bind(&socket).unwrap(),
        requests.clone(),
        subscribers.clone(),
    );
    let tokens = Arc::new(CountingTokens(Mutex::new(0)));
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    spawn_cloud_link(
        CloudLinkConfig {
            socket,
            chief: CHIEF.into(),
            conversation: CONV.into(),
        },
        tokens.clone(),
        Arc::new(move |e| tx.lock().unwrap().send(e).unwrap()),
        Arc::new(|_: &str| {}),
    );
    let wait = Duration::from_secs(30);
    let Ok(DaemonEvent::Up {
        mut port,
        conversation,
        ..
    }) = rx.recv_timeout(wait)
    else {
        panic!("no Up")
    };
    assert_eq!(conversation.id, CONV);
    assert!(
        conversation
            .participants
            .iter()
            .any(|p| p.id == "agent_mux")
    );
    {
        let requests = requests.lock().unwrap();
        let set = requests
            .iter()
            .find(|r| r["cmd"] == "cloud-session-set")
            .unwrap();
        assert_eq!(set["access_token"], "jwt-1");
        assert_eq!(set["api_base_url"], "https://api.example.test");
        let sub = requests
            .iter()
            .find(|r| r["cmd"] == "cloud-conversation-subscribe")
            .unwrap();
        assert_eq!(sub["conversation"], CONV);
        // Never bound: a bound connection is refused every cloud command.
        assert!(!requests.iter().any(|r| r["cmd"] == "conversation-bind"));
    }
    port.op(
        CONV,
        "turn:optchat:1:1",
        &Op::MessageSend {
            client_msg_id: "turn:optchat:1:1".into(),
            parts: vec![Part::Text {
                text: "hello".into(),
                runs: None,
            }],
            reply_to: None,
        },
    )
    .unwrap();
    assert!(
        requests
            .lock()
            .unwrap()
            .iter()
            .any(|r| r["cmd"] == "cloud-conversation-op" && r["op"]["kind"] == "message.send")
    );

    let mut sub = subscribers.lock().unwrap()[0].try_clone().unwrap();
    writeln!(sub, "{}", json!({"event": "cloud-conversation-changed", "conversation": CONV, "rev": 5, "seq": 10, "transaction": "t",
        "change": {"kind": "message", "message": cloud_message(2, OWNER, "next")}})).unwrap();
    match rx.recv_timeout(wait).unwrap() {
        DaemonEvent::Changed {
            conversation,
            change: Change::Message { message },
        } => {
            assert_eq!((conversation.as_str(), message.seq), (CONV, 2))
        }
        _ => panic!("expected the message"),
    }
    // The daemon asks for a new lease: the link mints one and sets it.
    writeln!(
        sub,
        "{}",
        json!({"event": "cloud-session-needed", "reason": "expiring", "expires_at": 1})
    )
    .unwrap();
    let deadline = std::time::Instant::now() + wait;
    while !requests
        .lock()
        .unwrap()
        .iter()
        .any(|r| r["cmd"] == "cloud-session-set" && r["access_token"] == "jwt-2")
    {
        assert!(std::time::Instant::now() < deadline, "no lease refresh");
        std::thread::sleep(Duration::from_millis(20));
    }
    // The upstream socket drops: Down, then Up again.
    writeln!(sub, "{}", json!({"event": "cloud-subscription-state", "scope": "conversation", "conversation": CONV, "state": "disconnected", "reason": "unavailable"})).unwrap();
    assert!(matches!(rx.recv_timeout(wait).unwrap(), DaemonEvent::Down));
    assert!(matches!(
        rx.recv_timeout(wait).unwrap(),
        DaemonEvent::Up { .. }
    ));
}

#[test]
fn a_daemon_without_the_cloud_capability_is_fatal() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("daemon.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    std::thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let mut out = conn.try_clone().unwrap();
            for line in BufReader::new(conn).lines() {
                let Ok(line) = line else { return };
                let req: Value = serde_json::from_str(&line).unwrap();
                let _ = writeln!(
                    out,
                    "{}",
                    json!({"id": req["id"], "ok": true, "data": {"app": "cmux", "version": "old", "capabilities": ["local-conversations-v1"]}})
                );
            }
        }
    });
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    spawn_cloud_link(
        CloudLinkConfig {
            socket,
            chief: CHIEF.into(),
            conversation: CONV.into(),
        },
        Arc::new(CountingTokens(Mutex::new(0))),
        Arc::new(move |e| tx.lock().unwrap().send(e).unwrap()),
        Arc::new(|_: &str| {}),
    );
    match rx.recv_timeout(Duration::from_secs(30)).unwrap() {
        DaemonEvent::Fatal(why) => assert!(why.contains("cloud-conversations-v1"), "{why}"),
        _ => panic!("expected Fatal"),
    }
}

// ---------------------------------------------------------------- host flags

#[test]
fn the_cloud_source_needs_a_registered_install_with_a_chief() {
    use optchat_chief::cli::Flags;
    use optchat_chief::host::{Source, conversation_source};
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("install.json");
    let mut file = InstallFile::generate("https://api.example.test").unwrap();
    file.save(&path).unwrap();
    let args: Vec<String> = [
        "host",
        "--conversation-source",
        "cloud",
        "--cloud-install",
        path.to_str().unwrap(),
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let err = conversation_source(&Flags::parse(&args))
        .err()
        .expect("unregistered install refused");
    assert!(err.contains("install, user, chief, conversation"), "{err}");
    file.install = Some("inst_1".into());
    file.user = Some(OWNER.into());
    file.chief = Some(CHIEF.into());
    file.conversation = Some(CONV.into());
    file.save(&path).unwrap();
    assert!(matches!(
        conversation_source(&Flags::parse(&args)),
        Ok(Source::Cloud { .. })
    ));
    let bad: Vec<String> = ["host", "--conversation-source", "carrier-pigeon"]
        .iter()
        .map(|s| s.to_string())
        .collect();
    assert!(conversation_source(&Flags::parse(&bad)).is_err());
}

// ---------------------------------------------------------------- wake queue (G9)

fn wake(conversation: &str, seq: u64) -> MuxWake {
    MuxWake {
        conversation: conversation.into(),
        seq,
        reason: "mention".into(),
    }
}

#[test]
fn the_wake_queue_events_become_brain_wakes() {
    let woke = json!({"event": "cloud-mux-wake", "seq": 8, "account": OWNER,
        "wakes": [{"conversation": "conv_side", "seq": 4, "reason": "mention"}]});
    match map_event(&woke, CONV, CHIEF) {
        Some(CloudSignal::MuxWakes(wakes)) => assert_eq!(wakes, vec![wake("conv_side", 4)]),
        _ => panic!("expected the wakes"),
    }
    let resynced = json!({"event": "cloud-mux-resynced", "seq": 7,
        "pending": [{"conversation": "conv_side", "seq": 3, "reason": "mention"},
                    {"conversation": CONV, "seq": 2, "reason": "mention"}]});
    match map_event(&resynced, CONV, CHIEF) {
        Some(CloudSignal::MuxWakes(wakes)) => {
            assert_eq!(wakes, vec![wake("conv_side", 3), wake(CONV, 2)])
        }
        _ => panic!("expected the pending wakes"),
    }
}

#[test]
fn the_port_acks_wakes_for_the_leased_chief_by_ids_only() {
    let rpc = FakeRpc::default();
    rpc.replies.lock().unwrap().push(Ok(
        json!({"value": {"cursor": 4, "cleared": 1}, "rev": 2, "replayed": false}),
    ));
    let mut port = CloudPort::new(rpc.clone(), CHIEF.into());
    port.mux_ack("conv_side", 4).unwrap();
    let calls = rpc.calls.lock().unwrap();
    assert_eq!(calls.len(), 1);
    assert_eq!(calls[0].0, "cloud-mux-ack");
    // No `agent`: the daemon acks for the lease's own chief.
    assert_eq!(calls[0].1, json!({"conversation": "conv_side", "seq": 4}));
}

/// The link subscribes to the chief's wake queue after the lease is set and
/// the main conversation is subscribed (a person's lease cannot: the daemon
/// answers `mux_needs_chief`), and relays wakes and resyncs to the brain.
#[test]
fn the_cloud_link_subscribes_the_wake_queue_with_the_chief_lease() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("daemon.sock");
    let requests = Arc::new(Mutex::new(Vec::new()));
    let subscribers = Arc::new(Mutex::new(Vec::new()));
    serve_cloud(
        UnixListener::bind(&socket).unwrap(),
        requests.clone(),
        subscribers.clone(),
    );
    let (tx, rx) = channel();
    let tx = Mutex::new(tx);
    spawn_cloud_link(
        CloudLinkConfig {
            socket,
            chief: CHIEF.into(),
            conversation: CONV.into(),
        },
        Arc::new(CountingTokens(Mutex::new(0))),
        Arc::new(move |e| tx.lock().unwrap().send(e).unwrap()),
        Arc::new(|_: &str| {}),
    );
    let wait = Duration::from_secs(30);
    assert!(matches!(rx.recv_timeout(wait), Ok(DaemonEvent::Up { .. })));
    {
        let requests = requests.lock().unwrap();
        let at = |cmd: &str| requests.iter().position(|r| r["cmd"] == cmd);
        let (lease, main, queue) = (
            at("cloud-session-set").expect("the lease"),
            at("cloud-conversation-subscribe").expect("the main subscribe"),
            at("cloud-mux-subscribe").expect("the wake queue subscribe"),
        );
        assert!(lease < main && main < queue, "{requests:?}");
        let fields: Vec<&String> = requests[queue].as_object().unwrap().keys().collect();
        assert_eq!(fields, vec!["cmd", "id"], "the request never names a chief");
    }
    let mut sub = subscribers.lock().unwrap()[0].try_clone().unwrap();
    writeln!(
        sub,
        "{}",
        json!({"event": "cloud-mux-resynced", "seq": 7,
        "pending": [{"conversation": "conv_side", "seq": 3, "reason": "dm"}]})
    )
    .unwrap();
    match rx.recv_timeout(wait).unwrap() {
        DaemonEvent::MuxWake(wakes) => assert_eq!(
            wakes,
            vec![MuxWake {
                conversation: "conv_side".into(),
                seq: 3,
                reason: "dm".into()
            }]
        ),
        _ => panic!("expected the pending wakes"),
    }
    writeln!(
        sub,
        "{}",
        json!({"event": "cloud-mux-wake", "seq": 8,
        "wakes": [{"conversation": "conv_other", "seq": 1, "reason": "mention"}]})
    )
    .unwrap();
    match rx.recv_timeout(wait).unwrap() {
        DaemonEvent::MuxWake(wakes) => assert_eq!(wakes, vec![wake("conv_other", 1)]),
        _ => panic!("expected the new wake"),
    }
}
