//! `cmux::raw::ByteAttachment` against a scripted protocol-v12 server.
//!
//! Each test runs a fake daemon on a private Unix socket. The fake reads the
//! exact request lines the SDK writes and answers with v12 responses and
//! attach events, so these tests pin the wire contract the real daemon
//! expects (`spec/commands.md` attach-surface, send, resize-attached-view,
//! release-attached-view-size, detach-attached-view, set-client-sizing).

use base64::Engine as _;
use base64::engine::general_purpose::STANDARD;
use cmux::TerminalId;
use cmux::raw::{
    AttachOptions, AttachTarget, AttachmentItem, BYTE_ATTACHMENT_CAPABILITIES, ByteAttachment,
    ByteAttachmentReader, ByteAttachmentWriter, CellSize, ClientConfig, ClientIdentity,
    DetachReason, EndReason, Error, Reattach,
};
use serde_json::{Value, json};
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::PathBuf;
use std::sync::atomic::{AtomicU64, Ordering};
use std::thread::{self, JoinHandle};
use std::time::{Duration, Instant};

const TERMINAL: &str = "term_00000000000000000000000000000008";
const SERVER_CAPABILITIES: &[&str] = &[
    "attach-initial-size",
    "view-attachment-lease-v1",
    "view-attachment-detach-v1",
    "attach-identity-v1",
    "terminal-pending-sequence-v1",
    "shared-sizing-v1",
];

static NEXT_SOCKET: AtomicU64 = AtomicU64::new(1);

fn socket_path() -> PathBuf {
    std::env::temp_dir().join(format!(
        "cmux-sdk-byte-attach-{}-{}.sock",
        std::process::id(),
        NEXT_SOCKET.fetch_add(1, Ordering::Relaxed)
    ))
}

fn config(path: &PathBuf) -> ClientConfig {
    ClientConfig::from_socket_path(path).with_timeout(Duration::from_secs(5))
}

fn b64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

fn unb64(value: &Value) -> Vec<u8> {
    STANDARD.decode(value.as_str().expect("base64 string")).expect("valid base64")
}

/// One accepted connection of the fake daemon.
struct Fake {
    stream: UnixStream,
    reader: BufReader<UnixStream>,
}

impl Fake {
    fn new(stream: UnixStream) -> Self {
        stream.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        let reader = BufReader::new(stream.try_clone().unwrap());
        Self { stream, reader }
    }

    fn read(&mut self) -> Value {
        let mut line = String::new();
        let read = self.reader.read_line(&mut line).expect("fake daemon read");
        assert_ne!(read, 0, "client closed the connection before the expected request");
        serde_json::from_str(&line).expect("request is one JSON line")
    }

    /// True when the client closed its side without sending another request.
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

    fn reject(&mut self, request: &Value, message: &str) {
        self.write(json!({"id": request["id"], "ok": false, "error": message}));
    }

    /// Answers `identify` and `set-client-info`, in that order, and returns
    /// the `set-client-info` request.
    fn handshake(&mut self, protocol: u32, capabilities: &[&str]) -> Value {
        let identify = self.read();
        assert_eq!(identify["cmd"], "identify");
        let info = self.read();
        assert_eq!(info["cmd"], "set-client-info");
        self.reply(
            &identify,
            json!({
                "app": "cmux-tui", "version": "0.1.0", "protocol": protocol,
                "capabilities": capabilities, "session": "main", "pid": 1,
                "registry_id": "reg", "generation": "gen-1", "daemon_handoff": 1,
                "terminal_revision": 1
            }),
        );
        self.reply(&info, json!({}));
        info
    }

    /// Full successful open: handshake, then the `vt-state` before the
    /// attach reply, as the daemon orders it. Returns the attach request.
    fn accept_attach(&mut self, surface: u64) -> Value {
        self.handshake(12, SERVER_CAPABILITIES);
        let attach = self.read();
        assert_eq!(attach["cmd"], "attach-surface");
        self.write(vt_state(surface, b"\x1bcprompt$ ", b"\x1b["));
        self.reply(&attach, json!({"lease": "lease-1", "participant": "c1"}));
        attach
    }
}

fn vt_state(surface: u64, data: &[u8], pending: &[u8]) -> Value {
    json!({
        "event": "vt-state", "surface": surface, "cols": 80, "rows": 24,
        "data": b64(data), "pending": b64(pending),
        "colors": {"fg": "#d8d9da", "bg": "#131415", "cursor": null,
                   "selection_bg": null, "selection_fg": null,
                   "cursor_style": "bar", "cursor_blink": false}
    })
}

fn spawn(server: impl FnOnce(UnixListener) + Send + 'static) -> (PathBuf, JoinHandle<()>) {
    let path = socket_path();
    let listener = UnixListener::bind(&path).unwrap();
    (path, thread::spawn(move || server(listener)))
}

fn spawn_one(server: impl FnOnce(Fake) + Send + 'static) -> (PathBuf, JoinHandle<()>) {
    spawn(move |listener| {
        let (stream, _) = listener.accept().unwrap();
        server(Fake::new(stream));
    })
}

fn open_surface(path: &PathBuf, options: AttachOptions) -> ByteAttachment {
    ByteAttachment::open(&config(path), AttachTarget::Surface(7), CellSize::new(80, 24), options)
        .expect("open succeeds")
}

fn next(reader: &mut ByteAttachmentReader) -> AttachmentItem {
    reader.recv_timeout(Duration::from_secs(5)).expect("attachment item")
}

fn finish(path: PathBuf, server: JoinHandle<()>) {
    server.join().expect("fake daemon assertions");
    let _ = std::fs::remove_file(path);
}

#[test]
fn byte_attachment_set_client_info_with_the_lease_capability_precedes_attach_on_one_connection() {
    let (path, server) = spawn(|listener| {
        let (stream, _) = listener.accept().unwrap();
        let mut fake = Fake::new(stream);
        let info = fake.handshake(12, SERVER_CAPABILITIES);
        let advertised: Vec<&str> =
            info["capabilities"].as_array().unwrap().iter().map(|v| v.as_str().unwrap()).collect();
        assert_eq!(advertised, BYTE_ATTACHMENT_CAPABILITIES);
        assert!(advertised.contains(&"view-attachment-lease-v1"));
        assert_eq!(info["kind"], "frontend");
        assert_eq!(info["name"], "cmux-browser");
        assert_eq!(info["device_kind"], "browser");
        assert_eq!(info["device_name"], "Studio");
        assert!(info.get("user_id").is_none(), "unset identity fields are omitted");
        let attach = fake.read();
        assert_eq!(attach["cmd"], "attach-surface");
        assert_eq!(attach["mode"], "bytes");
        assert_eq!(attach["surface"], 7);
        assert_eq!((attach["cols"].as_u64(), attach["rows"].as_u64()), (Some(80), Some(24)));
        assert!(attach.get("expected_terminal_id").is_none());
        fake.write(vt_state(7, b"\x1bcprompt$ ", b"\x1b["));
        fake.reply(&attach, json!({"lease": "lease-1", "participant": "c1"}));
        listener.set_nonblocking(true).unwrap();
        thread::sleep(Duration::from_millis(100));
        assert_eq!(
            listener.accept().map_err(|error| error.kind()).err(),
            Some(ErrorKind::WouldBlock),
            "the attachment must use exactly one connection"
        );
        assert!(fake.at_eof());
    });
    let options = AttachOptions {
        client: ClientIdentity {
            name: Some("cmux-browser".into()),
            device_kind: Some("browser".into()),
            device_name: Some("Studio".into()),
            ..ClientIdentity::default()
        },
        ..AttachOptions::default()
    };
    let ByteAttachment { writer, mut reader, info } = open_surface(&path, options);
    assert_eq!(info.surface, 7);
    assert_eq!(info.lease, "lease-1");
    assert_eq!(info.participant.as_deref(), Some("c1"));
    assert_eq!(info.generation, "gen-1");
    assert_eq!(info.server.protocol, 12);
    assert_eq!(writer.surface(), 7);
    assert_eq!(writer.lease(), "lease-1");
    let AttachmentItem::VtState(replay) = next(&mut reader) else { panic!("vt-state first") };
    assert_eq!((replay.surface, replay.cols, replay.rows), (7, 80, 24));
    assert_eq!(replay.data, b"\x1bcprompt$ ");
    assert_eq!(replay.pending, b"\x1b[");
    assert!(replay.colors.is_some());
    drop(reader);
    drop(writer);
    finish(path, server);
}

#[test]
fn byte_attachment_identity_target_omits_the_surface_and_resolves_it_from_vt_state() {
    let (path, server) = spawn_one(|mut fake| {
        fake.handshake(12, SERVER_CAPABILITIES);
        let attach = fake.read();
        assert!(attach.get("surface").is_none());
        assert_eq!(attach["expected_terminal_id"], TERMINAL);
        assert_eq!(attach["expected_generation"], "gen-1");
        fake.write(vt_state(42, b"x", b""));
        fake.reply(&attach, json!({"lease": "lease-9"}));
        let send = fake.read();
        assert_eq!(send["cmd"], "send");
        assert_eq!(send["surface"], 42);
    });
    let target = AttachTarget::Terminal {
        id: TerminalId::parse(TERMINAL).unwrap(),
        generation: "gen-1".to_string(),
    };
    let ByteAttachment { writer, mut reader, info } =
        ByteAttachment::open(&config(&path), target, CellSize::new(80, 24), Default::default())
            .unwrap();
    assert_eq!(info.surface, 42);
    assert_eq!(writer.surface(), 42);
    let AttachmentItem::VtState(replay) = next(&mut reader) else { panic!("vt-state first") };
    assert!(replay.pending.is_empty());
    writer.send_bytes(b"a").unwrap();
    finish(path, server);
}

#[test]
fn byte_attachment_missing_server_capabilities_fail_before_attach_with_typed_errors() {
    for missing in ["view-attachment-lease-v1", "view-attachment-detach-v1", "attach-initial-size"]
    {
        let capabilities: Vec<&str> =
            SERVER_CAPABILITIES.iter().copied().filter(|c| *c != missing).collect();
        let (path, server) = spawn_one(move |mut fake| {
            fake.handshake(12, &capabilities);
            assert!(fake.at_eof(), "no attach-surface after a missing capability");
        });
        let error = ByteAttachment::open(
            &config(&path),
            AttachTarget::Surface(7),
            CellSize::new(80, 24),
            Default::default(),
        )
        .err()
        .expect("open must fail");
        assert!(
            matches!(error, Error::MissingCapability { command: "attach-surface", capability } if capability == missing),
            "{missing}: {error:?}"
        );
        finish(path, server);
    }
}

#[test]
fn byte_attachment_identity_target_requires_the_identity_capability() {
    let (path, server) = spawn_one(|mut fake| {
        let capabilities: Vec<&str> =
            SERVER_CAPABILITIES.iter().copied().filter(|c| *c != "attach-identity-v1").collect();
        fake.handshake(12, &capabilities);
        assert!(fake.at_eof());
    });
    let target = AttachTarget::Terminal {
        id: TerminalId::parse(TERMINAL).unwrap(),
        generation: "gen-1".to_string(),
    };
    let error =
        ByteAttachment::open(&config(&path), target, CellSize::new(80, 24), Default::default())
            .err()
            .unwrap();
    assert!(matches!(error, Error::MissingCapability { capability: "attach-identity-v1", .. }));
    finish(path, server);
}

#[test]
fn byte_attachment_old_protocol_is_rejected() {
    let (path, server) = spawn_one(|mut fake| {
        fake.handshake(11, SERVER_CAPABILITIES);
        assert!(fake.at_eof());
    });
    let error = ByteAttachment::open(
        &config(&path),
        AttachTarget::Surface(7),
        CellSize::new(80, 24),
        Default::default(),
    )
    .err()
    .unwrap();
    assert!(matches!(error, Error::ProtocolVersion { required: 12, actual: 11, .. }));
    finish(path, server);
}

#[test]
fn byte_attachment_attach_reply_without_a_lease_is_rejected_and_the_connection_closed() {
    let (path, server) = spawn_one(|mut fake| {
        fake.handshake(12, SERVER_CAPABILITIES);
        let attach = fake.read();
        fake.write(vt_state(7, b"", b""));
        fake.reply(&attach, json!({}));
        assert!(fake.at_eof());
    });
    let error = ByteAttachment::open(
        &config(&path),
        AttachTarget::Surface(7),
        CellSize::new(80, 24),
        Default::default(),
    )
    .err()
    .unwrap();
    assert!(matches!(error, Error::UnexpectedEnvelope(_)), "{error:?}");
    finish(path, server);
}

#[test]
fn byte_attachment_attach_rejection_is_a_command_error() {
    let (path, server) = spawn_one(|mut fake| {
        fake.handshake(12, SERVER_CAPABILITIES);
        let attach = fake.read();
        fake.reject(&attach, "expected generation gen-0 does not match gen-1");
    });
    let error = ByteAttachment::open(
        &config(&path),
        AttachTarget::Surface(7),
        CellSize::new(80, 24),
        Default::default(),
    )
    .err()
    .unwrap();
    assert!(
        matches!(&error, Error::Command { command, message, .. }
            if command == "attach-surface" && message.contains("gen-0")),
        "{error:?}"
    );
    finish(path, server);
}

#[test]
fn byte_attachment_handshake_is_bounded_by_the_config_timeout() {
    let (path, server) = spawn_one(|mut fake| {
        let _identify = fake.read();
        let _info = fake.read();
        assert!(fake.at_eof(), "client gives up and closes");
    });
    let started = Instant::now();
    let error = ByteAttachment::open(
        &ClientConfig::from_socket_path(&path).with_timeout(Duration::from_millis(300)),
        AttachTarget::Surface(7),
        CellSize::new(80, 24),
        Default::default(),
    )
    .err()
    .unwrap();
    assert!(matches!(error, Error::Timeout(_)), "{error:?}");
    assert!(started.elapsed() < Duration::from_secs(3));
    finish(path, server);
}

#[test]
fn byte_attachment_claim_geometry_option_claims_after_the_attach_reply() {
    let (path, server) = spawn_one(|mut fake| {
        fake.accept_attach(7);
        let claim = fake.read();
        assert_eq!(claim["cmd"], "set-client-sizing");
        assert_eq!(claim["surface"], 7);
        assert_eq!(claim["enabled"], true);
        assert_eq!(claim["exclusive"], true);
        assert!(claim.get("client").is_none());
        fake.reply(&claim, json!({}));
    });
    let attachment =
        open_surface(&path, AttachOptions { claim_geometry: true, ..Default::default() });
    drop(attachment);
    finish(path, server);
}

#[test]
fn byte_attachment_writer_commands_from_another_thread_use_the_lease_in_call_order() {
    let (path, server) = spawn_one(|mut fake| {
        fake.accept_attach(7);
        let mut ids = Vec::new();
        let mut expect = |fake: &mut Fake, cmd: &str| {
            let request = fake.read();
            assert_eq!(request["cmd"], cmd, "{request}");
            ids.push(request["id"].clone());
            request
        };
        let send = expect(&mut fake, "send");
        assert_eq!((send["surface"].as_u64(), unb64(&send["bytes"])), (Some(7), b"ls\r".to_vec()));
        assert!(send.get("paste").is_none_or(|paste| paste == false));
        let resize = expect(&mut fake, "resize-attached-view");
        assert_eq!(resize["lease"], "lease-1");
        assert_eq!((resize["cols"].as_u64(), resize["rows"].as_u64()), (Some(100), Some(30)));
        // The duplicate resize is skipped; claim reports first, then claims.
        let report = expect(&mut fake, "resize-attached-view");
        assert_eq!((report["cols"].as_u64(), report["rows"].as_u64()), (Some(100), Some(30)));
        let claim = expect(&mut fake, "set-client-sizing");
        assert_eq!(
            (claim["enabled"].clone(), claim["exclusive"].clone()),
            (json!(true), json!(true))
        );
        let release = expect(&mut fake, "release-attached-view-size");
        assert_eq!(
            (release["surface"].as_u64(), release["lease"].as_str()),
            (Some(7), Some("lease-1"))
        );
        // Release clears the dedupe, so the same size is reported again.
        expect(&mut fake, "resize-attached-view");
        let detach = expect(&mut fake, "detach-attached-view");
        assert_eq!(detach["lease"], "lease-1");
        let unique: std::collections::HashSet<String> = ids.iter().map(Value::to_string).collect();
        assert_eq!(unique.len(), ids.len(), "every request id is unique");
        assert!(fake.at_eof(), "detach closes the connection after its request");
    });
    let ByteAttachment { writer, mut reader, .. } = open_surface(&path, Default::default());
    let _ = next(&mut reader);
    let worker = writer.clone();
    thread::spawn(move || {
        worker.send_bytes(b"ls\r").unwrap();
        worker.send_bytes(b"").unwrap();
        worker.resize(CellSize::new(100, 30)).unwrap();
        worker.resize(CellSize::new(100, 30)).unwrap();
        worker.claim_geometry(None).unwrap();
        worker.release_geometry().unwrap();
        worker.resize(CellSize::new(100, 30)).unwrap();
        worker.detach().unwrap();
        worker.detach().unwrap();
    })
    .join()
    .unwrap();
    assert_eq!(next(&mut reader), AttachmentItem::Ended(EndReason::ClosedByClient));
    assert!(matches!(reader.recv(), Err(Error::Closed)));
    assert!(matches!(writer.send_bytes(b"late"), Err(Error::Closed)));
    finish(path, server);
}

#[test]
fn byte_attachment_send_bytes_splits_large_input_into_ordered_frames() {
    let payload: Vec<u8> = (0..(2 * 1024 * 1024 + 512 * 1024)).map(|i| (i % 251) as u8).collect();
    let expected = payload.clone();
    let (path, server) = spawn_one(move |mut fake| {
        fake.accept_attach(7);
        let mut received = Vec::new();
        let mut frames = 0;
        while received.len() < expected.len() {
            let send = fake.read();
            assert_eq!(send["cmd"], "send");
            let chunk = unb64(&send["bytes"]);
            assert!(chunk.len() <= 1024 * 1024, "frame carries at most 1 MiB raw");
            received.extend(chunk);
            frames += 1;
        }
        assert_eq!(frames, 3);
        assert_eq!(received, expected);
    });
    let ByteAttachment { writer, reader, .. } = open_surface(&path, Default::default());
    writer.send_bytes(&payload).unwrap();
    finish(path, server);
    drop(reader);
}

#[test]
fn byte_attachment_attach_events_decode_in_wire_order() {
    let (path, server) = spawn_one(|mut fake| {
        fake.accept_attach(7);
        fake.write(json!({"event": "output", "surface": 7, "data": b64(b"hello"),
                          "colors": {"fg": "#ffffff", "bg": null, "selection_bg": null, "selection_fg": null}}));
        fake.write(json!({"event": "output", "surface": 8, "data": b64(b"other surface")}));
        fake.write(json!({"event": "resized", "surface": 7, "cols": 100, "rows": 30,
                          "replay": b64(b"R"), "pending": b64(b"\x1b")}));
        fake.write(
            json!({"event": "resized", "surface": 7, "cols": 90, "rows": 20, "data": b64(b"L")}),
        );
        fake.write(
            json!({"event": "colors-changed", "surface": 7, "fg": "#000000", "bg": "#ffffff",
                          "selection_bg": null, "selection_fg": null,
                          "overrides": {"fg": "#111111", "bg": null, "cursor": null}}),
        );
        fake.write(
            json!({"event": "scroll-changed", "surface": 7, "offset": 12, "at_bottom": false}),
        );
        fake.write(json!({"event": "size-state", "surface": 7, "state": {
            "generation": 3, "cols": 100, "rows": 30, "reason": "latest", "owners": ["c1"],
            "policy": {"mode": "latest", "priority": [], "fixed": null}, "participants": []}}));
        fake.write(json!({"event": "notification", "surface": 7, "title": "t"}));
        fake.write(json!({"event": "detached", "surface": 7, "scope": "view",
                          "reason": "disconnected-by", "by": {"display_name": "Maya"}}));
        fake.write(json!({"event": "detached", "surface": 7, "reason": "disconnected-by",
                          "by": {"display_name": "Maya", "device_name": "Mac Studio"}}));
    });
    let ByteAttachment { mut reader, writer, .. } = open_surface(&path, Default::default());
    assert!(matches!(next(&mut reader), AttachmentItem::VtState(_)));
    let AttachmentItem::Output { data, colors } = next(&mut reader) else { panic!("output") };
    assert_eq!(data, b"hello");
    assert!(colors.is_some());
    let AttachmentItem::Resized(replay) = next(&mut reader) else { panic!("resized") };
    assert_eq!(
        (replay.cols, replay.rows, replay.data, replay.pending),
        (100, 30, b"R".to_vec(), b"\x1b".to_vec())
    );
    let AttachmentItem::Resized(legacy) = next(&mut reader) else { panic!("legacy resized") };
    assert_eq!((legacy.cols, legacy.data), (90, b"L".to_vec()));
    let AttachmentItem::ColorsChanged(colors) = next(&mut reader) else { panic!("colors") };
    assert!(colors.overrides.is_some());
    assert_eq!(next(&mut reader), AttachmentItem::ScrollChanged { offset: 12, at_bottom: false });
    let AttachmentItem::SizeState(state) = next(&mut reader) else { panic!("size-state") };
    assert_eq!((state.generation, state.cols, state.rows), (3, 100, 30));
    let AttachmentItem::Other { event, .. } = next(&mut reader) else { panic!("other") };
    assert_eq!(event, "notification");
    let AttachmentItem::ViewDetached { actor } = next(&mut reader) else { panic!("view detach") };
    assert!(actor.is_some());
    let AttachmentItem::Ended(end) = next(&mut reader) else { panic!("end") };
    let EndReason::Detached { reason, actor } = &end else { panic!("detached end: {end:?}") };
    assert_eq!(*reason, Some(DetachReason::DisconnectedBy));
    assert!(actor.is_some());
    assert_eq!(end.reattach(), Reattach::Never);
    assert!(matches!(reader.recv(), Err(Error::Closed)));
    assert!(reader.next().is_none(), "the iterator stops after the end");
    assert!(matches!(writer.send_bytes(b"x"), Err(Error::Closed)));
    finish(path, server);
}

#[test]
fn byte_attachment_end_reasons_map_to_the_spec_reattach_policy() {
    let detached = |reason| EndReason::Detached { reason, actor: None };
    assert_eq!(detached(Some(DetachReason::Network)).reattach(), Reattach::Now);
    // Absent or unrecognized reasons mean network (spec events.md detached).
    assert_eq!(detached(None).reattach(), Reattach::Now);
    assert_eq!(
        detached(Some(DetachReason::HostShutdown)).reattach(),
        Reattach::AfterGenerationResolves
    );
    assert_eq!(detached(Some(DetachReason::DisconnectedBy)).reattach(), Reattach::Never);
    assert_eq!(EndReason::Overflow.reattach(), Reattach::Now);
    assert_eq!(EndReason::ConnectionLost("eof".into()).reattach(), Reattach::Now);
    assert_eq!(EndReason::ClosedByClient.reattach(), Reattach::Never);
}

#[test]
fn byte_attachment_absent_detach_reason_and_overflow_end_the_stream() {
    for (event, expected) in [
        (
            json!({"event": "detached", "surface": 7}),
            EndReason::Detached { reason: None, actor: None },
        ),
        (
            json!({"event": "overflow", "error": "behind", "scope": "surface", "surface": 7}),
            EndReason::Overflow,
        ),
    ] {
        let (path, server) = spawn_one(move |mut fake| {
            fake.accept_attach(7);
            fake.write(event);
        });
        // Keep the writer: dropping its last clone detaches the view.
        let ByteAttachment { mut reader, writer: _writer, .. } =
            open_surface(&path, Default::default());
        let _ = next(&mut reader);
        assert_eq!(next(&mut reader), AttachmentItem::Ended(expected));
        finish(path, server);
    }
}

#[test]
fn byte_attachment_eof_ends_with_connection_lost_exactly_once() {
    let (path, server) = spawn_one(|mut fake| {
        fake.accept_attach(7);
    });
    let ByteAttachment { mut reader, writer, .. } = open_surface(&path, Default::default());
    let _ = next(&mut reader);
    let AttachmentItem::Ended(EndReason::ConnectionLost(_)) = next(&mut reader) else {
        panic!("connection lost")
    };
    assert!(matches!(reader.recv(), Err(Error::Closed)));
    assert!(matches!(writer.resize(CellSize::new(10, 10)), Err(Error::Closed)));
    finish(path, server);
}

#[test]
fn byte_attachment_rejected_writer_command_is_reported_and_the_stream_continues() {
    let (path, server) = spawn_one(|mut fake| {
        fake.accept_attach(7);
        let resize = fake.read();
        fake.reject(&resize, "lease lease-1 is retired");
        let send = fake.read();
        fake.reply(&send, json!({}));
        fake.write(json!({"event": "output", "surface": 7, "data": b64(b"after")}));
    });
    let ByteAttachment { mut reader, writer, .. } = open_surface(&path, Default::default());
    let _ = next(&mut reader);
    writer.resize(CellSize::new(120, 40)).unwrap();
    writer.send_bytes(b"x").unwrap();
    assert_eq!(
        next(&mut reader),
        AttachmentItem::CommandRejected {
            command: "resize-attached-view",
            message: "lease lease-1 is retired".to_string()
        }
    );
    let AttachmentItem::Output { data, .. } = next(&mut reader) else { panic!("output") };
    assert_eq!(data, b"after");
    finish(path, server);
}

#[test]
fn byte_attachment_write_deadline_poisons_the_connection() {
    let (release, hold) = std::sync::mpsc::channel::<()>();
    let (path, server) = spawn_one(move |mut fake| {
        fake.accept_attach(7);
        // Stop reading so the client's socket buffer fills.
        let _ = hold.recv_timeout(Duration::from_secs(20));
    });
    let options =
        AttachOptions { write_timeout: Some(Duration::from_millis(200)), ..Default::default() };
    let ByteAttachment { mut reader, writer, .. } = open_surface(&path, options);
    let _ = next(&mut reader);
    let chunk = vec![b'x'; 1024 * 1024];
    let started = Instant::now();
    let error = loop {
        match writer.send_bytes(&chunk) {
            Ok(()) => assert!(started.elapsed() < Duration::from_secs(10), "writes never blocked"),
            Err(error) => break error,
        }
    };
    assert!(matches!(error, Error::Timeout(_)), "{error:?}");
    assert!(matches!(writer.send_bytes(b"x"), Err(Error::Closed)));
    let AttachmentItem::Ended(EndReason::ConnectionLost(_)) = next(&mut reader) else {
        panic!("poisoned connection ends the reader")
    };
    release.send(()).unwrap();
    finish(path, server);
}

#[test]
fn byte_attachment_recv_timeout_keeps_a_partial_frame() {
    let (step, wait) = std::sync::mpsc::channel::<()>();
    let (path, server) = spawn_one(move |mut fake| {
        fake.accept_attach(7);
        let line = json!({"event": "output", "surface": 7, "data": b64(b"split")}).to_string();
        let (head, tail) = line.split_at(line.len() / 2);
        fake.stream.write_all(head.as_bytes()).unwrap();
        wait.recv().unwrap();
        writeln!(fake.stream, "{tail}").unwrap();
    });
    let ByteAttachment { mut reader, writer: _writer, .. } =
        open_surface(&path, Default::default());
    let _ = next(&mut reader);
    assert!(matches!(reader.recv_timeout(Duration::from_millis(150)), Err(Error::Timeout(_))));
    step.send(()).unwrap();
    let AttachmentItem::Output { data, .. } = next(&mut reader) else { panic!("output") };
    assert_eq!(data, b"split");
    finish(path, server);
}

#[test]
fn byte_attachment_closer_unblocks_recv_from_another_thread() {
    let (path, server) = spawn_one(|mut fake| {
        fake.accept_attach(7);
        assert!(fake.at_eof());
    });
    let ByteAttachment { mut reader, writer, .. } = open_surface(&path, Default::default());
    let _ = next(&mut reader);
    let closer = reader.closer();
    let blocked = thread::spawn(move || reader.recv());
    thread::sleep(Duration::from_millis(100));
    closer.close();
    let item = blocked.join().unwrap().unwrap();
    assert_eq!(item, AttachmentItem::Ended(EndReason::ClosedByClient));
    drop(writer);
    finish(path, server);
}

#[test]
fn byte_attachment_dropping_the_last_writer_clone_detaches() {
    let (dropped_one, wait) = std::sync::mpsc::channel::<()>();
    let (path, server) = spawn_one(move |mut fake| {
        fake.accept_attach(7);
        wait.recv().unwrap();
        let detach = fake.read();
        assert_eq!(detach["cmd"], "detach-attached-view", "only the last drop detaches");
    });
    let ByteAttachment { reader, writer, .. } = open_surface(&path, Default::default());
    let clone = writer.clone();
    drop(writer);
    dropped_one.send(()).unwrap();
    drop(clone);
    finish(path, server);
    drop(reader);
}

#[test]
fn byte_attachment_thread_contract_is_enforced_by_the_type_system() {
    fn send_sync_clone<T: Send + Sync + Clone + 'static>() {}
    fn send<T: Send + 'static>() {}
    send_sync_clone::<ByteAttachmentWriter>();
    send::<ByteAttachmentReader>();
    send::<ByteAttachment>();
}
