//! Chief-to-Chief messages (peer_chiefs.rs; the user, 2026-10-21: "make it
//! so it's possible for you to talk to the cloud chief"): `tell("chief:<name>")`
//! on the tools socket posts to the peer's agent-hub box with this Chief's
//! box as `reply_to`, the inbox turns the peer's messages into notes, and a
//! note wakes an idle Chief like a subagent's report.

mod common;

use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use common::*;
use optchat_chief::brain::Input;
use optchat_chief::peer_chiefs::PeerChiefs;
use optchat_chief::tools::{Call, Served};
use serde_json::{Value, json};

/// One request the fake hub took: (method, path, authorization, body).
type Seen = (String, String, String, Value);

/// A one-thread HTTP agent hub: records each request; a GET of a box
/// answers `inbox` once, then nothing.
fn fake_hub(inbox: Vec<Value>) -> (String, Arc<Mutex<Vec<Seen>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = seen.clone();
    std::thread::spawn(move || {
        let mut inbox = Some(inbox);
        for stream in listener.incoming() {
            let Ok(mut stream) = stream else { return };
            let mut reader = BufReader::new(stream.try_clone().unwrap());
            let mut line = String::new();
            reader.read_line(&mut line).unwrap();
            let mut parts = line.split_whitespace();
            let (method, path) = (
                parts.next().unwrap_or("").to_owned(),
                parts.next().unwrap_or("").to_owned(),
            );
            let (mut auth, mut len) = (String::new(), 0_usize);
            loop {
                let mut h = String::new();
                reader.read_line(&mut h).unwrap();
                let h = h.trim_end();
                if h.is_empty() {
                    break;
                }
                let (k, v) = h.split_once(':').unwrap_or((h, ""));
                match k.to_ascii_lowercase().as_str() {
                    "authorization" => auth = v.trim().to_owned(),
                    "content-length" => len = v.trim().parse().unwrap_or(0),
                    _ => {}
                }
            }
            let mut body = vec![0; len];
            reader.read_exact(&mut body).unwrap();
            let body: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);
            let answer = if method == "GET" {
                json!({"messages": inbox.take().unwrap_or_default()})
            } else if path.ends_with("/ack") {
                json!({"ok": true})
            } else {
                json!({"seq": 41, "id": "m1"})
            };
            log.lock().unwrap().push((method, path, auth, body));
            let text = answer.to_string();
            let _ = write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}",
                text.len()
            );
        }
    });
    (url, seen)
}

fn peers(dir: &std::path::Path, hub: &str) -> Arc<PeerChiefs> {
    let token = dir.join("mac-chief.token");
    std::fs::write(&token, "tok-123\n").unwrap();
    let config = dir.join("peer-chiefs.json");
    std::fs::write(
        &config,
        json!({
            "hub": hub,
            "token_file": token,
            "me": "mac-chief",
            "peers": [{"name": "cloud-chief", "label": "Cloud Chief", "place": "cloud"}],
        })
        .to_string(),
    )
    .unwrap();
    PeerChiefs::from_file(&config).unwrap().expect("configured")
}

#[test]
fn tell_to_a_peer_chief_posts_to_its_hub_box_with_the_reply_box() {
    let dir = tempfile::tempdir().unwrap();
    let (hub, seen) = fake_hub(Vec::new());
    let socket = dir.path().join("tools.sock");
    optchat_chief::tools::serve_all(
        &socket,
        Served {
            memory: open_chat(&dir.path().join("memory")),
            orchestrator: None,
            control: None,
            inspector: None,
            chief: None,
            turn: None,
            peers: Some(peers(dir.path(), &hub)),
        },
    )
    .unwrap();
    let answer = optchat_chief::tools::ask(
        &socket,
        Call::Tell {
            id: "chief:cloud-chief".into(),
            message: "ping from the Mac".into(),
            key: None,
            queue: false,
        },
    )
    .expect("tell answers");
    assert!(answer.contains("sent to Cloud Chief"), "{answer}");
    let seen = seen.lock().unwrap();
    assert_eq!(seen.len(), 1, "{seen:?}");
    let (method, path, auth, body) = &seen[0];
    assert_eq!(method, "POST");
    assert_eq!(path, "/v1/boxes/agent%3Acloud-chief/messages");
    assert_eq!(auth, "Bearer tok-123");
    assert_eq!(body["reply_to"], "agent:mac-chief");
    assert_eq!(body["body"]["text"], "ping from the Mac");
}

#[test]
fn tell_to_a_peer_chief_without_peers_says_why() {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("tools.sock");
    optchat_chief::tools::serve_all(
        &socket,
        Served {
            memory: open_chat(&dir.path().join("memory")),
            orchestrator: None,
            control: None,
            inspector: None,
            chief: None,
            turn: None,
            peers: None,
        },
    )
    .unwrap();
    let answer = optchat_chief::tools::ask(
        &socket,
        Call::Tell {
            id: "chief:cloud-chief".into(),
            message: "ping".into(),
            key: None,
            queue: false,
        },
    );
    let error = answer.expect_err("no peers");
    assert!(error.contains("no peer Chiefs"), "{error}");
}

#[test]
fn the_inbox_reads_the_hub_cursor_delivers_a_note_and_acks_it() {
    let dir = tempfile::tempdir().unwrap();
    let (hub, seen) = fake_hub(vec![json!({
        "seq": 9, "id": "m9", "from": "cloud-chief", "kind": "tell",
        "body": {"text": "pong from the cloud"}, "reply_to": "agent:cloud-chief"
    })]);
    let p = peers(dir.path(), &hub);
    let got = Mutex::new(Vec::new());
    let n = p
        .poll_once(
            0,
            &|text| {
                got.lock().unwrap().push(text);
                true
            },
            &|_| {},
        )
        .unwrap();
    assert_eq!(n, 1);
    assert!(got.lock().unwrap()[0].starts_with("[chief:cloud-chief] pong from the cloud"));
    let seen = seen.lock().unwrap();
    assert_eq!(seen[0].0, "GET");
    assert!(
        seen[0]
            .1
            .starts_with("/v1/boxes/agent%3Amac-chief/messages?after=cursor"),
        "{}",
        seen[0].1
    );
    assert_eq!(seen[1].1, "/v1/boxes/agent%3Amac-chief/ack");
    assert_eq!(seen[1].3["seq"], 9);
}

#[test]
fn a_peer_chief_note_wakes_an_idle_chief() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.brain.step(Input::PeerChiefNote {
        text: "[chief:cloud-chief] pong from the cloud".into(),
    });
    let deadline = Instant::now() + Duration::from_secs(10);
    while h.agents.inner.lock().unwrap().prompts.is_empty() {
        assert!(Instant::now() < deadline, "the note never woke the Chief");
        h.step();
    }
    let prompt = serde_json::to_string(&h.agents.inner.lock().unwrap().prompts[0]).unwrap();
    assert!(
        prompt.contains("[chief:cloud-chief] pong from the cloud"),
        "{prompt}"
    );
}
