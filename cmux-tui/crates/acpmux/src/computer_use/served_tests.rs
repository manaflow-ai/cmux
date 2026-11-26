use super::*;
use serde_json::json;

fn env(session: &str) -> HashMap<String, String> {
    HashMap::from([
        (SESSION_ENV.to_owned(), session.to_owned()),
        (DAEMON_SOCKET_ENV.to_owned(), "/nonexistent/cmux-tui.sock".to_owned()),
    ])
}

#[test]
fn a_codex_client_gets_the_second_choice_tools_and_a_cmux_front_does_not() {
    let served =
        crate::tool_env::sync_scope(env("cu-served-codex"), || served(&Arc::default()).unwrap());
    assert_eq!(served.name, SERVER_NAME);
    let list = served.list.as_ref().unwrap();
    let init = served.on_initialize.as_ref().unwrap();
    let first = |tools: Value| tools[0]["description"].as_str().unwrap().to_owned();
    let codex = json!({"clientInfo": {"name": "codex-mcp-client", "version": "1"}});
    assert_eq!(init(&codex).as_deref(), Some(super::super::mcp::DEFER_INSTRUCTIONS));
    assert!(first(list()).starts_with(super::super::mcp::DEFER_PREFIX));
    // A `cmux` server in front marks them itself: ours stay plain, its client's name labels.
    let front = json!({"clientInfo": {"name": "cmux", "title": "codex-mcp-client"}});
    assert_eq!(init(&front).as_deref(), Some(cmux_computer_use::tools::INSTRUCTIONS));
    assert!(!first(list()).starts_with(super::super::mcp::DEFER_PREFIX));
    end("cu-served-codex");
}

#[test]
fn the_session_state_outlives_a_remade_server_and_goes_when_the_chat_ends() {
    let made =
        || crate::tool_env::sync_scope(env("cu-served-keep"), || served(&Arc::default()).unwrap());
    let first = made();
    (first.on_initialize.as_ref().unwrap())(&json!({"clientInfo": {"name": "codex"}}));
    drop(first);
    // The gateway's idle stop made it again: the client it learned at initialize stays.
    let again = made();
    let tools = (again.list.as_ref().unwrap())();
    assert!(tools[0]["description"].as_str().unwrap().starts_with(super::super::mcp::DEFER_PREFIX));
    assert!(has("cu-served-keep"));
    end("cu-served-keep");
    assert!(!has("cu-served-keep"));
}

#[test]
fn no_session_in_the_env_is_no_server() {
    let made = crate::tool_env::sync_scope(HashMap::new(), || served(&Arc::default()));
    // The daemon's own env may name one (a session's terminal); only an empty one refuses.
    if std::env::var_os(SESSION_ENV).is_none() {
        assert!(made.is_err());
    }
}
