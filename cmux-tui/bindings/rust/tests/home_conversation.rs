//! Home on the typed SDK: `Session::ensure_home`, the `conversation-tabs-v1`
//! declaration, `TabContentKind::Conversation`, and the typed results of the
//! raw `conversation-*` and `new-conversation-tab` commands. Each wire test
//! runs the SDK against a one-connection mock daemon and checks the exact
//! request and the typed result; the decode tests use the shapes of
//! spec/commands.md (`tests/home_conversation_live.rs` checks them against a
//! real daemon).

use cmux::raw::{
    ConversationChange, ConversationCreateResult, ConversationListResult, ConversationOpResult,
    ConversationPart, ConversationReactionKind, ConversationSnapshotResult, ConversationTapback,
    NewConversationTabResult,
};
use cmux::{
    CONVERSATION_TABS_CAPABILITY, Config, Error, MutationOptions, Selector, SessionId,
    TabContentId, TabContentKind, TabSnapshot, WorkspaceId,
};
use serde_json::{Map, Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread;
use std::time::Duration;

const SESSION: &str = "session_00000000000000000000000000000002";
const WORKSPACE: &str = "ws_00000000000000000000000000000003";
const PANE: &str = "pane_00000000000000000000000000000006";
const TAB: &str = "tab_00000000000000000000000000000007";
const BROWSER: &str = "browser_0000000000000000000000000000000d";
const CLIENT: &str = "client_0000000000000000000000000000000c";

static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);

/// A mock daemon on a fresh socket that serves one connection with `serve`.
fn mock(
    serve: impl FnOnce(&mut UnixStream, &mut BufReader<UnixStream>) + Send + 'static,
) -> (PathBuf, thread::JoinHandle<()>) {
    let path = std::env::temp_dir().join(format!(
        "cmux-home-conv-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ));
    let listener = UnixListener::bind(&path).unwrap();
    let server = thread::spawn(move || {
        let (mut stream, _) = listener.accept().unwrap();
        let mut reader = BufReader::new(stream.try_clone().unwrap());
        serve(&mut stream, &mut reader);
    });
    (path, server)
}

fn request(reader: &mut BufReader<UnixStream>, operation: &str) -> Value {
    let mut line = String::new();
    assert_ne!(reader.read_line(&mut line).unwrap(), 0, "the client closed early");
    let value: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(value["protocol"], "cmux.protocol/2");
    assert_eq!(value["operation"], operation, "{value}");
    value
}

fn respond(stream: &mut UnixStream, request: &Value, result: Value) {
    let response = Map::from_iter([
        ("protocol".to_string(), json!("cmux.protocol/2")),
        ("type".to_string(), json!("response")),
        ("id".to_string(), request["id"].clone()),
        ("ok".to_string(), json!(true)),
        ("result".to_string(), result),
    ]);
    writeln!(stream, "{}", Value::Object(response)).unwrap();
}

#[test]
fn ensure_home_sends_the_operation_and_returns_the_home_workspace_handle() {
    let (path, server) = mock(|stream, reader| {
        for (key, replayed) in [("home-1", false), ("home-2", true)] {
            let ensure = request(reader, "workspace.ensure_home");
            assert_eq!(ensure["idempotency_key"], key);
            assert_eq!(ensure["params"], json!({"machine": "current", "session": SESSION}));
            let value = json!({"kind": "workspace", "workspace_id": WORKSPACE});
            let result = json!({"value": value, "generation": "g", "revision": "4",
                                "replayed": replayed});
            respond(stream, &ensure, result);
        }
        let terminal = request(reader, "workspace.ensure_home");
        let value = json!({"kind": "terminal", "workspace_id": WORKSPACE});
        respond(
            stream,
            &terminal,
            json!({"value": value, "generation": "g", "revision": "4",
                                          "replayed": true}),
        );
    });
    let client =
        cmux::Client::connect(Config::from_socket_path(&path).with_timeout(Duration::from_secs(2)))
            .unwrap();
    let session = client.session(SessionId::parse(SESSION).unwrap());
    let home = WorkspaceId::parse(WORKSPACE).unwrap();
    let first = session.ensure_home_with(MutationOptions::new("home-1").unwrap()).unwrap();
    assert_eq!(first.resource.selector(), &Selector::from(home.clone()));
    assert_eq!((first.revision, first.replayed), (4, false));
    let again = session.ensure_home_with(MutationOptions::new("home-2").unwrap()).unwrap();
    assert_eq!(again.resource.selector(), &Selector::from(home));
    assert!(again.replayed);
    // A path that names no workspace alone is refused.
    let error = session.ensure_home().unwrap_err();
    assert!(!matches!(error, Error::InvalidArgument(_)), "{error:?}");
    client.close().unwrap();
    server.join().unwrap();
    let _ = std::fs::remove_file(path);
}

#[test]
fn declare_capabilities_sends_them_alone_on_the_current_connection() {
    let (path, server) = mock(|stream, reader| {
        let declare = request(reader, "client.metadata.update");
        assert!(declare.get("idempotency_key").is_none(), "{declare}");
        assert_eq!(
            declare["params"],
            json!({"machine": "current", "session": SESSION, "client": "current",
                   "capabilities": [CONVERSATION_TABS_CAPABILITY]})
        );
        let snapshot = json!({"id": CLIENT, "session_id": SESSION, "name": null,
                              "client_kind": null, "transport": "unix",
                              "connected_seconds": "1", "attached_terminal_ids": [],
                              "sizes": [], "self": true});
        respond(stream, &declare, snapshot);
    });
    let client =
        cmux::Client::connect(Config::from_socket_path(&path).with_timeout(Duration::from_secs(2)))
            .unwrap();
    let me =
        client.session(SessionId::parse(SESSION).unwrap()).connected_client(Selector::current());
    assert!(me.declare_capabilities([CONVERSATION_TABS_CAPABILITY]).unwrap().is_self);
    // Refused before any request.
    for bad in [vec![], vec![String::new()], vec!["x".repeat(129)]] {
        let error = me.declare_capabilities(bad).unwrap_err();
        assert!(matches!(error, Error::InvalidArgument(_)), "{error:?}");
    }
    client.close().unwrap();
    server.join().unwrap();
    let _ = std::fs::remove_file(path);
}

#[test]
fn a_conversation_tab_decodes_with_its_browser_content_id() {
    let tab: TabSnapshot = serde_json::from_value(json!({
        "id": TAB, "pane_id": PANE, "name": null, "index": 0, "focused": true,
        "content_kind": "conversation", "content_id": BROWSER,
        "extra": {"conversation": {"conversation": "conv_01CHIEF", "owner": "local"}},
    }))
    .unwrap();
    assert_eq!(tab.content_kind, TabContentKind::Conversation);
    assert!(matches!(tab.content_id, TabContentId::Browser(_)));
    assert_eq!(tab.extra["conversation"]["conversation"], "conv_01CHIEF");
}

fn summary() -> Value {
    json!({
        "id": "conv_01CHIEF", "owner": "local", "title": "Chief",
        "participants": [
            {"id": "user_local", "kind": "human", "display_name": "Me"},
            {"id": "agent_mux", "kind": "agent", "display_name": "Chief",
             "agent_class": "mux", "acp_session": "mux"}
        ],
        "last_seq": 1, "rev": 2,
        "created_at": "2026-10-03T00:00:00.000Z", "updated_at": "2026-10-03T00:00:01.000Z",
        "last_message": message(),
        "read_cursors": {"user_local": 1},
    })
}

fn message() -> Value {
    json!({
        "id": "msg_01A", "conversation": "conv_01CHIEF", "seq": 1, "client_msg_id": "c-1",
        "author": "user_local",
        "parts": [
            {"type": "text", "text": "hi @chief", "runs": [{"start": 3, "length": 6,
                                                         "mention": "agent_mux"}]},
            {"type": "work", "session": "s1", "status": "running"}
        ],
        "created_at": "2026-10-03T00:00:01.000Z",
        "reactions": [
            {"author": "agent_mux", "part_index": 0, "kind": {"tapback": "like"},
             "at": "2026-10-03T00:00:02.000Z"},
            {"author": "agent_mux", "part_index": 0, "kind": {"emoji": "🎉"},
             "at": "2026-10-03T00:00:03.000Z"}
        ],
    })
}

#[test]
fn conversation_results_decode_typed() {
    let list: ConversationListResult =
        serde_json::from_value(json!({"conversations": [summary()]})).unwrap();
    let chief = &list.conversations[0];
    assert_eq!(
        (chief.title.as_str(), chief.rev, chief.read_cursors["user_local"]),
        ("Chief", 2, 1)
    );
    assert_eq!(chief.participants[1].acp_session.as_deref(), Some("mux"));

    let created: ConversationCreateResult =
        serde_json::from_value(json!({"conversation": summary(), "replayed": true})).unwrap();
    assert!(created.replayed);

    let snapshot: ConversationSnapshotResult =
        serde_json::from_value(json!({"conversation": summary(), "messages": [message()]}))
            .unwrap();
    let parts = &snapshot.messages[0].parts;
    assert!(matches!(&parts[0], ConversationPart::Text { text, .. } if text == "hi @chief"));
    assert!(matches!(&parts[1], ConversationPart::Work { session, .. } if session == "s1"));
    let reactions = &snapshot.messages[0].reactions;
    assert!(matches!(&reactions[0].kind, ConversationReactionKind::ConversationTapbackReaction(r)
        if r.tapback == ConversationTapback::Like));
    assert!(matches!(&reactions[1].kind, ConversationReactionKind::ConversationEmojiReaction(r)
        if r.emoji == "🎉"));

    let sent: ConversationOpResult = serde_json::from_value(json!({
        "rev": 3, "seq": 2, "replayed": false, "transaction": "t-1",
        "change": {"kind": "message", "message": message()},
    }))
    .unwrap();
    assert_eq!((sent.rev, sent.seq, sent.transaction.as_deref()), (3, Some(2), Some("t-1")));
    assert!(matches!(sent.change, ConversationChange::Message { .. }));
    let cursor: ConversationOpResult = serde_json::from_value(json!({
        "rev": 4, "replayed": true,
        "change": {"kind": "read-cursor", "participant": "user_local", "seq": 2},
    }))
    .unwrap();
    assert_eq!(cursor.seq, None);
    assert!(matches!(cursor.change, ConversationChange::ReadCursor { seq: 2, .. }));

    let tab: NewConversationTabResult = serde_json::from_value(json!({
        "surface": 8, "tab_resource_id": TAB, "content_resource_id": BROWSER,
        "conversation": {"conversation": "conv_01CHIEF", "owner": "local"}, "replayed": false,
    }))
    .unwrap();
    assert_eq!((tab.surface, tab.conversation.owner.as_str()), (8, "local"));
}
