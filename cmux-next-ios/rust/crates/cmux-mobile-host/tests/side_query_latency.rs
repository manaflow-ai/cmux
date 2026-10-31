//! Runs unchanged against base and head. Set CMUX_SIDE_QUERY_BASELINE=1 only to
//! record the pre-fix latency (all forwarding/cwd assertions still run).
//! The link, daemon service and Unix socket are real; only the daemon is fake.

use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;

use bytes::Bytes;
use cmux_mobile_host::config::{AcpmuxTarget, ServiceConfig};
use cmux_mobile_host::pairing::LinkAuth;
use cmux_mobile_host::services::{Peer, serve};
use cmux_mobile_link::{Channel, ChannelEvent, Link, LinkConfig, Role};
use serde_json::{Value, json};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::mpsc;
use tokio::time::Instant;

const SNAPSHOT_DELAY: Duration = Duration::from_millis(250);

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
async fn keystrokes_do_not_wait_for_workspace_side_queries() {
    let sockets = tempfile::tempdir().unwrap();
    let folder = tempfile::tempdir().unwrap();
    let cwd = folder.path().canonicalize().unwrap().to_str().unwrap().to_owned();
    let listener = tokio::net::UnixListener::bind(sockets.path().join("main.sock")).unwrap();
    let (received_tx, mut received_rx) = mpsc::unbounded_channel();
    let (observed_tx, mut observed_rx) = mpsc::unbounded_channel();
    let tree = json!({"registry_id":"test-registry", "workspaces":[{
        "id":1, "key":"test-workspace", "screens":[{"id":2,"panes":[{
            "id":3,"active_tab":0,"tabs":[{"surface":4,"kind":"terminal","cwd":cwd}]
        }]}]
    }]});
    // JoinSet owns every accepted socket task; aborting this parent below also
    // stops any delayed snapshot and closes the sockets (no detached servers).
    let fake_daemon = tokio::spawn(async move {
        let mut clients = tokio::task::JoinSet::new();
        loop {
            tokio::select! {
                accepted = listener.accept() => {
                    let (stream, _) = accepted.unwrap();
                    let received_tx = received_tx.clone();
                    let observed_tx = observed_tx.clone();
                    let tree = tree.clone();
                    clients.spawn(async move {
                        let (read, mut write) = stream.into_split();
                        let mut lines = BufReader::new(read).lines();
                        while let Ok(Some(line)) = lines.next_line().await {
                            let request: Value = serde_json::from_str(&line).unwrap();
                            observed_tx.send((request["id"].clone(), request["cmd"].clone())).unwrap();
                            if request["cmd"] == "send" {
                                received_tx.send((request["id"].clone(), Instant::now())).unwrap();
                            }
                            let mut answer = json!({"id":request["id"],"ok":true,"data":request});
                            match request["cmd"].as_str() {
                                Some("list-workspaces") => {
                                    tokio::time::sleep(SNAPSHOT_DELAY).await;
                                    answer["data"] = tree.clone();
                                }
                                Some("list-personal") => {
                                    answer["data"] = json!({"groups":[],"workspaces":[]});
                                }
                                _ if request["operation"] == "sidebar_layout.get" => {
                                    answer["result"] = json!({"sections":[]});
                                }
                                _ => {}
                            }
                            if write.write_all(format!("{answer}\n").as_bytes()).await.is_err() {
                                return;
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

    // The first request intentionally starts cold. The tree snapshot is held
    // for 250 ms, then an ordinary terminal input is sent immediately behind
    // it. A head with the old inline lookup blocks this input; the cache path
    // forwards it while the side worker waits. This also checks that a
    // non-input side request stays ahead of a later close-pane while input may
    // bypass both.
    let cold_side = json!({"id":"cold-side","cmd":"new-tab","pane":3});
    let cold_close = json!({"id":"cold-close","cmd":"close-pane","pane":3});
    let cold_key = json!({"id":"cold-key","cmd":"send","surface":4,"text":"x"});
    let cold_began = Instant::now();
    channel.send(Bytes::from(format!("{cold_side}\n{cold_close}\n{cold_key}\n"))).await.unwrap();
    let (received_id, received_at) = tokio::time::timeout(Duration::from_secs(3), received_rx.recv())
        .await
        .expect("cold keystroke forwarded")
        .expect("fake daemon still connected");
    assert_eq!(received_id, "cold-key");
    let cold_latency = received_at.duration_since(cold_began).as_secs_f64() * 1000.0;
    let mut cold_answers = HashMap::new();
    while cold_answers.len() < 3 {
        let answer = reply(&mut channel, &mut buffered).await;
        cold_answers.insert(answer["id"].as_str().unwrap().to_owned(), answer);
    }
    assert_eq!(cold_answers["cold-side"]["data"]["cwd"], cwd);
    assert_eq!(cold_answers["cold-key"]["data"]["text"], "x");
    assert_eq!(cold_answers["cold-close"]["data"]["cmd"], "close-pane");
    let mut cold_order = Vec::new();
    tokio::time::timeout(Duration::from_secs(3), async {
        while cold_order.len() < 3 {
            let (id, _) = observed_rx.recv().await.expect("daemon observation");
            if id.as_str().is_some_and(|id| id.starts_with("cold-")) {
                cold_order.push(id);
            }
        }
    })
    .await
    .expect("all cold commands forwarded");
    let side_position = cold_order.iter().position(|id| id == "cold-side").unwrap();
    let close_position = cold_order.iter().position(|id| id == "cold-close").unwrap();
    assert!(side_position < close_position, "side request reordered with close-pane: {cold_order:?}");

    // The successful cold request above warmed the cache through the public
    // protocol and proved that the daemon's authoritative cwd is available.
    let mut samples = Vec::new();
    for sample in 0..12 {
        let side_id = format!("side-{sample}");
        let key_id = format!("key-{sample}");
        let side = json!({"id":side_id,"cmd":"new-tab","pane":3});
        let key = json!({"id":key_id,"cmd":"send","surface":4,"text":"x"});
        let began = Instant::now();
        // Same message and ordering on both revisions: a request that needs a
        // tree lookup immediately before terminal input in the same splice.
        channel.send(Bytes::from(format!("{side}\n{key}\n"))).await.unwrap();
        let (received_id, received_at) = tokio::time::timeout(Duration::from_secs(3), received_rx.recv())
            .await
            .expect("keystroke forwarded")
            .expect("fake daemon still connected");
        assert_eq!(received_id, key_id);
        samples.push(received_at.duration_since(began).as_secs_f64() * 1000.0);
        let mut answers = HashMap::new();
        while answers.len() < 2 {
            let answer = reply(&mut channel, &mut buffered).await;
            answers.insert(answer["id"].as_str().unwrap().to_owned(), answer);
        }
        assert_eq!(answers[&side_id]["data"]["cwd"], cwd, "cached lookup changed terminal directory");
        assert_eq!(answers[&key_id]["data"]["text"], "x");
    }
    samples.sort_by(f64::total_cmp);
    let p50 = samples[samples.len() / 2];
    let p95 = samples[samples.len() - 1];
    println!(
        "SIDE_QUERY_LATENCY snapshot_delay_ms={} samples={} p50_ms={p50:.3} p95_ms={p95:.3}",
        SNAPSHOT_DELAY.as_millis(),
        samples.len(),
    );
    println!("SIDE_QUERY_LATENCY cold_ms={cold_latency:.3}");
    channel.close("eof", "test complete").await;
    phone.close("test complete");
    tokio::time::timeout(Duration::from_secs(3), host).await.expect("host shutdown").unwrap();
    fake_daemon.abort();
    let _ = fake_daemon.await;
    if std::env::var_os("CMUX_SIDE_QUERY_BASELINE").is_none() {
        assert_eq!(cold_order[0], "cold-key", "input did not bypass cold non-input requests");
        assert!(p95 < 125.0, "keystroke forwarding waited on a {SNAPSHOT_DELAY:?} tree lookup: {p95:.3} ms");
        assert!(
            cold_latency < 125.0,
            "cold keystroke forwarding waited on a {SNAPSHOT_DELAY:?} tree lookup: {cold_latency:.3} ms"
        );
    }
}
