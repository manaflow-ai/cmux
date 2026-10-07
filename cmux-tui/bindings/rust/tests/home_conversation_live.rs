//! Home against a real cmux-tui daemon: `Session::ensure_home`, the
//! `conversation-tabs-v1` declaration and `TabContentKind::Conversation`,
//! and every typed `conversation-*` and `new-conversation-tab` result
//! decoded from the daemon's own output.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.

use cmux::raw::{
    ClientConfig, ConversationAgentTokenRequest, ConversationBindRequest,
    ConversationCreateRequest, ConversationHistoryRequest, ConversationListRequest,
    ConversationOpRequest, ConversationSearchRequest, ConversationSnapshotRequest,
    ConversationTypingRequest, NewConversationTabRequest, Nullable, Optional,
};
use cmux::{CONVERSATION_TABS_CAPABILITY, Config, Selector, TabContentKind};
use serde_json::{Map, Value, json};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

struct Daemon {
    child: Child,
    dir: PathBuf,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

fn start_daemon(binary: &Path) -> (Daemon, PathBuf) {
    let dir = std::env::temp_dir().join(format!("cmux-sdk-home-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", "sdk-home", "--socket"])
        .arg(&socket)
        .arg("--state")
        .arg(dir.join("state"))
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::inherit())
        .spawn()
        .expect("start cmux-tui");
    let daemon = Daemon { child, dir };
    let deadline = Instant::now() + Duration::from_secs(30);
    while UnixStream::connect(&socket).is_err() {
        assert!(Instant::now() < deadline, "cmux-tui did not listen on {socket:?}");
        thread::sleep(Duration::from_millis(50));
    }
    (daemon, socket)
}

fn raw(socket: &Path) -> cmux::raw::Client {
    let config = ClientConfig::from_socket_path(socket).with_timeout(Duration::from_secs(10));
    cmux::raw::Client::connect(config).unwrap()
}

fn op(conversation: &str, key: &str, op: Value) -> ConversationOpRequest {
    ConversationOpRequest {
        actor: Optional::Missing,
        conversation: conversation.to_string(),
        idempotency_key: key.to_string(),
        op: Nullable::value(op),
        transaction: Optional::Value(format!("tx-{key}")),
    }
}

#[test]
fn home_and_conversation_results_live_daemon() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let (_daemon, socket) = start_daemon(Path::new(&binary));
    let config = Config::from_socket_path(&socket).with_timeout(Duration::from_secs(10));
    let capable = cmux::Client::connect(config.clone()).unwrap();
    let session = capable.current_session();
    let me = session.connected_client(Selector::current());
    assert!(me.declare_capabilities([CONVERSATION_TABS_CAPABILITY]).unwrap().is_self);

    // workspace.ensure_home: created once, the same workspace after that.
    let home = session.ensure_home().unwrap();
    assert!(!home.replayed);
    let again = session.ensure_home().unwrap();
    assert!(again.replayed);
    assert_eq!(again.resource.selector(), home.resource.selector());
    let home_id = home.value.workspace_id().clone();

    let mut client = raw(&socket);
    let capabilities = client.identify_server().unwrap().capabilities.unwrap_or_default();
    for needed in ["local-conversations-v1", CONVERSATION_TABS_CAPABILITY] {
        assert!(capabilities.iter().any(|c| c == needed), "{needed} in {capabilities:?}");
    }

    let participants = json!([
        {"id": "user_local", "kind": "human", "display_name": "Me"},
        {"id": "agent_mux", "kind": "agent", "display_name": "Chief",
         "agent_class": "mux", "acp_session": "mux"},
    ]);
    let create = || ConversationCreateRequest {
        actor: Optional::Missing,
        idempotency_key: "live-chief".into(),
        participants: Nullable::value(participants.clone()),
        title: "Chief".into(),
    };
    let created = client.conversation_create(create()).unwrap();
    assert!(!created.replayed);
    assert!(client.conversation_create(create()).unwrap().replayed);
    let id = created.conversation.id.clone();
    assert_eq!(created.conversation.participants[1].acp_session.as_deref(), Some("mux"));

    let listed = client.conversation_list(ConversationListRequest::default()).unwrap();
    assert!(listed.conversations.iter().any(|summary| summary.id == id));

    let send = json!({"kind": "message.send", "client_msg_id": "c-1",
                      "parts": [{"type": "text", "text": "hello chief"}]});
    let sent = client.conversation_op(op(&id, "c-1", send)).unwrap();
    assert_eq!((sent.seq, sent.transaction.as_deref()), (Some(1), Some("tx-c-1")));
    assert_eq!(sent.change.kind, "message", "{sent:?}");
    let message = sent.change.message.expect("message.send changes a message");
    let like = json!({"kind": "reaction.add", "message_id": message.id, "part_index": 0,
                      "reaction": {"tapback": "like"}});
    let liked = client.conversation_op(op(&id, "like-1", like)).unwrap();
    assert_eq!(liked.change.kind, "message-updated", "{liked:?}");
    assert!(liked.change.additional.is_empty(), "{liked:?}");
    let read =
        client.conversation_op(op(&id, "read-1", json!({"kind": "read_cursor.set", "seq": 1})));
    let read = read.unwrap().change;
    assert_eq!((read.kind.as_str(), read.seq), ("read-cursor", Some(1)));
    let titled = client
        .conversation_op(op(&id, "title-1", json!({"kind": "title.set", "title": "Chief 2"})))
        .unwrap();
    assert_eq!(titled.change.kind, "conversation", "{titled:?}");
    assert_eq!(titled.change.conversation.as_ref().map(|c| c.title.as_str()), Some("Chief 2"));

    let snapshot = client
        .conversation_snapshot(ConversationSnapshotRequest { conversation: id.clone(), tail: 10 })
        .unwrap();
    assert_eq!(snapshot.conversation.title, "Chief 2");
    assert_eq!(snapshot.conversation.read_cursors.get("user_local"), Some(&1));
    let first = &snapshot.messages[0];
    assert_eq!(first.parts[0].type_, "text");
    assert_eq!(first.parts[0].text.as_deref(), Some("hello chief"));
    assert!(first.parts[0].additional.is_empty(), "{first:?}");
    assert_eq!(first.reactions[0].kind.tapback.as_deref(), Some("like"));
    assert_eq!(snapshot.conversation.participants[0].kind, "human");
    let history = client
        .conversation_history(ConversationHistoryRequest {
            conversation: id.clone(),
            before_seq: 2,
            limit: 10,
        })
        .unwrap();
    assert_eq!(history.messages.len(), 1);
    if capabilities.iter().any(|c| c == "conversation-search-v1") {
        let found = client
            .conversation_search(ConversationSearchRequest { query: "hello".into(), limit: 5 })
            .unwrap();
        assert_eq!(found.hits[0].message_id, first.id);
    }
    client
        .conversation_typing(ConversationTypingRequest {
            actor: Optional::Missing,
            conversation: id.clone(),
            on: true,
        })
        .unwrap();
    let token = client
        .conversation_agent_token(ConversationAgentTokenRequest { participant: "agent_mux".into() })
        .unwrap();
    let bound = raw(&socket)
        .conversation_bind(ConversationBindRequest {
            participant: token.participant.clone(),
            token: token.token,
        })
        .unwrap();
    assert_eq!(bound.participant, "agent_mux");

    // new-conversation-tab in the home workspace (its raw id from the tree).
    let tree = client
        .request_raw(Map::from_iter([("cmd".to_string(), json!("list-workspaces"))]))
        .unwrap();
    let raw_home = tree["data"]["workspaces"]
        .as_array()
        .unwrap()
        .iter()
        .find(|workspace| workspace["resource_id"] == home_id.as_str())
        .and_then(|workspace| workspace["id"].as_u64())
        .expect("the home workspace is in the raw tree");
    let tab = client
        .new_conversation_tab(NewConversationTabRequest {
            agent_session: Optional::Missing,
            cols: Optional::Missing,
            conversation: Optional::Value(id.clone()),
            mutation_id: Optional::Value("live-tab".into()),
            origin: Optional::Value("sdk-live".into()),
            owner: Optional::Value("local".into()),
            page: Optional::Missing,
            pane: Optional::Missing,
            rows: Optional::Missing,
            transaction: Optional::Missing,
            workspace: Optional::Value(raw_home),
        })
        .unwrap();
    assert_eq!(
        (tab.conversation.conversation.as_deref(), tab.replayed),
        (Some(id.as_str()), false)
    );
    let tab_id = tab.tab_resource_id.into_option().expect("a tab resource id");

    // The declared connection reads the canonical kind; another reads browser.
    let kind_on = |client: &cmux::Client| {
        let snapshot = client.current_session().snapshot().unwrap();
        snapshot.tabs.iter().find(|t| t.id.as_str() == tab_id).map(|t| t.content_kind)
    };
    assert_eq!(kind_on(&capable), Some(TabContentKind::Conversation));
    let plain = cmux::Client::connect(config).unwrap();
    assert_eq!(kind_on(&plain), Some(TabContentKind::Browser));
    plain.close().unwrap();
    capable.close().unwrap();
}
