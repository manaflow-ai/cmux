use super::*;
use base64::Engine as _;
use ring::signature::{Ed25519KeyPair, KeyPair};
use std::path::PathBuf;
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

fn pair(seed: u8) -> Ed25519KeyPair {
    Ed25519KeyPair::from_seed_unchecked(&[seed; 32]).unwrap()
}

fn keys() -> Vec<(String, [u8; 32])> {
    let raw: [u8; 32] = pair(7).public_key().as_ref().try_into().unwrap();
    vec![(cmux_signed_envelope::key_id(&raw), raw)]
}

fn envelope(pair: &Ed25519KeyPair, payload: &Value) -> String {
    let b64 = base64::engine::general_purpose::STANDARD;
    let bytes = serde_json::to_vec(payload).unwrap();
    let raw: [u8; 32] = pair.public_key().as_ref().try_into().unwrap();
    json!({"schema": 1, "payload": b64.encode(&bytes),
           "signatures": [{"key_id": cmux_signed_envelope::key_id(&raw),
                           "sig": b64.encode(pair.sign(&bytes).as_ref())}]})
    .to_string()
}

fn file(serial: u64, pieces: Value) -> Value {
    json!({"schema": 1, "purpose": phone::PURPOSE, "channel": "internal", "serial": serial,
           "published_at": 1_795_340_000u64, "pieces": pieces})
}

fn signed(serial: u64, pieces: Value) -> Fetched {
    Fetched::Body(envelope(&pair(7), &file(serial, pieces)), Some("\"e1\"".to_owned()))
}

fn markdown_off() -> Value {
    json!({"markdown-web": {"serve": "bundled", "reason": "blank math"}})
}

/// A folder of this test's own, removed when the test ends.
struct Folder(PathBuf);

impl Folder {
    fn new() -> Self {
        let path = std::env::temp_dir().join(format!("cmux-ios-pieces-{}", uuid::Uuid::new_v4()));
        Self(path.join("state"))
    }

    fn take(&self, fetched: Fetched, now: u64) -> Reading {
        take(&self.0, "internal", fetched, &keys(), now)
    }

    /// What the next launch holds before any request. `load` checks against the pinned keys,
    /// which never matters: the kept switches were verified when they were taken.
    fn launch(&self) -> Reading {
        load(&self.0, "internal")
    }

    fn log(&self) -> Vec<Value> {
        log_tail(&self.0, 100).iter().map(|line| serde_json::from_str(line).unwrap()).collect()
    }
}

impl Drop for Folder {
    fn drop(&mut self) {
        if let Some(parent) = self.0.parent() {
            let _ = std::fs::remove_dir_all(parent);
        }
    }
}

fn off(pairs: &[(&str, &str)]) -> Vec<(String, String)> {
    pairs.iter().map(|(piece, reason)| ((*piece).to_owned(), (*reason).to_owned())).collect()
}

#[test]
fn a_launch_with_nothing_on_disk_switches_nothing_and_writes_nothing() {
    let folder = Folder::new();
    let reading = folder.launch();
    assert_eq!(reading, Reading { off: vec![], serial: 0, verdict: "no_file".to_owned() });
    assert!(!folder.0.exists());
}

#[test]
fn a_piece_goes_off_stays_off_across_launches_and_comes_back_on() {
    let folder = Folder::new();
    let reading = folder.take(signed(3, markdown_off()), 100);
    assert_eq!(reading.off, off(&[("markdown-web", "blank math")]));
    assert_eq!((reading.serial, reading.verdict.as_str()), (3, "taken"));
    // The next launch holds it off from the disk, before any request.
    assert_eq!(folder.launch().off, off(&[("markdown-web", "blank math")]));
    assert_eq!(folder.launch().serial, 3);

    // The switch is removed: the piece is on again, at once and at the next launch.
    let reading = folder.take(signed(4, json!({})), 200);
    assert_eq!((reading.off.len(), reading.serial, reading.verdict.as_str()), (0, 4, "taken"));
    assert_eq!(folder.launch().off, vec![]);

    let log = folder.log();
    assert_eq!(log.len(), 2);
    assert_eq!(log[0]["off"], json!(["markdown-web"]));
    assert_eq!(log[0]["serial"], 3);
    assert_eq!(log[1]["off"], json!([]));
    assert_eq!(log[1]["serial"], 4);
}

#[test]
fn every_refused_or_failed_read_keeps_what_the_phone_holds() {
    let folder = Folder::new();
    folder.take(signed(3, markdown_off()), 100);
    let held = off(&[("markdown-web", "blank math")]);
    let body = |text: String| Fetched::Body(text, Some("\"e2\"".to_owned()));
    let cases: Vec<(&str, Fetched)> = vec![
        ("unsigned", body(file(9, json!({})).to_string())),
        ("unsigned", body("<html>".to_owned())),
        ("unsigned", body(envelope(&pair(8), &file(9, json!({}))))),
        ("stale", body(envelope(&pair(7), &file(2, json!({}))))),
        (
            "too_large",
            body(envelope(
                &pair(7),
                &file(
                    9,
                    json!({"markdown-web": {"serve": "bundled",
                                                 "reason": "x".repeat(cmux_web_pieces::MAX_BYTES)}}),
                ),
            )),
        ),
        (
            "wrong_purpose",
            body(envelope(&pair(7), &{
                let mut mac = file(9, json!({}));
                mac["purpose"] = json!(cmux_web_pieces::PURPOSE);
                mac
            })),
        ),
        (
            "wrong_channel",
            body(envelope(&pair(7), &{
                let mut other = file(9, json!({}));
                other["channel"] = json!("app-store");
                other
            })),
        ),
        ("no_file", Fetched::Missing),
        ("no_file", Fetched::NotModified),
        ("no_file", Fetched::Failed("no route".to_owned())),
    ];
    for (verdict, fetched) in cases {
        let reading = folder.take(fetched, 200);
        assert_eq!(reading.verdict, verdict);
        assert_eq!(reading.off, held, "{verdict}");
        assert_eq!(reading.serial, 3, "{verdict}");
        assert_eq!(folder.launch().off, held, "{verdict}");
    }
    // Each refusal is on the log, and the ETag of the file taken is still the one kept.
    let refused: Vec<String> = folder
        .log()
        .iter()
        .map(|line| line["verdict"].as_str().unwrap().to_owned())
        .filter(|verdict| verdict != "taken" && verdict != "no_file")
        .collect();
    assert_eq!(
        refused,
        ["unsigned", "unsigned", "unsigned", "stale", "too_large", "wrong_purpose", "wrong_channel"]
    );
    assert_eq!(State::of(&folder.0, "internal").etag.as_deref(), Some("\"e1\""));
}

#[test]
fn an_unknown_piece_name_switches_nothing_and_is_logged() {
    let folder = Folder::new();
    let reading = folder.take(signed(1, json!({"a-later-piece": {"serve": "bundled"}})), 100);
    assert_eq!((reading.off.len(), reading.verdict.as_str()), (0, "taken"));
    assert_eq!(folder.log()[0]["unknown"], json!(["a-later-piece"]));
}

#[test]
fn a_quiet_check_adds_no_log_line() {
    let folder = Folder::new();
    folder.take(signed(3, markdown_off()), 100);
    folder.take(signed(3, markdown_off()), 200);
    folder.take(Fetched::NotModified, 300);
    assert_eq!(folder.log().len(), 2, "taken, then no_file once");
    folder.take(Fetched::NotModified, 400);
    assert_eq!(folder.log().len(), 2);
}

#[test]
fn a_folder_that_cannot_be_written_never_fails_the_app() {
    let folder = Folder::new();
    // The state folder's path is a file: nothing can be created under it.
    std::fs::create_dir_all(folder.0.parent().unwrap()).unwrap();
    std::fs::write(&folder.0, b"not a folder").unwrap();
    let reading = folder.take(signed(3, markdown_off()), 100);
    // The file is still honored for this run; only the memory of it is lost.
    assert_eq!(reading.off, off(&[("markdown-web", "blank math")]));
    assert_eq!(folder.launch().off, vec![]);
    assert!(log_tail(&folder.0, 10).is_empty());
}

#[test]
fn a_damaged_state_file_is_no_state() {
    let folder = Folder::new();
    folder.take(signed(3, markdown_off()), 100);
    std::fs::write(folder.0.join(STATE_FILE), b"{\"channel\": \"internal\", \"floor\": ").unwrap();
    assert_eq!(folder.launch().off, vec![]);
    std::fs::write(folder.0.join(STATE_FILE), b"[1, 2]").unwrap();
    assert_eq!(folder.launch().off, vec![]);
}

#[tokio::test]
async fn a_check_soon_after_the_last_answer_asks_nothing() {
    let folder = Folder::new();
    folder.take(signed(3, markdown_off()), 1_000);
    // No server is reachable from a test: a request would fail, not answer `fresh`.
    let reading = check(&folder.0, "internal", 1_000 + CHECK_EVERY.as_secs() - 1).await;
    assert_eq!(reading.verdict, "fresh");
    assert_eq!(reading.off, off(&[("markdown-web", "blank math")]));
}

/// Serves `response` once on a local port; answers the request's text.
async fn serve(response: String) -> (String, tokio::task::JoinHandle<String>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let url = format!("http://{}/ota/pieces-ios-internal.json", listener.local_addr().unwrap());
    let served = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        let mut buffer = [0u8; 1024];
        while !request.windows(4).any(|window| window == b"\r\n\r\n") {
            let read = stream.read(&mut buffer).await.unwrap();
            if read == 0 {
                break;
            }
            request.extend_from_slice(&buffer[..read]);
        }
        let _ = stream.write_all(response.as_bytes()).await;
        let _ = stream.shutdown().await;
        String::from_utf8_lossy(&request).into_owned()
    });
    (url, served)
}

fn response(status: &str, headers: &str, body: &str) -> String {
    format!("HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n{headers}\r\n{body}", body.len())
}

#[tokio::test]
async fn the_get_reads_a_body_and_its_etag_and_sends_the_kept_one() {
    let (url, served) = serve(response("200 OK", "ETag: \"e9\"\r\n", "{\"schema\":1}")).await;
    let fetched = fetch(&url, Some("\"e1\"")).await;
    assert_eq!(fetched, Fetched::Body("{\"schema\":1}".to_owned(), Some("\"e9\"".to_owned())));
    let request = served.await.unwrap().to_ascii_lowercase();
    assert!(request.contains("if-none-match: \"e1\""), "{request}");
    // The request names nobody: no cookie, no authorization.
    assert!(!request.contains("cookie:") && !request.contains("authorization:"), "{request}");
}

#[tokio::test]
async fn the_get_maps_every_other_answer() {
    let (url, _served) = serve(response("304 Not Modified", "", "")).await;
    assert_eq!(fetch(&url, None).await, Fetched::NotModified);
    let (url, _served) = serve(response("404 Not Found", "", "no")).await;
    assert_eq!(fetch(&url, None).await, Fetched::Missing);
    let (url, _served) = serve(response("500 Internal Server Error", "", "no")).await;
    assert!(matches!(fetch(&url, None).await, Fetched::Failed(_)));
    // A redirect is not followed: no other host is asked.
    let (url, _served) = serve(response("302 Found", "Location: http://127.0.0.1:1/elsewhere\r\n", "")).await;
    assert!(matches!(fetch(&url, None).await, Fetched::Failed(error) if error.contains("302")));
    // A body past the bound is dropped before it is parsed.
    let big = "x".repeat(cmux_web_pieces::MAX_BYTES + 1);
    let (url, _served) = serve(response("200 OK", "", &big)).await;
    assert!(matches!(fetch(&url, None).await, Fetched::Failed(error) if error.contains("larger")));
    // No answer at all.
    assert!(matches!(fetch("http://127.0.0.1:1/x", None).await, Fetched::Failed(_)));
}
