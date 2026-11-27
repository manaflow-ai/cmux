//! Share Screen with Chief (docs/chief-screen-share.md): what the app wrote
//! into the screen inbox while the person shared their screen joins the
//! Chief's log as one note when the next turn starts, so that turn sees it,
//! and the inbox is emptied while the frames stay. A screen entry alone
//! never starts a turn.

mod common;

use common::*;

fn write_entry(h: &Harness, name: &str, time: &str, text: &str) {
    let inbox = h.dir.path().join("screen/inbox");
    std::fs::create_dir_all(&inbox).unwrap();
    std::fs::write(
        inbox.join(name),
        format!(
            r#"{{"at":"2026-10-30T17:40:00Z","day":"2026-10-30","time":"{time}","app":"Xcode","window":"cmux — Build Failed","text":"{text}","frame":"/frames/{name}.jpg"}}"#
        ),
    )
    .unwrap();
}

#[test]
fn the_next_turn_sees_what_the_shared_screen_showed() {
    let mut h = Harness::new(default_script());
    write_entry(
        &h,
        "1793382001000.json",
        "17:40:01",
        "Build Failed: 2 errors",
    );
    write_entry(&h, "1793382125000.json", "17:42:05", "Build Succeeded");
    h.connect();
    h.say("user_local", "did my build pass?");
    h.settle_posts();

    let notes: Vec<String> = h
        .log()
        .into_iter()
        .filter(|(kind, text)| kind == "note" && text.starts_with("screen share "))
        .map(|(_, text)| text)
        .collect();
    assert_eq!(notes.len(), 1, "{:#?}", h.log());
    assert!(notes[0].contains("2 changed frames"), "{}", notes[0]);
    assert!(notes[0].contains("17:40 Xcode — \"cmux — Build Failed\": Build Failed: 2 errors [/frames/1793382001000.json.jpg]"));
    assert!(notes[0].contains("17:42 Xcode — \"cmux — Build Failed\": Build Succeeded"));

    let prompts = h.agents.inner.lock().unwrap().prompts.clone();
    assert!(
        prompts.iter().any(|p| serde_json::to_string(p)
            .unwrap()
            .contains("Build Succeeded")),
        "the turn's prompt carries the note"
    );
    let left = std::fs::read_dir(h.dir.path().join("screen/inbox"))
        .unwrap()
        .count();
    assert_eq!(left, 0, "the inbox is emptied");
}

#[test]
fn screen_entries_alone_never_start_a_turn() {
    let mut h = Harness::new(default_script());
    h.connect();
    h.settle_posts();
    write_entry(&h, "1793382001000.json", "17:40:01", "a quiet screen");
    h.settle_posts();
    assert!(h.agents.inner.lock().unwrap().prompts.is_empty());
    assert!(
        h.log()
            .iter()
            .all(|(_, text)| !text.starts_with("screen share "))
    );
    let left = std::fs::read_dir(h.dir.path().join("screen/inbox"))
        .unwrap()
        .count();
    assert_eq!(left, 1, "the entry waits for the next turn");
}
