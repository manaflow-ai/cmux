use super::*;
use std::fs;
use std::time::Duration;

fn person(id: &str) -> PresencePerson {
    PresencePerson { id: id.into(), name: id.into(), devices: 1, viewing: true, typing: false }
}

#[test]
fn draft_size_refusal_does_not_touch_existing_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("draft");
    fs::write(&path, "old").unwrap();

    let error = write_draft_atomic(&path, &"x".repeat(MAX_DRAFT_BYTES + 1)).unwrap_err();
    assert!(matches!(error, ActError::DraftTooLarge { .. }));
    assert_eq!(error.reason(), Some(TOO_LARGE));
    assert_eq!(fs::read_to_string(&path).unwrap(), "old");
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
}

#[test]
fn draft_commit_renames_one_complete_file() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("draft");
    let commit = write_draft_atomic(&path, "new text").unwrap();
    assert_eq!(commit.path, path);
    assert_eq!(commit.bytes, 8);
    assert_eq!(fs::read_to_string(&path).unwrap(), "new text");
    assert_eq!(fs::read_dir(dir.path()).unwrap().count(), 1);
}

#[test]
fn presence_replacement_is_sorted_and_coalesced_without_history() {
    let first =
        PresenceStateOp::replace("chat", "owner", vec![person("z"), person("owner")]).unwrap();
    let second = PresenceStateOp::replace("chat", "owner", vec![person("a")]).unwrap();
    assert_eq!(first.participants[0].id, "owner");

    let mut queue = PresenceCoalescer::default();
    assert!(!queue.submit(first).unwrap());
    assert!(queue.submit(second.clone()).unwrap());
    assert_eq!(queue.len(), 1);
    assert_eq!(queue.pop().unwrap(), second);
    assert!(queue.pop().is_none());
}

#[test]
fn presence_bounds_people_and_encoded_bytes() {
    let many = (0..=MAX_PRESENCE_PEOPLE).map(|n| person(&n.to_string())).collect();
    assert!(matches!(
        PresenceStateOp::replace("chat", "local", many),
        Err(ActError::PresenceTooManyPeople { .. })
    ));
    let mut exactly_full = vec![person("local")];
    exactly_full.extend((0..MAX_PRESENCE_PEOPLE).map(|n| person(&format!("other-{n}"))));
    assert!(PresenceStateOp::replace("chat", "local", exactly_full).is_ok());

    let mut huge = person("person");
    huge.name = "x".repeat(MAX_PRESENCE_BYTES);
    assert!(matches!(
        PresenceStateOp::replace("chat", "local", vec![huge]),
        Err(ActError::PresenceTooLarge { .. })
    ));
}

#[test]
fn typing_is_rate_limited_per_connection_and_expires() {
    let start = std::time::Instant::now();
    let mut tracker = TypingTracker::default();
    tracker.update("connection", "person", true, start).unwrap();
    tracker.update("connection", "person", false, start + Duration::from_millis(1)).unwrap();
    assert!(matches!(
        tracker.update("connection", "person", true, start + Duration::from_millis(2)),
        Err(TypingRateLimited { .. })
    ));
    assert!(!tracker.is_typing("connection", "person", start + TYPING_EXPIRY));

    tracker.update("other", "person", true, start).unwrap();
    assert!(tracker.is_typing("other", "person", start + Duration::from_secs(1)));
}
