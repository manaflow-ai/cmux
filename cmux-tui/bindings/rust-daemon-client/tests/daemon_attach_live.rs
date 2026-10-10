//! `DaemonAttacher` against a real cmux-tui daemon, with the generation read
//! from a `DaemonClient` mirror through `MirrorWatch` (the GPUI app's path).
//!
//! Runs when `CMUX_SDK_LIVE_TUI_BIN` names a cmux-tui binary, like the SDK's
//! `byte_attachment_live.rs`; otherwise it reports the skip and passes.
// Unix sockets and a live Unix daemon; the Windows suite is separate.
#![cfg(unix)]

use cmux_daemon_client::attach::{AttachmentItem, CellSize, Replay};
use cmux_daemon_client::cmux::{self, RunCommand};
use cmux_daemon_client::{
    AttachEnd, AttachRequest, DaemonAttacher, DaemonClient, DaemonConfig, GenerationWait,
    MirrorWatch, TerminalAttacher, TerminalByteSink,
};
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
    let dir = std::env::temp_dir().join(format!("cmux-dc-live-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    let socket = dir.join("s.sock");
    let child = Command::new(binary)
        .args(["--headless", "--session", "daemon-client-attach", "--socket"])
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

enum Seen {
    Replay(Vec<u8>),
    Resized(u16, u16),
    Bytes(Vec<u8>),
    Ended(AttachEnd),
}

struct Forward(mpsc::Sender<Seen>);

impl TerminalByteSink for Forward {
    fn replay(&mut self, replay: &Replay) {
        let _ = self.0.send(Seen::Replay(replay.data.clone()));
    }
    fn resized(&mut self, replay: &Replay) {
        let _ = self.0.send(Seen::Resized(replay.cols, replay.rows));
    }
    fn bytes(&mut self, data: &[u8]) {
        let _ = self.0.send(Seen::Bytes(data.to_vec()));
    }
    fn item(&mut self, item: &AttachmentItem) {
        if let AttachmentItem::SizeState(state) = item {
            let _ = self.0.send(Seen::Resized(state.cols, state.rows));
        }
    }
    fn ended(&mut self, end: AttachEnd) {
        let _ = self.0.send(Seen::Ended(end));
    }
}

fn sink() -> (Box<Forward>, mpsc::Receiver<Seen>) {
    let (tx, rx) = mpsc::channel();
    (Box::new(Forward(tx)), rx)
}

fn wait_for(rx: &mpsc::Receiver<Seen>, what: &str, mut accept: impl FnMut(&Seen) -> bool) {
    let deadline = Instant::now() + Duration::from_secs(15);
    loop {
        let left = deadline.saturating_duration_since(Instant::now());
        let seen = rx.recv_timeout(left).unwrap_or_else(|e| panic!("waiting for {what}: {e}"));
        if accept(&seen) {
            return;
        }
        if let Seen::Ended(end) = seen {
            panic!("ended while waiting for {what}: {end:?}");
        }
    }
}

fn contains(bytes: &[u8], marker: &[u8]) -> bool {
    bytes.windows(marker.len()).any(|w| w == marker)
}

#[test]
fn daemon_attach_live_mirror_generation_input_resize_detach_and_reattach_replay() {
    let Some(binary) = std::env::var_os("CMUX_SDK_LIVE_TUI_BIN") else {
        eprintln!("skipped: set CMUX_SDK_LIVE_TUI_BIN to a cmux-tui binary to run");
        return;
    };
    let (_daemon, socket) = start_daemon(Path::new(&binary));

    let watch = MirrorWatch::new();
    let mut config = DaemonConfig::new("daemon-client-attach");
    config.socket = Some(socket.clone());
    let observer = watch.clone();
    let mut client =
        DaemonClient::spawn(config, move |_, mirror| observer.observe(mirror)).unwrap();

    let sdk = cmux::Client::connect(cmux::Config::from_socket_path(&socket)).unwrap();
    let workspace = sdk.current_session().create_workspace(Some("attach-live".into())).unwrap();
    let created = workspace.resource.run(RunCommand::argv(["cat"]).unwrap()).unwrap();
    let terminal = created.resource.id().expect("terminal id").clone();
    let generation = match watch.wait_for_terminal(&terminal, Duration::from_secs(15)) {
        GenerationWait::Resolved(generation) => generation,
        other => panic!("the mirror never showed {terminal:?}: {other:?}"),
    };

    let attacher = DaemonAttacher::new(&socket);
    let request = |size| AttachRequest {
        terminal: terminal.clone(),
        generation: generation.clone(),
        size,
        claim_geometry: true,
    };
    let (first_sink, rx) = sink();
    let attachment = attacher.attach(request(CellSize::new(80, 24)), first_sink).unwrap();
    wait_for(&rx, "the first replay", |s| matches!(s, Seen::Replay(_)));
    attachment.write(b"daemon-client-live-marker\r").unwrap();
    wait_for(
        &rx,
        "echoed input",
        |s| matches!(s, Seen::Bytes(b) if contains(b, b"daemon-client-live-marker")),
    );
    attachment.resize(CellSize::new(100, 30)).unwrap();
    wait_for(&rx, "the 100x30 grid", |s| matches!(s, Seen::Resized(100, 30)));
    attachment.detach();
    wait_for(&rx, "released", |s| matches!(s, Seen::Ended(AttachEnd::Released)));
    drop(attachment);

    let (second_sink, rx) = sink();
    let again = attacher.attach(request(CellSize::new(100, 30)), second_sink).unwrap();
    wait_for(
        &rx,
        "the reattach replay with the earlier output",
        |s| matches!(s, Seen::Replay(data) if contains(data, b"daemon-client-live-marker")),
    );
    drop(again);
    workspace.resource.close().unwrap();
    sdk.close().unwrap();
    client.stop();
}
