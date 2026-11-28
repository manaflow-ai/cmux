//! The optional Chief coordinator contact is persisted and validated without
//! changing the default prompt or allowing ambiguous acpmux session ids.

mod common;

use optchat_chief::chief_settings::{CONTACT, ChiefSettings, parse_contact};
use serde_json::Value;

#[test]
fn contact_is_unset_by_default_and_round_trips() {
    assert_eq!(ChiefSettings::default().contact, None);
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("settings.json");
    std::fs::write(&file, r#"{"contact":"test-host/coordinator"}"#).unwrap();
    let settings = ChiefSettings::load(&file);
    assert_eq!(settings.contact.as_deref(), Some("test-host/coordinator"));
    settings.save(&file).unwrap();
    let saved: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert_eq!(saved[CONTACT], "test-host/coordinator");

    let mut cleared = settings;
    cleared.contact = parse_contact("").unwrap();
    cleared.save(&file).unwrap();
    let saved: Value = serde_json::from_str(&std::fs::read_to_string(&file).unwrap()).unwrap();
    assert!(
        saved.get(CONTACT).is_none(),
        "clearing omits the contact: {saved}"
    );
}

#[test]
fn contact_rejects_ambiguous_session_ids() {
    for invalid in [
        "",
        "invalid-host",
        "/session",
        "host/",
        "host/a/b",
        "host/a b",
    ] {
        if invalid.is_empty() {
            assert_eq!(parse_contact(invalid).unwrap(), None);
        } else {
            assert!(parse_contact(invalid).is_err(), "accepted {invalid:?}");
        }
    }
    assert_eq!(
        parse_contact(" test-host/coordinator ").unwrap().as_deref(),
        Some("test-host/coordinator")
    );
}

#[test]
fn the_running_brain_saves_and_clears_contact_and_refuses_invalid_updates() {
    let mut h = common::Harness::new(common::default_script());
    let file = h.dir.path().join("settings.json");
    let answer = h
        .brain
        .set_setting(CONTACT, "test-host/coordinator")
        .unwrap();
    assert!(answer.contains("applies after host restart"));
    assert_eq!(
        ChiefSettings::load(&file).contact.as_deref(),
        Some("test-host/coordinator")
    );
    assert!(h.brain.set_setting(CONTACT, "host/a/b").is_err());
    assert_eq!(
        ChiefSettings::load(&file).contact.as_deref(),
        Some("test-host/coordinator")
    );
    // Updating an existing setting must preserve the new String field too.
    h.brain.set_setting("replies.thread", "always").unwrap();
    assert_eq!(
        ChiefSettings::load(&file).contact.as_deref(),
        Some("test-host/coordinator")
    );
    h.brain.set_setting(CONTACT, "").unwrap();
    assert_eq!(ChiefSettings::load(&file).contact, None);
}
