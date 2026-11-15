//! What the log keeps of Claude's raw system/init lines (`logged_init.rs`).

use super::*;

/// `leave_out_repeats`, then the write succeeds.
fn log(logged: &mut LoggedInit, kind: &str, line: &mut Value) {
    let sections = logged.leave_out_repeats(kind, line);
    logged.note_logged(sections);
}

fn init(uuid: &str, commands: &[&str]) -> Value {
    json!({"type": "system", "subtype": "init", "session_id": "cc-1", "uuid": uuid,
        "model": "claude-opus-5-5", "cwd": "/w", "tools": ["Bash", "Read"],
        "mcp_servers": [{"name": "cmux", "status": "connected"}],
        "slash_commands": commands, "user_message_uuids": [uuid]})
}

/// The first init is logged whole; the next one keeps its scalars and the sections that changed
/// (`user_message_uuids`), and names the ones it left out.
#[test]
fn a_repeated_init_keeps_only_what_changed() {
    let mut logged = LoggedInit::default();
    let mut first = init("u1", &["compact", "review"]);
    log(&mut logged, "claude.system.init", &mut first);
    assert_eq!(first, init("u1", &["compact", "review"]));

    let mut second = init("u2", &["compact", "review"]);
    log(&mut logged, "claude.system.init", &mut second);
    assert_eq!(
        second,
        json!({"type": "system", "subtype": "init", "session_id": "cc-1", "uuid": "u2",
            "model": "claude-opus-5-5", "cwd": "/w", "user_message_uuids": ["u2"],
            "_acpmux": {"sameAsLastInit": ["mcp_servers", "slash_commands", "tools"]}})
    );

    // A new slash command logs that section whole again, and only it.
    let mut third = init("u3", &["compact", "review", "loop"]);
    log(&mut logged, "claude.system.init", &mut third);
    assert_eq!(third["slash_commands"], json!(["compact", "review", "loop"]));
    assert_eq!(third["_acpmux"]["sameAsLastInit"], json!(["mcp_servers", "tools"]));
}

/// Another kind, and another session's first init, are left whole.
#[test]
fn other_kinds_and_sessions_are_untouched() {
    let mut logged = LoggedInit::default();
    let mut user = json!({"type": "user", "tools": ["Bash"]});
    log(&mut logged, "claude.user", &mut user);
    log(&mut logged, "claude.user", &mut user);
    assert_eq!(user, json!({"type": "user", "tools": ["Bash"]}));

    let mut a = LoggedInit::default();
    let mut line = init("u1", &["compact"]);
    log(&mut logged, "claude.system.init", &mut init("u0", &["compact"]));
    log(&mut a, "claude.system.init", &mut line);
    assert_eq!(line, init("u1", &["compact"]));
}

/// The bytes a chat's log takes for a day of one session's inits (Leo's Mac, 2026-11-08: 1,256
/// inits a day across sessions, ~79 KB each): the harness the PR's before and after numbers
/// come from.
#[test]
fn a_day_of_repeated_inits_logs_the_sections_once() {
    let commands: Vec<String> = (0..1200).map(|i| format!("plugin-{i:04}:command-name")).collect();
    let refs: Vec<&str> = commands.iter().map(String::as_str).collect();
    let mut logged = LoggedInit::default();
    let (mut before, mut after) = (0usize, 0usize);
    for turn in 0..100 {
        let mut line = init(&format!("u{turn}"), &refs);
        before += serde_json::to_vec(&line).unwrap().len();
        log(&mut logged, "claude.system.init", &mut line);
        after += serde_json::to_vec(&line).unwrap().len();
    }
    eprintln!("100 inits: {before} bytes before, {after} after");
    assert!(after * 20 < before, "100 inits: {before} bytes before, {after} after");
}

/// An init whose write failed leaves nothing recorded: its retry is logged whole (review F1 on
/// #39147).
#[test]
fn a_failed_init_write_is_logged_whole_on_retry() {
    let mut logged = LoggedInit::default();
    drop(logged.leave_out_repeats("claude.system.init", &mut init("u1", &["compact"])));
    let mut retry = init("u1", &["compact"]);
    log(&mut logged, "claude.system.init", &mut retry);
    assert_eq!(retry, init("u1", &["compact"]));
}
