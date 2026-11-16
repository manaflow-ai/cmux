//! A chat served over a socket pair: `conn::run` with the routing source, the registry and a
//! real actor on a raw file the test appends to.

use super::*;
use crate::chat::source::{self, Chunk, RawSource};
use crate::chat::{ChatConfig, random_u64};
use crate::conn::{self, ConnectionMetrics, MissingChatSource, Role, RouteSource, Source};
use crate::registry::Registry;
use crate::wire::{ChatDelta, ChatOp, Sub as SubRequest, decode_blob};
use acpmux_book::checkpoint::Person;
use acpmux_book::translate::Harness;
use serde_json::{Value, json};
use std::fs;
use std::io::Write as _;
use std::path::{Path, PathBuf};
use std::sync::Mutex;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};

const WAIT: Duration = Duration::from_secs(20);

fn mux(seq: u64, kind: &str, msg: Value) -> String {
    json!({"seq": seq, "at": seq * 1000, "dir": "mux", "kind": kind, "msg": msg}).to_string()
}

fn chunk(seq: u64, text: &str, message: &str) -> String {
    json!({"seq": seq, "at": seq * 1000, "dir": "in", "kind": "agent_message_chunk",
        "msg": {"method": "session/update", "params": {"update": {
            "sessionUpdate": "agent_message_chunk", "messageId": message,
            "content": {"type": "text", "text": text}}}}})
    .to_string()
}

/// An `agent_thought_chunk` of `text`: a thinking row of its own.
fn thought(seq: u64, text: &str, message: &str) -> String {
    json!({"seq": seq, "at": seq * 1000, "dir": "in", "kind": "agent_thought_chunk",
        "msg": {"method": "session/update", "params": {"update": {
            "sessionUpdate": "agent_thought_chunk", "messageId": message,
            "content": {"type": "text", "text": text}}}}})
    .to_string()
}

/// Turn `n`'s opening lines: its prompt and its start. Its seqs are `n * 10 + 1..`.
fn open_turn(n: u64) -> Vec<String> {
    let seq = n * 10;
    vec![
        mux(
            seq + 1,
            "user_message",
            json!({"promptId": format!("p{n}"), "turnId": format!("t{n}"), "text": format!("prompt {n}")}),
        ),
        mux(
            seq + 2,
            "turn_started",
            json!({"turnId": format!("t{n}"), "promptId": format!("p{n}")}),
        ),
    ]
}

/// A whole turn: its prompt, a reply of `text`, and its end.
fn turn(n: u64, text: &str) -> Vec<String> {
    let seq = n * 10;
    let mut lines = open_turn(n);
    lines.push(chunk(seq + 3, text, &format!("m{n}")));
    lines.push(mux(
        seq + 4,
        "turn_result",
        json!({"turnId": format!("t{n}"), "status": "completed"}),
    ));
    lines
}

type Factory = Arc<dyn Fn(PathBuf) -> std::io::Result<Box<dyn RawSource>> + Send + Sync>;

fn file_source() -> Factory {
    Arc::new(|raw| source::FileSource::open(&raw).map(|s| Box::new(s) as Box<dyn RawSource>))
}

struct Chat {
    home: tempfile::TempDir,
    raw: PathBuf,
    registry: Registry,
    config: Arc<Mutex<ChatConfig>>,
}

impl Chat {
    fn new(lines: &[String]) -> Self {
        Self::with_source(lines, file_source())
    }

    fn with_source(lines: &[String], factory: Factory) -> Self {
        let home = tempfile::tempdir().unwrap();
        let raw = home.path().join("raw.ndjson");
        fs::write(&raw, lines.iter().map(|line| format!("{line}\n")).collect::<String>()).unwrap();
        let book = home.path().join("book");
        fs::create_dir_all(&book).unwrap();
        let path = raw.clone();
        let mut config = ChatConfig::new("chat", &book, Harness::V1)
            .with_source_factory(Arc::new(move || factory(path.clone())));
        config.hint_poll = Duration::from_millis(2);
        Self { home, raw, registry: Registry::new(), config: Arc::new(Mutex::new(config)) }
    }

    fn book(&self) -> PathBuf {
        self.home.path().join("book")
    }

    fn append(&self, lines: &[String]) {
        let mut file = fs::OpenOptions::new().append(true).open(&self.raw).unwrap();
        for line in lines {
            writeln!(file, "{line}").unwrap();
        }
    }

    fn connect(&self, conn: u64, surfaces: &[&str]) -> Client {
        self.connect_with(conn, surfaces, |route| route)
    }

    fn connect_with(
        &self,
        conn: u64,
        surfaces: &[&str],
        wrap: impl FnOnce(Arc<dyn Source>) -> Arc<dyn Source>,
    ) -> Client {
        let config = self.config.clone();
        let resolve: conn::Resolve = Arc::new(move |id| {
            let config = config.lock().unwrap().clone();
            (id == config.id).then_some(config)
        });
        let route =
            RouteSource::new(Arc::new(MissingChatSource), self.registry.clone(), resolve, conn);
        let source = wrap(Arc::new(route));
        let (client, server) = tokio::io::duplex(4 << 20);
        let (rd, wr) = tokio::io::split(server);
        let surfaces: Vec<String> = surfaces.iter().map(|s| (*s).to_owned()).collect();
        let task =
            tokio::spawn(
                async move { conn::run(rd, wr, source, "test", &surfaces, Role::Local).await },
            );
        Client { io: client, _task: task }
    }
}

struct Client {
    io: DuplexStream,
    _task: tokio::task::JoinHandle<Result<(), conn::ConnError>>,
}

impl Client {
    async fn send(&mut self, request: Value) {
        let frame = Frame::json(FrameKind::Request, &request).unwrap();
        self.io.write_all(&frame.encode()).await.unwrap();
    }

    async fn recv(&mut self) -> Frame {
        tokio::time::timeout(WAIT, async {
            let mut header = [0; 4];
            self.io.read_exact(&mut header).await.unwrap();
            let mut bytes = vec![0; u32::from_be_bytes(header) as usize];
            self.io.read_exact(&mut bytes).await.unwrap();
            let mut encoded = header.to_vec();
            encoded.extend(bytes);
            Frame::from_encoded(&encoded).unwrap()
        })
        .await
        .expect("a frame within the wait")
    }

    async fn hello(&mut self, identity: Option<&str>) {
        let mut params = json!({"clientKind": "test", "protocol": 2});
        if let Some(identity) = identity {
            params["identity"] = identity.into();
        }
        self.send(json!({"method": "hello", "params": params})).await;
        assert_eq!(self.recv().await.kind, FrameKind::Hello);
    }

    async fn sub(&mut self, sid: &str, extra: Value) {
        let mut params = json!({"sid": sid, "stream": "chat:chat"});
        if let (Some(params), Some(extra)) = (params.as_object_mut(), extra.as_object()) {
            params.extend(extra.clone());
        }
        self.send(json!({"method": "sub", "params": params})).await;
    }

    /// Frames until one `pick` takes; the others go to `skipped`.
    async fn until<T>(
        &mut self,
        skipped: &mut Vec<Frame>,
        pick: impl Fn(&Frame) -> Option<T>,
    ) -> T {
        loop {
            let frame = self.recv().await;
            if let Some(value) = pick(&frame) {
                return value;
            }
            skipped.push(frame);
        }
    }

    async fn window(&mut self, sid: &str) -> ChatWindow {
        let sid = sid.to_owned();
        self.until(&mut Vec::new(), |frame| {
            if frame.kind == FrameKind::Error {
                panic!("an error before the window: {}", String::from_utf8_lossy(frame.payload()));
            }
            (frame.kind == FrameKind::Window)
                .then(|| frame.decode_json::<ChatWindow>().unwrap())
                .filter(|window| window.sid == sid)
        })
        .await
    }

    /// The window on `sid` once the book is ready: while the actor books a large chat a
    /// `not_ready` for the sub comes first, and the window follows on the same sid.
    async fn ready_window(&mut self, sid: &str) -> ChatWindow {
        let sid = sid.to_owned();
        self.until(&mut Vec::new(), |frame| {
            if frame.kind == FrameKind::Error {
                let error: Value = frame.decode_json().unwrap();
                assert_eq!(error["code"], "not_ready", "{error}");
                return None;
            }
            (frame.kind == FrameKind::Window)
                .then(|| frame.decode_json::<ChatWindow>().unwrap())
                .filter(|window| window.sid == sid)
        })
        .await
    }

    async fn error(&mut self) -> Value {
        self.until(&mut Vec::new(), |frame| {
            (frame.kind == FrameKind::Error).then(|| frame.decode_json::<Value>().unwrap())
        })
        .await
    }

    /// Returns once a fresh window shows `text`: the actor booked the lines that hold it.
    async fn booked(&mut self, text: &str) {
        loop {
            self.sub("w", json!({})).await;
            let window = self.window("w").await;
            self.send(json!({"method": "unsub", "params": {"sid": "w"}})).await;
            if window.rows.iter().any(|row| row.get().contains(text)) {
                return;
            }
            tokio::time::sleep(Duration::from_millis(20)).await;
        }
    }

    /// An open row's whole body text, read by `blob` a range at a time, as a client reads a
    /// body a resume left out. Frames on `s` met on the way are credited.
    async fn open_body(&mut self, row: u64, edition: u32, consumed: &mut u64) -> String {
        let mut bytes = Vec::new();
        loop {
            let id = format!("b{}", bytes.len());
            self.send(json!({"method": "blob", "params": {"id": id, "stream": "chat:chat",
                "edition": edition, "rowId": row, "start": bytes.len(),
                "len": MAX_BLOB_READ}}))
                .await;
            let frame = loop {
                let frame = self.recv().await;
                match frame.kind {
                    FrameKind::Blob => break frame,
                    FrameKind::Error => panic!("{}", String::from_utf8_lossy(frame.payload())),
                    _ => {
                        *consumed += frame.encoded_len() as u64;
                        self.credit("s", *consumed).await;
                    }
                }
            };
            let (head, piece) = decode_blob(&frame).unwrap();
            bytes.extend_from_slice(piece);
            if piece.is_empty() || bytes.len() as u64 >= head.total {
                break;
            }
        }
        let body: Value = serde_json::from_slice(&bytes).unwrap();
        body["text"].as_str().unwrap().to_owned()
    }

    async fn credit(&mut self, sid: &str, consumed: u64) {
        self.send(json!({"method": "credit", "params": {"sid": sid, "consumed": consumed}})).await;
    }
}

fn row_value(row: &RawJson) -> Value {
    serde_json::from_str(row.get()).unwrap()
}

/// The open reply row's id and its text, from a window.
fn open_reply(window: &ChatWindow) -> Option<(u64, String)> {
    window.open.iter().map(|open| row_value(&open.row)).find_map(|row| {
        (row["kind"] == "text").then(|| {
            (row["id"].as_u64().unwrap(), row["body"]["text"].as_str().unwrap_or("").to_owned())
        })
    })
}

/// Applies a delta's ops to the reply text the client holds.
fn apply(delta: &ChatDelta, row_id: u64, text: &mut String) {
    for op in &delta.ops {
        match op {
            ChatOp::Text { row_id: id, text: piece, .. } if *id == row_id => {
                text.push_str(&serde_json::from_str::<String>(piece.get()).unwrap());
            }
            ChatOp::Row { row, .. } => {
                let row = row_value(row);
                if row["id"] == row_id {
                    *text = row["body"]["text"].as_str().unwrap_or("").to_owned();
                }
            }
            _ => {}
        }
    }
}

fn runtime() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().unwrap()
}

/// Live text held past a frame's worth goes out in frames of at most 256 KB, none lost. The
/// text holds escapes and four-byte characters, so a cut inside either would show. A thought
/// opened after the reply makes the reply an older row, which the translator never cuts: all of
/// its text is one row's, held in one coalesce.
#[test]
fn three_mebibytes_of_live_text_in_one_coalesce_reach_a_subscriber_whole_in_small_frames() {
    runtime().block_on(async {
        let mut lines = open_turn(1);
        lines.push(chunk(13, "start ", "m1"));
        lines.push(thought(14, "thinking", "m1"));
        let chat = Chat::new(&lines);
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        let (row, mut text) = open_reply(&window).expect("the open reply is in the window");
        assert_eq!(text, "start ");
        let piece = "a\"b\\c\n🙂é ".repeat(64 * 1024 / 16);
        let pieces = (3 << 20) / piece.len() + 1;
        let mut full = text.clone();
        let mut appended = Vec::new();
        for n in 0..pieces as u64 {
            appended.push(chunk(15 + n, &piece, "m1"));
            full.push_str(&piece);
        }
        // One write: the actor reads it in a few chunks, well inside one 16 ms coalesce.
        chat.append(&appended);
        let mut consumed = window_bytes(&window);
        let mut largest = 0;
        while text.len() < full.len() {
            let frame = client.recv().await;
            consumed += frame.encoded_len() as u64;
            assert_ne!(frame.kind, FrameKind::Dropped, "a live subscriber was dropped");
            if frame.kind == FrameKind::Delta {
                largest = largest.max(frame.encoded_len());
                let delta: ChatDelta = frame.decode_json().unwrap();
                // Past the credit window the subscriber stops; its resume names the open row
                // with its body left out, which a client reads by `blob`.
                let left_out = delta.ops.iter().any(|op| {
                    matches!(op, ChatOp::Row { row: r, body_len: Some(_), .. }
                        if row_value(r)["id"] == row)
                });
                if left_out {
                    client.credit("s", consumed).await;
                    text = client.open_body(row, window.edition, &mut consumed).await;
                } else {
                    apply(&delta, row, &mut text);
                }
                assert!(full.starts_with(&text), "the text went wrong at byte {}", text.len());
            }
            client.credit("s", consumed).await;
        }
        assert_eq!(text, full);
        assert!(largest <= MAX_REPLAY_FRAME_BYTES + 512, "a frame of {largest} bytes");
    });
}

#[test]
fn a_person_joining_mid_turn_a_thousand_times_holds_the_whole_reply() {
    runtime().block_on(async {
        let mut lines = open_turn(1);
        lines.push(chunk(13, "w0 ", "m1"));
        let chat = Chat::new(&lines);
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        let mut full = "w0 ".to_owned();
        for n in 1..=1000u64 {
            let sid = format!("s{n}");
            client.sub(&sid, json!({})).await;
            let window = client.window(&sid).await;
            let (row, mut text) = open_reply(&window).expect("the open reply is in the window");
            assert!(full.starts_with(&text), "join {n}: {text:?} is not a prefix of {full:?}");
            let piece = format!("w{n} ");
            chat.append(&[chunk(13 + n, &piece, "m1")]);
            full.push_str(&piece);
            let mut consumed = window_bytes(&window);
            while text != full {
                let frame = client.recv().await;
                consumed += frame.encoded_len() as u64;
                if frame.kind == FrameKind::Delta {
                    let delta: ChatDelta = frame.decode_json().unwrap();
                    if delta.sid == sid {
                        apply(&delta, row, &mut text);
                        assert!(full.starts_with(&text), "join {n}: {text:?} went past {full:?}");
                    }
                }
            }
            client.credit(&sid, consumed).await;
            client.send(json!({"method": "unsub", "params": {"sid": sid}})).await;
        }
    });
}

fn window_bytes(window: &ChatWindow) -> u64 {
    Frame::json(FrameKind::Window, window).unwrap().encoded_len() as u64
}

/// A source whose reads give nothing, not at its end, until the test opens it.
struct Gated {
    inner: Box<dyn RawSource>,
    open: Arc<AtomicBool>,
}

impl RawSource for Gated {
    fn read_chunk(&mut self, place: u64) -> std::io::Result<Chunk> {
        if !self.open.load(Ordering::Acquire) {
            std::thread::sleep(Duration::from_millis(1));
            let stamp = self.inner.stamp();
            return Ok(Chunk::with_stamp(Vec::new(), place, source::byte_places, false, 0, stamp));
        }
        self.inner.read_chunk(place)
    }
    fn holds(&mut self, place: u64) -> std::io::Result<bool> {
        self.inner.holds(place)
    }
    fn hint(&self) -> std::io::Result<u64> {
        self.inner.hint()
    }
    fn sync_through(&mut self, place: u64) -> std::io::Result<()> {
        self.inner.sync_through(place)
    }
    fn identity(&self) -> &[u8] {
        self.inner.identity()
    }
    fn stamp(&self) -> u64 {
        self.inner.stamp()
    }
    fn read_at(&mut self, place: u64, offset: u64, max: usize) -> std::io::Result<source::Piece> {
        self.inner.read_at(place, offset, max)
    }
}

#[test]
fn a_sub_before_the_book_is_ready_gets_not_ready_then_its_window_on_the_same_sid() {
    runtime().block_on(async {
        let open = Arc::new(AtomicBool::new(false));
        let gate = open.clone();
        let chat = Chat::with_source(
            &turn(1, "hello"),
            Arc::new(move |raw| {
                let inner = source::FileSource::open(&raw)?;
                Ok(Box::new(Gated { inner: Box::new(inner), open: gate.clone() })
                    as Box<dyn RawSource>)
            }),
        );
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({"cursor": 0})).await;
        let error = client.error().await;
        assert_eq!(error["code"], "not_ready", "{error}");
        assert_eq!(error["sid"], "s");
        assert!(error.get("hint").is_some());
        open.store(true, Ordering::Release);
        let window = client.window("s").await;
        assert!(window.rows.len() >= 2, "{:?}", window.rows);
    });
}

#[test]
fn another_edition_gets_stale_edition_on_a_page_and_a_fresh_window_on_a_resume() {
    runtime().block_on(async {
        let lines: Vec<String> = (1..=5).flat_map(|n| turn(n, &format!("reply {n}"))).collect();
        let chat = Chat::new(&lines);
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        let first = row_value(&window.rows[0])["id"].as_u64().unwrap();
        client
            .send(json!({"method": "page", "params": {"sid": "s", "stream": "chat:chat",
                "after": first, "edition": window.edition + 1}}))
            .await;
        let error = client.error().await;
        assert_eq!(error["code"], "stale_edition", "{error}");
        // The actor goes; its subscriber is told `dropped`. Another boot gives another edition.
        assert!(chat.registry.evict("chat"));
        client.until(&mut Vec::new(), |f| (f.kind == FrameKind::Dropped).then_some(())).await;
        chat.config.lock().unwrap().boot_id ^= 1;
        client.sub("s", json!({"cursor": window.cursor, "edition": window.edition})).await;
        let fresh = client.window("s").await;
        assert_ne!(fresh.edition, window.edition);
        assert!(!fresh.rows.is_empty());
    });
}

#[test]
fn a_resume_replays_what_it_missed_then_a_state_frame_and_two_mebibytes_get_a_window() {
    runtime().block_on(async {
        let chat = Chat::new(&turn(1, "first"));
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        client.send(json!({"method": "unsub", "params": {"sid": "s"}})).await;
        let more: Vec<String> = (2..=11).flat_map(|n| turn(n, &format!("missed {n}"))).collect();
        chat.append(&more);
        client.booked("missed 11").await;
        client.sub("r", json!({"cursor": window.cursor, "edition": window.edition})).await;
        let mut rows = 0;
        let mut ended = false;
        while !ended {
            let frame = client.recv().await;
            assert_ne!(frame.kind, FrameKind::Window, "a small resume got a window");
            if frame.kind != FrameKind::Delta {
                continue;
            }
            let delta: ChatDelta = frame.decode_json().unwrap();
            if delta.sid != "r" {
                continue;
            }
            assert!(delta.replay.is_some(), "a live op before the state frame");
            rows += delta.ops.iter().filter(|op| matches!(op, ChatOp::Row { .. })).count();
            ended = delta.replay == Some(crate::wire::ReplayMark::End);
            if ended {
                assert!(
                    delta.ops.iter().any(|op| matches!(op, ChatOp::Queue { head: Some(_), .. })),
                    "the state frame holds the queue's head"
                );
            }
        }
        assert!(rows >= 20, "{rows} rows replayed for 10 turns");
        // Two mebibytes missed: a window, no replay.
        client.sub("s2", json!({})).await;
        let before = client.window("s2").await;
        client.send(json!({"method": "unsub", "params": {"sid": "s2"}})).await;
        // A record holds at most 16 KB of a reply: 160 replies of 14 KB are 2 MiB of records.
        let big = "x".repeat(14 * 1024);
        let lots: Vec<String> =
            (12..=171).flat_map(|n| turn(n, &format!("last {n} {big}"))).collect();
        chat.append(&lots);
        client.booked("last 171 ").await;
        client.sub("s3", json!({"cursor": before.cursor, "edition": before.edition})).await;
        let frame = client
            .until(&mut Vec::new(), |frame| {
                let sid = frame.decode_json::<Value>().ok()?["sid"].as_str()?.to_owned();
                (sid == "s3").then_some(frame.kind)
            })
            .await;
        assert_eq!(frame, FrameKind::Window);
    });
}

/// Holds the connection's metrics, which its sink hands the source.
struct Spy {
    inner: Arc<dyn Source>,
    metrics: Mutex<Option<Arc<ConnectionMetrics>>>,
}

impl Source for Spy {
    fn subscribe(
        &self,
        sub: &SubRequest,
        person: Option<&[u8]>,
        sink: Arc<dyn OfferSink>,
    ) -> Result<(), conn::ConnError> {
        *self.metrics.lock().unwrap() = Some(sink.metrics());
        self.inner.subscribe(sub, person, sink)
    }
    fn resume(&self, sid: &str, cursor: Cursor) {
        self.inner.resume(sid, cursor);
    }
    fn page(&self, page: &Page, person: Option<&[u8]>) -> Result<Frame, conn::ConnError> {
        self.inner.page(page, person)
    }
    fn later(
        &self,
        request: conn::Later<'_>,
        person: Option<&[u8]>,
        reply: Reply,
    ) -> Option<Reply> {
        self.inner.later(request, person, reply)
    }
    fn end(&self, sid: &str) {
        self.inner.end(sid);
    }
}

#[test]
fn sixty_pages_and_blobs_sent_at_once_are_answered_one_at_a_time() {
    runtime().block_on(async {
        let lines: Vec<String> = (1..=30).flat_map(|n| turn(n, &format!("reply {n}"))).collect();
        let chat = Chat::new(&lines);
        let spy = Arc::new(Mutex::new(None::<Arc<Spy>>));
        let held = spy.clone();
        let mut client = chat.connect_with(1, &["chat"], move |inner| {
            let spy = Arc::new(Spy { inner, metrics: Mutex::new(None) });
            *held.lock().unwrap() = Some(spy.clone());
            spy
        });
        client.hello(None).await;
        client.sub("s", json!({"window": 4})).await;
        let window = client.window("s").await;
        let first = row_value(&window.rows[0])["id"].as_u64().unwrap();
        for n in 0..30 {
            client
                .send(json!({"method": "page", "params": {"sid": "s", "stream": "chat:chat",
                    "before": first, "edition": window.edition, "maxBytes": 4096}}))
                .await;
            client
                .send(json!({"method": "blob", "params": {"id": format!("b{n}"), "stream": "chat:chat",
                    "edition": window.edition, "rowId": first, "len": 64}}))
                .await;
        }
        let (mut pages, mut blobs) = (0, 0);
        while pages + blobs < 60 {
            let frame = client.recv().await;
            match frame.kind {
                FrameKind::Page => pages += 1,
                FrameKind::Blob => blobs += 1,
                FrameKind::Error => panic!("{}", String::from_utf8_lossy(frame.payload())),
                _ => {}
            }
        }
        assert_eq!((pages, blobs), (30, 30));
        let spy = spy.lock().unwrap().clone().unwrap();
        let metrics = spy.metrics.lock().unwrap().clone().unwrap();
        assert_eq!(metrics.peak_unanswered(), 1);
        assert_eq!(metrics.failed_replies(), 0);
    });
}

/// A whole turn with a tool call, so it has a group row: its prompt, a read, a reply, its end.
fn tool_turn(n: u64) -> Vec<String> {
    let seq = n * 10;
    let update = |seq: u64, kind: &str, update: Value| {
        json!({"seq": seq, "at": seq * 1000, "dir": "in", "kind": kind,
            "msg": {"method": "session/update", "params": {"update": update}}})
        .to_string()
    };
    let call = format!("c{n}");
    let mut lines = open_turn(n);
    lines.push(update(
        seq + 3,
        "tool_call",
        json!({"sessionUpdate": "tool_call",
        "toolCallId": call, "title": "Read a.rs", "kind": "read", "status": "pending"}),
    ));
    lines.push(update(
        seq + 4,
        "tool_call_update",
        json!({"sessionUpdate": "tool_call_update",
        "toolCallId": call, "status": "completed",
        "content": [{"type": "content", "content": {"type": "text", "text": "fn a() {}"}}]}),
    ));
    lines.push(chunk(seq + 5, &format!("reply {n}"), &format!("m{n}")));
    lines.push(mux(
        seq + 6,
        "turn_result",
        json!({"turnId": format!("t{n}"), "status": "completed"}),
    ));
    lines
}

#[test]
fn a_page_of_turns_holds_the_settled_group_rows_and_not_the_open_one() {
    runtime().block_on(async {
        let mut lines: Vec<String> = (1..=12).flat_map(tool_turn).collect();
        // Turn 13 is open: its group row is open too, in the window and not in the page.
        let mut open = tool_turn(13);
        open.truncate(open.len() - 2);
        lines.extend(open);
        let chat = Chat::new(&lines);
        let mut client = chat.connect(1, &["chat", "list"]);
        client.hello(None).await;
        client.booked("reply 12").await;
        client.sub("s", json!({"window": 4})).await;
        let window = client.window("s").await;
        assert!(window.open.iter().any(|open| row_value(&open.row)["kind"] == "group"));
        let page = |params: Value| {
            let mut base = json!({"sid": "s", "stream": "chat:chat", "edition": window.edition,
                "turns": true});
            base.as_object_mut().unwrap().extend(params.as_object().unwrap().clone());
            json!({"method": "page", "params": base})
        };
        client.send(page(json!({"before": u64::MAX}))).await;
        let frame = client
            .until(&mut Vec::new(), |frame| (frame.kind == FrameKind::Page).then(|| frame.clone()))
            .await;
        let result: ChatPageResult = frame.decode_json().unwrap();
        assert!(result.turns, "the reply to a page of turns says so");
        let rows: Vec<Value> = result.rows.iter().map(row_value).collect();
        assert_eq!(rows.len(), 12, "{rows:?}");
        assert!(rows.iter().all(|row| row["kind"] == "group"), "{rows:?}");
        let ids: Vec<u64> = rows.iter().map(|row| row["id"].as_u64().unwrap()).collect();
        assert!(ids.windows(2).all(|pair| pair[0] < pair[1]));
        assert!(!result.has_before && !result.has_after);
        // The same bytes the window carries for the closed folds' group rows it holds.
        for row in &window.rows {
            if row_value(row)["kind"] == "group" {
                assert!(result.rows.iter().any(|turn| turn.get() == row.get()));
            }
        }
        // A page of two from the newest end names more before it.
        let two: usize = result
            .rows
            .iter()
            .rev()
            .take(2)
            .map(|row| row.get().len() + log::RECORD_OVERHEAD)
            .sum();
        let pages = [(json!({"before": u64::MAX, "maxBytes": two}), &ids[10..], true)];
        // Over 256 KB is clamped to 256 KB, as any chat page: answered, not refused.
        let clamped = (json!({"before": u64::MAX, "maxBytes": 4u32 << 20}), &ids[..], false);
        // From inside turn 6, the turns before it, turn 6 among them.
        let inside = (json!({"before": ids[5] + 1}), &ids[..6], false);
        for (params, expected, has_before) in pages.into_iter().chain([clamped, inside]) {
            client.send(page(params)).await;
            let frame = client
                .until(&mut Vec::new(), |frame| {
                    (frame.kind == FrameKind::Page).then(|| frame.clone())
                })
                .await;
            let got: ChatPageResult = frame.decode_json().unwrap();
            let got_ids: Vec<u64> =
                got.rows.iter().map(|row| row_value(row)["id"].as_u64().unwrap()).collect();
            assert_eq!(got_ids, expected);
            assert_eq!(got.has_before, has_before);
        }
        // A rowId of another edition.
        client.send(page(json!({"before": u64::MAX, "edition": window.edition + 1}))).await;
        assert_eq!(client.error().await["code"], "stale_edition");
        // With a fold, refused; on the list, refused.
        client.send(page(json!({"before": ids[3], "fold": ids[2]}))).await;
        assert_eq!(client.error().await["code"], "bad_request");
        client
            .send(json!({"method": "page", "params": {"sid": "l", "stream": "list",
                "before": 1, "turns": true}}))
            .await;
        assert!(client.error().await["message"].as_str().unwrap_or("").contains("turns"));
    });
}

#[test]
fn a_page_or_blob_for_a_chat_with_no_actor_is_answered_at_once() {
    runtime().block_on(async {
        let chat = Chat::new(&turn(1, "hello"));
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client
            .send(json!({"method": "page", "params": {"sid": "s", "stream": "chat:chat",
                "before": 5, "edition": 1}}))
            .await;
        assert_eq!(client.error().await["code"], "not_open");
        client
            .send(json!({"method": "blob", "params": {"id": "b", "stream": "chat:chat",
                "edition": 1, "rowId": 1, "len": 1}}))
            .await;
        let error = client.error().await;
        assert_eq!(error["code"], "not_open");
        assert_eq!(error["id"], "b");
    });
}

#[test]
fn a_settled_rows_blob_is_its_stored_body_escaped_once() {
    runtime().block_on(async {
        let said = "he said \"hi\"\n\tand \\ left";
        let chat = Chat::new(&turn(1, said));
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        let reply = window
            .rows
            .iter()
            .map(row_value)
            .find(|row| row["kind"] == "text")
            .expect("the reply row");
        let id = reply["id"].as_u64().unwrap();
        client
            .send(json!({"method": "blob", "params": {"id": "b", "stream": "chat:chat",
                "edition": window.edition, "rowId": id, "len": 1 << 20}}))
            .await;
        let frame =
            client.until(&mut Vec::new(), |f| (f.kind == FrameKind::Blob).then(|| f.clone())).await;
        let (head, bytes) = decode_blob(&frame).unwrap();
        assert!(!head.open);
        assert_eq!(head.total, bytes.len() as u64);
        let body: Value = serde_json::from_slice(bytes).unwrap();
        assert_eq!(body["text"], said);
        let stored = serde_json::to_string(&reply["body"]).unwrap();
        assert_eq!(bytes, stored.as_bytes(), "the blob is not the stored body");
        let raw = String::from_utf8(bytes.to_vec()).unwrap();
        assert!(raw.contains(r#"\"hi\""#) && !raw.contains(r#"\\\""#), "{raw}");
    });
}

#[test]
fn an_open_rows_blob_holds_its_text_ops_and_bytes_before_fixed_stay_within_a_generation() {
    runtime().block_on(async {
        let mut lines = open_turn(1);
        lines.push(chunk(13, "a", "m1"));
        let chat = Chat::new(&lines);
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        let (row, mut text) = open_reply(&window).unwrap();
        let mut last: Option<(String, u64, Vec<u8>)> = None;
        let mut consumed = window_bytes(&window);
        for n in 0..1000u64 {
            chat.append(&[chunk(14 + n, &format!("{n},\"\n"), "m1")]);
            client
                .send(json!({"method": "blob", "params": {"id": format!("b{n}"), "stream": "chat:chat",
                    "edition": window.edition, "rowId": row, "start": 0, "len": 1 << 20}}))
                .await;
            let frame = loop {
                let frame = client.recv().await;
                consumed += frame.encoded_len() as u64;
                match frame.kind {
                    FrameKind::Delta => apply(&frame.decode_json().unwrap(), row, &mut text),
                    FrameKind::Blob => break frame,
                    FrameKind::Error => panic!("{}", String::from_utf8_lossy(frame.payload())),
                    _ => {}
                }
            };
            let (head, bytes) = decode_blob(&frame).unwrap();
            assert!(head.open);
            let generation = head.generation.clone().expect("an open row's blob names its gen");
            let fixed = head.fixed.expect("and where its text's content ends") as usize;
            // Every text op for the row came before its blob: the client's text is the blob's.
            let body: Value = serde_json::from_slice(bytes).unwrap();
            assert_eq!(body["text"].as_str().unwrap(), text, "blob {n}");
            if let Some((was, was_fixed, was_bytes)) = &last
                && *was == generation
            {
                let was_fixed = *was_fixed as usize;
                assert_eq!(bytes.get(..was_fixed), was_bytes.get(..was_fixed), "blob {n}");
            }
            last = Some((generation, fixed as u64, bytes.to_vec()));
            if consumed > 512 * 1024 {
                client.credit("s", consumed).await;
            }
        }
    });
}

#[test]
fn generations_differ_across_a_thousand_lives() {
    let mut seen = std::collections::BTreeSet::new();
    for _ in 0..1000 {
        assert!(seen.insert(random_u64()), "a generation base came twice");
    }
}

#[test]
fn two_keys_are_two_people_and_no_key_is_written() {
    runtime().block_on(async {
        let chat = Chat::new(&turn(1, "hello"));
        let mut one = chat.connect(1, &["chat"]);
        one.hello(Some("key-one-secret")).await;
        let mut two = chat.connect(2, &["chat"]);
        two.hello(Some("key-two-secret")).await;
        one.sub("a", json!({})).await;
        let _ = one.window("a").await;
        let handle = chat.registry.get("chat").unwrap();
        let person = person_id(Some(&b"key-one-secret"[..]));
        assert_ne!(person, person_id(Some(&b"key-two-secret"[..])));
        handle.set_person(Person { id: person, seen: 3, folds: Vec::new() }).unwrap();
        one.sub("b", json!({})).await;
        two.sub("b", json!({})).await;
        assert_eq!(one.window("b").await.seen, Some(3));
        assert_eq!(two.window("b").await.seen, None);
        assert!(chat.registry.evict("chat"));
        for file in walk(&chat.book()) {
            let bytes = fs::read(&file).unwrap();
            assert!(
                !bytes.windows(10).any(|w| w == b"key-one-se"),
                "{} holds a key",
                file.display()
            );
        }
        let recovered = log::saved_checkpoint(&chat.book()).unwrap().unwrap();
        let checkpoint = acpmux_book::checkpoint::Checkpoint::from_recovered(&recovered).unwrap();
        assert_eq!(checkpoint.people.iter().map(|p| p.id).collect::<Vec<_>>(), vec![person]);
    });
}

fn walk(dir: &Path) -> Vec<PathBuf> {
    let mut files = Vec::new();
    for entry in fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            files.extend(walk(&path));
        } else {
            files.push(path);
        }
    }
    files
}

#[test]
fn a_chat_sub_without_the_chat_surface_is_refused() {
    runtime().block_on(async {
        let chat = Chat::new(&turn(1, "hello"));
        let mut client = chat.connect(1, &["list"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let error = client.error().await;
        assert!(error["message"].as_str().unwrap().contains("surface"), "{error}");
        assert!(chat.registry.is_empty(), "a refused sub hydrated the chat");
    });
}

/// A source with no `read_at`, as a v1 chat's is until it reads pieces of a line.
struct Whole(Box<dyn RawSource>);

impl RawSource for Whole {
    fn read_chunk(&mut self, place: u64) -> std::io::Result<Chunk> {
        self.0.read_chunk(place)
    }
    fn holds(&mut self, place: u64) -> std::io::Result<bool> {
        self.0.holds(place)
    }
    fn hint(&self) -> std::io::Result<u64> {
        self.0.hint()
    }
    fn sync_through(&mut self, place: u64) -> std::io::Result<()> {
        self.0.sync_through(place)
    }
    fn identity(&self) -> &[u8] {
        self.0.identity()
    }
    fn stamp(&self) -> u64 {
        self.0.stamp()
    }
}

fn waiting() -> Vec<String> {
    let mut lines = open_turn(1);
    lines.push(mux(
        13,
        "queued",
        json!({"promptId": "q1", "turnId": "u1", "text": "first waiting"}),
    ));
    lines.push(mux(14, "queued", json!({"promptId": "q2", "turnId": "u2", "text": "second"})));
    lines
}

#[test]
fn a_queue_head_has_entries_where_lines_can_be_read_in_pieces_and_the_count_alone_elsewhere() {
    runtime().block_on(async {
        let chat = Chat::new(&waiting());
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        assert_eq!(window.queue.count, 2);
        let ids: Vec<&str> = window.queue.entries.iter().map(|e| e.id.as_str()).collect();
        assert_eq!(ids, ["q1", "q2"]);
        assert_eq!(window.queue.entries[0].text, "first waiting");
        client
            .send(json!({"method": "blob", "params": {"id": "b", "stream": "chat:chat",
                "edition": window.edition, "prompt": "q1", "len": 100}}))
            .await;
        let frame =
            client.until(&mut Vec::new(), |f| (f.kind == FrameKind::Blob).then(|| f.clone())).await;
        assert_eq!(decode_blob(&frame).unwrap().1, b"first waiting");

        let whole = Chat::with_source(
            &waiting(),
            Arc::new(|raw| {
                let inner = source::FileSource::open(&raw)?;
                Ok(Box::new(Whole(Box::new(inner))) as Box<dyn RawSource>)
            }),
        );
        let mut client = whole.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        assert_eq!(window.queue.count, 2);
        assert!(window.queue.entries.is_empty());
        client
            .send(json!({"method": "blob", "params": {"id": "b", "stream": "chat:chat",
                "edition": window.edition, "prompt": "q1", "len": 100}}))
            .await;
        assert_eq!(client.error().await["code"], "read_failed");
    });
}

#[test]
fn a_window_asked_past_the_bound_holds_the_bound() {
    runtime().block_on(async {
        let lines: Vec<String> = (1..=260).flat_map(|n| turn(n, "r")).collect();
        let chat = Chat::new(&lines);
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({"window": 65535})).await;
        let window = client.window("s").await;
        assert!(window.rows.len() <= MAX_ROWS, "{}", window.rows.len());
        assert!(window.has_before);
    });
}

#[test]
fn held_text_is_cut_only_where_each_piece_decodes_on_its_own() {
    let b = char::from(92);
    let mut text = format!("ab{b}\"c{b}u00e9{b}ud83d{b}ude42").into_bytes();
    text.extend_from_slice("é🙂x".as_bytes());
    for max in 1..=text.len() + 1 {
        let mut rest = text.as_slice();
        let mut decoded = String::new();
        while !rest.is_empty() {
            let cut = text_cut(rest, max);
            assert!(cut > 0, "a cut at {max} made no progress");
            let (piece, after) = rest.split_at(cut);
            let piece = std::str::from_utf8(piece).expect("a cut inside a character");
            decoded.push_str(&serde_json::from_str::<String>(&format!("\"{piece}\"")).unwrap());
            rest = after;
        }
        assert_eq!(decoded, "ab\"cé🙂é🙂x", "max {max}");
    }
}

/// A sink whose connection holds its subscription, or let it go.
struct Held(bool);

impl OfferSink for Held {
    fn offer(&self, _sid: &str, _frame: Frame, _cursor: Cursor) -> Offer {
        Offer::Taken
    }
    fn fail(&self, _sid: &str) {}
    fn dropped(&self, _sid: &str) {}
    fn control(&self, _sid: &str) -> Option<Arc<conn::SubscriptionControl>> {
        self.0.then(Arc::default)
    }
    fn metrics(&self) -> Arc<ConnectionMetrics> {
        Arc::default()
    }
}

/// An `end` the mailbox refused leaves a subscriber its connection no longer holds; the idle
/// check forgets it, so it does not keep the actor alive.
#[test]
fn a_subscriber_its_connection_let_go_is_forgotten_at_the_idle_check() {
    let chat = Chat::new(&turn(1, "hello"));
    let config = chat.config.lock().unwrap().clone();
    let mut state = crate::chat::open_state(config).unwrap();
    for (sid, held) in [("gone", false), ("kept", true), ("stopped", false)] {
        state.subs.list.push(Subscriber {
            conn: 1,
            sid: sid.to_owned(),
            sink: Arc::new(Held(held)),
            person: person_id(None),
            edition: state.edition,
            phase: if sid == "stopped" { Phase::Stopped } else { Phase::Live },
            taken: 0,
        });
    }
    prune(&mut state);
    let left: Vec<&str> = state.subs.list.iter().map(|sub| sub.sid.as_str()).collect();
    assert_eq!(left, ["kept"]);
    state.subs.list.clear();
    prune(&mut state);
    assert!(state.subs.is_empty());
}

/// Flips one byte of `marker` where a segment of the book's rows holds it: that record's check
/// fails, and a read refuses it.
fn flip_in_segments(book: &Path, marker: &[u8]) {
    for path in walk(book) {
        if path.extension().is_none_or(|extension| extension != "seg") {
            continue;
        }
        let mut bytes = fs::read(&path).unwrap();
        if let Some(at) = bytes.windows(marker.len()).position(|window| window == marker) {
            bytes[at] ^= 1;
            let mut file = fs::OpenOptions::new().write(true).open(&path).unwrap();
            file.write_all(&bytes).unwrap();
            return;
        }
    }
    panic!("no segment of the book holds {}", String::from_utf8_lossy(marker));
}

/// A resume across a record the book refuses, 300 KB in: its first frames go out, then a window
/// that names the record, with no replay past it and no `end`. The actor rebuilds the book from
/// raw at the end of that step. A rebuild from the same raw keeps its edition (its row ids are
/// the same), so each subscriber resumes from what it holds: the refused one and one live
/// through the rebuild each get their `end` and nothing they hold again, and a fresh window
/// holds the row the old book refused.
#[test]
fn a_resume_across_a_refused_record_gets_a_window_and_the_rebuilt_book_holds_the_row() {
    runtime().block_on(async {
        let chat = Chat::new(&turn(1, "first"));
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        client.send(json!({"method": "unsub", "params": {"sid": "s"}})).await;
        // 20 replies of 15 KB, then the two marked ones: the first marked record is 300 KB in.
        let pad = "w".repeat(15 * 1024);
        let mut more: Vec<String> = (2..=21).flat_map(|n| turn(n, &format!("{n} {pad}"))).collect();
        more.extend((22..=23).flat_map(|n| turn(n, &format!("marker{n}q"))));
        chat.append(&more);
        client.booked("marker23q").await;
        client.sub("l", json!({})).await;
        client.window("l").await;
        flip_in_segments(&chat.book(), b"marker22q");
        client.sub("r", json!({"cursor": window.cursor, "edition": window.edition})).await;
        let (mut refusing, mut replayed) = (None::<ChatWindow>, 0);
        let (mut resumed_end, mut live_end) = (false, false);
        while !(resumed_end && live_end) {
            let frame = client.recv().await;
            let Ok(value) = frame.decode_json::<Value>() else { continue };
            let sid = value["sid"].as_str().unwrap_or_default().to_owned();
            if sid != "r" && sid != "l" {
                continue;
            }
            if frame.kind == FrameKind::Window {
                assert_eq!(sid, "r", "a window for the live subscriber: the edition changed");
                assert!(refusing.is_none(), "a second window for the refused resume");
                refusing = Some(frame.decode_json().unwrap());
                continue;
            }
            if frame.kind != FrameKind::Delta {
                continue;
            }
            let delta: ChatDelta = frame.decode_json().unwrap();
            let end = delta.replay == Some(crate::wire::ReplayMark::End);
            let text = String::from_utf8_lossy(frame.payload()).into_owned();
            if sid == "l" {
                assert!(end, "the live subscriber got more than its `end`: {text}");
                live_end = true;
            } else if refusing.is_none() {
                assert!(!end, "an `end` before the refused record's window");
                assert!(!text.contains("marker23q"), "a record past the refused one");
                replayed += 1;
            } else {
                assert!(end, "the resume after the rebuild sent more than its `end`: {text}");
                assert!(!text.contains("marker2"), "a record the window held, sent again");
                resumed_end = true;
            }
        }
        assert!(replayed >= 1, "the frames before the refused record went out");
        let Some(refusing) = refusing else { panic!("no window for the refused resume") };
        assert!(!refusing.refused.is_empty(), "the window names the refused record");
        client.sub("w2", json!({})).await;
        let rebuilt = client.ready_window("w2").await;
        assert_eq!(rebuilt.edition, refusing.edition, "a rebuild from the same raw keeps it");
        assert!(rebuilt.refused.is_empty(), "the rebuilt book refuses nothing");
        assert!(
            rebuilt.rows.iter().any(|row| row.get().contains("marker22q")),
            "the rebuilt book holds the row"
        );
    });
}

/// A file source whose stamp the test changes, as v1's does when it rewrites lines it delivered.
struct Stamped {
    inner: Box<dyn RawSource>,
    stamp: Arc<AtomicU64>,
}

impl RawSource for Stamped {
    fn read_chunk(&mut self, place: u64) -> std::io::Result<Chunk> {
        let mut chunk = self.inner.read_chunk(place)?;
        chunk.stamp = self.stamp.load(Ordering::Acquire);
        Ok(chunk)
    }
    fn holds(&mut self, place: u64) -> std::io::Result<bool> {
        self.inner.holds(place)
    }
    fn hint(&self) -> std::io::Result<u64> {
        self.inner.hint()
    }
    fn sync_through(&mut self, place: u64) -> std::io::Result<()> {
        self.inner.sync_through(place)
    }
    fn identity(&self) -> &[u8] {
        self.inner.identity()
    }
    fn stamp(&self) -> u64 {
        self.stamp.load(Ordering::Acquire)
    }
    fn read_at(&mut self, place: u64, offset: u64, max: usize) -> std::io::Result<source::Piece> {
        self.inner.read_at(place, offset, max)
    }
}

/// A subscriber live when the book takes a new edition (the source changed lines it delivered)
/// gets a fresh window of the new edition in place of its next delta.
#[test]
fn a_subscriber_live_when_the_book_takes_a_new_edition_gets_a_fresh_window() {
    runtime().block_on(async {
        let stamp = Arc::new(AtomicU64::new(1));
        let shared = stamp.clone();
        let chat = Chat::with_source(
            &turn(1, "first"),
            Arc::new(move |raw| {
                let inner = source::FileSource::open(&raw)?;
                Ok(Box::new(Stamped { inner: Box::new(inner), stamp: shared.clone() })
                    as Box<dyn RawSource>)
            }),
        );
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("l", json!({})).await;
        let live = client.window("l").await;
        stamp.store(2, Ordering::Release);
        chat.append(&turn(2, "after the change"));
        let frame = client
            .until(&mut Vec::new(), |frame| {
                let value: Value = frame.decode_json().ok()?;
                (value["sid"] == "l" && matches!(frame.kind, FrameKind::Window | FrameKind::Delta))
                    .then(|| frame.clone())
            })
            .await;
        assert_eq!(frame.kind, FrameKind::Window, "a delta in place of the fresh window");
        let fresh: ChatWindow = frame.decode_json().unwrap();
        assert_ne!(fresh.edition, live.edition, "the fresh window is the new edition's");
        assert!(!fresh.rows.is_empty());
    });
}

/// A replayed record whose rev is above 1 is a `patch`, and a patch is the whole row: a client
/// that never held the row's first record (it was outside its window) takes the patch as the
/// row, by its rowId.
#[test]
fn a_replayed_patch_is_the_whole_row_for_a_client_that_never_held_its_first_record() {
    runtime().block_on(async {
        let mut lines = open_turn(1);
        // Two settled rows and an open one: a window of one row holds only the second.
        let text = format!("{}\n\n{}\n\ntail", "x".repeat(9000), "y".repeat(9000));
        lines.push(chunk(13, &text, "old"));
        let chat = Chat::new(&lines);
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({"window": 1})).await;
        let window = client.window("s").await;
        let held: Vec<Value> = window.rows.iter().map(|row| row_value(row)["id"].clone()).collect();
        client.send(json!({"method": "unsub", "params": {"sid": "s"}})).await;
        chat.append(&[
            mux(14, "message_superseded", json!({"oldMessageId": "old"})),
            chunk(15, "Replacement.", "new"),
            mux(16, "turn_result", json!({"turnId": "t1"})),
        ]);
        client.booked("Replacement.").await;
        client.sub("r", json!({"cursor": window.cursor, "edition": window.edition})).await;
        let mut patches = Vec::new();
        loop {
            let frame = client.recv().await;
            if frame.kind != FrameKind::Delta {
                continue;
            }
            let delta: ChatDelta = frame.decode_json().unwrap();
            if delta.sid != "r" {
                continue;
            }
            for op in &delta.ops {
                if let ChatOp::Patch { row, .. } = op {
                    patches.push(row_value(row));
                }
            }
            if delta.replay == Some(crate::wire::ReplayMark::End) {
                break;
            }
        }
        let unseen: Vec<&Value> = patches.iter().filter(|row| !held.contains(&row["id"])).collect();
        assert!(!unseen.is_empty(), "no patch of a row outside the window: {patches:?}");
        for row in unseen {
            assert!(row["rev"].as_u64() > Some(1), "{row}");
            for field in ["id", "kind", "turn", "open"] {
                assert!(row.get(field).is_some(), "a patch without `{field}`: {row}");
            }
        }
    });
}

/// The state frame at its largest: open bodies inline up to 64 KB together (a larger body is
/// left out, its length named), every open row's head, and 64 queue heads of at most 1 KB of
/// text each. Its bound: those parts, under one frame of 256 KB. A `blob` asked for 4 GiB of
/// the body left out gets at most 256 KB.
#[test]
fn the_largest_state_frame_holds_its_bound_and_a_blob_past_its_bound_is_cut() {
    runtime().block_on(async {
        let mut lines = open_turn(1);
        lines.push(chunk(13, "start ", "m1"));
        lines.push(thought(14, "thinking", "m1"));
        // The reply is an older row than the thought, so it is never cut: one 600 KB body.
        let piece = "r".repeat(100 * 1024);
        lines.extend((15..21).map(|seq| chunk(seq, &piece, "m1")));
        let prompt = "p".repeat(2048);
        lines.extend((0..MAX_HEADS as u64).map(|n| {
            let (id, turn) = (format!("q{n}"), format!("u{n}"));
            mux(21 + n, "queued", json!({"promptId": id, "turnId": turn, "text": prompt}))
        }));
        let chat = Chat::new(&lines);
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.ready_window("s").await;
        client.send(json!({"method": "unsub", "params": {"sid": "s"}})).await;
        client.sub("r", json!({"cursor": window.cursor, "edition": window.edition})).await;
        let state = client
            .until(&mut Vec::new(), |frame| {
                let delta: ChatDelta = frame.decode_json().ok()?;
                (delta.sid == "r" && delta.replay == Some(crate::wire::ReplayMark::End))
                    .then(|| (frame.encoded_len(), delta))
            })
            .await;
        let (bytes, delta) = state;
        let head = delta.ops.iter().find_map(|op| match op {
            ChatOp::Queue { head: Some(head), .. } => Some(head),
            _ => None,
        });
        let head = head.expect("the state frame holds the queue's head");
        assert_eq!(head.entries.len(), MAX_HEADS);
        assert!(head.entries.iter().all(|entry| entry.text.len() <= queue::HEAD_TEXT));
        let (row, body_len) = delta
            .ops
            .iter()
            .find_map(|op| match op {
                ChatOp::Row { row, body_len: Some(len), .. } => Some((row_value(row), *len)),
                _ => None,
            })
            .expect("the 600 KB body is left out, its length named");
        assert!(body_len > OPEN_INLINE as u64);
        let bound = OPEN_INLINE + MAX_HEADS * (queue::HEAD_TEXT + 256) + 16 * 1024;
        assert!(bound <= MAX_REPLAY_FRAME_BYTES);
        assert!(bytes <= bound, "a state frame of {bytes} bytes, past its bound of {bound}");
        client
            .send(json!({"method": "blob", "params": {"id": "b", "stream": "chat:chat",
                "edition": window.edition, "rowId": row["id"], "len": u32::MAX}}))
            .await;
        let blob =
            client.until(&mut Vec::new(), |f| (f.kind == FrameKind::Blob).then(|| f.clone())).await;
        let (blob_head, bytes) = decode_blob(&blob).unwrap();
        assert_eq!(bytes.len(), MAX_BLOB_READ, "a blob past its bound is cut to it");
        assert!(blob_head.total > MAX_BLOB_READ as u64);
    });
}

/// A `page` asked for 64 MiB holds at most 256 KB, and a resume of about 900 KB missed goes
/// out in frames of at most 256 KB.
#[test]
fn a_page_and_a_resume_asked_past_their_bounds_hold_them() {
    runtime().block_on(async {
        let big = "z".repeat(14 * 1024);
        let lines: Vec<String> = (1..=40).flat_map(|n| turn(n, &format!("a {n} {big}"))).collect();
        let chat = Chat::new(&lines);
        let mut client = chat.connect(1, &["chat"]);
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.ready_window("s").await;
        let first = row_value(&window.rows[0])["id"].as_u64().unwrap();
        client
            .send(json!({"method": "page", "params": {"sid": "s", "stream": "chat:chat",
                "before": first + 1, "after": null, "maxBytes": 64u32 << 20,
                "edition": window.edition}}))
            .await;
        let page =
            client.until(&mut Vec::new(), |f| (f.kind == FrameKind::Page).then(|| f.clone())).await;
        assert!(page.encoded_len() <= MAX_PAGE_BYTES + 1024, "a page of {}", page.encoded_len());
        client.send(json!({"method": "unsub", "params": {"sid": "s"}})).await;
        // About 900 KB of records missed: under the missed bound, so a replay, not a window.
        let more: Vec<String> = (41..=100).flat_map(|n| turn(n, &format!("b {n} {big}"))).collect();
        chat.append(&more);
        client.booked("b 100 ").await;
        client.sub("r", json!({"cursor": window.cursor, "edition": window.edition})).await;
        let (mut largest, mut consumed, mut credited) = (0, 0, 0);
        loop {
            let frame = client.recv().await;
            let Ok(value) = frame.decode_json::<Value>() else { continue };
            if value["sid"] != "r" {
                continue;
            }
            let text =
                String::from_utf8_lossy(frame.payload().get(..300).unwrap_or(frame.payload()))
                    .into_owned();
            assert_eq!(frame.kind, FrameKind::Delta, "900 KB missed got {:?}: {text}", frame.kind);
            let delta: ChatDelta = frame.decode_json().unwrap();
            largest = largest.max(frame.encoded_len());
            if delta.replay == Some(crate::wire::ReplayMark::End) {
                break;
            }
            // Credit as a client does: frame bytes past the records' own pass the window.
            consumed += frame.encoded_len() as u64;
            if consumed - credited >= crate::wire::CREDIT_WINDOW_BYTES / 4 {
                client.credit("r", consumed).await;
                credited = consumed;
            }
        }
        assert!(largest <= MAX_REPLAY_FRAME_BYTES + 512, "a replay frame of {largest} bytes");
    });
}

/// A sink that takes every frame and keeps what it was given: each frame's sid and kind, and
/// the sids it was told were dropped.
#[derive(Default)]
struct Recorder {
    offers: Mutex<Vec<(String, FrameKind)>>,
    dropped: Mutex<Vec<String>>,
}

impl OfferSink for Recorder {
    fn offer(&self, sid: &str, frame: Frame, _cursor: Cursor) -> Offer {
        self.offers.lock().unwrap().push((sid.to_owned(), frame.kind));
        Offer::Taken
    }
    fn fail(&self, _sid: &str) {}
    fn dropped(&self, sid: &str) {
        self.dropped.lock().unwrap().push(sid.to_owned());
    }
    fn control(&self, _sid: &str) -> Option<Arc<conn::SubscriptionControl>> {
        Some(Arc::default())
    }
    fn metrics(&self) -> Arc<ConnectionMetrics> {
        Arc::default()
    }
}

/// An actor's state at its source's end, as the actor reads it, and ready.
fn ready_state(chat: &Chat) -> ActorState {
    let config = chat.config.lock().unwrap().clone();
    let mut state = crate::chat::open_state(config).unwrap();
    let stop = AtomicBool::new(false);
    while !crate::chat::read_history(&mut state, &stop).unwrap() {}
    state.ready = true;
    crate::chat::checkpoint(&mut state).unwrap();
    state
}

fn subscriber(state: &ActorState, sid: &str, sink: Arc<dyn OfferSink>, phase: Phase) -> Subscriber {
    Subscriber {
        conn: 1,
        sid: sid.to_owned(),
        sink,
        person: person_id(None),
        edition: state.edition,
        phase,
        taken: 0,
    }
}

/// A resume whose way to the record after its cursor meets a header that is not the next
/// record's: its size cannot be measured, so it gets a window, and the step ends in a rebuild
/// from raw, as one that refused a record does. The record is 600 rows back, where the window
/// never reads it, so only the measure meets the damage.
#[test]
fn a_resume_that_cannot_be_measured_past_a_damaged_header_ends_its_step_in_a_rebuild() {
    let lines: Vec<String> = (1..=300).flat_map(|n| turn(n, &format!("reply {n}"))).collect();
    let chat = Chat::new(&lines);
    let mut state = ready_state(&chat);
    assert!(state.log.last_seq() > 600, "{} records", state.log.last_seq());
    // The header of a record at or before the cursor gets another seq.
    let cursor = 10;
    let segment = chat.book().join("rows/000001.seg");
    let mut bytes = fs::read(&segment).unwrap();
    let damaged = (1..=cursor)
        .filter_map(|id| state.log.row(id))
        .map(|row| row.off as usize - log::HEADER_LEN)
        .find(|&at| {
            let seq = u64::from_le_bytes(bytes[at + 4..at + 12].try_into().unwrap());
            (2..=cursor).contains(&seq)
        })
        .expect("a record between seq.idx's first entry and the cursor");
    bytes[damaged + 4..damaged + 12].copy_from_slice(&u64::MAX.to_le_bytes());
    fs::write(&segment, &bytes).unwrap();
    let sink = Arc::new(Recorder::default());
    let resuming = Phase::Resuming { cursor, checked: false };
    let sub = subscriber(&state, "r", sink.clone(), resuming);
    state.subs.list.push(sub);
    let stepped = step(&mut state);
    assert_eq!(*sink.offers.lock().unwrap(), [("r".to_owned(), FrameKind::Window)]);
    assert!(
        matches!(stepped, Err(ChatError::Book(log::Error::Rebuild(_)))),
        "the step did not end in a rebuild: {stepped:?}"
    );
}

/// A live op that no frame can hold for one subscriber (its sid alone is past a frame's bound)
/// drops that subscriber, which resumes from its cursor; the others take the op.
#[test]
fn a_frame_that_fails_to_build_drops_its_subscriber() {
    let chat = Chat::new(&turn(1, "hello"));
    let mut state = ready_state(&chat);
    let sink = Arc::new(Recorder::default());
    let huge = "s".repeat(crate::wire::MAX_FRAME_BYTES);
    for sid in ["before", huge.as_str(), "after"] {
        let sub = subscriber(&state, sid, sink.clone(), Phase::Live);
        state.subs.list.push(sub);
    }
    let seq = state.log.last_seq();
    offer_live(&mut state, br#"{"op":"text","seq":1,"rowId":1,"text":"x"}"#, seq);
    let left: Vec<&str> = state.subs.list.iter().map(|sub| sub.sid.as_str()).collect();
    assert_eq!(left, ["before", "after"]);
    assert_eq!(*sink.dropped.lock().unwrap(), std::slice::from_ref(&huge));
    let offers = sink.offers.lock().unwrap().clone();
    let took = |sid: &str| (sid.to_owned(), FrameKind::Delta);
    assert_eq!(offers, [took("before"), took("after")]);
}

/// A source whose `hint` blocks while `hold` is set, so a caught-up actor stops taking its
/// mailbox; `parked` says it is blocked there.
struct Parked {
    inner: Box<dyn RawSource>,
    hold: Arc<AtomicBool>,
    parked: Arc<AtomicBool>,
}

impl RawSource for Parked {
    fn read_chunk(&mut self, place: u64) -> std::io::Result<Chunk> {
        self.inner.read_chunk(place)
    }
    fn holds(&mut self, place: u64) -> std::io::Result<bool> {
        self.inner.holds(place)
    }
    fn hint(&self) -> std::io::Result<u64> {
        while self.hold.load(Ordering::Acquire) {
            self.parked.store(true, Ordering::Release);
            std::thread::sleep(Duration::from_millis(1));
        }
        self.parked.store(false, Ordering::Release);
        self.inner.hint()
    }
    fn sync_through(&mut self, place: u64) -> std::io::Result<()> {
        self.inner.sync_through(place)
    }
    fn identity(&self) -> &[u8] {
        self.inner.identity()
    }
    fn stamp(&self) -> u64 {
        self.inner.stamp()
    }
    fn read_at(&mut self, place: u64, offset: u64, max: usize) -> std::io::Result<source::Piece> {
        self.inner.read_at(place, offset, max)
    }
}

/// A resume the actor's full mailbox refuses ends the subscription as `dropped`, so the client
/// resumes instead of waiting, and a `sub` on the same sid gets its window. The actor still
/// holds the old entry for the sid until then (the test below reads its replacement).
#[test]
fn a_resume_a_full_mailbox_refuses_ends_as_dropped_and_the_sid_subscribes_again() {
    runtime().block_on(async {
        let hold = Arc::new(AtomicBool::new(false));
        let parked = Arc::new(AtomicBool::new(false));
        let (gate, seen) = (hold.clone(), parked.clone());
        let chat = Chat::with_source(
            &turn(1, "hello"),
            Arc::new(move |raw| {
                let inner = source::FileSource::open(&raw)?;
                Ok(Box::new(Parked {
                    inner: Box::new(inner),
                    hold: gate.clone(),
                    parked: seen.clone(),
                }) as Box<dyn RawSource>)
            }),
        );
        let route = Arc::new(Mutex::new(None::<Arc<dyn Source>>));
        let held = route.clone();
        let mut client = chat.connect_with(1, &["chat"], move |inner| {
            *held.lock().unwrap() = Some(inner.clone());
            inner
        });
        client.hello(None).await;
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        // The actor parks in its source's hint; its mailbox fills.
        hold.store(true, Ordering::Release);
        while !parked.load(Ordering::Acquire) {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        let handle = chat.registry.get("chat").unwrap();
        while handle.wake().is_ok() {}
        assert!(matches!(handle.wake(), Err(ChatError::MailboxFull)));
        let route = route.lock().unwrap().clone().unwrap();
        route.resume("s", Cursor(window.cursor));
        let dropped = client
            .until(&mut Vec::new(), |frame| {
                let value = frame.decode_json::<Value>().ok()?;
                (frame.kind == FrameKind::Dropped).then(|| value["sid"].as_str().map(str::to_owned))
            })
            .await;
        assert_eq!(dropped.as_deref(), Some("s"));
        // The actor takes its mailbox again; the `sub` waits until there is room for it.
        hold.store(false, Ordering::Release);
        while handle.queued() > 0 {
            tokio::time::sleep(Duration::from_millis(1)).await;
        }
        client.sub("s", json!({})).await;
        client.window("s").await;
    });
}

/// The entry a refused resume left for a sid is replaced by the next `sub` on it from the same
/// connection: one entry, the new sink's, which gets the window and the live ops; the old sink
/// gets nothing more. Read at the actor: a client on the socket does not see a kept entry.
#[test]
fn the_next_sub_on_a_sid_replaces_the_actors_entry_for_it() {
    let chat = Chat::new(&turn(1, "hello"));
    let mut state = ready_state(&chat);
    let (old, new) = (Arc::new(Recorder::default()), Arc::new(Recorder::default()));
    let kept = subscriber(&state, "s", old.clone(), Phase::Live);
    state.subs.list.push(kept);
    let sub = ChatSub {
        sid: "s".to_owned(),
        conn: 1,
        cursor: None,
        edition: None,
        anchor: None,
        window: 0,
        person: person_id(None),
    };
    subscribe(&mut state, sub, Ticket::new("s".to_owned(), new.clone()));
    assert_eq!(state.subs.list.len(), 1, "the old entry is kept beside the new one");
    let seq = state.log.last_seq();
    offer_live(&mut state, br#"{"op":"text","seq":1,"rowId":1,"text":"x"}"#, seq);
    let took = |kind| ("s".to_owned(), kind);
    assert_eq!(*new.offers.lock().unwrap(), [took(FrameKind::Window), took(FrameKind::Delta)]);
    assert!(old.offers.lock().unwrap().is_empty(), "the replaced entry was offered a frame");
    assert!(old.dropped.lock().unwrap().is_empty() && new.dropped.lock().unwrap().is_empty());
}

/// Row 3c's release gates, beside the tests whose chats and clients they use.
#[cfg(target_os = "linux")]
#[path = "gates_tests.rs"]
mod gates;

/// The parity corpus: the change strings a page gets for each raw log (decision 233).
#[path = "parity_tests.rs"]
mod parity;
