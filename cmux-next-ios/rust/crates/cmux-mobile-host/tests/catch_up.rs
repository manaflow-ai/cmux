//! The `catch-up` service end to end through `services::serve`: one request, one reply
//! carrying the workspaces, the chat list and each chat, with a fake daemon socket and a fake
//! acpmux WebSocket behind it.

use std::path::Path;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::control::SessionExposure;
use cmux_mobile_host::pairing::LinkAuth;
use cmux_mobile_host::services::{Peer, serve};
use cmux_mobile_link::{ChannelEvent, Link, LinkConfig, Role};
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixListener;
use tokio::sync::watch;
use tokio_tungstenite::tungstenite::Message;

const S1: &str = "00000000-0000-7000-8000-000000000001";
const S2: &str = "00000000-0000-7000-8000-000000000002";
const HIDDEN: &str = "00000000-0000-7000-8000-00000000dead";
const BIG: &str = "00000000-0000-7000-8000-0000000000b1";

/// A daemon answering `set-client-info` and `list-workspaces`; it records every line.
fn fake_daemon(dir: &Path) -> Arc<Mutex<Vec<Value>>> {
    let listener = UnixListener::bind(dir.join("main.sock")).unwrap();
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let log = Arc::clone(&log);
            tokio::spawn(async move {
                let (read, mut write) = stream.into_split();
                let mut lines = BufReader::new(read).lines();
                while let Ok(Some(line)) = lines.next_line().await {
                    let request: Value = serde_json::from_str(&line).unwrap();
                    log.lock().unwrap().push(request.clone());
                    let reply = match request["cmd"].as_str().unwrap() {
                        "list-workspaces" => json!({"id": request["id"], "ok": true, "data": {
                            "revision": "r2",
                            "workspaces": [{"id": "w1", "screens": [{"panes": [{"tabs": [
                                {"id": 7, "title": "shell"},
                                {"id": 8, "title": "hidden chat", "agent_session": HIDDEN},
                            ]}]}]}],
                        }}),
                        _ => json!({"id": request["id"], "ok": true}),
                    };
                    let _ = write.write_all(format!("{reply}\n").as_bytes()).await;
                }
            });
        }
    });
    seen
}

/// An acpmux answering `_acpmux/info` (each id is its own canonical id), `_acpmux/watch` (the
/// list holds every test chat) and `_acpmux/attach` (a few records; `BIG`'s are large). It
/// records every request but `_acpmux/info`.
async fn fake_acpmux() -> (String, Arc<Mutex<Vec<Value>>>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("ws://{}/", listener.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let log = Arc::clone(&seen);
    tokio::spawn(async move {
        while let Ok((stream, _)) = listener.accept().await {
            let log = Arc::clone(&log);
            tokio::spawn(async move {
                let Ok(socket) = tokio_tungstenite::accept_async(stream).await else { return };
                let (mut sink, mut source) = socket.split();
                while let Some(Ok(Message::Text(text))) = source.next().await {
                    let request: Value = serde_json::from_str(&text).unwrap();
                    let params = &request["params"];
                    let result = match request["method"].as_str().unwrap() {
                        "_acpmux/info" => json!({"sessionId": params["sessionId"]}),
                        "_acpmux/watch" => {
                            log.lock().unwrap().push(request.clone());
                            json!({"listEpoch": "E", "listSeq": 91, "follow": true, "sessions": [
                                {"sessionId": S1, "title": "one"},
                                {"sessionId": S2, "title": "two"},
                                {"sessionId": HIDDEN, "title": "secret"},
                            ]})
                        }
                        "_acpmux/attach" => {
                            log.lock().unwrap().push(request.clone());
                            let session = params["sessionId"].as_str().unwrap();
                            let text = if session == BIG { "x".repeat(8192) } else { "hi".into() };
                            let events: Vec<Value> = (11..=12)
                                .map(|seq| json!({"seq": seq, "kind": "transcript", "sessionId": session, "msg": {"text": text}}))
                                .collect();
                            json!({"session": {"sessionId": session}, "events": events, "hasMore": true,
                                "lastSeq": 12, "pageThrough": 12})
                        }
                        other => panic!("unexpected {other}"),
                    };
                    let reply = json!({"jsonrpc": "2.0", "id": request["id"], "result": result});
                    let _ = sink.send(Message::Text(reply.to_string().into())).await;
                }
            });
        }
    });
    (url, seen)
}

fn config(dir: &Path, acpmux_url: String) -> Arc<ServiceConfig> {
    Arc::new(ServiceConfig {
        tui_socket_dir: dir.to_owned(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![],
        acpmux: AcpmuxTarget::Fixed { url: acpmux_url, token: None },
        pairing: None,
        agent_tab_host: None,
        uploads_dir: dir.join("uploads"),
        chief_socket: None,
        browser: cmux_mobile_host::browser::BrowserConfig::new(None, 1),
        surface: cmux_mobile_host::surface::SurfaceConfig::new(None, 1),
        viewport_sync: None,
    })
}

fn exposure(blocked: &[&str]) -> SessionExposure {
    SessionExposure {
        available: true,
        configured: true,
        allowed: Default::default(),
        blocked: blocked.iter().map(|s| (*s).to_owned()).collect(),
    }
}

/// Opens `catch-up` with `request` through `services::serve` and returns its one reply frame
/// (as text, so a test can look for an id anywhere in it) and how the channel closed.
async fn catch_up(config: Arc<ServiceConfig>, state: SessionExposure, request: Value) -> (String, String) {
    let (_tx, rx) = watch::channel(state);
    let (phone_stream, mac_stream) = tokio::io::duplex(1 << 20);
    let link = Link::new(phone_stream, Role::Phone, LinkConfig::default(), None);
    let mac = Link::new(mac_stream, Role::Mac, LinkConfig::default(), None);
    tokio::spawn(async move {
        let Some(incoming) = mac.accept().await else { return };
        let peer = Peer {
            device_id: "phone-1".into(),
            session_id: "s".into(),
            video: None,
            session_exposure: Some(rx),
            path: None,
            viewport: None,
            route: None,
        };
        serve(config, peer, Arc::new(LinkAuth::default()), incoming).await;
        let _mac = mac;
    });
    let mut channel = link.open("catch-up", request).await.unwrap();
    let mut reply = String::new();
    let code = tokio::time::timeout(Duration::from_secs(20), async {
        loop {
            match channel.recv().await {
                Some(ChannelEvent::Data(data)) => reply = String::from_utf8(data.to_vec()).unwrap(),
                Some(ChannelEvent::Closed(info)) => return info.code,
                None => return "none".into(),
            }
        }
    })
    .await
    .expect("reply in time");
    (reply, code)
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn one_request_answers_workspaces_the_chat_list_and_two_chats() {
    let dir = tempfile::tempdir().unwrap();
    let daemon = fake_daemon(dir.path());
    let (url, acpmux) = fake_acpmux().await;
    let request = json!({"v": 1, "wake": "background",
        "workspaces": {"known": "r1", "since": 1234, "capabilities": ["page-tabs-v1"]},
        "chatList": {"listEpoch": "E", "afterSeq": 88},
        "chats": [{"sessionId": S1, "lastSeq": 10}, {"sessionId": S2, "lastSeq": 10, "first": "forward"}],
        "terminals": [{"surface": "t1", "offset": 5, "generation": 7}]});
    let (text, code) = catch_up(config(dir.path(), url), exposure(&[]), request).await;
    assert_eq!(code, "eof");
    let reply: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(reply["v"], 1);
    assert_eq!(reply["workspaces"]["revision"], "r2");
    assert_eq!(reply["chatList"]["listSeq"], 91);
    let chats = reply["chats"].as_array().unwrap();
    assert_eq!(chats.len(), 2, "{reply}");
    assert_eq!(chats[0]["sessionId"], S1);
    assert_eq!(chats[0]["pageThrough"], 12);
    assert_eq!(chats[0]["olderBefore"], 11, "a newest-first page with more says where older ones start");
    assert_eq!(chats[1]["sessionId"], S2);
    assert!(chats[1].get("olderBefore").is_none(), "a forward page pages on forward");
    assert_eq!(reply["cut"], json!([]));
    assert!(reply.get("terminals").is_none(), "terminals resume on their own daemon channel");

    // The phone's cursors went through as it sent them.
    let lines = daemon.lock().unwrap().clone();
    let list = lines.iter().find(|line| line["cmd"] == "list-workspaces").unwrap();
    assert_eq!(list["known"], "r1");
    assert_eq!(list["since"], 1234);
    let hello = lines.iter().find(|line| line["cmd"] == "set-client-info").unwrap();
    assert_eq!(hello["remote"], true, "set-client-info passed the daemon policy's rewrite");
    assert_eq!(hello["device_id"], "phone-1");
    let asked = acpmux.lock().unwrap().clone();
    let watch = asked.iter().find(|r| r["method"] == "_acpmux/watch").unwrap();
    assert_eq!(watch["params"]["afterSeq"], 88);
    assert_eq!(watch["params"]["listEpoch"], "E");
    let attaches: Vec<&Value> = asked.iter().filter(|r| r["method"] == "_acpmux/attach").collect();
    assert_eq!(attaches.len(), 2);
    let first = attaches.iter().find(|r| r["params"]["sessionId"] == S1).unwrap();
    assert_eq!(first["params"]["afterSeq"], 10);
    assert_eq!(first["params"]["beforeSeq"], 9_007_199_254_740_991u64);
    assert_eq!(first["params"]["visible"], false, "a background wake shows nobody the chat");
    assert!(first["params"]["maxBytes"].as_u64().unwrap() <= 64 * 1024);
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_the_phone_may_not_see_never_appears() {
    let dir = tempfile::tempdir().unwrap();
    let _daemon = fake_daemon(dir.path());
    let (url, acpmux) = fake_acpmux().await;
    let request =
        json!({"v": 1, "chats": [{"sessionId": S1, "lastSeq": 10}, {"sessionId": HIDDEN, "lastSeq": 3}]});
    let (text, code) = catch_up(config(dir.path(), url), exposure(&[HIDDEN]), request).await;
    assert_eq!(code, "eof");
    assert!(!text.contains(HIDDEN), "the hidden chat is nowhere in the reply: {text}");
    let reply: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(reply["chats"].as_array().unwrap().len(), 1);
    assert_eq!(reply["chatList"]["sessions"].as_array().unwrap().len(), 2, "its list row is filtered");
    assert!(!reply["workspaces"].to_string().contains("hidden chat"), "its tab row is filtered");
    let asked = acpmux.lock().unwrap().clone();
    assert!(!asked.iter().any(|r| r["params"]["sessionId"] == HIDDEN), "acpmux was never asked about it");

    // Unreadable exposure: refused, as `daemon` and `acpmux` are.
    let mut unreadable = exposure(&[]);
    unreadable.available = false;
    let (url, _) = fake_acpmux().await;
    let (text, code) = catch_up(config(dir.path(), url), unreadable, json!({"v": 1})).await;
    assert_eq!(code, "forbidden");
    assert!(text.is_empty());
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn a_chat_past_the_budget_is_cut_and_keeps_its_cursor() {
    let dir = tempfile::tempdir().unwrap();
    let _daemon = fake_daemon(dir.path());
    let (url, _) = fake_acpmux().await;
    let request = json!({"v": 1, "budgetBytes": 4096,
        "chats": [{"sessionId": S1, "lastSeq": 10}, {"sessionId": BIG, "lastSeq": 10}, {"sessionId": S2, "lastSeq": 10}]});
    let (text, _) = catch_up(config(dir.path(), url), exposure(&[]), request).await;
    let reply: Value = serde_json::from_str(&text).unwrap();
    let ids: Vec<&str> =
        reply["chats"].as_array().unwrap().iter().map(|c| c["sessionId"].as_str().unwrap()).collect();
    assert_eq!(ids, [S1, S2]);
    assert_eq!(reply["cut"], json!([format!("chats:{BIG}")]));
    assert_eq!(reply["cutWhy"][format!("chats:{BIG}")], "budget");
    assert!(text.len() < 4096 + 2048, "chats stay within the budget");
}

#[tokio::test(flavor = "multi_thread", worker_threads = 4)]
async fn without_acpmux_the_workspaces_still_come_and_the_chats_are_cut() {
    let dir = tempfile::tempdir().unwrap();
    let _daemon = fake_daemon(dir.path());
    let request = json!({"v": 1, "chats": [{"sessionId": S1, "lastSeq": 10}]});
    let (text, code) = catch_up(config(dir.path(), "ws://127.0.0.1:1/".into()), exposure(&[]), request).await;
    assert_eq!(code, "eof");
    let reply: Value = serde_json::from_str(&text).unwrap();
    assert_eq!(reply["workspaces"]["revision"], "r2");
    assert_eq!(reply["chats"], json!([]));
    assert_eq!(reply["cut"], json!(["chatList", format!("chats:{S1}")]));
}
