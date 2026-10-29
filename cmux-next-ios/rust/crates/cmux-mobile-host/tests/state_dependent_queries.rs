//! A queued state-dependent query must see preceding mutations after their
//! acknowledgement, even when the daemon has not emitted a tree delta yet.

use std::collections::HashMap;
use std::sync::Arc;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::pairing::LinkAuth;
use cmux_mobile_host::services::{Peer, serve};
use cmux_mobile_link::{Channel, ChannelEvent, Link, LinkConfig, Role};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex, mpsc};
use tokio::time::Instant;

async fn reply(channel: &mut Channel, buffered: &mut Vec<u8>) -> Value {
    tokio::time::timeout(Duration::from_secs(3), async {
        loop {
            if let Some(end) = buffered.iter().position(|b| *b == b'\n') {
                return serde_json::from_slice(&buffered.drain(..=end).collect::<Vec<_>>()).unwrap();
            }
            match channel.recv().await {
                Some(ChannelEvent::Data(data)) => buffered.extend_from_slice(&data),
                event => panic!("daemon channel ended before reply: {event:?}"),
            }
        }
    })
    .await
    .expect("daemon reply")
}

#[tokio::test]
async fn new_tab_uses_the_selection_acknowledged_before_it() {
    let sockets = tempfile::tempdir().unwrap();
    let folder_a = tempfile::tempdir().unwrap();
    let folder_b = tempfile::tempdir().unwrap();
    let cwd_a = folder_a.path().canonicalize().unwrap().to_str().unwrap().to_owned();
    let cwd_b = folder_b.path().canonicalize().unwrap().to_str().unwrap().to_owned();
    let listener = tokio::net::UnixListener::bind(sockets.path().join("main.sock")).unwrap();
    let selected = Arc::new(AtomicUsize::new(0));
    let (key_tx, mut key_rx) = mpsc::unbounded_channel();
    let (created_tx, mut created_rx) = mpsc::unbounded_channel();
    let tree = json!({"registry_id":"test-registry", "workspaces":[{
        "id":1, "key":"test-workspace", "screens":[{"id":2,"panes":[{
            "id":3,"active_tab":0,"tabs":[
                {"surface":4,"kind":"terminal","cwd":cwd_a},
                {"surface":5,"kind":"terminal","cwd":cwd_b}
            ]
        }]}]
    }]});
    let fake_daemon = tokio::spawn(async move {
        // Both levels own their child tasks. Shutdown aborts delayed writes
        // and closes every socket, including the cache subscription.
        let mut clients = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let (stream, _) = accepted.unwrap();
                    let selected = Arc::clone(&selected);
                    let key_tx = key_tx.clone();
                    let created_tx = created_tx.clone();
                    let tree = tree.clone();
                    clients.spawn(async move {
                        let (read, write) = stream.into_split();
                        let write = Arc::new(Mutex::new(write));
                        let mut lines = BufReader::new(read).lines();
                        let mut delayed = tokio::task::JoinSet::new();
                        loop {
                            tokio::select! {
                                line = lines.next_line() => {
                                    let Ok(Some(line)) = line else { return };
                                    let request: Value = serde_json::from_str(&line).unwrap();
                                    let mut answer = json!({"id":request["id"],"ok":true,"data":request});
                                    match request["cmd"].as_str() {
                                        Some("select-tab") => {
                                            assert_eq!(request["surface"], 5);
                                            let selected = Arc::clone(&selected);
                                            let write = Arc::clone(&write);
                                            delayed.spawn(async move {
                                                // The daemon accepts the command now but applies
                                                // it only just before its acknowledgement. Other
                                                // input can still be received during this wait.
                                                tokio::time::sleep(Duration::from_millis(250)).await;
                                                selected.store(1, Ordering::SeqCst);
                                                let _ = write.lock().await.write_all(format!("{answer}\n").as_bytes()).await;
                                            });
                                            continue;
                                        }
                                        Some("new-tab") => {
                                            created_tx.send((request["cwd"].clone(), selected.load(Ordering::SeqCst))).unwrap();
                                        }
                                        Some("send") => {
                                            key_tx.send(Instant::now()).unwrap();
                                        }
                                        Some("list-workspaces") => {
                                            let mut current = tree.clone();
                                            current["workspaces"][0]["screens"][0]["panes"][0]["active_tab"] =
                                                json!(selected.load(Ordering::SeqCst));
                                            answer["data"] = current;
                                        }
                                        Some("list-personal") => answer["data"] = json!({"groups":[],"workspaces":[]}),
                                        _ if request["operation"] == "sidebar_layout.get" => {
                                            answer["result"] = json!({"sections":[]});
                                        }
                                        // subscribe receives its normal acknowledgement, but
                                        // deliberately no tree event follows select-tab. The
                                        // next state-dependent command needs a post-ack refresh.
                                        _ => {}
                                    }
                                    if write.lock().await.write_all(format!("{answer}\n").as_bytes()).await.is_err() {
                                        return;
                                    }
                                }
                                _ = delayed.join_next(), if !delayed.is_empty() => {}
                            }
                        }
                    });
                }
                _ = clients.join_next(), if !clients.is_empty() => {}
            }
        }
    });
    let config = Arc::new(ServiceConfig {
        tui_socket_dir: sockets.path().to_owned(),
        default_session: "main".into(),
        default_socket: None,
        file_roots: vec![],
        acpmux: AcpmuxTarget::Fixed { url: "ws://127.0.0.1:1/".into(), token: None },
        pairing: None,
        agent_tab_host: None,
        uploads_dir: sockets.path().join("uploads"),
        chief_socket: None,
        browser: cmux_mobile_host::browser::BrowserConfig::new(None, 1),
        surface: cmux_mobile_host::surface::SurfaceConfig::new(None, 1),
    });
    let (phone_stream, mac_stream) = tokio::io::duplex(64 * 1024);
    let phone = Link::new(phone_stream, Role::Phone, LinkConfig::default(), None);
    let mac = Link::new(mac_stream, Role::Mac, LinkConfig::default(), None);
    let host = tokio::spawn(async move {
        let incoming = mac.accept().await.unwrap();
        serve(
            config,
            Peer { device_id: "test-phone".into(), session_id: "test-session".into(), video: None },
            Arc::new(LinkAuth::default()),
            incoming,
        )
        .await;
        mac.close("test complete");
    });
    let mut channel = phone.open("daemon", json!({})).await.unwrap();
    let mut buffered = Vec::new();

    // Warm through the public protocol and prove which selection is cached.
    channel.send(Bytes::from_static(b"{\"id\":\"warm\",\"cmd\":\"new-tab\",\"pane\":3}\n")).await.unwrap();
    let warm = reply(&mut channel, &mut buffered).await;
    assert_eq!(warm["id"], "warm");
    assert_eq!(warm["data"]["cwd"], cwd_a);
    assert_eq!(created_rx.recv().await.unwrap(), (json!(cwd_a), 0));

    let began = Instant::now();
    channel.send(Bytes::from_static(
        b"{\"id\":\"select\",\"cmd\":\"select-tab\",\"surface\":5}\n{\"id\":\"create\",\"cmd\":\"new-tab\",\"pane\":3}\n{\"id\":\"input\",\"cmd\":\"send\",\"surface\":4,\"text\":\"x\"}\n",
    )).await.unwrap();
    let key_at =
        tokio::time::timeout(Duration::from_secs(3), key_rx.recv()).await.expect("input forwarded").unwrap();
    let mut answers = HashMap::new();
    while answers.len() < 3 {
        let answer = reply(&mut channel, &mut buffered).await;
        answers.insert(answer["id"].as_str().unwrap().to_owned(), answer);
    }
    // The host's internal ordered-command IDs never reach the phone.
    assert_eq!(answers["select"]["ok"], true);
    assert_eq!(answers["create"]["data"]["cwd"], cwd_b);
    assert_eq!(answers["input"]["data"]["text"], "x");
    let creation = tokio::time::timeout(Duration::from_secs(3), created_rx.recv())
        .await
        .expect("creation forwarded")
        .unwrap();
    assert_eq!(creation, (json!(cwd_b), 1), "creation ran before selection was applied");
    let input_latency = key_at.duration_since(began);

    channel.close("eof", "test complete").await;
    phone.close("test complete");
    tokio::time::timeout(Duration::from_secs(3), host).await.expect("host shutdown").unwrap();
    fake_daemon.abort();
    let _ = fake_daemon.await;
    assert!(input_latency < Duration::from_millis(125), "input waited for select-tab: {input_latency:?}");
}
