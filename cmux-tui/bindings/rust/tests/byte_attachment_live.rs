//! `cmux::raw::ByteAttachment` against a real cmux-tui daemon.
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a built `cmux-tui` binary; the
//! `cmux-tui-sdks.yml` live conformance job sets it. Without the variable the
//! test reports the skip and passes, because the SDK package lanes do not
//! build the daemon.
// Unix sockets and a live Unix daemon; the Windows suite is separate.
#![cfg(unix)]

use cmux::raw::{
    AttachOptions, AttachTarget, AttachmentItem, ByteAttachment, ByteAttachmentReader, CellSize,
    ClientConfig, ClientIdentity, EndReason, Error, IdentifyRequest,
};
use cmux::{Config, RunCommand};
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
    let dir = std::env::temp_dir().join(format!("cmux-sdk-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", "sdk-byte-attach", "--socket"])
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

/// Reads items until `accept` returns true or the deadline passes.
fn wait_for(
    reader: &mut ByteAttachmentReader,
    what: &str,
    mut accept: impl FnMut(&AttachmentItem) -> bool,
) -> AttachmentItem {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        assert!(!left.is_zero(), "timed out waiting for {what}");
        match reader.recv_timeout(left) {
            Ok(item) if accept(&item) => return item,
            Ok(AttachmentItem::Ended(end)) => {
                panic!("attachment ended while waiting for {what}: {end:?}")
            }
            Ok(_) | Err(Error::Timeout(_)) => {}
            Err(error) => panic!("reader failed while waiting for {what}: {error}"),
        }
    }
}

fn output_contains(item: &AttachmentItem, marker: &[u8]) -> bool {
    let bytes = match item {
        AttachmentItem::Output { data, .. } => data,
        AttachmentItem::VtState(replay) | AttachmentItem::Resized(replay) => &replay.data,
        _ => return false,
    };
    bytes.windows(marker.len()).any(|window| window == marker)
}

#[test]
fn byte_attachment_live_daemon_identity_attach_input_resize_detach_and_reattach() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let (_daemon, socket) = start_daemon(Path::new(&binary));

    let client = cmux::Client::connect(Config::from_socket_path(&socket)).unwrap();
    let workspace = client.current_session().create_workspace(Some("byte-attach".into())).unwrap();
    let terminal = workspace.resource.run(RunCommand::argv(["cat"]).unwrap()).unwrap();
    let terminal_id = terminal.resource.id().expect("created terminal has an id").clone();
    let mut raw = cmux::raw::Client::connect(ClientConfig::from_socket_path(&socket)).unwrap();
    let generation = raw.identify(IdentifyRequest {}).unwrap().generation;

    let config = ClientConfig::from_socket_path(&socket).with_timeout(Duration::from_secs(10));
    let target =
        || AttachTarget::Terminal { id: terminal_id.clone(), generation: generation.clone() };
    let options = || AttachOptions {
        client: ClientIdentity {
            name: Some("sdk-live".into()),
            device_kind: Some("browser".into()),
            ..ClientIdentity::default()
        },
        claim_geometry: true,
        ..AttachOptions::default()
    };
    let ByteAttachment { writer, mut reader, info } =
        ByteAttachment::open(&config, target(), CellSize::new(80, 24), options()).unwrap();
    assert!(!info.lease.is_empty(), "the daemon minted a view lease");
    assert!(info.surface > 0);
    assert_eq!(info.generation, generation);
    assert!(matches!(reader.recv().unwrap(), AttachmentItem::VtState(_)));

    let input = thread::spawn(move || {
        writer.send_bytes(b"sdk-byte-attach-marker\r").unwrap();
        writer
    });
    let writer = input.join().unwrap();
    wait_for(&mut reader, "echoed input", |item| output_contains(item, b"sdk-byte-attach-marker"));

    writer.resize(CellSize::new(100, 30)).unwrap();
    wait_for(&mut reader, "the 100x30 grid", |item| match item {
        AttachmentItem::Resized(replay) => (replay.cols, replay.rows) == (100, 30),
        AttachmentItem::SizeState(state) => (state.cols, state.rows) == (100, 30),
        _ => false,
    });
    writer.release_geometry().unwrap();
    writer.detach().unwrap();
    wait_for(&mut reader, "client detach", |item| {
        matches!(item, AttachmentItem::Ended(EndReason::ClosedByClient))
    });

    // Reattach by identity: the replay carries the earlier output.
    let ByteAttachment { writer, mut reader, .. } =
        ByteAttachment::open(&config, target(), CellSize::new(100, 30), options()).unwrap();
    let AttachmentItem::VtState(replay) = reader.recv().unwrap() else { panic!("vt-state first") };
    assert!(
        output_contains(&AttachmentItem::VtState(replay), b"sdk-byte-attach-marker"),
        "reattach replay restores the screen"
    );
    drop(writer);
    workspace.resource.close().unwrap();
}
