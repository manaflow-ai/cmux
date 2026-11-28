use super::*;
use std::sync::atomic::{AtomicUsize, Ordering};

struct FakeCapability {
    calls: AtomicUsize,
}
impl OwnerCapability for FakeCapability {
    fn bearer(&self) -> Result<Zeroizing<String>> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(Zeroizing::new("owner-capability".into()))
    }
}

fn preparation() -> CloudTurnEnvelope {
    CloudTurnEnvelope {
        capability: format!("trc_{}", "a".repeat(43)),
        team: "team".into(),
        user: "user".into(),
        workspace: "ws".into(),
        machine: "machine".into(),
        generation: 7,
        session: "session".into(),
        turn: "prompt".into(),
        expires_at: 0,
        purpose: "prepare".into(),
        attempt_id: "attempt".into(),
    }
}

#[test]
fn preparation_requires_explicit_purpose_and_exact_request_scope() {
    let auth = preparation();
    let check = |auth: &CloudTurnEnvelope| {
        preparation_scope("ws", "machine", "session", "prompt", 7, "attempt", auth)
    };
    assert!(check(&auth).is_ok());
    for field in [
        "workspace",
        "machine",
        "session",
        "turn",
        "generation",
        "attempt",
        "purpose",
        "missing-purpose",
    ] {
        let mut wrong = auth.clone();
        match field {
            "workspace" => wrong.workspace = "other".into(),
            "machine" => wrong.machine = "other".into(),
            "session" => wrong.session = "other".into(),
            "turn" => wrong.turn = "other".into(),
            "generation" => wrong.generation += 1,
            "attempt" => wrong.attempt_id = "other".into(),
            "purpose" => wrong.purpose = "execute".into(),
            _ => wrong.purpose.clear(),
        }
        assert!(check(&wrong).is_err(), "accepted wrong {field}");
    }
    let mut missing = auth;
    missing.attempt_id.clear();
    assert!(preparation_scope("ws", "machine", "session", "prompt", 7, "", &missing).is_err());
}

async fn claim_server(status: u16, body: Value) -> (String, tokio::task::JoinHandle<String>) {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let (mut socket, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        loop {
            let mut chunk = [0; 4096];
            let count = socket.read(&mut chunk).await.unwrap();
            assert!(count > 0);
            request.extend_from_slice(&chunk[..count]);
            if let Some(end) = request.windows(4).position(|part| part == b"\r\n\r\n") {
                let header = String::from_utf8_lossy(&request[..end]);
                let length: usize = header
                    .lines()
                    .find_map(|line| {
                        line.to_ascii_lowercase().strip_prefix("content-length: ").map(str::parse)
                    })
                    .unwrap()
                    .unwrap();
                if request.len() >= end + 4 + length {
                    break;
                }
            }
        }
        let body = body.to_string();
        socket.write_all(format!("HTTP/1.1 {status} Response\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
        String::from_utf8(request).unwrap()
    });
    (origin, task)
}

fn test_client(origin: &str) -> CloudTurnClient {
    let auth = Arc::new(EphemeralCapability::new(preparation().capability).unwrap());
    let mut client = CloudTurnClient::new("https://cloud.example", "ws", "machine", auth).unwrap();
    // Only tests can replace the validated HTTPS origin with a local HTTP listener.
    client.origin = reqwest::Url::parse(origin).unwrap();
    client
}

#[tokio::test]
async fn preparation_claim_posts_scope_and_requires_authoritative_confirmation() {
    let scope = preparation().scope();
    let mut body = serde_json::to_value(&scope).unwrap();
    body["claimed"] = Value::Bool(true);
    let (origin, server) = claim_server(200, body).await;
    let verified = test_client(&origin).verify_preparation(&scope).await.unwrap();
    assert_eq!(verified, scope);
    let request = server.await.unwrap();
    assert!(request.starts_with("POST /v1/turn-execution/claim HTTP/1.1"));
    let (_, body) = request.split_once("\r\n\r\n").unwrap();
    assert_eq!(serde_json::from_str::<TurnScope>(body).unwrap(), scope);
    assert!(!body.contains("trc_"));
}

#[tokio::test]
async fn preparation_refuses_denial_missing_ack_and_mismatched_backend_scope() {
    let scope = preparation().scope();
    for variation in [
        "denied",
        "empty",
        "false",
        "team",
        "user",
        "workspace",
        "machine",
        "session",
        "turn",
        "generation",
        "purpose",
        "attemptId",
    ] {
        let mut body = serde_json::to_value(&scope).unwrap();
        body["claimed"] = Value::Bool(true);
        let status = if variation == "denied" { 409 } else { 200 };
        match variation {
            "denied" => {}
            "empty" => body = serde_json::json!({}),
            "false" => body["claimed"] = Value::Bool(false),
            "generation" => body[variation] = Value::from(8),
            field => body[field] = Value::from("other"),
        }
        let (origin, server) = claim_server(status, body).await;
        assert!(
            test_client(&origin).verify_preparation(&scope).await.is_err(),
            "accepted {variation}"
        );
        server.await.unwrap();
    }
}

#[tokio::test]
async fn preparation_cannot_be_used_as_execution_or_for_another_machine() {
    let client = test_client("http://127.0.0.1:1");
    let scope = preparation().scope();
    assert!(
        client.claim_execution(&scope).await.unwrap_err().to_string().contains("execute purpose")
    );
    assert!(
        client.finish_execution(&scope).await.unwrap_err().to_string().contains("execute purpose")
    );
    let mut wrong = scope.clone();
    wrong.machine = "other".into();
    assert!(
        client.verify_preparation(&wrong).await.unwrap_err().to_string().contains("machine fence")
    );
    wrong = scope;
    wrong.workspace = "other".into();
    assert!(
        client
            .verify_preparation(&wrong)
            .await
            .unwrap_err()
            .to_string()
            .contains("workspace fence")
    );
}

#[test]
fn ledger_is_idempotent_and_fenced() {
    let ledger = TurnCaptureLedger::new("machine-a", 3);
    let active = ledger.claim("session", "turn-a").unwrap();
    assert_eq!(active.generation, 3);
    let capture = SnapshotReply {
        id: "capture-a".into(),
        workspace: "ws".into(),
        session: "session".into(),
        turn: "turn-a".into(),
        machine_id: "machine-a".into(),
        machine_generation: 3,
        snapshot_id: "snapshot-a".into(),
        status: "ready".into(),
        created_at: None,
        updated_at: None,
    };
    assert_eq!(ledger.record_capture(capture.clone()).unwrap(), capture);
    assert_eq!(ledger.record_capture(capture.clone()).unwrap(), capture);
    ledger.finish("session", "turn-a", 3).unwrap();
    assert!(ledger.finish("session", "turn-a", 3).is_err());
    ledger
        .apply_rewind(
            "session",
            "turn-a",
            &MachineReplacement { id: "machine-b".into(), generation: 4 },
        )
        .unwrap();
    assert_eq!(ledger.machine().as_deref(), Some("machine-b"));
    assert_eq!(ledger.generation(), 4);
    assert!(ledger.capture("session", "turn-a").is_none());
}

#[test]
fn rejects_conflicting_capture_and_stale_rewind() {
    let ledger = TurnCaptureLedger::new("machine-a", 8);
    ledger.claim("session", "turn-a").unwrap();
    let mut capture = SnapshotReply {
        id: "capture-a".into(),
        workspace: "ws".into(),
        session: "session".into(),
        turn: "turn-a".into(),
        machine_id: "machine-a".into(),
        machine_generation: 8,
        snapshot_id: "snapshot-a".into(),
        status: "ready".into(),
        created_at: None,
        updated_at: None,
    };
    ledger.record_capture(capture.clone()).unwrap();
    capture.snapshot_id = "snapshot-other".into();
    assert!(ledger.record_capture(capture).is_err());
    assert!(
        ledger
            .apply_rewind(
                "session",
                "turn-a",
                &MachineReplacement { id: "machine-b".into(), generation: 8 }
            )
            .is_err()
    );
}

#[test]
fn client_rejects_untrusted_origin_and_stable_key_has_no_secret() {
    let auth = Arc::new(FakeCapability { calls: AtomicUsize::new(0) });
    assert!(CloudTurnClient::new("http://cloud.example", "ws", "machine", auth.clone()).is_err());
    assert_eq!(CloudTurnClient::client_key("session-1").unwrap(), "acpmux-session-1");
    assert!(CloudTurnClient::client_key("session/evil").is_err());
    assert_eq!(auth.calls.load(Ordering::SeqCst), 0);
}
