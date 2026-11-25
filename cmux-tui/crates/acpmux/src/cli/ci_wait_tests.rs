use super::*;
use std::sync::{Arc, Mutex};
use tokio::io::{AsyncReadExt as _, AsyncWriteExt as _};

fn run(name: &str, status: &str, conclusion: Option<&str>) -> Value {
    json!({"name": name, "status": status, "conclusion": conclusion})
}

fn open_pull() -> Value {
    json!({"state": "open", "merged": false, "merged_at": null, "head": {"sha": "abc123"}})
}

#[test]
fn a_pull_request_is_green_only_when_every_check_finished_clean() {
    let none = json!({"statuses": []});
    let waited = Duration::from_secs(1);
    let runs = [run("build", "completed", Some("success")), run("lint", "in_progress", None)];
    assert_eq!(pr_state(&open_pull(), &runs, &none, waited), State::Pending { done: 1, total: 2 });
    let runs =
        [run("build", "completed", Some("success")), run("docs", "completed", Some("skipped"))];
    assert!(matches!(pr_state(&open_pull(), &runs, &none, waited), State::Green { .. }));
    let pending_status = json!({"statuses": [{"context": "ci/x", "state": "pending"}]});
    assert!(matches!(
        pr_state(&open_pull(), &runs, &pending_status, waited),
        State::Pending { .. }
    ));
}

#[test]
fn the_first_failing_check_ends_the_wait_red() {
    let none = json!({"statuses": []});
    let runs = [run("build", "completed", Some("failure")), run("slow", "queued", None)];
    assert_eq!(
        pr_state(&open_pull(), &runs, &none, Duration::ZERO),
        State::Red { note: "failing: build".into() }
    );
    let status = json!({"statuses": [{"context": "ci/legacy", "state": "error"}]});
    assert_eq!(
        pr_state(&open_pull(), &[], &status, Duration::ZERO),
        State::Red { note: "failing: ci/legacy".into() }
    );
}

#[test]
fn merged_closed_and_checkless_pull_requests_end_the_wait() {
    let merged = json!({"state": "closed", "merged": true, "head": {"sha": "a"}});
    assert!(matches!(pr_state(&merged, &[], &Value::Null, Duration::ZERO), State::Green { .. }));
    let closed =
        json!({"state": "closed", "merged": false, "merged_at": null, "head": {"sha": "a"}});
    assert!(matches!(pr_state(&closed, &[], &Value::Null, Duration::ZERO), State::Red { .. }));
    let none = json!({"statuses": []});
    assert!(matches!(pr_state(&open_pull(), &[], &none, Duration::ZERO), State::Pending { .. }));
    assert!(matches!(pr_state(&open_pull(), &[], &none, NO_CHECKS_GRACE), State::Green { .. }));
}

#[test]
fn a_workflow_run_is_red_on_a_failing_conclusion() {
    assert!(matches!(run_state(&json!({"status": "in_progress"})), State::Pending { .. }));
    assert!(matches!(
        run_state(&json!({"status": "completed", "conclusion": "success"})),
        State::Green { .. }
    ));
    assert!(matches!(
        run_state(&json!({"status": "completed", "conclusion": "cancelled"})),
        State::Red { .. }
    ));
}

#[test]
fn the_interval_grows_while_nothing_changes_and_resets_on_a_change() {
    let s = Schedule::default();
    let mut i = s.base;
    for _ in 0..20 {
        i = s.next(i, false);
    }
    assert_eq!(i, s.cap);
    assert_eq!(s.next(Duration::from_secs(20), false), Duration::from_secs(30));
    assert_eq!(s.next(s.cap, true), s.base);
}

#[test]
fn a_rate_limit_waits_out_retry_after_or_the_reset() {
    let mut h = reqwest::header::HeaderMap::new();
    h.insert("retry-after", "42".parse().unwrap());
    assert_eq!(throttle(429, &h, 1000), Some(Duration::from_secs(42)));
    let mut h = reqwest::header::HeaderMap::new();
    h.insert("x-ratelimit-remaining", "0".parse().unwrap());
    h.insert("x-ratelimit-reset", "1100".parse().unwrap());
    assert_eq!(throttle(403, &h, 1000), Some(Duration::from_secs(101)));
    assert_eq!(
        throttle(403, &reqwest::header::HeaderMap::new(), 1000),
        Some(Duration::from_secs(60))
    );
    assert_eq!(throttle(200, &reqwest::header::HeaderMap::new(), 1000), None);
}

#[test]
fn origin_urls_name_their_repository() {
    for url in [
        "https://github.com/manaflow-ai/cmux.git",
        "https://github.com/manaflow-ai/cmux",
        "git@github.com:manaflow-ai/cmux.git",
        "ssh://git@github.com/manaflow-ai/cmux.git",
    ] {
        assert_eq!(repo_from_remote(url).as_deref(), Some("manaflow-ai/cmux"), "{url}");
    }
    assert_eq!(repo_from_remote("https://gitlab.com/a/b"), None);
    assert!(valid_repo("a-b/c.d_e"));
    assert!(!valid_repo("a/b/c"));
    assert!(!valid_repo("a/../b"));
}

/// A fake GitHub: answers each path from `bodies`, with `"<path>-etag"` as the ETag, and 304 when
/// the request sends it back. Counts full answers per path.
async fn fake_github(
    bodies: Arc<Mutex<std::collections::HashMap<String, Value>>>,
) -> (String, Arc<Mutex<Vec<(String, u16)>>>) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let log = Arc::new(Mutex::new(Vec::new()));
    let seen = log.clone();
    tokio::spawn(async move {
        loop {
            let Ok((mut stream, _)) = listener.accept().await else { return };
            let mut head = Vec::new();
            let mut buf = [0u8; 2048];
            while !head.windows(4).any(|w| w == b"\r\n\r\n") {
                let n = stream.read(&mut buf).await.unwrap_or(0);
                if n == 0 {
                    break;
                }
                head.extend_from_slice(&buf[..n]);
            }
            let text = String::from_utf8_lossy(&head).to_string();
            let path = text.split_whitespace().nth(1).unwrap_or("").to_owned();
            let body = bodies.lock().unwrap().get(&path).cloned().unwrap_or(Value::Null);
            let etag = format!("\"{:x}\"", Sha256::digest(body.to_string().as_bytes()));
            let matched = text.lines().any(|l| {
                l.to_ascii_lowercase().starts_with("if-none-match:") && l.ends_with(&etag)
            });
            let reply = if matched {
                seen.lock().unwrap().push((path, 304));
                format!(
                    "HTTP/1.1 304 Not Modified\r\netag: {etag}\r\nx-ratelimit-remaining: 4999\r\nconnection: close\r\n\r\n"
                )
            } else {
                seen.lock().unwrap().push((path, 200));
                let b = body.to_string();
                format!(
                    "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\netag: {etag}\r\nx-ratelimit-remaining: 4999\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{b}",
                    b.len()
                )
            };
            let _ = stream.write_all(reply.as_bytes()).await;
        }
    });
    (origin, log)
}

#[tokio::test]
async fn unchanged_reads_are_conditional_and_the_wait_ends_green() {
    let bodies = Arc::new(Mutex::new(std::collections::HashMap::new()));
    let runs_path = "/repos/o/r/commits/abc123/check-runs?per_page=100&page=1".to_owned();
    {
        let mut b = bodies.lock().unwrap();
        b.insert("/repos/o/r/pulls/7".into(), open_pull());
        b.insert(
            runs_path.clone(),
            json!({"total_count": 1, "check_runs": [run("build", "in_progress", None)]}),
        );
        b.insert("/repos/o/r/commits/abc123/status".into(), json!({"statuses": []}));
    }
    let (origin, log) = fake_github(bodies.clone()).await;
    let dir = tempfile::tempdir().unwrap();
    let mut reader = Reader::new(origin, "t".into(), Cache::new(dir.path().into())).unwrap();
    let schedule = Schedule { base: Duration::from_millis(20), cap: Duration::from_millis(40) };
    let finisher = bodies.clone();
    let path = runs_path.clone();
    tokio::spawn(async move {
        tokio::time::sleep(Duration::from_millis(300)).await;
        finisher.lock().unwrap().insert(
            path,
            json!({"total_count": 1, "check_runs": [run("build", "completed", Some("success"))]}),
        );
    });
    let (state, sha) =
        wait(&mut reader, "o/r", Kind::Pr, "7", Duration::from_secs(10), schedule).await.unwrap();
    assert!(matches!(state, State::Green { .. }), "{state:?}");
    assert_eq!(sha.as_deref(), Some("abc123"));
    {
        let log = log.lock().unwrap();
        // Every path's first read is full; every later read of an unchanged path is a free 304.
        let pulls: Vec<u16> =
            log.iter().filter(|(p, _)| p == "/repos/o/r/pulls/7").map(|(_, s)| *s).collect();
        assert!(pulls.len() >= 3, "{log:?}");
        assert_eq!(pulls[0], 200);
        assert!(pulls[1..].iter().all(|s| *s == 304), "{pulls:?}");
        assert_eq!(reader.counts.requests, log.len() as u64);
        let free = log.iter().filter(|(_, s)| *s == 304).count() as u64;
        assert_eq!(reader.counts.not_modified, free);
    }

    // A second wait on the same machine starts from the shared cache: no full read at all.
    let mut second =
        Reader::new(reader.api.clone(), "t".into(), Cache::new(dir.path().into())).unwrap();
    let (state, _) =
        wait(&mut second, "o/r", Kind::Pr, "7", Duration::from_secs(10), schedule).await.unwrap();
    assert!(matches!(state, State::Green { .. }));
    assert_eq!(second.counts.not_modified, second.counts.requests);
}

#[tokio::test]
async fn the_deadline_ends_a_pending_wait_with_a_timeout() {
    let bodies = Arc::new(Mutex::new(std::collections::HashMap::new()));
    bodies.lock().unwrap().insert("/repos/o/r/actions/runs/5".into(), json!({"status": "queued"}));
    let (origin, _log) = fake_github(bodies).await;
    let dir = tempfile::tempdir().unwrap();
    let mut reader = Reader::new(origin, "t".into(), Cache::new(dir.path().into())).unwrap();
    let schedule = Schedule { base: Duration::from_millis(20), cap: Duration::from_millis(40) };
    let error = wait(&mut reader, "o/r", Kind::Run, "5", Duration::from_millis(200), schedule)
        .await
        .unwrap_err();
    let app = error.downcast_ref::<AppError>().expect("a typed error");
    assert_eq!(app.code, Code::Timeout);
}
