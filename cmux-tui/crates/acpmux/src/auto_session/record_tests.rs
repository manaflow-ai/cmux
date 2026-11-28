use super::*;

#[test]
fn the_row_carries_what_the_pane_decodes() {
    let mut record = AutoRecord::on();
    record.here = true;
    let held = json!({
        "auto": true, "mode": "auto", "state": "local", "here": true, "keepInCloud": false,
    });
    assert_eq!(record.row(), held);
    record.here = false;
    record.state = State::ComingBack;
    record.blocked = Some(Blocked::NoMachine);
    record.leftover = Some(Leftover {
        files: vec!["a.rs".into(), "b/c.rs".into()],
        at: 1,
        path: "/x/auto-leftover.patch".into(),
        top: "/x".into(),
    });
    assert_eq!(
        record.row(),
        json!({
            "auto": true, "mode": "auto", "state": "coming_back", "here": false,
            "keepInCloud": false, "blocked": "no_machine", "leftover": { "files": 2 },
        })
    );
}

#[test]
fn the_row_says_the_mode_and_where_the_chat_is_moving() {
    let mut record = AutoRecord::on();
    assert_eq!(record.row()["mode"], "auto");
    assert_eq!(record.row().get("moving"), None, "absent when the chat is not moving");
    record.keep_in_cloud = true;
    record.moving = Some(MoveTo::Cloud);
    assert_eq!((record.mode(), Mode::parse("cloud")), (Mode::Cloud, Some(Mode::Cloud)));
    assert_eq!(record.row()["mode"], "cloud");
    assert_eq!(record.row()["moving"], "cloud");
    record.moving = Some(MoveTo::Local);
    assert_eq!(record.row()["moving"], "local");
    // Auto off: the chat runs here, whatever the record last held.
    record.auto = false;
    assert_eq!(record.row()["mode"], "local");
    assert_eq!(record.row().get("moving"), None);
    assert_eq!(Mode::parse("hybrid"), None);
    // Set to this machine only while the Cloud has it: local at once, on its way home.
    let mut leaving = AutoRecord::on();
    leaving.local_wanted = true;
    leaving.moving = Some(MoveTo::Local);
    assert_eq!(leaving.row()["mode"], "local");
    assert_eq!(leaving.row()["auto"], true);
    assert_eq!(leaving.row()["moving"], "local");
}

#[test]
fn a_record_from_an_older_build_reads_with_defaults() {
    let record: AutoRecord = serde_json::from_value(json!({ "auto": true })).unwrap();
    assert_eq!(record, AutoRecord::on());
    assert!(!record.spent());
    let off: AutoRecord = serde_json::from_value(json!({ "auto": false })).unwrap();
    assert!(off.spent());
}

#[test]
fn a_chat_with_auto_off_reads_as_running_here() {
    let off = json!({
        "auto": false, "mode": "local", "state": "local", "here": true, "keepInCloud": false,
    });
    assert_eq!(AutoRecord::row_of(None), off);
    let mut was_away = AutoRecord::on();
    was_away.auto = false;
    was_away.state = State::Cloud;
    was_away.keep_in_cloud = true;
    assert_eq!(AutoRecord::row_of(Some(&was_away)), off);
}
