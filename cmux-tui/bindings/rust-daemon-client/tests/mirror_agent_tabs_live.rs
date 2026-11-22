//! `DaemonConfig::capabilities` against a real cmux-tui daemon: a mirror
//! that declares `conversation-tabs-v1` and `agent-session-tabs-v1` keeps an
//! agent session tab another client created as `TabContentKind::Conversation`
//! with its `extra.conversation.agent_session` record (the event stream is a
//! connection of its own), and the record follows a session bind.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.
// Unix sockets and a live Unix daemon; the Windows suite is separate.
#![cfg(unix)]

use cmux_daemon_client::cmux;
use cmux_daemon_client::{DaemonClient, DaemonConfig, DaemonEvent, Mirror};
use serde_json::{Map, Value};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
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
    let dir =
        std::env::temp_dir().join(format!("cmux-daemon-client-agent-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", "daemon-client-agent-live", "--socket"])
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

const HOST: &str = "install:daemon-client-agent-live";

fn agent_session(mirror: &Mirror) -> Option<(cmux::TabContentKind, Value)> {
    mirror.tabs.values().find_map(|tab| {
        let record = tab.extra.get("conversation")?.get("agent_session")?;
        (record.get("host")?.as_str() == Some(HOST)).then(|| (tab.content_kind, record.clone()))
    })
}

fn wait_for(
    rx: &mpsc::Receiver<(DaemonEvent, Mirror)>,
    what: &str,
    mut done: impl FnMut(&DaemonEvent, &Mirror) -> bool,
) -> (DaemonEvent, Mirror) {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let (event, mirror) =
            rx.recv_timeout(left).unwrap_or_else(|e| panic!("waiting for {what}: {e}"));
        if let DaemonEvent::Disconnected { error, .. } = &event {
            panic!("disconnected while waiting for {what}: {error}");
        }
        if done(&event, &mirror) {
            return (event, mirror);
        }
    }
}

#[test]
fn mirror_reads_agent_session_tabs_canonically_live_daemon() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let (_daemon, socket) = start_daemon(Path::new(&binary));
    let mut config = DaemonConfig::new("daemon-client-agent-live");
    config.socket = Some(socket.clone());
    config.capabilities = vec![
        "conversation-tabs-v1".into(),
        "agent-session-tabs-v1".into(),
        "not-advertised-v1".into(),
    ];
    let (tx, rx) = mpsc::channel();
    let mut client = DaemonClient::spawn(config, move |event, mirror| {
        let _ = tx.send((event.clone(), mirror.clone()));
    })
    .unwrap();
    wait_for(&rx, "connect", |e, _| matches!(e, DaemonEvent::Connected(_)));
    wait_for(&rx, "reset", |e, _| *e == DaemonEvent::Reset);

    let sdk = cmux::Client::connect(
        cmux::Config::from_socket_path(&socket).with_timeout(Duration::from_secs(10)),
    )
    .unwrap();
    sdk.current_session().create_workspace(Some("agent-live".into())).unwrap();
    let raw_config =
        cmux::raw::ClientConfig::from_socket_path(&socket).with_timeout(Duration::from_secs(10));
    let mut raw = cmux::raw::Client::connect(raw_config).unwrap();
    let tree = raw
        .request_raw(Map::from_iter([("cmd".to_string(), Value::from("list-workspaces"))]))
        .unwrap();
    let workspace = tree["data"]["workspaces"][0]["id"].as_u64().expect("a workspace in the tree");
    let source: cmux::raw::AgentSessionSource =
        serde_json::from_value(serde_json::json!({"host": HOST, "harness": "codex"})).unwrap();
    let created = raw
        .new_conversation_tab(cmux::raw::NewConversationTabRequest {
            agent_session: cmux::raw::Optional::Value(source),
            workspace: cmux::raw::Optional::Value(workspace),
            ..Default::default()
        })
        .unwrap();
    let (_, mirror) = wait_for(&rx, "the agent tab", |_, m| agent_session(m).is_some());
    let (kind, record) = agent_session(&mirror).unwrap();
    assert_eq!(kind, cmux::TabContentKind::Conversation);
    assert_eq!(record["session"], Value::Null);
    assert_eq!(record["harness"], "codex");

    raw.bind_conversation_tab_session(cmux::raw::BindConversationTabSessionRequest {
        surface: created.surface,
        session: "ses-agent-live".into(),
        expected_session: cmux::raw::Nullable::null(),
    })
    .unwrap();
    let (_, mirror) = wait_for(&rx, "the bind", |_, m| {
        agent_session(m).is_some_and(|(_, r)| r["session"] == "ses-agent-live")
    });
    assert_eq!(agent_session(&mirror).unwrap().0, cmux::TabContentKind::Conversation);
    client.stop();
}
