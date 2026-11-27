//! `set_build_space`: once the app sets a dev build's `dev:<slug>`, the warm
//! pool's `GET /v1/ice` and signaling upgrade carry `x-cmux-build-space`;
//! with none set (nightly, TestFlight, App Store) neither does.
//!
//! One test: the build space is a process setting, and tests in one binary
//! run in parallel.

use std::sync::{Arc, Mutex};

use cmux_mobile_link_ffi::{WarmPool, set_build_space};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// Records each request head (lowercased); answers HTTP with an empty ICE
/// config and refuses every WebSocket upgrade (401).
async fn recorder() -> (String, Arc<Mutex<Vec<String>>>) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let base_url = format!("http://{}", listener.local_addr().unwrap());
    let heads = Arc::new(Mutex::new(Vec::new()));
    let recorded = Arc::clone(&heads);
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            let recorded = Arc::clone(&recorded);
            tokio::spawn(async move {
                let mut head = Vec::new();
                let mut byte = [0u8; 1];
                while !head.ends_with(b"\r\n\r\n") {
                    if stream.read(&mut byte).await.unwrap_or(0) == 0 {
                        return;
                    }
                    head.push(byte[0]);
                }
                let head = String::from_utf8_lossy(&head).to_ascii_lowercase();
                let upgrade = head.contains("upgrade: websocket");
                recorded.lock().unwrap().push(head);
                let reply = if upgrade {
                    "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\nconnection: close\r\n\r\n".to_owned()
                } else {
                    let body = r#"{"iceServers":[],"ttl":1}"#;
                    format!(
                        "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\n\r\n{body}",
                        body.len()
                    )
                };
                let _ = stream.write_all(reply.as_bytes()).await;
                let _ = stream.shutdown().await;
            });
        }
    });
    (base_url, heads)
}

async fn prewarm_heads(build_space: Option<&str>) -> Vec<String> {
    set_build_space(build_space.map(str::to_owned));
    let (base_url, heads) = recorder().await;
    WarmPool::new().prewarm(base_url, "user:alice".into(), "team".into(), "phone".into()).await;
    let heads = heads.lock().unwrap().clone();
    assert!(heads.iter().any(|h| h.starts_with("get /v1/ice")), "{heads:?}");
    assert!(heads.iter().any(|h| h.contains("upgrade: websocket")), "{heads:?}");
    heads
}

#[tokio::test]
async fn the_warm_pool_sends_the_build_space_only_when_set() {
    for head in prewarm_heads(Some("dev:my-tag-2")).await {
        assert!(head.contains("x-cmux-build-space: dev:my-tag-2\r\n"), "{head}");
    }
    for unset in [None, Some(""), Some("dev:Not_Valid")] {
        for head in prewarm_heads(unset).await {
            assert!(!head.contains("x-cmux-build-space"), "{unset:?}: {head}");
        }
    }
    set_build_space(None);
}
