//! A machine joined before the hub recorded capabilities states them itself, at daemon start.
//! A machine joined by a pair code or a join line has no person's token, so the sign-in rotate
//! (`enroll.rs`, `rotate_once`) never reaches it: it sends this acpmux's list
//! ([`machine_capabilities`]) with its own credential to
//! `PUT /v1/machines/credentials/self/capabilities`, and its record keeps the hub's answer, so it
//! never asks again.
//!
//! - Only a record with no list asks: one a redeem or a rotate wrote never does.
//! - 409 `machine.capabilities_widen`: the hub holds a narrower list a person set. It is left as
//!   it is and recorded so (an empty list), never sent again.
//! - 401 `machine.revoked`: the record is marked revoked, as a sign-in's check marks it.
//! - No answer, or a retryable refusal (503 `machine.join.unavailable`): tried again in the
//!   background, at most [`BACKOFF`]`.len() + 1` times over about an hour, then not until the
//!   next start. The daemon's start and its relay never wait for it.
//! - Any other refusal: nothing is recorded; the next start asks once more.
use super::*;
use std::path::Path;
use std::time::Duration;

/// The waits between tries: five tries over about an hour (0, 2, 7, 22 and 62 minutes).
pub(crate) const BACKOFF: [Duration; 4] = [
    Duration::from_secs(2 * 60),
    Duration::from_secs(5 * 60),
    Duration::from_secs(15 * 60),
    Duration::from_secs(40 * 60),
];

/// What a start's statement did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Stated {
    /// No call: not joined, a copy of another box's join, revoked, a list already recorded, or a
    /// sign-out's leave pending.
    NotNeeded,
    /// The hub recorded this list, and the record keeps it.
    Recorded(Vec<String>),
    /// 409: the hub keeps the narrower list a person set; recorded as an empty list.
    LeftAlone,
    /// 401 `machine.revoked`: the record is marked revoked.
    Revoked,
    /// Refused for good (an unknown credential, an unknown capability): nothing recorded.
    Refused,
    /// The record changed while the hub answered (a sign-in rotated it, a leave removed it), or
    /// the join lock stayed held: nothing recorded here.
    Unsaved,
    /// Every try went unanswered: nothing recorded; the next start tries again.
    GaveUp,
}

/// The hub's answer to one try.
enum Answer {
    Set(Vec<String>),
    Widen,
    Revoked,
    Refused(String),
    Unavailable(String),
}

/// At daemon start, after its relay: states this machine's capabilities in the background when
/// its record has none.
pub(crate) fn state_at_start() {
    // task-owner: at most `BACKOFF.len() + 1` hub requests (each with the join client's 10 s
    // deadline) and `BACKOFF`'s waits, about an hour in all; ends with them or the daemon.
    tokio::spawn(async {
        let home = state_dir();
        let current = host_fingerprint::current();
        let stated = state_at(&home, current.as_deref(), &BACKOFF).await;
        if stated != Stated::NotNeeded {
            tracing::info!(?stated, "machine capabilities at start");
        }
    });
}

/// The record in `home` that has no list yet and may ask with its own credential.
fn legacy_record(home: &Path, current: Option<&str>) -> Option<MachineCredential> {
    if std::fs::symlink_metadata(home.join(enroll::LEAVE_FILE)).is_ok() {
        return None;
    }
    load_at(home).ok().flatten().filter(|record| {
        record.capabilities.is_none()
            && !record.revoked
            && record.credential.starts_with("cmm_")
            && !copied_here(home, record, current)
    })
}

/// States this acpmux's list for the record in `home` (the box whose fingerprint is `current`),
/// trying again after each of `backoff`'s waits while the hub does not answer.
pub(crate) async fn state_at(home: &Path, current: Option<&str>, backoff: &[Duration]) -> Stated {
    let sent = machine_capabilities();
    let mut waits = backoff.iter();
    loop {
        // Read again before each try: a sign-in may have rotated it meanwhile.
        let Some(record) = legacy_record(home, current) else { return Stated::NotNeeded };
        match ask(&record, &sent).await {
            Answer::Set(list) => {
                return save_if_unchanged(home, &record, |r| r.capabilities = Some(list.clone()))
                    .await
                    .map_or(Stated::Unsaved, |()| Stated::Recorded(list));
            }
            Answer::Widen => {
                return save_if_unchanged(home, &record, |r| r.capabilities = Some(Vec::new()))
                    .await
                    .map_or(Stated::Unsaved, |()| Stated::LeftAlone);
            }
            Answer::Revoked => {
                return save_if_unchanged(home, &record, |r| r.revoked = true)
                    .await
                    .map_or(Stated::Unsaved, |()| Stated::Revoked);
            }
            Answer::Refused(why) => {
                tracing::warn!("machine capabilities: the hub refused: {why}");
                return Stated::Refused;
            }
            Answer::Unavailable(why) => {
                let Some(wait) = waits.next() else {
                    tracing::warn!("machine capabilities: no answer, until the next start: {why}");
                    return Stated::GaveUp;
                };
                tracing::debug!("machine capabilities: no answer, trying again: {why}");
                tokio::time::sleep(*wait).await;
            }
        }
    }
}

/// One `PUT /v1/machines/credentials/self/capabilities` with the record's own credential.
async fn ask(record: &MachineCredential, sent: &[String]) -> Answer {
    let client = match origin(Some(record.hub_origin.clone()))
        .and_then(|hub| hub_client(&hub, Some(&record.credential)))
    {
        Ok(client) => client,
        Err(e) => return Answer::Refused(format!("{e:#}")),
    };
    let body: cmux_cloud_client::types::MachineSelfCapabilities =
        match serde_json::from_value(json!({"capabilities": sent})) {
            Ok(body) => body,
            Err(e) => return Answer::Refused(e.to_string()),
        };
    let answer = match client.machine_redeem_self_capabilities(&body).await {
        Ok(answer) => serde_json::to_value(answer.into_inner()).unwrap_or_default(),
        Err(error) => {
            let error = cmux_cloud_client::ApiError::from_api(error).await;
            // Status and code only: a message may repeat what was sent.
            let why = format!("{:?} {}", error.status, error.code.as_deref().unwrap_or_default());
            return match (error.status, error.code.as_deref()) {
                (Some(409), Some("machine.capabilities_widen")) => Answer::Widen,
                (Some(401), Some("machine.revoked")) => Answer::Revoked,
                _ if error.retryable => Answer::Unavailable(why),
                _ => Answer::Refused(why),
            };
        }
    };
    if answer.get("machineId").and_then(Value::as_str) != Some(record.machine_id.as_str()) {
        return Answer::Refused("the hub answered for another machine".to_owned());
    }
    let Some(list) = answer.get("capabilities").and_then(Value::as_array) else {
        return Answer::Refused("the hub answered with no list".to_owned());
    };
    Answer::Set(list.iter().filter_map(Value::as_str).filter_map(safe_id).collect())
}

/// Saves `edit` of the record in `home` only when it is still the one that asked: the same
/// credential, still with no list and not revoked.
async fn save_if_unchanged(
    home: &Path,
    asked: &MachineCredential,
    edit: impl FnOnce(&mut MachineCredential),
) -> Result<()> {
    let _lock = enroll::wait_for_lock(home)
        .await
        .ok_or_else(|| anyhow!("another machine join is in progress"))?;
    let mut record = load_at(home)?.ok_or_else(|| anyhow!("the join was removed"))?;
    anyhow::ensure!(
        record.credential == asked.credential && record.capabilities.is_none() && !record.revoked,
        "the record changed"
    );
    edit(&mut record);
    save_at(home, &record).inspect_err(|e| tracing::warn!("machine capabilities: not saved: {e:#}"))
}

#[cfg(all(test, unix))]
mod tests {
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
        let (hub, seen, server) =
            fake_hub(vec![down.clone(), down, set(json!(["vault.proxy.v1"]))]);
        joined(home.path(), &hub, |_| {});
        let stated = state_at(home.path(), None, &NO_WAIT).await;
        assert_eq!(stated, Stated::Recorded(vec!["vault.proxy.v1".to_owned()]));
        server.join().unwrap();
        assert_eq!(seen.lock().unwrap().len(), 3);
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
        let (hub, seen, server) =
            fake_hub(vec![refusal(401, "JoinUnauthorized", "machine.unknown")]);
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
}
