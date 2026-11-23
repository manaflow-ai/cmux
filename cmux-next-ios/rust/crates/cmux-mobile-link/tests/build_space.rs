//! A dev build's `x-cmux-build-space` header: sent on every HTTP request and
//! on the signaling WebSocket upgrade when the client has a build space, and
//! never otherwise (nightly and stable builds send nothing).

use std::sync::{Arc, Mutex};

use cmux_mobile_link::api::ApiClient;
use cmux_mobile_link::build_space::HEADER;
use cmux_mobile_link::{BuildSpace, SignalingClient};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

/// A listener that records each request's head (lowercased) and answers
/// HTTP with `{"devices":[],"iceServers":[]}` and a WebSocket upgrade with 401.
struct Recorder {
    base_url: String,
    heads: Arc<Mutex<Vec<String>>>,
}

impl Recorder {
    async fn start() -> Self {
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
                        "HTTP/1.1 401 Unauthorized\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
                            .to_owned()
                    } else {
                        let body = r#"{"devices":[],"iceServers":[],"ttl":60}"#;
                        format!(
                            "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{body}",
                            body.len()
                        )
                    };
                    let _ = stream.write_all(reply.as_bytes()).await;
                    let _ = stream.shutdown().await;
                });
            }
        });
        Self { base_url, heads }
    }

    fn heads(&self) -> Vec<String> {
        self.heads.lock().unwrap().clone()
    }
}

fn header_line(value: &str) -> String {
    format!("{HEADER}: {value}\r\n")
}

#[test]
fn parse_accepts_only_the_backend_pattern() {
    for valid in ["dev:a", "dev:my-tag-2", "dev:a1", format!("dev:{}", "a".repeat(64)).as_str()] {
        assert_eq!(
            BuildSpace::parse(valid).map(|s| s.as_str().to_owned()),
            Some(valid.to_owned()),
            "{valid}"
        );
    }
    for invalid in [
        "",
        "dev:",
        "a",
        "dev:-a",
        "dev:a-",
        "dev:A",
        "dev:a_b",
        "prod:a",
        "dev:a b",
        format!("dev:{}", "a".repeat(65)).as_str(),
    ] {
        assert_eq!(BuildSpace::parse(invalid), None, "{invalid}");
    }
    assert_eq!(BuildSpace::parse_optional(None), None);
    assert_eq!(BuildSpace::parse_optional(Some("  ")), None);
    assert_eq!(BuildSpace::parse_optional(Some(" dev:x ")).map(|s| s.to_string()), Some("dev:x".to_owned()));
    assert_eq!(HEADER, "x-cmux-build-space");
}

#[tokio::test]
async fn http_requests_carry_the_build_space_only_when_set() {
    let server = Recorder::start().await;
    let space = BuildSpace::parse("dev:my-tag-2").unwrap();
    let tagged = ApiClient::new(&server.base_url, "user:alice").with_build_space(Some(space.clone()));
    assert_eq!(tagged.build_space(), Some(&space));
    tagged.my_devices().await.unwrap();
    tagged.ice().await.unwrap();
    let untagged = ApiClient::new(&server.base_url, "user:alice");
    assert_eq!(untagged.build_space(), None);
    untagged.my_devices().await.unwrap();
    untagged.ice().await.unwrap();
    // `with_build_space(None)` is no space too.
    ApiClient::new(&server.base_url, "user:alice").with_build_space(None).my_devices().await.unwrap();

    let heads = server.heads();
    assert_eq!(heads.len(), 5, "{heads:?}");
    for head in &heads[..2] {
        assert!(head.contains(&header_line("dev:my-tag-2")), "{head}");
        assert!(head.contains("authorization: bearer user:alice"), "{head}");
    }
    for head in &heads[2..] {
        assert!(!head.contains(HEADER), "{head}");
    }
}

#[tokio::test]
async fn the_signaling_upgrade_carries_the_build_space_only_when_set() {
    let server = Recorder::start().await;
    let space = BuildSpace::parse("dev:my-tag-2").unwrap();
    let tagged =
        SignalingClient::connect_in(&server.base_url, "user:alice", "team", "mac", Some(&space)).await;
    assert!(tagged.is_err(), "the recorder refuses every upgrade");
    let untagged = SignalingClient::connect(&server.base_url, "user:alice", "team", "mac").await;
    assert!(untagged.is_err());
    let none = SignalingClient::connect_in(&server.base_url, "user:alice", "team", "mac", None).await;
    assert!(none.is_err());

    let heads = server.heads();
    assert_eq!(heads.len(), 3, "{heads:?}");
    assert!(heads.iter().all(|head| head.contains("upgrade: websocket")), "{heads:?}");
    assert!(heads[0].contains(&header_line("dev:my-tag-2")), "{}", heads[0]);
    assert!(heads[0].contains("authorization: bearer user:alice"), "{}", heads[0]);
    assert!(!heads[1].contains(HEADER), "{}", heads[1]);
    assert!(!heads[2].contains(HEADER), "{}", heads[2]);
}
