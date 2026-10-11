//! Notifications against a real cmux-tui daemon, over its socket: creating
//! one, its upsert on `session.events`, `session.snapshot` and
//! `notification.list` all decode the daemon's notification record (with
//! `read_by`, `NotificationSnapshot` in resource-operations-v2.json), and the
//! session keeps working after it. A client that refused the record lost its
//! session on every snapshot while the notification existed (cx-d56v).
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary (the
//! `cmux-tui-sdks.yml` live conformance job sets it). Without the variable the
//! test reports the skip and passes.
// Unix sockets and a live Unix daemon; the Windows suite is separate.
#![cfg(unix)]

use cmux::{
    Config, EventStreamOptions, NotificationListOptions, NotificationOptions, ResourceChange,
    ResourceEntitySnapshot, SessionEvent, StreamPoll,
};
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

/// A headless daemon in its own state directory.
fn live() -> Option<(Daemon, PathBuf)> {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return None;
    };
    let dir =
        std::env::temp_dir().join(format!("cmux-sdk-notification-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", "sdk-notification", "--socket"])
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
    Some((daemon, socket))
}

fn connect(socket: &Path) -> cmux::Client {
    cmux::Client::connect(Config::from_socket_path(socket).with_timeout(Duration::from_secs(10)))
        .unwrap()
}

#[test]
fn a_notification_keeps_the_session_readable_live_daemon() {
    let Some((_daemon, socket)) = live() else { return };
    let client = connect(&socket);
    let session = client.current_session();
    let before = session.snapshot().expect("session.snapshot before any notification");
    let mut events = session.events(EventStreamOptions { cursor: Some(before.cursor) }).unwrap();

    let created = session
        .create_notification(NotificationOptions {
            title: "Done".to_string(),
            body: "Tests passed".to_string(),
            level: None,
            terminal_id: None,
        })
        .expect("notification.create result decodes");
    let id = created.value.id;

    // Its upsert on the event stream decodes (the stream does not end).
    let deadline = Instant::now() + Duration::from_secs(10);
    let upserted = loop {
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "no upsert of notification {id:?} on session.events");
        let StreamPoll::Item(item) =
            events.next_timeout(left).expect("session.events item decodes")
        else {
            continue;
        };
        let SessionEvent::Delta(delta) = item.value else { continue };
        let found =
            delta.changes.into_iter().find_map(|change| match change {
                ResourceChange::Upsert {
                    value: ResourceEntitySnapshot::Notification(n), ..
                } if n.id == id => Some(n),
                _ => None,
            });
        if let Some(n) = found {
            break n;
        }
    };
    assert_eq!(upserted.title, "Done");

    // The whole session snapshot and the list still decode with it in.
    let after = session.snapshot().expect("session.snapshot with a notification");
    let listed = after
        .notifications
        .iter()
        .find(|n| n.id == id)
        .expect("the notification in session.snapshot");
    assert_eq!((listed.title.as_str(), listed.body.as_str()), ("Done", "Tests passed"));
    let list = session
        .notifications(NotificationListOptions::default())
        .expect("notification.list decodes");
    assert!(
        list.iter().any(|n| n.refresh().is_ok_and(|s| s.id == id)),
        "notification.list names {id:?}"
    );

    // And the session keeps working: a later snapshot on a new connection.
    let again =
        connect(&socket).current_session().snapshot().expect("a new client's session.snapshot");
    assert!(again.notifications.iter().any(|n| n.id == id));
}
