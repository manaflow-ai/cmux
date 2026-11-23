use super::*;
use tokio::io::{AsyncReadExt, AsyncWriteExt};

const ID: &str = "3f1c2a9e-8b7d-4c6e-9a5b-1d2e3f4a5b6c";

/// A fake platform: answers each connection with the next `(status, body)` and hands back every
/// request it read, in order.
async fn server(answers: Vec<(u16, Value)>) -> (String, tokio::task::JoinHandle<Vec<String>>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let task = tokio::spawn(async move {
        let mut seen = Vec::new();
        for (status, body) in answers {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            loop {
                let mut chunk = [0; 4096];
                let count = socket.read(&mut chunk).await.unwrap();
                assert!(count > 0);
                request.extend_from_slice(&chunk[..count]);
                if let Some(end) = request.windows(4).position(|w| w == b"\r\n\r\n") {
                    let header = String::from_utf8_lossy(&request[..end]).to_ascii_lowercase();
                    let length: usize = header
                        .lines()
                        .find_map(|l| {
                            l.strip_prefix("content-length: ").map(|v| v.parse().unwrap())
                        })
                        .unwrap_or(0);
                    if request.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            let body = body.to_string();
            let reply = format!(
                "HTTP/1.1 {status} R\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            );
            socket.write_all(reply.as_bytes()).await.unwrap();
            seen.push(String::from_utf8(request).unwrap());
        }
        seen
    });
    (origin, task)
}

fn client(origin: &str) -> TriggerClient {
    TriggerClient::new(origin.to_owned(), Zeroizing::new("cmx_owner".into())).unwrap()
}

fn trigger(enabled: bool) -> Value {
    json!({
        "id": ID, "owner": "u", "team": "t", "repository": "acme/app", "prompt": "fix CI",
        "target": {"machine": "m1", "workspace": "w1", "session": "fixer", "cwd": "/repo",
                   "harness": "codex", "policy": "wake_existing"},
        "enabled": enabled, "revision": 1, "events": ["ci_failure", "pr_comment"],
    })
}

fn args() -> CreateArgs {
    CreateArgs {
        repo: "acme/app".into(),
        events: vec!["ci_failure".into(), "pr_comment".into()],
        machine: "m1".into(),
        workspace: "w1".into(),
        session: "fixer".into(),
        cwd: "/repo".into(),
        harness: "codex".into(),
        prompt: vec!["fix".into(), "CI".into()],
        ..CreateArgs::default()
    }
}

#[test]
fn create_body_is_the_platform_trigger_create_shape() {
    let body = create_body(&args()).unwrap();
    assert_eq!(
        body,
        json!({
            "repository": "acme/app", "prompt": "fix CI", "events": ["ci_failure", "pr_comment"],
            "target": {"machine": "m1", "workspace": "w1", "session": "fixer", "cwd": "/repo",
                       "harness": "codex"},
        })
    );
    let mut more = args();
    more.start_session = true;
    more.installation = Some(7);
    more.cooldown = Some(0);
    let body = create_body(&more).unwrap();
    assert_eq!(body["target"]["policy"], "start_session");
    assert_eq!(body["installation"], 7);
    assert_eq!(body["guardrails"], json!({"cooldownSeconds": 0, "maxRunsPerDay": 24}));
    let mut hook = args();
    hook.webhook = true;
    hook.events = vec!["deploy.failed".into()];
    let body = create_body(&hook).unwrap();
    assert_eq!(body["source"], "webhook");
    assert_eq!(body["events"], json!(["deploy.failed"]));
}

#[test]
fn create_body_refuses_what_the_platform_would() {
    let mut bad = args();
    bad.repo = "acme".into();
    assert!(create_body(&bad).is_err());
    let mut bad = args();
    bad.events = vec!["push".into()];
    assert!(create_body(&bad).unwrap_err().to_string().contains("no GitHub trigger event"));
    let mut bad = args();
    bad.cwd = "repo".into();
    assert!(create_body(&bad).is_err());
    assert!(valid_id(ID).is_ok());
    assert!(valid_id("../machines").is_err());
    assert!(valid_id("0190f1c2-8b7d-7c6e-9a5b-1d2e3f4a5b6c").is_err());
}

#[tokio::test]
async fn create_posts_with_the_bearer_and_returns_the_secret_and_delivery_url() {
    let (origin, seen) =
        server(vec![(200, json!({"trigger": trigger(true), "secret": "whsec_1"}))]).await;
    let c = client(&origin);
    let created = c.create(&create_body(&args()).unwrap()).await.unwrap();
    assert_eq!(created["secret"], "whsec_1");
    assert_eq!(c.delivery_url(&created["trigger"]), format!("{origin}/v1/triggers/{ID}/github"));
    let seen = seen.await.unwrap();
    assert!(seen[0].starts_with("POST /v1/triggers HTTP/1.1"));
    assert!(seen[0].to_ascii_lowercase().contains("authorization: bearer cmx_owner"));
    let (_, body) = seen[0].split_once("\r\n\r\n").unwrap();
    assert_eq!(serde_json::from_str::<Value>(body).unwrap()["repository"], "acme/app");
}

#[tokio::test]
async fn rm_deletes_then_reads_the_trigger_back_disabled() {
    let (origin, seen) = server(vec![(200, json!({"removed": true})), (200, trigger(false))]).await;
    let out = client(&origin).remove(ID).await.unwrap();
    assert_eq!(out["removed"], true);
    assert_eq!(out["trigger"]["enabled"], false);
    let seen = seen.await.unwrap();
    assert!(seen[0].starts_with(&format!("DELETE /v1/triggers/{ID} HTTP/1.1")));
    assert!(seen[1].starts_with(&format!("GET /v1/triggers/{ID} HTTP/1.1")));
}

#[tokio::test]
async fn rm_that_still_reads_enabled_is_a_retryable_failure() {
    let (origin, _) = server(vec![(200, json!({"removed": true})), (200, trigger(true))]).await;
    let e = client(&origin).remove(ID).await.unwrap_err();
    let app = crate::cli::errors::classify(&e);
    assert!(app.retryable, "{}", app.message);
}

#[tokio::test]
async fn a_platform_with_triggers_off_names_the_flag() {
    let body = json!({"_tag": "TriggerNotFound", "code": "trigger.not_found", "message": "no such trigger"});
    let (origin, _) = server(vec![(404, body)]).await;
    let e = client(&origin).get(ID).await.unwrap_err();
    let app = crate::cli::errors::classify(&e);
    assert_eq!(app.detail, "trigger.not_found");
    assert!(app.message.contains("CLOUD_TRIGGERS"), "{}", app.message);
    let forbidden = json!({"code": "trigger.forbidden", "message": "an agent cannot register a trigger; a person does"});
    let (origin, _) = server(vec![(403, forbidden)]).await;
    let e = client(&origin).create(&create_body(&args()).unwrap()).await.unwrap_err();
    assert!(crate::cli::errors::classify(&e).message.contains("a person does"));
}

#[test]
fn the_index_keeps_ids_per_origin_and_never_a_secret() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(INDEX_FILE);
    assert!(read_index(&path).is_empty());
    let rows = vec![
        json!({"origin": "https://a.debussy.workers.dev", "id": ID, "repository": "acme/app"}),
        json!({"origin": "https://b.debussy.workers.dev", "id": "other"}),
    ];
    write_index(&path, &rows).unwrap();
    let back = read_index(&path);
    assert_eq!(indexed_ids(&back, "https://a.debussy.workers.dev"), vec![ID.to_owned()]);
    assert!(!std::fs::read_to_string(&path).unwrap().contains("secret"));
}

#[test]
fn a_record_line_names_state_repo_events_and_target() {
    let text = line(&record(&trigger(true)));
    assert!(text.contains(ID) && text.contains(" on ") && text.contains("acme/app"), "{text}");
    assert!(text.contains("ci_failure,pr_comment") && text.contains("m1/fixer (codex)"), "{text}");
}
