//! `self_capabilities.rs`'s tests.
use super::*;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::sync::{Arc, Mutex};

const CREDENTIAL: &str = "cmm_self_capabilities_test";
const ROUTE: &str = "PUT /v1/machines/credentials/self/capabilities ";

/// One request the fake hub took: its request line, bearer and body.
type Seen = Arc<Mutex<Vec<(String, String, Value)>>>;

/// A hub on loopback that answers each request with the next of `answers`, then closes.
fn fake_hub(answers: Vec<(u16, Value)>) -> (String, Seen, std::thread::JoinHandle<()>) {
    fake_hub_gated(answers, None)
}

/// A request's arrival, told to the test, and its answer, held until the test releases it.
type Gate = (std::sync::mpsc::Sender<()>, std::sync::mpsc::Receiver<()>);

/// [`fake_hub`], each answer held at `gate` when given.
fn fake_hub_gated(
    answers: Vec<(u16, Value)>,
    gate: Option<Gate>,
) -> (String, Seen, std::thread::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    let origin = format!("http://{}", listener.local_addr().unwrap());
    let seen: Seen = Arc::default();
    let log = Arc::clone(&seen);
    let thread = std::thread::spawn(move || {
        for (status, body) in answers {
            let (mut socket, _) = listener.accept().unwrap();
            socket.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
            let mut reader = BufReader::new(socket.try_clone().unwrap());
            let mut request = String::new();
            reader.read_line(&mut request).unwrap();
            let (mut length, mut bearer) = (0usize, String::new());
            loop {
                let mut line = String::new();
                assert!(reader.read_line(&mut line).unwrap() > 0, "truncated headers");
                if line == "\r\n" {
                    break;
                }
                if let Some((key, value)) = line.split_once(':') {
                    if key.eq_ignore_ascii_case("content-length") {
                        length = value.trim().parse().unwrap();
                    }
                    if key.eq_ignore_ascii_case("authorization") {
                        bearer = value.trim().to_owned();
                    }
                }
            }
            let mut bytes = vec![0; length];
            reader.read_exact(&mut bytes).unwrap();
            let sent = serde_json::from_slice(&bytes).unwrap_or(Value::Null);
            log.lock().unwrap().push((request, bearer, sent));
            if let Some((arrived, release)) = &gate {
                arrived.send(()).unwrap();
                release
                    .recv_timeout(std::time::Duration::from_secs(60))
                    .expect("the test released the held answer");
            }
            let text = body.to_string();
            write!(socket, "HTTP/1.1 {status} answer\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{text}", text.len()).unwrap();
        }
    });
    (origin, seen, thread)
}

fn joined(home: &Path, hub: &str, edit: impl FnOnce(&mut MachineCredential)) {
    let mut record = MachineCredential {
        credential: CREDENTIAL.into(),
        machine_id: "machine_1".into(),
        team_id: "team_1".into(),
        name: "box".into(),
        hub_origin: hub.into(),
        credential_generation: 1,
        ..Default::default()
    };
    edit(&mut record);
    save_at(home, &record).unwrap();
}

fn record(home: &Path) -> MachineCredential {
    load_at(home).unwrap().unwrap()
}

fn set(capabilities: Value) -> (u16, Value) {
    let body = json!({"machineId":"machine_1","teamId":"team_1","capabilities":capabilities,"changed":true});
    (200, body)
}

fn refusal(status: u16, tag: &str, code: &str) -> (u16, Value) {
    (status, json!({"_tag": tag, "code": code, "message": "refused"}))
}

const NO_WAIT: [Duration; 4] = [Duration::ZERO; 4];

#[tokio::test]
async fn a_legacy_record_states_its_list_once_and_keeps_the_answer() {
    let home = tempfile::tempdir().unwrap();
    let (hub, seen, server) = fake_hub(vec![set(json!(["vault.proxy.v1"]))]);
    joined(home.path(), &hub, |_| {});
    let stated = state_at(home.path(), None, &NO_WAIT).await;
    assert_eq!(stated, Stated::Recorded(vec!["vault.proxy.v1".to_owned()]));
    server.join().unwrap();
    let seen = seen.lock().unwrap().clone();
    assert_eq!(seen.len(), 1);
    assert!(seen[0].0.starts_with(ROUTE), "{}", seen[0].0);
    assert_eq!(seen[0].1, format!("Bearer {CREDENTIAL}"), "its own credential");
    assert_eq!(seen[0].2, json!({"capabilities": machine_capabilities()}));
    let saved = record(home.path());
    assert_eq!(saved.capabilities, Some(vec!["vault.proxy.v1".to_owned()]));
    assert_eq!(saved.credential, CREDENTIAL, "only the list changes");
    // The next start finds the list and asks nothing (the hub is gone: a call would fail).
    assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::NotNeeded);
}

#[tokio::test]
async fn a_record_that_has_a_list_never_asks() {
    for list in [vec!["vault.proxy.v1".to_owned()], Vec::new()] {
        let home = tempfile::tempdir().unwrap();
        // Nothing listens here: a call would be a failed try, not NotNeeded.
        joined(home.path(), "http://127.0.0.1:9", |r| r.capabilities = Some(list.clone()));
        assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::NotNeeded);
        assert_eq!(record(home.path()).capabilities, Some(list));
    }
    // Nor does a revoked record, a copy of another box's join, or no join at all.
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), "http://127.0.0.1:9", |r| r.revoked = true);
    assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::NotNeeded);
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), "http://127.0.0.1:9", |r| r.cloned = true);
    assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::NotNeeded);
    let home = tempfile::tempdir().unwrap();
    assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::NotNeeded);
}

#[tokio::test]
async fn a_narrower_list_a_person_set_is_left_alone_and_never_sent_again() {
    let home = tempfile::tempdir().unwrap();
    let (hub, seen, server) =
        fake_hub(vec![refusal(409, "JoinConflict", "machine.capabilities_widen")]);
    joined(home.path(), &hub, |_| {});
    assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::LeftAlone);
    server.join().unwrap();
    assert_eq!(seen.lock().unwrap().len(), 1, "no retry");
    assert_eq!(record(home.path()).capabilities, Some(Vec::new()));
    assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::NotNeeded);
}

#[tokio::test]
async fn an_unavailable_hub_is_tried_a_bounded_number_of_times() {
    let home = tempfile::tempdir().unwrap();
    let down = refusal(503, "JoinUnavailable", "machine.join.unavailable");
    let (hub, seen, server) = fake_hub(vec![down.clone(); NO_WAIT.len() + 1]);
    joined(home.path(), &hub, |_| {});
    assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::GaveUp);
    server.join().unwrap();
    assert_eq!(seen.lock().unwrap().len(), BACKOFF.len() + 1);
    assert_eq!(record(home.path()).capabilities, None, "the next start tries again");
    // An answer after a few unanswered tries is kept.
    let home = tempfile::tempdir().unwrap();
    let (hub, seen, server) = fake_hub(vec![down.clone(), down, set(json!(["vault.proxy.v1"]))]);
    joined(home.path(), &hub, |_| {});
    let stated = state_at(home.path(), None, &NO_WAIT).await;
    assert_eq!(stated, Stated::Recorded(vec!["vault.proxy.v1".to_owned()]));
    server.join().unwrap();
    assert_eq!(seen.lock().unwrap().len(), 3);
}

fn trigger() -> &'static Trigger {
    Box::leak(Box::new(Trigger::new()))
}

/// The tests' owner: the runtime ends what is left of it with the test.
fn test_scope() -> &'static cmux_scope::Scope {
    Box::leak(Box::new(cmux_scope::Scope::new("machine capabilities test")))
}

#[tokio::test]
async fn a_pending_leave_puts_the_statement_off_without_settling_it() {
    let home = tempfile::tempdir().unwrap();
    let (hub, seen, server) = fake_hub(vec![set(json!(["vault.proxy.v1"]))]);
    joined(home.path(), &hub, |_| {});
    recovery::write_durable(&home.path().join(enroll::LEAVE_FILE), b"{}", true).unwrap();
    let trigger = trigger();
    let fire = || trigger.fire(test_scope(), "test", home.path().to_owned(), None, &NO_WAIT);
    // The start's statement runs while its leave is still pending: put off, no call.
    assert_eq!(fire().unwrap().await.unwrap(), Stated::Deferred);
    assert!(seen.lock().unwrap().is_empty());
    // The leave keeps the join (a join line's machine): the next trigger states the list.
    std::fs::remove_file(home.path().join(enroll::LEAVE_FILE)).unwrap();
    let stated = fire().expect("not settled by the put-off statement").await.unwrap();
    assert_eq!(stated, Stated::Recorded(vec!["vault.proxy.v1".to_owned()]));
    server.join().unwrap();
    assert!(fire().is_none(), "settled once saved");
}

#[tokio::test]
async fn a_reconnect_states_once_never_two_at_a_time_and_never_after_saving() {
    let home = tempfile::tempdir().unwrap();
    let (arrived_tx, arrived) = std::sync::mpsc::channel();
    let (release, release_rx) = std::sync::mpsc::channel();
    let (hub, seen, server) =
        fake_hub_gated(vec![set(json!(["vault.proxy.v1"]))], Some((arrived_tx, release_rx)));
    joined(home.path(), &hub, |_| {});
    let trigger = trigger();
    let fire = || trigger.fire(test_scope(), "test", home.path().to_owned(), None, &NO_WAIT);
    // A reconnect with no list recorded states it.
    let first = fire().expect("a reconnect with no list starts a statement");
    let arrived = tokio::task::spawn_blocking(move || {
        arrived.recv_timeout(std::time::Duration::from_secs(60))
    })
    .await
    .unwrap();
    arrived.expect("the statement reached the hub");
    // Its answer is held: another reconnect (or the start) meanwhile starts none.
    assert!(fire().is_none(), "one statement at a time");
    release.send(()).unwrap();
    assert_eq!(first.await.unwrap(), Stated::Recorded(vec!["vault.proxy.v1".to_owned()]));
    server.join().unwrap();
    // Saved: no later reconnect starts one.
    assert!(fire().is_none(), "settled once saved");
    assert_eq!(seen.lock().unwrap().len(), 1);
    // Nor does the next daemon's (a fresh trigger): the record has its list.
    let next = trigger.fire(test_scope(), "test", home.path().to_owned(), None, &NO_WAIT);
    assert!(next.is_none());
    let next = super::Trigger::new();
    let next: &'static Trigger = Box::leak(Box::new(next));
    let stated = next
        .fire(test_scope(), "test", home.path().to_owned(), None, &NO_WAIT)
        .unwrap()
        .await
        .unwrap();
    assert_eq!(stated, Stated::NotNeeded);
}

#[tokio::test]
async fn an_unanswered_statement_leaves_the_next_reconnect_free_to_try() {
    let home = tempfile::tempdir().unwrap();
    let down = refusal(503, "JoinUnavailable", "machine.join.unavailable");
    let (hub, seen, server) = fake_hub(vec![down; NO_WAIT.len() + 1]);
    joined(home.path(), &hub, |_| {});
    let trigger = trigger();
    let task = trigger.fire(test_scope(), "test", home.path().to_owned(), None, &NO_WAIT).unwrap();
    assert_eq!(task.await.unwrap(), Stated::GaveUp);
    server.join().unwrap();
    assert_eq!(seen.lock().unwrap().len(), NO_WAIT.len() + 1, "the same bounded budget");
    // Not settled: the next reconnect may try (nothing listens now: one more budget).
    assert!(trigger.fire(test_scope(), "test", home.path().to_owned(), None, &NO_WAIT).is_some());
}

#[tokio::test]
async fn an_empty_list_after_a_409_is_only_what_the_hub_holds() {
    let home = tempfile::tempdir().unwrap();
    let (hub, _, server) =
        fake_hub(vec![refusal(409, "JoinConflict", "machine.capabilities_widen")]);
    joined(home.path(), &hub, |_| {});
    assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::LeftAlone);
    server.join().unwrap();
    assert_eq!(record(home.path()).capabilities, Some(Vec::new()));
    // The build decides what runs and what is sent: the vault's egress proxy, and the list.
    const { assert!(RUNS_EGRESS_PROXY) };
    assert_eq!(machine_capabilities(), vec![VAULT_PROXY_CAPABILITY.to_owned()]);
}

#[test]
fn the_backoff_spans_about_an_hour() {
    let total: Duration = BACKOFF.iter().sum();
    assert_eq!(BACKOFF.len() + 1, 5, "five tries");
    assert!(total >= Duration::from_secs(50 * 60) && total <= Duration::from_secs(70 * 60));
}

#[tokio::test]
async fn a_revoked_credential_is_marked_revoked_and_an_unknown_one_is_left_as_it_is() {
    let home = tempfile::tempdir().unwrap();
    let (hub, _, server) = fake_hub(vec![refusal(401, "JoinUnauthorized", "machine.revoked")]);
    joined(home.path(), &hub, |_| {});
    assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::Revoked);
    server.join().unwrap();
    let saved = record(home.path());
    assert!(saved.revoked && saved.capabilities.is_none());
    let home = tempfile::tempdir().unwrap();
    let (hub, seen, server) = fake_hub(vec![refusal(401, "JoinUnauthorized", "machine.unknown")]);
    joined(home.path(), &hub, |_| {});
    assert_eq!(state_at(home.path(), None, &NO_WAIT).await, Stated::Refused);
    server.join().unwrap();
    assert_eq!(seen.lock().unwrap().len(), 1, "no retry");
    let saved = record(home.path());
    assert!(!saved.revoked && saved.capabilities.is_none());
}

#[tokio::test]
async fn a_record_rotated_while_the_hub_answered_keeps_the_rotation() {
    let home = tempfile::tempdir().unwrap();
    joined(home.path(), "http://127.0.0.1:9", |_| {});
    let asked = record(home.path());
    // A sign-in rotated it meanwhile: a new credential and its own list.
    joined(home.path(), "http://127.0.0.1:9", |r| {
        r.credential = "cmm_rotated".into();
        r.capabilities = Some(Vec::new());
    });
    assert!(save_if_unchanged(home.path(), &asked, |r| r.revoked = true).await.is_err());
    let saved = record(home.path());
    assert_eq!((saved.credential.as_str(), saved.revoked), ("cmm_rotated", false));
}
