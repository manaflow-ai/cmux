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
    exercise_selection_then_creation(true, false, false).await;
}

#[tokio::test]
async fn new_tab_on_another_channel_sees_the_acknowledged_selection() {
    exercise_selection_then_creation(false, false, false).await;
}

#[tokio::test]
async fn a_pending_terminal_wait_does_not_block_mutations_or_input() {
    exercise_selection_then_creation(true, true, false).await;
}

#[tokio::test]
async fn a_disconnect_before_mutation_reply_invalidates_other_channels() {
    exercise_selection_then_creation(false, false, true).await;
}

async fn exercise_selection_then_creation(
    same_channel: bool,
    terminal_wait: bool,
    disconnect_before_reply: bool,
) {
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
                        let mut waiting_answer = None;
                        loop {
                            tokio::select! {
                                line = lines.next_line() => {
                                    let Ok(Some(line)) = line else { return };
                                    let request: Value = serde_json::from_str(&line).unwrap();
                                    let mut answer = json!({"id":request["id"],"ok":true,"data":request});
                                    match request["cmd"].as_str() {
                                        Some("wait-for") => {
                                            assert_eq!(request["timeout_ms"], 60_000);
                                            // No reply until a later mutation reaches us. If
                                            // the host adds this read to its acknowledgement
                                            // barrier, that mutation can never arrive.
                                            waiting_answer = Some(answer);
                                            continue;
                                        }
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
                                                if disconnect_before_reply {
                                                    // Mutation took effect, but the host never
                                                    // receives its acknowledgement or a delta.
                                                    let _ = write.lock().await.shutdown().await;
                                                } else {
                                                    let _ = write.lock().await.write_all(format!("{answer}\n").as_bytes()).await;
                                                }
                                            });
                                            continue;
                                        }
                                        Some("new-tab") => {
                                            created_tx.send((request["cwd"].clone(), selected.load(Ordering::SeqCst))).unwrap();
                                            if let Some(waiting) = waiting_answer.take() {
                                                write.lock().await.write_all(format!("{waiting}\n").as_bytes()).await.unwrap();
                                            }
                                        }
                                        Some("send" | "send-key" | "clear-history") => {
                                            key_tx.send((request["id"].clone(), Instant::now())).unwrap();
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
        let mut services = tokio::task::JoinSet::new();
        for _ in 0..if same_channel { 1 } else { 2 } {
            let incoming = mac.accept().await.unwrap();
            services.spawn(serve(
                Arc::clone(&config),
                Peer { device_id: "test-phone".into(), session_id: "test-session".into(), video: None },
                Arc::new(LinkAuth::default()),
                incoming,
            ));
        }
        while let Some(result) = services.join_next().await {
            result.unwrap();
        }
        mac.close("test complete");
    });
    let mut channel = phone.open("daemon", json!({})).await.unwrap();
    let mut mutation_channel =
        if same_channel { None } else { Some(phone.open("daemon", json!({})).await.unwrap()) };
    let mut buffered = Vec::new();
    let mut mutation_buffered = Vec::new();

    // Warm through the public protocol and prove which selection is cached.
    let warm = if let Some(mutator) = &mut mutation_channel {
        // Establish B's cache handle with a read only command, then warm the
        // shared view through A. B must never mutate before its final new-tab:
        // otherwise the old per-channel state_changed flag would refresh B
        // and conceal the missing invalidation from A's acknowledgement.
        channel.send(Bytes::from_static(b"{\"id\":\"establish\",\"cmd\":\"identify\"}\n")).await.unwrap();
        let established = reply(&mut channel, &mut buffered).await;
        assert_eq!(established["id"], "establish");
        assert_eq!(established["ok"], true);
        mutator
            .send(Bytes::from_static(b"{\"id\":\"warm\",\"cmd\":\"new-tab\",\"pane\":3}\n"))
            .await
            .unwrap();
        reply(mutator, &mut mutation_buffered).await
    } else {
        channel
            .send(Bytes::from_static(b"{\"id\":\"warm\",\"cmd\":\"new-tab\",\"pane\":3}\n"))
            .await
            .unwrap();
        reply(&mut channel, &mut buffered).await
    };
    assert_eq!(warm["id"], "warm");
    assert_eq!(warm["data"]["cwd"], cwd_a);
    assert_eq!(created_rx.recv().await.unwrap(), (json!(cwd_a), 0));

    if terminal_wait {
        channel.send(Bytes::from_static(
            b"{\"id\":\"waiting\",\"cmd\":\"wait-for\",\"surface\":4,\"pattern\":\"ready\",\"timeout_ms\":60000}\n",
        )).await.unwrap();
    }
    let began = Instant::now();
    if let Some(mutator) = &mutation_channel {
        mutator.send(Bytes::from_static(
            b"{\"id\":\"select\",\"cmd\":\"select-tab\",\"surface\":5}\n{\"id\":\"input-clear\",\"cmd\":\"clear-history\",\"surface\":4,\"fallback_key\":{\"key\":\"l\",\"mods\":{\"shift\":false,\"control\":true,\"alt\":false,\"super\":false,\"caps_lock\":false,\"num_lock\":false},\"consumed_mods\":{\"shift\":false,\"control\":false,\"alt\":false,\"super\":false,\"caps_lock\":false,\"num_lock\":false},\"utf8\":\"\",\"unshifted_codepoint\":\"l\",\"action\":\"press\",\"macos_option_as_alt\":false}}\n{\"id\":\"input\",\"cmd\":\"send\",\"terminal_id\":\"term-4\",\"text\":\"x\"}\n{\"id\":\"input-key\",\"cmd\":\"send-key\",\"surface\":4,\"keys\":[\"enter\"]}\n",
        )).await.unwrap();
    } else {
        channel.send(Bytes::from_static(
            b"{\"id\":\"select\",\"cmd\":\"select-tab\",\"surface\":5}\n{\"id\":\"create\",\"cmd\":\"new-tab\",\"pane\":3}\n{\"id\":\"input-clear\",\"cmd\":\"clear-history\",\"surface\":4,\"fallback_key\":{\"key\":\"l\",\"mods\":{\"shift\":false,\"control\":true,\"alt\":false,\"super\":false,\"caps_lock\":false,\"num_lock\":false},\"consumed_mods\":{\"shift\":false,\"control\":false,\"alt\":false,\"super\":false,\"caps_lock\":false,\"num_lock\":false},\"utf8\":\"\",\"unshifted_codepoint\":\"l\",\"action\":\"press\",\"macos_option_as_alt\":false}}\n{\"id\":\"input\",\"cmd\":\"send\",\"terminal_id\":\"term-4\",\"text\":\"x\"}\n{\"id\":\"input-key\",\"cmd\":\"send-key\",\"surface\":4,\"keys\":[\"enter\"]}\n",
        )).await.unwrap();
    }
    let (clear_input, clear_at) =
        tokio::time::timeout(Duration::from_secs(3), key_rx.recv()).await.expect("clear forwarded").unwrap();
    assert_eq!(clear_input, "input-clear", "text overtook the clear-history fallback key");
    let (first_input, first_at) =
        tokio::time::timeout(Duration::from_secs(3), key_rx.recv()).await.expect("text forwarded").unwrap();
    let (second_input, second_at) =
        tokio::time::timeout(Duration::from_secs(3), key_rx.recv()).await.expect("key forwarded").unwrap();
    assert_eq!(first_input, "input", "Return overtook text addressed by terminal_id");
    assert_eq!(second_input, "input-key");
    let mut answers = HashMap::new();
    if let Some(mutator) = &mut mutation_channel {
        while answers.len() < if disconnect_before_reply { 3 } else { 4 } {
            let answer = reply(mutator, &mut mutation_buffered).await;
            answers.insert(answer["id"].as_str().unwrap().to_owned(), answer);
        }
        // The phone has seen A's mutation acknowledgement. B already had a
        // cached cwdA before the selection, and no subscription event updates
        // it. A must invalidate that shared view before exposing this ack.
        if disconnect_before_reply {
            tokio::time::timeout(Duration::from_secs(3), async {
                assert!(matches!(mutator.recv().await, Some(ChannelEvent::Closed(_))));
            })
            .await
            .expect("mutator channel closes after losing the reply");
        } else {
            assert_eq!(answers["select"]["ok"], true);
        }
        channel
            .send(Bytes::from_static(b"{\"id\":\"create\",\"cmd\":\"new-tab\",\"pane\":3}\n"))
            .await
            .unwrap();
    }
    // Three input replies plus creation, with optional selection/wait replies.
    let expected_answers = 4 + usize::from(!disconnect_before_reply) + usize::from(terminal_wait);
    while answers.len() < expected_answers {
        let answer = reply(&mut channel, &mut buffered).await;
        answers.insert(answer["id"].as_str().unwrap().to_owned(), answer);
    }
    // The host's internal ordered-command IDs never reach the phone.
    if terminal_wait {
        assert_eq!(answers["waiting"]["ok"], true);
        assert_eq!(answers["waiting"]["data"]["timeout_ms"], 60_000);
    }
    if !disconnect_before_reply {
        assert_eq!(answers["select"]["ok"], true);
    }
    assert_eq!(answers["create"]["data"]["cwd"], cwd_b);
    assert_eq!(answers["input-clear"]["ok"], true);
    assert_eq!(answers["input-key"]["data"]["keys"], json!(["enter"]));
    assert_eq!(answers["input"]["data"]["text"], "x");
    let creation = tokio::time::timeout(Duration::from_secs(3), created_rx.recv())
        .await
        .expect("creation forwarded")
        .unwrap();
    assert_eq!(creation, (json!(cwd_b), 1), "creation ran before selection was applied");
    let input_latency = clear_at.max(first_at).max(second_at).duration_since(began);

    channel.close("eof", "test complete").await;
    if let Some(mutator) = mutation_channel {
        mutator.close("eof", "test complete").await;
    }
    phone.close("test complete");
    tokio::time::timeout(Duration::from_secs(3), host).await.expect("host shutdown").unwrap();
    fake_daemon.abort();
    let _ = fake_daemon.await;
    assert!(input_latency < Duration::from_millis(125), "input waited for select-tab: {input_latency:?}");
}
