//! A client's declared capabilities apply to every connection it opens, not
//! only to the connection that declared them: `session.events` (its own
//! connection) reads an agent session tab (`agent-session-tabs-v1`) as
//! `TabContentKind::Conversation` with its `extra.conversation.agent_session`
//! record, never as the `browser` tab with no record that a connection
//! without the capabilities reads.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.
// Unix sockets and a live Unix daemon; the Windows suite is separate.
#![cfg(unix)]

use cmux::raw::{ClientConfig, NewConversationTabRequest, Optional};
use cmux::{
    CONVERSATION_TABS_CAPABILITY, Config, EventStreamOptions, ResourceChange,
    ResourceEntitySnapshot, Selector, SessionEvent, StreamPoll, TabContentKind, TabSnapshot,
};
use serde_json::{Map, Value};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

const AGENT_SESSION_TABS: &str = "agent-session-tabs-v1";
const HOST: &str = "install:sdk-capabilities-live";

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
    let dir = std::env::temp_dir().join(format!("cmux-sdk-caps-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", "sdk-caps", "--socket"])
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

fn agent_host(tab: &TabSnapshot) -> Option<&str> {
    tab.extra.get("conversation")?.get("agent_session")?.get("host")?.as_str()
}

#[test]
fn declared_capabilities_reach_the_event_stream_live_daemon() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let (_daemon, socket) = start_daemon(Path::new(&binary));
    let config = Config::from_socket_path(&socket).with_timeout(Duration::from_secs(10));
    let capable = cmux::Client::connect(config).unwrap();
    let session = capable.current_session();
    let me = session.connected_client(Selector::current());
    me.declare_capabilities([CONVERSATION_TABS_CAPABILITY, AGENT_SESSION_TABS]).unwrap();

    // A pane for the tab: the home workspace's first pane.
    session.ensure_home().unwrap();
    let mut raw = cmux::raw::Client::connect(
        ClientConfig::from_socket_path(&socket).with_timeout(Duration::from_secs(10)),
    )
    .unwrap();
    let advertised = raw.identify_server().unwrap().capabilities.unwrap_or_default();
    assert!(advertised.iter().any(|c| c == AGENT_SESSION_TABS), "{advertised:?}");
    let tree = raw
        .request_raw(Map::from_iter([("cmd".to_string(), Value::from("list-workspaces"))]))
        .unwrap();
    let workspace = tree["data"]["workspaces"]
        .as_array()
        .and_then(|w| w.iter().find(|w| w["kind"] == "home"))
        .and_then(|w| w["id"].as_u64())
        .expect("the home workspace in the tree");

    let snapshot = session.snapshot().unwrap();
    let mut events = session.events(EventStreamOptions { cursor: Some(snapshot.cursor) }).unwrap();

    let source: cmux::raw::AgentSessionSource =
        serde_json::from_value(serde_json::json!({"host": HOST, "harness": "codex"})).unwrap();
    let created = raw
        .new_conversation_tab(NewConversationTabRequest {
            agent_session: Optional::Value(source),
            workspace: Optional::Value(workspace),
            ..Default::default()
        })
        .unwrap();
    let tab_id = created.tab_resource_id.into_option().expect("the created tab's id");

    // The tab's upsert on the event stream: canonical, with its record.
    let deadline = Instant::now() + Duration::from_secs(10);
    let tab = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "no upsert of the agent tab {tab_id} on session.events");
        let StreamPoll::Item(item) = events.next_timeout(left).unwrap() else { continue };
        let SessionEvent::Delta(delta) = item.value else { continue };
        let found = delta.changes.into_iter().find_map(|change| match change {
            ResourceChange::Upsert { value: ResourceEntitySnapshot::Tab(tab), .. }
                if tab.id.as_str() == tab_id =>
            {
                Some(tab)
            }
            _ => None,
        });
        if let Some(tab) = found {
            break tab;
        }
    };
    assert_eq!(tab.content_kind, TabContentKind::Conversation, "{tab:?}");
    assert_eq!(agent_host(&tab), Some(HOST), "{tab:?}");

    // The snapshot (the control connection) reads it the same way.
    let snapshot = session.snapshot().unwrap();
    let tab = snapshot.tabs.iter().find(|t| t.id.as_str() == tab_id).unwrap();
    assert_eq!(tab.content_kind, TabContentKind::Conversation, "{tab:?}");
    assert_eq!(agent_host(tab), Some(HOST), "{tab:?}");
}
