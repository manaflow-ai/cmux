//! `DaemonAttacher` against a scripted protocol-v12 server (the SDK's
//! `tests/byte_attachment.rs` pattern): the fake reads the exact request
//! lines and answers with v12 replies and attach events, so these tests pin
//! what the attacher sends and what the sink receives, in order.

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux_daemon_client::attach::{AttachmentItem, CellSize, EndReason, Reattach, Replay};
use cmux_daemon_client::cmux::{self, TerminalId};
use cmux_daemon_client::{
    AttachEnd, AttachError, AttachRequest, DaemonAttacher, GenerationWait, MirrorWatch,
    TerminalAttacher, TerminalByteSink, reattach,
};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::mpsc;
use std::thread::{self, JoinHandle};
use std::time::Duration;

const TERMINAL: &str = "term_00000000000000000000000000000008";
const CAPABILITIES: &[&str] = &[
    "attach-initial-size",
    "view-attachment-lease-v1",
    "view-attachment-detach-v1",
    "attach-identity-v1",
    "terminal-pending-sequence-v1",
    "shared-sizing-v1",
];

static NEXT: AtomicU64 = AtomicU64::new(1);

fn socket_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-daemon-attach-{}-{}.sock",
        std::process::id(),
        NEXT.fetch_add(1, Ordering::Relaxed)
    ))
}

fn terminal() -> TerminalId {
    serde_json::from_value(json!(TERMINAL)).expect("terminal id")
}

fn request(generation: &str) -> AttachRequest {
    AttachRequest {
        terminal: terminal(),
        generation: generation.into(),
        size: CellSize::new(80, 24),
        claim_geometry: false,
    }
}

fn b64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

struct Fake {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Fake {
    fn accept(listener: &UnixListener) -> Self {
        let (stream, _) = listener.accept().unwrap();
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        Self { stream, reader }
    }

    fn read(&mut self) -> Value {
        let mut line = String::new();
        assert_ne!(self.reader.read_line(&mut line).expect("fake read"), 0, "client closed early");
        serde_json::from_str(&line).expect("one JSON line")
    }

    fn at_eof(&mut self) -> bool {
        let mut line = String::new();
        matches!(self.reader.read_line(&mut line), Ok(0))
    }

    fn write(&mut self, value: Value) {
        writeln!(self.stream, "{value}").unwrap();
    }

    fn reply(&mut self, request: &Value, data: Value) {
        self.write(json!({"id": request["id"], "ok": true, "data": data}));
    }

    /// identify + set-client-info, then the attach request (returned, not
    /// answered yet).
    fn handshake(&mut self, generation: &str) -> Value {
        let identify = self.read();
        assert_eq!(identify["cmd"], "identify");
        let info = self.read();
        assert_eq!(info["cmd"], "set-client-info");
        assert_eq!(info["name"], "attach-test");
        self.reply(
            &identify,
            json!({"app": "cmux-tui", "version": "0", "protocol": 12, "capabilities": CAPABILITIES,
                   "session": "main", "pid": 1, "registry_id": "r", "generation": generation,
                   "daemon_handoff": 1, "terminal_revision": 1}),
        );
        self.reply(&info, json!({}));
        let attach = self.read();
        assert_eq!(attach["cmd"], "attach-surface");
        attach
    }

    /// Full open: vt-state (with a pending tail) before the attach reply.
    fn accept_attach(&mut self, generation: &str) -> Value {
        let attach = self.handshake(generation);
        self.write(vt_state("vt-state", 80, 24, b"\x1bcprompt$ ", b"\x1b["));
        self.reply(&attach, json!({"lease": "lease-1", "participant": "c1"}));
        attach
    }
}

fn vt_state(event: &str, cols: u16, rows: u16, data: &[u8], pending: &[u8]) -> Value {
    json!({"event": event, "surface": 7, "cols": cols, "rows": rows, "data": b64(data),
           "pending": b64(pending),
           "colors": {"fg": "#d8d9da", "bg": "#131415", "selection_bg": null,
                      "selection_fg": null, "cursor_style": "bar", "cursor_blink": false}})
}

fn spawn(server: impl FnOnce(UnixListener) + Send + 'static) -> (PathBuf, JoinHandle<()>) {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    (path, thread::spawn(move || server(listener)))
}

fn attacher(path: &PathBuf) -> DaemonAttacher {
    DaemonAttacher::new(path).with_timeout(Duration::from_secs(5)).with_client(
        cmux::raw::ClientIdentity { name: Some("attach-test".into()), ..Default::default() },
    )
}

/// What a sink saw, in order, with the thread it ran on.
#[derive(Debug, PartialEq)]
enum Seen {
    Replay { cols: u16, rows: u16, data: Vec<u8>, pending: Vec<u8> },
    Resized { cols: u16, rows: u16 },
    Bytes(Vec<u8>),
    Item(String),
    Ended(AttachEnd),
}

struct Recorder(mpsc::Sender<(Seen, Option<String>)>);

impl Recorder {
    fn new() -> (Box<Self>, mpsc::Receiver<(Seen, Option<String>)>) {
        let (tx, rx) = mpsc::channel();
        (Box::new(Self(tx)), rx)
    }

    fn send(&self, seen: Seen) {
        let _ = self.0.send((seen, thread::current().name().map(str::to_string)));
    }
}

impl TerminalByteSink for Recorder {
    fn replay(&mut self, r: &Replay) {
        self.send(Seen::Replay {
            cols: r.cols,
            rows: r.rows,
            data: r.data.clone(),
            pending: r.pending.clone(),
        });
    }
    fn resized(&mut self, r: &Replay) {
        self.send(Seen::Resized { cols: r.cols, rows: r.rows });
    }
    fn bytes(&mut self, data: &[u8]) {
        self.send(Seen::Bytes(data.to_vec()));
    }
    fn item(&mut self, item: &AttachmentItem) {
        let name = match item {
            AttachmentItem::ScrollChanged { .. } => "scroll".to_string(),
            AttachmentItem::ColorsChanged(_) => "colors".to_string(),
            AttachmentItem::CommandRejected { command, .. } => format!("rejected {command}"),
            other => format!("{other:?}"),
        };
        self.send(Seen::Item(name));
    }
    fn ended(&mut self, end: AttachEnd) {
        self.send(Seen::Ended(end));
    }
}

fn next(rx: &mpsc::Receiver<(Seen, Option<String>)>) -> Seen {
    rx.recv_timeout(Duration::from_secs(5)).expect("sink call").0
}

fn finish(path: PathBuf, server: JoinHandle<()>) {
    server.join().expect("fake daemon assertions");
    let _ = std::fs::remove_file(path);
}

#[test]
fn daemon_attach_identity_target_and_stream_order_reach_the_sink_on_its_reader_thread() {
    let (path, server) = spawn(|listener| {
        let mut fake = Fake::accept(&listener);
        let attach = fake.accept_attach("gen-1");
        assert_eq!(attach["mode"], "bytes");
        assert_eq!(attach["expected_terminal_id"], TERMINAL);
        assert_eq!(attach["expected_generation"], "gen-1");
        assert!(attach.get("surface").is_none(), "identity attach omits the numeric surface");
        assert_eq!((attach["cols"].as_u64(), attach["rows"].as_u64()), (Some(80), Some(24)));
        fake.write(json!({"event": "output", "surface": 7, "data": b64(b"[0mhello")}));
        fake.write(vt_state("resized", 100, 30, b"\x1bcreflowed", b""));
        fake.write(
            json!({"event": "scroll-changed", "surface": 7, "offset": 3, "at_bottom": false}),
        );
        fake.write(json!({"event": "output", "surface": 7, "data": b64(b"!"),
                          "colors": {"fg": "#ffffff", "bg": null, "selection_bg": null,
                                     "selection_fg": null}}));
        fake.write(json!({"event": "detached", "surface": 7, "reason": "network"}));
    });
    let (sink, rx) = Recorder::new();
    let attachment = attacher(&path).attach(request("gen-1"), sink).expect("attach");
    assert_eq!(attachment.terminal(), &terminal());

    let (first, thread_name) = rx.recv_timeout(Duration::from_secs(5)).unwrap();
    assert_eq!(
        first,
        Seen::Replay {
            cols: 80,
            rows: 24,
            data: b"\x1bcprompt$ ".to_vec(),
            pending: b"\x1b[".to_vec()
        }
    );
    assert_eq!(thread_name.as_deref(), Some("cmux-attach-7"), "sink runs on the reader thread");
    assert_eq!(next(&rx), Seen::Bytes(b"[0mhello".to_vec()));
    assert_eq!(next(&rx), Seen::Resized { cols: 100, rows: 30 });
    assert_eq!(next(&rx), Seen::Item("scroll".into()));
    assert_eq!(next(&rx), Seen::Item("colors".into()), "output colors precede their bytes");
    assert_eq!(next(&rx), Seen::Bytes(b"!".to_vec()));
    let Seen::Ended(end) = next(&rx) else { panic!("ended last") };
    assert!(matches!(end, AttachEnd::Interrupted { reattach: Reattach::Now, .. }), "{end:?}");
    assert!(rx.recv_timeout(Duration::from_millis(200)).is_err(), "nothing after ended");
    drop(attachment);
    finish(path, server);
}

#[test]
fn daemon_attach_writer_sends_input_geometry_and_detach_on_the_attach_connection() {
    let (path, server) = spawn(|listener| {
        let mut fake = Fake::accept(&listener);
        let attach = fake.handshake("gen-1");
        fake.write(vt_state("vt-state", 80, 24, b"", b""));
        fake.reply(&attach, json!({"lease": "lease-1"}));
        let claim = fake.read();
        assert_eq!(
            claim["cmd"], "set-client-sizing",
            "claim_geometry claims before attach returns"
        );
        fake.reply(&claim, json!({}));

        let send = fake.read();
        assert_eq!((send["cmd"].as_str(), send["surface"].as_u64()), (Some("send"), Some(7)));
        assert_eq!(STANDARD.decode(send["bytes"].as_str().unwrap()).unwrap(), b"ls\r");
        let resize = fake.read();
        assert_eq!(resize["cmd"], "resize-attached-view");
        assert_eq!((resize["cols"].as_u64(), resize["rows"].as_u64()), (Some(120), Some(40)));
        assert_eq!(resize["lease"], "lease-1");
        fake.write(json!({"id": resize["id"], "ok": false, "error": "not the geometry owner"}));
        let release = fake.read();
        assert_eq!(release["cmd"], "release-attached-view-size");
        let claim = fake.read();
        assert_eq!(claim["cmd"], "resize-attached-view", "a claim reports first");
        let claim = fake.read();
        assert_eq!(claim["cmd"], "set-client-sizing");
        let detach = fake.read();
        assert_eq!(detach["cmd"], "detach-attached-view");
        assert_eq!(detach["lease"], "lease-1");
        assert!(fake.at_eof(), "detach closes the connection and sends nothing else");
    });
    let (sink, rx) = Recorder::new();
    let mut req = request("gen-1");
    req.claim_geometry = true;
    let attachment = attacher(&path).attach(req, sink).expect("attach");
    assert!(matches!(next(&rx), Seen::Replay { .. }));
    let shared = std::sync::Arc::new(attachment);
    let input = {
        let shared = shared.clone();
        thread::spawn(move || shared.write(b"ls\r").expect("write"))
    };
    input.join().unwrap();
    shared.resize(CellSize::new(120, 40)).unwrap();
    shared.resize(CellSize::new(120, 40)).unwrap(); // deduplicated
    assert_eq!(next(&rx), Seen::Item("rejected resize-attached-view".into()));
    shared.release_geometry().unwrap();
    shared.claim_geometry(Some(CellSize::new(120, 40))).unwrap();
    shared.detach();
    shared.detach(); // idempotent
    assert_eq!(next(&rx), Seen::Ended(AttachEnd::Released));
    assert_eq!(shared.write(b"x"), Err(AttachError::Closed));
    finish(path, server);
}

#[test]
fn daemon_attach_drop_detaches_without_waiting_for_the_reader() {
    let (path, server) = spawn(|listener| {
        let mut fake = Fake::accept(&listener);
        fake.accept_attach("gen-1");
        assert_eq!(fake.read()["cmd"], "detach-attached-view");
        assert!(fake.at_eof());
    });
    let (sink, rx) = Recorder::new();
    let attachment = attacher(&path).attach(request("gen-1"), sink).expect("attach");
    assert!(matches!(next(&rx), Seen::Replay { .. }));
    drop(attachment);
    assert_eq!(next(&rx), Seen::Ended(AttachEnd::Released));
    finish(path, server);
}

#[test]
fn daemon_attach_kick_is_replaced_and_never_reattaches() {
    let (path, server) = spawn(|listener| {
        let mut fake = Fake::accept(&listener);
        fake.accept_attach("gen-1");
        fake.write(json!({"event": "detached", "surface": 7, "reason": "disconnected-by"}));
        let _ = fake.at_eof();
    });
    let (sink, rx) = Recorder::new();
    let attacher = attacher(&path);
    let attachment = attacher.attach(request("gen-1"), sink).expect("attach");
    assert!(matches!(next(&rx), Seen::Replay { .. }));
    assert_eq!(next(&rx), Seen::Ended(AttachEnd::Replaced));
    let (sink, _) = Recorder::new();
    let again =
        reattach(&attacher, &AttachEnd::Replaced, request("gen-1"), None, Duration::ZERO, sink);
    assert_eq!(again.err(), Some(AttachEnd::Replaced));
    drop(attachment);
    finish(path, server);
}

#[test]
fn daemon_attach_refused_identity_is_rejected_and_reattach_reports_terminal_gone() {
    let (path, server) = spawn(|listener| {
        for _ in 0..2 {
            let mut fake = Fake::accept(&listener);
            let attach = fake.handshake("gen-1");
            fake.write(json!({"id": attach["id"], "ok": false,
                              "error": "terminal identity does not match"}));
        }
    });
    let attacher = attacher(&path);
    let (sink, _) = Recorder::new();
    let error = attacher.attach(request("gen-1"), sink).err().expect("refused");
    assert!(matches!(&error, AttachError::Rejected(m) if m.contains("identity")), "{error:?}");
    let lost = AttachEnd::from_end(EndReason::Overflow);
    assert_eq!(lost.reattach(), Reattach::Now);
    let (sink, _) = Recorder::new();
    let again = reattach(&attacher, &lost, request("gen-1"), None, Duration::ZERO, sink);
    assert!(matches!(again.err(), Some(AttachEnd::TerminalGone(_))));
    finish(path, server);
}

#[test]
fn daemon_attach_host_shutdown_waits_for_the_mirror_generation_then_reattaches_into_a_fresh_replay()
{
    let (path, server) = spawn(|listener| {
        let mut fake = Fake::accept(&listener);
        fake.accept_attach("gen-1");
        fake.write(json!({"event": "detached", "surface": 7, "reason": "host-shutdown"}));
        drop(fake);
        let mut fake = Fake::accept(&listener);
        let attach = fake.handshake("gen-2");
        assert_eq!(attach["expected_generation"], "gen-2", "reattach uses the resolved generation");
        fake.write(vt_state("vt-state", 80, 24, b"scrollback", b""));
        fake.reply(&attach, json!({"lease": "lease-2"}));
        assert_eq!(fake.read()["cmd"], "detach-attached-view");
    });
    let watch = MirrorWatch::new();
    watch.update(Some("gen-1".into()), [terminal()]);
    let attacher = attacher(&path);
    let (sink, rx) = Recorder::new();
    let first = attacher.attach(request("gen-1"), sink).expect("attach");
    assert!(matches!(next(&rx), Seen::Replay { .. }));
    let Seen::Ended(end) = next(&rx) else { panic!("ended") };
    assert_eq!(end.reattach(), Reattach::AfterGenerationResolves);
    drop(first);

    let resolver = {
        let watch = watch.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(100));
            watch.update(Some("gen-2".into()), [terminal()]);
        })
    };
    let (sink, rx) = Recorder::new();
    let second =
        reattach(&attacher, &end, request("gen-1"), Some(&watch), Duration::from_secs(5), sink)
            .expect("reattached");
    resolver.join().unwrap();
    assert_eq!(
        next(&rx),
        Seen::Replay { cols: 80, rows: 24, data: b"scrollback".to_vec(), pending: Vec::new() },
        "a reattach starts with a replay for a fresh surface"
    );
    drop(second);
    finish(path, server);
}

#[test]
fn daemon_attach_mirror_watch_resolves_created_terminals_and_reports_gone_timeout_and_close() {
    let watch = MirrorWatch::new();
    let term = terminal();
    assert_eq!(
        watch.wait_for_new_generation(&term, "gen-1", Duration::from_millis(50)),
        GenerationWait::TimedOut
    );
    let creator = {
        let watch = watch.clone();
        let term = term.clone();
        thread::spawn(move || {
            thread::sleep(Duration::from_millis(50));
            watch.update(Some("gen-1".into()), [term]);
        })
    };
    assert_eq!(
        watch.wait_for_terminal(&term, Duration::from_secs(5)),
        GenerationWait::Resolved("gen-1".into()),
        "a created terminal resolves once the mirror has it"
    );
    creator.join().unwrap();
    assert_eq!(watch.generation_of(&term).as_deref(), Some("gen-1"));
    watch.update(Some("gen-2".into()), []);
    assert_eq!(watch.generation_of(&term), None);
    assert_eq!(
        watch.wait_for_new_generation(&term, "gen-1", Duration::from_secs(1)),
        GenerationWait::Gone
    );
    let waiter = {
        let watch = watch.clone();
        thread::spawn(move || {
            watch.wait_for_new_generation(&term, "gen-2", Duration::from_secs(10))
        })
    };
    thread::sleep(Duration::from_millis(50));
    watch.close();
    assert_eq!(waiter.join().unwrap(), GenerationWait::Closed);
}

#[test]
fn daemon_attach_unsupported_attacher_refuses() {
    let (sink, _) = Recorder::new();
    let result = cmux_daemon_client::attach::UnsupportedAttacher.attach(request("g"), sink);
    assert_eq!(result.err(), Some(AttachError::Unsupported));
}

#[test]
fn daemon_attach_cursor_restore_follows_cmux_next() {
    use cmux_daemon_client::attach::cursor_restore;
    let replay = |colors: Value| -> Replay {
        Replay {
            surface: 7,
            cols: 1,
            rows: 1,
            data: Vec::new(),
            pending: Vec::new(),
            colors: Some(serde_json::from_value(colors).unwrap()),
            kitty_image_aliases: Vec::new(),
            kitty_graphics_state: None,
        }
    };
    let base = json!({"fg": null, "bg": null, "selection_bg": null, "selection_fg": null});
    let mut bar = base.clone();
    bar["cursor_style"] = json!("bar");
    bar["cursor_blink"] = json!(false);
    assert_eq!(cursor_restore(&replay(bar), "block", None), b"\x1b[6 q");
    let mut block = base.clone();
    block["cursor_style"] = json!("block");
    assert!(
        cursor_restore(&replay(block), "block", None).is_empty(),
        "the default shape is skipped"
    );
    assert!(cursor_restore(&replay(base), "block", None).is_empty(), "no shape, no restore");
}
