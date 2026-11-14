//! Row 3c's gates (agent service v2): a chat's actor serving `sub`, `page`, `blob` and a resume
//! over a v2 connection, god against small, and PR 4's chat stream to a stopped reader. Each
//! writes one line per registry row to the file `V2_GATE_OUT` names. In a release build, one
//! test at a time:
//! `cargo test -p acpmux-core --release --lib v2_pr03c_ -- --ignored --nocapture --test-threads=1`,
//! and the same with `v2_pr04_chat_stopped_reader`.
//!
//! The chats stand up as the tests beside these do (`Chat`, `Client`, `conn::run` over a duplex
//! pipe), from raw lines made with the same helpers. acpmux-book's testkit writes a book with no
//! source and no checkpoint, which an actor does not open, so no part of it is used here. The
//! god chat is `god_fixture`'s god (81,000 messages, 1.09 GB of JSONL) as 40,500 turns of a
//! 13 KiB prompt and a 13 KiB reply, each a row held inline; the small one is 100 such turns, so
//! both hold the same largest line. Both are booked line by line as the actor books them, with
//! one checkpoint at the end, and the small one is padded with notices to the god's phase of
//! `seq.idx`'s 256. `ACPMUX_GOD_SCALE` (a fraction) shrinks the god chat for a quick run.

use super::*;
use crate::wire::{CONNECTION_BUDGET_BYTES, CREDIT_WINDOW_BYTES, ReplayMark};
use acpmux_book::row::RowHead;
use std::fs::File;
use std::hash::{DefaultHasher, Hash, Hasher};
use std::io::{BufRead, BufReader, BufWriter, Write};
use tokio::runtime::Runtime;
use tokio::sync::watch;

const ROUNDS: usize = 5;
/// Untimed and timed samples a round, for a sample of microseconds.
const WARMUP: usize = 32;
const SAMPLES: usize = 200;
/// Bytes a sample's `rchar` counts that no book read made: the runtime's wakes (eight bytes of
/// an eventfd each) and the read of `/proc/self/io` itself.
const READ_NOISE: u64 = 4096;

// ---- measures ----

#[derive(Clone, Copy, Debug)]
struct Measures {
    small: u64,
    god: u64,
    small_all: u64,
    god_all: u64,
}

impl Measures {
    fn ratio(self) -> f64 {
        self.god as f64 / self.small.max(1) as f64
    }

    fn report(self, name: &str, mode: &str) {
        println!(
            "{name} mode={mode} small_p95={} god_p95={} ratio={:.3} small_p95_all={} god_p95_all={} ratio_all={:.3}",
            self.small,
            self.god,
            self.ratio(),
            self.small_all,
            self.god_all,
            self.god_all as f64 / self.small.max(1) as f64,
        );
    }

    /// The best p95 within 1.2x; with `pooled`, every sample's god p95 within 2x of the same
    /// best small p95, as the registry compares them.
    fn check(self, name: &str, mode: &str, pooled: bool) {
        assert!(
            self.god as f64 <= self.small as f64 * 1.2,
            "{name} {mode}: best p95 ratio {:.3} exceeds 1.2",
            self.ratio()
        );
        assert!(
            !pooled || self.god_all as f64 <= self.small as f64 * 2.0,
            "{name} {mode}: pooled p95 ratio exceeds 2"
        );
    }
}

fn emit(name: &str, measures: Measures, unit: &str) {
    let Measures { small, god, god_all, .. } = measures;
    let line = format!(
        "{{\"name\":\"{name}\",\"small_p95\":{small},\"god_p95\":{god},\"god_p95_all\":{god_all},\"unit\":\"{unit}\"}}"
    );
    println!("{line}");
    if let Some(path) = std::env::var_os("V2_GATE_OUT") {
        let mut file = fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(file, "{line}").unwrap();
    }
}

fn percentile(samples: &[u64]) -> u64 {
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    sorted.get((sorted.len() * 95).div_ceil(100).saturating_sub(1)).copied().unwrap()
}

/// Five rounds, each god round after its small twin; the best round p95 of each side and the
/// p95 of all its samples.
fn paired(
    name: &str,
    mode: &str,
    warmup: usize,
    samples: usize,
    mut small: impl FnMut() -> u64,
    mut god: impl FnMut() -> u64,
) -> Measures {
    fn round(
        sample: &mut impl FnMut() -> u64,
        warmup: usize,
        samples: usize,
        into: &mut Vec<u64>,
    ) -> u64 {
        for _ in 0..warmup {
            std::hint::black_box(sample());
        }
        let start = into.len();
        for _ in 0..samples {
            into.push(sample());
        }
        percentile(into.get(start..).unwrap())
    }
    let (mut small_samples, mut god_samples) = (Vec::new(), Vec::new());
    let (mut small_best, mut god_best) = (u64::MAX, u64::MAX);
    for number in 1..=ROUNDS {
        let small_round = round(&mut small, warmup, samples, &mut small_samples);
        let god_round = round(&mut god, warmup, samples, &mut god_samples);
        small_best = small_best.min(small_round);
        god_best = god_best.min(god_round);
        println!("{name} mode={mode} round={number} small_p95={small_round} god_p95={god_round}");
    }
    let measures = Measures {
        small: small_best,
        god: god_best,
        small_all: percentile(&small_samples),
        god_all: percentile(&god_samples),
    };
    measures.report(name, mode);
    measures
}

fn proc_field(file: &str, field: &str) -> u64 {
    fs::read_to_string(file)
        .unwrap()
        .lines()
        .find_map(|line| line.strip_prefix(field)?.split_whitespace().next()?.parse().ok())
        .unwrap_or_else(|| panic!("{file} has no {field}"))
}

/// Bytes this process read through `read` calls: a segment's `pread`, a source's read.
fn rchar() -> u64 {
    proc_field("/proc/self/io", "rchar:")
}

fn status_bytes(field: &str) -> u64 {
    proc_field("/proc/self/status", field) * 1024
}

/// Resets `VmHWM` to the resident size now.
fn reset_peak() {
    fs::write("/proc/self/clear_refs", b"5\n").unwrap();
}

/// The allocator's live bytes: a counter of bytes held, with the `allocation-metrics` feature.
#[cfg(feature = "allocation-metrics")]
fn live_bytes() -> u64 {
    crate::allocation_metrics::live_bytes()
}

#[cfg(not(feature = "allocation-metrics"))]
fn live_bytes() -> u64 {
    0
}

// ---- the chats ----

/// Bytes of a fixture turn's prompt and of its reply: each a row under the 16 KB held inline.
const MESSAGE_BYTES: usize = 13 * 1024;
const SMALL_TURNS: u64 = 100;
const GOD_TURNS: u64 = 40_500;

fn god_turns() -> u64 {
    let scale = std::env::var("ACPMUX_GOD_SCALE")
        .ok()
        .and_then(|scale| scale.parse::<f64>().ok())
        .unwrap_or(1.0);
    ((GOD_TURNS as f64 * scale) as u64).max(SMALL_TURNS)
}

/// Raw lines with their seqs in order: v1 passes over a seq at or under the last, so a line can
/// be added after any other.
#[derive(Default)]
struct Raw {
    seq: u64,
}

impl Raw {
    fn next(&mut self) -> u64 {
        self.seq += 1;
        self.seq
    }

    /// Turn `n`'s prompt and its start.
    fn open(&mut self, n: u64, prompt: &str) -> Vec<String> {
        let (turn, prompt_id) = (format!("t{n}"), format!("p{n}"));
        vec![
            mux(
                self.next(),
                "user_message",
                json!({"promptId": prompt_id, "turnId": turn, "text": prompt}),
            ),
            mux(self.next(), "turn_started", json!({"turnId": turn, "promptId": prompt_id})),
        ]
    }

    /// A whole turn: its prompt, its reply and its end.
    fn turn(&mut self, n: u64, prompt: &str, reply: &str) -> Vec<String> {
        let mut lines = self.open(n, prompt);
        lines.push(chunk(self.next(), reply, &format!("m{n}")));
        lines.push(mux(
            self.next(),
            "turn_result",
            json!({"turnId": format!("t{n}"), "status": "completed"}),
        ));
        lines
    }

    /// A reply of its own in the open turn: it settles the one before it.
    fn reply(&mut self, n: u64, text: &str) -> String {
        chunk(self.next(), text, &format!("r{n}"))
    }

    /// A notice: one settled row.
    fn notice(&mut self, text: &str) -> String {
        mux(self.next(), "host_notice", json!({"text": text}))
    }

    fn queued(&mut self, id: &str, text: &str) -> String {
        mux(self.next(), "queued", json!({"promptId": id, "text": text}))
    }
}

struct Fixture {
    chat: Chat,
    raw: Raw,
    last_seq: u64,
}

/// A chat over `home/raw.ndjson` and `home/book`, configured as `Chat::new`'s.
fn chat_in(home: tempfile::TempDir) -> Chat {
    let raw = home.path().join("raw.ndjson");
    let book = home.path().join("book");
    let path = raw.clone();
    let factory = file_source();
    let mut config = ChatConfig::new("chat", &book, Harness::V1)
        .with_source_factory(Arc::new(move || factory(path.clone())));
    config.hint_poll = Duration::from_millis(2);
    Chat { home, raw, registry: Registry::new(), config: Arc::new(Mutex::new(config)) }
}

/// A chat of the lines `lines` puts, written to its raw file a line at a time and booked.
fn build(phase: Option<u64>, lines: impl FnOnce(&mut Raw, &mut dyn FnMut(String))) -> Fixture {
    let chat = chat_in(tempfile::tempdir().unwrap());
    let mut raw = Raw::default();
    let mut out = BufWriter::new(File::create(&chat.raw).unwrap());
    lines(&mut raw, &mut |line: String| {
        out.write_all(line.as_bytes()).unwrap();
        out.write_all(b"\n").unwrap();
    });
    out.flush().unwrap();
    drop(out);
    book(chat, raw, phase)
}

/// Books the chat's raw file as its actor would, line by line and with one checkpoint at the
/// end, so the actor that opens it is at its source's end. With `phase`, notices follow until
/// the last seq is at that phase of `seq.idx`'s stride.
fn book(chat: Chat, mut raw: Raw, phase: Option<u64>) -> Fixture {
    fs::create_dir_all(chat.book()).unwrap();
    let config = chat.config.lock().unwrap().clone();
    let mut state = crate::chat::open_state(config).unwrap();
    let mut place = 0;
    let mut reader = BufReader::new(File::open(&chat.raw).unwrap());
    let mut line = Vec::new();
    while reader.read_until(b'\n', &mut line).unwrap() > 0 {
        book_line(&mut state, &line, &mut place);
        line.clear();
    }
    if let Some(phase) = phase {
        while state.log.last_seq() % log::SEQ_STRIDE != phase {
            let before = state.log.last_seq();
            let notice = raw.notice("pad");
            chat.append(std::slice::from_ref(&notice));
            book_line(&mut state, format!("{notice}\n").as_bytes(), &mut place);
            assert_eq!(state.log.last_seq(), before + 1, "a notice is one record");
        }
    }
    crate::chat::checkpoint(&mut state).unwrap();
    let last_seq = state.log.last_seq();
    drop(state);
    Fixture { chat, raw, last_seq }
}

/// One raw line (with its newline) at `place`, as `read_source` applies it.
fn book_line(state: &mut ActorState, line: &[u8], place: &mut u64) {
    let span = line.len() as u64;
    let bytes = line.strip_suffix(b"\n").unwrap_or(line);
    let file = state.raw_file;
    state.raw_place = *place + span;
    crate::chat::apply_ops(state, bytes, file, *place, span, false).unwrap();
    *place += span;
}

/// A chat of `turns` fixture turns.
fn turns_chat(turns: u64, phase: Option<u64>) -> Fixture {
    let text = "x".repeat(MESSAGE_BYTES);
    build(phase, |raw, put| {
        for n in 1..=turns {
            for line in raw.turn(n, &text, &text) {
                put(line);
            }
        }
    })
}

/// The god chat and the small one, at the same phase of `seq.idx`.
fn god_and_small() -> (Fixture, Fixture) {
    let started = Instant::now();
    let god = turns_chat(god_turns(), None);
    let small = turns_chat(SMALL_TURNS, Some(god.last_seq % log::SEQ_STRIDE));
    println!(
        "fixtures: god {} records, small {} records, built in {:?}",
        god.last_seq,
        small.last_seq,
        started.elapsed()
    );
    (god, small)
}

// ---- the client ----

/// A connection to one fixture chat, and a count for fresh sids.
struct Reader {
    fixture: Fixture,
    client: Client,
    n: u64,
}

impl Reader {
    fn new(rt: &Runtime, fixture: Fixture) -> Self {
        let client = rt.block_on(async {
            let mut client = fixture.chat.connect(1, &["chat"]);
            client.hello(None).await;
            client
        });
        Self { fixture, client, n: 0 }
    }

    fn sid(&mut self, prefix: &str) -> String {
        self.n += 1;
        format!("{prefix}{}", self.n)
    }

    fn phase(&self) -> u64 {
        self.fixture.last_seq % log::SEQ_STRIDE
    }
}

/// The next window frame, not yet decoded: a client has taken it once its bytes are in.
async fn window_frame(client: &mut Client) -> Frame {
    loop {
        let frame = client.recv().await;
        if frame.kind == FrameKind::Window {
            return frame;
        }
        assert_ne!(frame.kind, FrameKind::Error, "{}", String::from_utf8_lossy(frame.payload()));
    }
}

async fn unsub(client: &mut Client, sid: &str) {
    client.send(json!({"method": "unsub", "params": {"sid": sid}})).await;
}

// ---- v2.pr03c.first_window ----

/// The budget for a cold chat's first window.
const FIRST_WINDOW_MAX: u64 = 50_000_000;

/// From `sub` on a cold chat to its window's bytes at the client. The actor is closed and
/// joined after, outside the clock, so the next sample's chat is cold and its book's lock free.
fn first_window_sample(rt: &Runtime, reader: &mut Reader) -> u64 {
    let sid = reader.sid("f");
    let client = &mut reader.client;
    let (elapsed, frame) = rt.block_on(async {
        let start = Instant::now();
        client.sub(&sid, json!({})).await;
        let frame = window_frame(client).await;
        let elapsed = start.elapsed().as_nanos() as u64;
        unsub(client, &sid).await;
        (elapsed, frame)
    });
    let window: ChatWindow = frame.decode_json().unwrap();
    assert_eq!(window.sid, sid);
    assert_eq!(window.cursor % log::SEQ_STRIDE, reader.phase());
    assert!(!window.rows.is_empty());
    assert!(reader.fixture.chat.registry.evict("chat"), "the window's actor ran");
    elapsed
}

#[test]
#[ignore]
fn v2_pr03c_first_window() {
    let rt = runtime();
    let (god, small) = god_and_small();
    let (mut god, mut small) = (Reader::new(&rt, god), Reader::new(&rt, small));
    let name = "v2.pr03c.first_window";
    let measures = paired(
        name,
        "cold",
        4,
        50,
        || first_window_sample(&rt, &mut small),
        || first_window_sample(&rt, &mut god),
    );
    emit(name, measures, "ns");
    measures.check(name, "cold", true);
    assert!(measures.god <= FIRST_WINDOW_MAX, "{name}: god p95 {} ns is past 50 ms", measures.god);
}

// ---- v2.pr03c.resume_missed ----

/// Turns both sides miss: the same lines, appended once after the cursor.
const MISSED_TURNS: u64 = 8;

struct Resumer {
    reader: Reader,
    cursor: u64,
    edition: u32,
    /// The rows every resume replays.
    rows: Option<usize>,
    /// Bytes read by each resume.
    read: Vec<u64>,
}

fn resumer(rt: &Runtime, fixture: Fixture) -> Resumer {
    let mut reader = Reader::new(rt, fixture);
    let client = &mut reader.client;
    let window = rt.block_on(async {
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        unsub(client, "s").await;
        window
    });
    let text = "m".repeat(1024);
    let raw = &mut reader.fixture.raw;
    let lines: Vec<String> = (1..=MISSED_TURNS)
        .flat_map(|k| raw.turn(1_000_000 + k, &format!("missed {k} {text}"), &text))
        .collect();
    reader.fixture.chat.append(&lines);
    rt.block_on(reader.client.booked(&format!("missed {MISSED_TURNS} ")));
    Resumer { reader, cursor: window.cursor, edition: window.edition, rows: None, read: Vec::new() }
}

/// Only what tells a resume's last frame.
#[derive(serde::Deserialize)]
struct Mark {
    replay: Option<ReplayMark>,
}

/// From a `sub` with the cursor to the resume's `end` at the client, and the bytes read on the
/// way. Outside the clock: the records missed, each once and in order, on every sample.
fn resume_sample(rt: &Runtime, side: &mut Resumer) -> u64 {
    let sid = side.reader.sid("r");
    let (cursor, edition) = (side.cursor, side.edition);
    let client = &mut side.reader.client;
    let (elapsed, read, frames) = rt.block_on(async {
        let mut frames = Vec::new();
        let read = rchar();
        let start = Instant::now();
        client.sub(&sid, json!({"cursor": cursor, "edition": edition})).await;
        loop {
            let frame = client.recv().await;
            assert_ne!(
                frame.kind,
                FrameKind::Window,
                "a resume of {MISSED_TURNS} turns got a window"
            );
            assert_ne!(
                frame.kind,
                FrameKind::Error,
                "{}",
                String::from_utf8_lossy(frame.payload())
            );
            if frame.kind != FrameKind::Delta {
                continue;
            }
            let mark: Mark = frame.decode_json().unwrap();
            frames.push(frame);
            if mark.replay == Some(ReplayMark::End) {
                break;
            }
        }
        let elapsed = start.elapsed().as_nanos() as u64;
        let read = rchar() - read;
        unsub(client, &sid).await;
        (elapsed, read, frames)
    });
    let (mut last, mut rows) = (cursor, 0);
    for frame in &frames {
        let delta: ChatDelta = frame.decode_json().unwrap();
        assert_eq!(delta.sid, sid);
        if delta.replay != Some(ReplayMark::Replay) {
            continue;
        }
        for op in &delta.ops {
            if let ChatOp::Row { seq, .. } | ChatOp::Patch { seq, .. } = op {
                assert!(*seq > last, "record {seq} replayed after {last}");
                last = *seq;
                rows += 1;
            }
        }
    }
    assert!(rows > 0, "a resume replayed no row");
    assert_eq!(*side.rows.get_or_insert(rows), rows, "every resume replays the same records");
    side.read.push(read);
    elapsed
}

#[test]
#[ignore]
fn v2_pr03c_resume_missed() {
    let rt = runtime();
    let (god, small) = god_and_small();
    let (mut god, mut small) = (resumer(&rt, god), resumer(&rt, small));
    assert_eq!(god.cursor % log::SEQ_STRIDE, small.cursor % log::SEQ_STRIDE, "the cursors' phase");
    let name = "v2.pr03c.resume_missed";
    let measures = paired(
        name,
        "missed",
        WARMUP,
        SAMPLES,
        || resume_sample(&rt, &mut small),
        || resume_sample(&rt, &mut god),
    );
    assert_eq!(small.rows, god.rows, "both sides replay the same records");
    let (small_read, god_read) = (percentile(&small.read), percentile(&god.read));
    println!(
        "{name} mode=missed rows={:?} small_read_p95={small_read} god_read_p95={god_read}",
        small.rows
    );
    emit(name, measures, "ns");
    measures.check(name, "missed", true);
    assert!(
        god_read as f64 <= small_read as f64 * 1.2 + READ_NOISE as f64,
        "{name}: god reads {god_read} bytes a resume against {small_read}"
    );
}

// ---- v2.pr03c.subscribed_rss ----

/// The resident rise from a `sub` on a cold chat to its window at the client, the chat still
/// subscribed. Free allocator pages go back before the baseline. The allocator's live bytes
/// (with `allocation-metrics`) and the resident split are printed beside it.
fn rss_sample(rt: &Runtime, reader: &mut Reader, side: &str) -> u64 {
    let sid = reader.sid("m");
    crate::memory::release_free_pages();
    let (rss, held) = (status_bytes("VmRSS:"), live_bytes());
    let client = &mut reader.client;
    let frame = rt.block_on(async {
        client.sub(&sid, json!({})).await;
        window_frame(client).await
    });
    let rise = status_bytes("VmRSS:").saturating_sub(rss);
    let held = live_bytes().saturating_sub(held);
    println!(
        "v2_pr03c_subscribed_rss side={side} rise={rise} held={held} window_bytes={} rss_anon={} rss_file={}",
        frame.encoded_len(),
        status_bytes("RssAnon:"),
        status_bytes("RssFile:")
    );
    drop(frame);
    rt.block_on(unsub(client, &sid));
    assert!(reader.fixture.chat.registry.evict("chat"), "the window's actor ran");
    rise
}

#[test]
#[ignore]
fn v2_pr03c_subscribed_rss() {
    let rt = runtime();
    let (god, small) = god_and_small();
    let (mut god, mut small) = (Reader::new(&rt, god), Reader::new(&rt, small));
    let name = "v2.pr03c.subscribed_rss";
    let measures = paired(
        name,
        "subscribed",
        1,
        1,
        || rss_sample(&rt, &mut small, "small"),
        || rss_sample(&rt, &mut god, "god"),
    );
    emit(name, measures, "bytes");
    measures.check(name, "subscribed", false);
}

// ---- v2.pr03c.append_behind_page ----

/// A live subscriber, and the bytes it consumed and credited.
struct Appender {
    reader: Reader,
    edition: u32,
    consumed: u64,
    credited: u64,
}

fn appender(rt: &Runtime, fixture: Fixture) -> Appender {
    let mut reader = Reader::new(rt, fixture);
    let client = &mut reader.client;
    let window = rt.block_on(async {
        client.sub("s", json!({})).await;
        client.window("s").await
    });
    let consumed = window_bytes(&window);
    Appender { reader, edition: window.edition, consumed, credited: consumed }
}

/// Puts every segment of a book out of the page cache: the next read of one is from the disk.
fn drop_cached(rows: &Path) {
    use std::os::fd::AsRawFd;
    for entry in fs::read_dir(rows).unwrap() {
        let file = File::open(entry.unwrap().path()).unwrap();
        // A page not yet written back is not dropped.
        file.sync_data().unwrap();
        // SAFETY: the descriptor is open for the call, and the call takes no memory of ours.
        let advised =
            unsafe { libc::posix_fadvise(file.as_raw_fd(), 0, 0, libc::POSIX_FADV_DONTNEED) };
        assert_eq!(advised, 0, "posix_fadvise");
    }
}

/// Frames to the live subscriber until a delta holds `marker`; the bytes they took.
async fn until_marker(client: &mut Client, marker: &[u8]) -> u64 {
    let mut consumed = 0;
    loop {
        let frame = client.recv().await;
        consumed += frame.encoded_len() as u64;
        assert_eq!(
            frame.kind,
            FrameKind::Delta,
            "the live subscriber got {}",
            String::from_utf8_lossy(frame.payload())
        );
        if frame.payload().windows(marker.len()).any(|bytes| bytes == marker) {
            return consumed;
        }
    }
}

/// A `page` from the chat's first row, its segment out of the page cache on both sides, goes
/// into the mailbox; then a line is appended and the actor woken. The time from the append to
/// its row's delta at the live subscriber: the append's wait behind the cold read.
fn append_sample(rt: &Runtime, side: &mut Appender) -> u64 {
    drop_cached(&side.reader.fixture.chat.book().join("rows"));
    let marker = format!("append-{:08}", side.reader.n);
    side.reader.n += 1;
    let notice = side.reader.fixture.raw.notice(&marker);
    let chat = &side.reader.fixture.chat;
    let handle = chat.registry.get("chat").expect("the subscribed chat's actor runs");
    let page: Page = serde_json::from_value(
        json!({"sid": "s", "stream": "chat:chat", "after": 1, "edition": side.edition}),
    )
    .unwrap();
    let (reply, answer) = Reply::channel("page", Some("s".to_owned()), None);
    handle.page(page, person_id(None), reply);
    chat.append(&[notice]);
    let start = Instant::now();
    handle.wake().unwrap();
    let consumed = rt.block_on(until_marker(&mut side.reader.client, marker.as_bytes()));
    let elapsed = start.elapsed().as_nanos() as u64;
    let page = answer.recv_timeout(WAIT).expect("the page is answered");
    assert_eq!(page.kind, FrameKind::Page, "{}", String::from_utf8_lossy(page.payload()));
    side.consumed += consumed;
    if side.consumed - side.credited >= CREDIT_WINDOW_BYTES / 4 {
        rt.block_on(side.reader.client.credit("s", side.consumed));
        side.credited = side.consumed;
    }
    elapsed
}

#[test]
#[ignore]
fn v2_pr03c_append_behind_page() {
    let rt = runtime();
    let (god, small) = god_and_small();
    let (mut god, mut small) = (appender(&rt, god), appender(&rt, small));
    // One row a sample on each side keeps the two at the same phase.
    assert_eq!(god.reader.phase(), small.reader.phase());
    let name = "v2.pr03c.append_behind_page";
    let measures = paired(
        name,
        "cold_page",
        8,
        100,
        || append_sample(&rt, &mut small),
        || append_sample(&rt, &mut god),
    );
    emit(name, measures, "ns");
    measures.check(name, "cold_page", true);
}

// ---- v2.pr03c.queue_window ----

const QUEUED: usize = 64;

/// A chat in a turn with 64 prompts of `text_bytes` waiting.
fn queue_chat(text_bytes: usize) -> Fixture {
    let text = "q".repeat(text_bytes);
    build(None, |raw, put| {
        for line in raw.open(1, "the turn the queue waits on") {
            put(line);
        }
        for n in 0..QUEUED {
            put(raw.queued(&format!("q{n:02}"), &text));
        }
    })
}

struct QueueSide {
    reader: Reader,
    text_bytes: usize,
    read: Vec<u64>,
}

/// From `sub` to the window's bytes at the client, and the bytes read on the way.
fn queue_sample(rt: &Runtime, side: &mut QueueSide) -> u64 {
    let sid = side.reader.sid("q");
    let client = &mut side.reader.client;
    let (elapsed, read, frame) = rt.block_on(async {
        let read = rchar();
        let start = Instant::now();
        client.sub(&sid, json!({})).await;
        let frame = window_frame(client).await;
        let elapsed = start.elapsed().as_nanos() as u64;
        let read = rchar() - read;
        unsub(client, &sid).await;
        (elapsed, read, frame)
    });
    let window: ChatWindow = frame.decode_json().unwrap();
    assert_eq!(window.sid, sid);
    assert_eq!(window.queue.count as usize, QUEUED);
    assert_eq!(window.queue.entries.len(), QUEUED);
    assert!(window.queue.entries.iter().all(|entry| entry.len == side.text_bytes as u64));
    side.read.push(read);
    elapsed
}

#[test]
#[ignore]
fn v2_pr03c_queue_window() {
    let rt = runtime();
    let mut sides = [100 * 1024, 100].map(|text_bytes| QueueSide {
        reader: Reader::new(&rt, queue_chat(text_bytes)),
        text_bytes,
        read: Vec::new(),
    });
    let [god, small] = &mut sides;
    assert_eq!(god.reader.fixture.last_seq, small.reader.fixture.last_seq, "the same records");
    let name = "v2.pr03c.queue_window";
    let measures = paired(
        name,
        "queue",
        WARMUP,
        SAMPLES,
        || queue_sample(&rt, small),
        || queue_sample(&rt, god),
    );
    let (small_read, god_read) = (percentile(&small.read), percentile(&god.read));
    println!("{name} mode=queue small_read_p95={small_read} god_read_p95={god_read}");
    emit(name, measures, "ns");
    measures.check(name, "queue", true);
    assert!(
        god_read as f64 <= small_read as f64 * 1.2 + READ_NOISE as f64,
        "{name}: god reads {god_read} bytes of the lines a window against {small_read}"
    );
}

// ---- v2.pr03c.prompt_blob_next ----

const BIG_PROMPT: usize = 100 * 1024 * 1024;
const SMALL_PROMPT: usize = 300 * 1024;

/// A `blob` of the waiting prompt `big`, from `from` when given, and its reply.
async fn prompt_blob(client: &mut Client, edition: u32, len: u64, from: Option<&str>) -> Frame {
    let mut params = json!({"id": "b", "stream": "chat:chat", "edition": edition,
        "prompt": "big", "len": len});
    if let Some(from) = from {
        params["from"] = from.into();
    }
    client.send(json!({"method": "blob", "params": params})).await;
    loop {
        let frame = client.recv().await;
        if frame.kind == FrameKind::Blob {
            return frame;
        }
        assert_ne!(frame.kind, FrameKind::Error, "{}", String::from_utf8_lossy(frame.payload()));
    }
}

struct PromptSide {
    reader: Reader,
    edition: u32,
    total: u64,
    /// The `next` token at the prompt's last 256 KB.
    token: String,
}

/// A chat in a turn with one prompt of `bytes` waiting, read on by `next` (outside any clock)
/// to its last 256 KB, as a client reads a long prompt.
fn prompt_side(rt: &Runtime, bytes: usize) -> PromptSide {
    let text = "p".repeat(bytes);
    let fixture = build(None, |raw, put| {
        for line in raw.open(1, "the turn the prompt waits on") {
            put(line);
        }
        put(raw.queued("big", &text));
    });
    drop(text);
    let mut reader = Reader::new(rt, fixture);
    let client = &mut reader.client;
    let target = (bytes - MAX_BLOB_READ) as u64;
    let (edition, token) = rt.block_on(async {
        client.sub("s", json!({})).await;
        let window = client.window("s").await;
        assert_eq!(window.queue.count, 1);
        let (mut at, mut token) = (0, None::<String>);
        while at < target {
            let len = (target - at).min(MAX_BLOB_READ as u64);
            let frame = prompt_blob(client, window.edition, len, token.as_deref()).await;
            let (head, piece) = decode_blob(&frame).unwrap();
            assert_eq!((head.start, head.len, piece.len() as u64), (at, len, len));
            at += head.len;
            token = head.next;
        }
        (window.edition, token.expect("a prompt read short of its end has a next token"))
    });
    assert_eq!(Token::decode(&token).map(|token| token.text), Some(target));
    PromptSide { reader, edition, total: bytes as u64, token }
}

/// One request from the `next` token for the last 256 KB, sent to its reply's bytes in.
fn prompt_sample(rt: &Runtime, side: &mut PromptSide) -> u64 {
    let (edition, token) = (side.edition, side.token.clone());
    let client = &mut side.reader.client;
    let (elapsed, frame) = rt.block_on(async {
        let start = Instant::now();
        let frame = prompt_blob(client, edition, MAX_BLOB_READ as u64, Some(&token)).await;
        (start.elapsed().as_nanos() as u64, frame)
    });
    let (head, bytes) = decode_blob(&frame).unwrap();
    assert_eq!(head.start, side.total - MAX_BLOB_READ as u64);
    assert_eq!(head.len, MAX_BLOB_READ as u64);
    assert_eq!(head.total, side.total);
    assert!(head.next.is_none(), "the last range has no next token");
    assert!(bytes.iter().all(|byte| *byte == b'p'));
    elapsed
}

#[test]
#[ignore]
fn v2_pr03c_prompt_blob_next() {
    let rt = runtime();
    let mut god = prompt_side(&rt, BIG_PROMPT);
    let mut small = prompt_side(&rt, SMALL_PROMPT);
    assert_eq!(god.reader.fixture.last_seq, small.reader.fixture.last_seq, "the same records");
    let name = "v2.pr03c.prompt_blob_next";
    let measures = paired(
        name,
        "next",
        WARMUP,
        SAMPLES,
        || prompt_sample(&rt, &mut small),
        || prompt_sample(&rt, &mut god),
    );
    emit(name, measures, "ns");
    measures.check(name, "next", true);
}

// ---- v2.pr04.chat_stopped_reader ----

/// Raw bytes streamed to the stopped reader: PR 4's connection shapes.
const STOPPED_SMALL: u64 = 16 << 20;
const STOPPED_GOD: u64 = 1 << 30;
/// Both sides reset their peak this far before the end: stretches of the same length.
const STOPPED_STRETCH: u64 = 8 << 20;
const STOPPED_TEXT: usize = 8 * 1024;
const STOPPED_BATCH: usize = 128;
/// Settled rows the reference reader keeps, by id: more than any window holds.
const VIEW_ROWS: usize = 4096;
const STOPPED_CASE: &str = "V2_PR04_CHAT_CASE";
const STOPPED_LINE: &str = "PR4_CHAT_STOPPED ";

fn hash_of(text: &str) -> u64 {
    let mut hasher = DefaultHasher::new();
    text.hash(&mut hasher);
    hasher.finish()
}

/// The highest `k0000000001:` marker in a payload.
fn marker_in(payload: &[u8]) -> u64 {
    payload
        .windows(12)
        .filter(|w| w[0] == b'k' && w[11] == b':' && w[1..11].iter().all(u8::is_ascii_digit))
        .filter_map(|w| std::str::from_utf8(&w[1..11]).ok()?.parse().ok())
        .max()
        .unwrap_or(0)
}

/// What a reader holds: its cursor, its last window's rows, and the last settled rows by id (as
/// hashes of their text, so a 1 GiB stream holds no more than they do).
#[derive(Default)]
struct View {
    rows: BTreeMap<u64, u64>,
    window: Vec<(u64, u64)>,
    cursor: u64,
    edition: u32,
    consumed: u64,
    windows: usize,
    marker: u64,
}

impl View {
    fn keep(&mut self, row: &RawJson) -> (u64, u64) {
        let head = RowHead::parse(row.get().as_bytes()).expect("a row text");
        let hashed = (head.id, hash_of(row.get()));
        self.rows.insert(hashed.0, hashed.1);
        while self.rows.len() > VIEW_ROWS {
            self.rows.pop_first();
        }
        hashed
    }

    /// A replayed record comes once, after the cursor; a live op is never behind it.
    fn seq(&mut self, seq: u64, replayed: bool) {
        if replayed {
            assert!(seq > self.cursor, "record {seq} replayed again at {}", self.cursor);
        } else {
            assert!(seq >= self.cursor, "op at {seq} behind the cursor {}", self.cursor);
        }
        self.cursor = seq;
    }

    fn apply(&mut self, frame: &Frame) {
        self.consumed += frame.encoded_len() as u64;
        self.marker = self.marker.max(marker_in(frame.payload()));
        if frame.kind == FrameKind::Window {
            let window: ChatWindow = frame.decode_json().unwrap();
            assert!(window.cursor >= self.cursor, "a window behind the cursor");
            self.cursor = window.cursor;
            self.edition = window.edition;
            self.windows += 1;
            let rows = window.rows.iter().map(|row| self.keep(row)).collect();
            self.window = rows;
            return;
        }
        assert_eq!(frame.kind, FrameKind::Delta, "{}", String::from_utf8_lossy(frame.payload()));
        let delta: ChatDelta = frame.decode_json().unwrap();
        let replayed = delta.replay == Some(ReplayMark::Replay);
        for op in &delta.ops {
            match op {
                ChatOp::Row { seq, row, body_len } => {
                    self.seq(*seq, replayed);
                    if body_len.is_none() {
                        self.keep(row);
                    }
                }
                ChatOp::Patch { seq, row } => {
                    self.seq(*seq, replayed);
                    self.keep(row);
                }
                ChatOp::Text { seq, .. } | ChatOp::Queue { seq, .. } => self.seq(*seq, false),
            }
        }
    }
}

/// `total` raw bytes of replies to a chat with a reader that stopped after its window and a
/// reference reader that keeps up. The peak resident rise over the last 8 MiB and the resume,
/// less the baseline taken after the free pages went back; then the stopped reader resumes
/// and ends where the reference does, holding the same rows.
async fn stopped(total: u64) -> Value {
    let mut raw = Raw::default();
    let chat = Chat::new(&raw.open(1, "the turn the replies stream in"));
    let mut slow = chat.connect(1, &["chat"]);
    slow.hello(None).await;
    slow.sub("slow", json!({})).await;
    let mut slow_view = View::default();
    slow_view.apply(&window_frame(&mut slow).await);
    let mut fast = chat.connect(2, &["chat"]);
    fast.hello(None).await;
    fast.sub("fast", json!({})).await;
    let mut fast_view = View::default();
    fast_view.apply(&window_frame(&mut fast).await);
    let (progress, mut seen) = watch::channel(0u64);
    let (stop, mut stopping) = tokio::sync::oneshot::channel::<()>();
    let reference = tokio::spawn(async move {
        let mut credited = fast_view.consumed;
        loop {
            let frame = tokio::select! {
                frame = fast.recv() => frame,
                _ = &mut stopping => break,
            };
            fast_view.apply(&frame);
            if fast_view.consumed - credited >= CREDIT_WINDOW_BYTES / 4 {
                fast.credit("fast", fast_view.consumed).await;
                credited = fast_view.consumed;
            }
            progress.send_replace(fast_view.marker);
        }
        (fast, fast_view)
    });
    let filler = "y".repeat(STOPPED_TEXT);
    crate::memory::release_free_pages();
    reset_peak();
    let baseline = status_bytes("VmRSS:");
    let (mut bytes, mut k, mut rise, mut whole, mut reset) = (0u64, 0u64, 0u64, 0u64, false);
    while bytes < total {
        let mut lines = Vec::with_capacity(STOPPED_BATCH);
        for _ in 0..STOPPED_BATCH {
            k += 1;
            let line = raw.reply(k, &format!("k{k:010}:{filler}"));
            bytes += line.len() as u64 + 1;
            lines.push(line);
        }
        chat.append(&lines);
        if let Some(handle) = chat.registry.get("chat") {
            let _ = handle.wake();
        }
        tokio::time::timeout(WAIT, seen.wait_for(|marker| *marker >= k))
            .await
            .expect("the reference reader keeps up")
            .expect("the reference reader runs");
        whole = whole.max(status_bytes("VmHWM:").saturating_sub(baseline));
        if !reset && bytes + STOPPED_STRETCH >= total {
            reset_peak();
            reset = true;
        }
        if reset {
            rise = rise.max(status_bytes("VmHWM:").saturating_sub(baseline));
        }
    }
    stop.send(()).unwrap();
    let (_fast, fast_view) = reference.await.unwrap();
    // The stopped reader reads what its credit let through, credits it, and resumes.
    let mut credited = 0;
    slow.credit("slow", slow_view.consumed).await;
    while slow_view.cursor < fast_view.cursor || slow_view.windows < 2 {
        let frame = slow.recv().await;
        if frame.kind == FrameKind::Dropped {
            let params = json!({"cursor": slow_view.cursor, "edition": slow_view.edition});
            slow.sub("slow", params).await;
            (slow_view.consumed, credited) = (0, 0);
            continue;
        }
        slow_view.apply(&frame);
        if slow_view.consumed - credited >= CREDIT_WINDOW_BYTES / 4 {
            slow.credit("slow", slow_view.consumed).await;
            credited = slow_view.consumed;
        }
    }
    assert_eq!(slow_view.cursor, fast_view.cursor, "the resumed reader ends where the other does");
    assert!(!slow_view.window.is_empty());
    for (id, hash) in &slow_view.window {
        assert_eq!(fast_view.rows.get(id), Some(hash), "row {id} after the resume");
    }
    // The resume is in the mark too.
    rise = rise.max(status_bytes("VmHWM:").saturating_sub(baseline));
    whole = whole.max(rise);
    json!({"rise": rise, "whole": whole, "bytes": bytes, "lines": k, "windows": slow_view.windows})
}

/// The child entry point: one side in a fresh process, so its peak is this stream's alone.
#[test]
#[ignore]
fn v2_pr04_chat_stopped_worker() {
    let Ok(case) = std::env::var(STOPPED_CASE) else { return };
    let total = if case == "god" { STOPPED_GOD } else { STOPPED_SMALL };
    let result = runtime().block_on(stopped(total));
    println!("{STOPPED_LINE}{result}");
}

fn stopped_worker(case: &str) -> Value {
    let module = module_path!().split_once("::").map_or("", |(_, path)| path);
    let test = format!("{module}::v2_pr04_chat_stopped_worker");
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["--exact", &test, "--ignored", "--nocapture", "--test-threads=1"])
        .env(STOPPED_CASE, case)
        .output()
        .unwrap();
    let stdout = String::from_utf8(output.stdout).unwrap();
    print!("{stdout}");
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    let line = stdout.lines().find_map(|line| line.strip_prefix(STOPPED_LINE)).unwrap();
    serde_json::from_str(line).unwrap()
}

#[test]
#[ignore]
fn v2_pr04_chat_stopped_reader() {
    let small = stopped_worker("small");
    let god = stopped_worker("god");
    let rise = |result: &Value| result["rise"].as_u64().unwrap();
    let name = "v2.pr04.chat_stopped_reader";
    let (small_rise, god_rise) = (rise(&small), rise(&god));
    let measures =
        Measures { small: small_rise, god: god_rise, small_all: small_rise, god_all: god_rise };
    measures.report(name, "stopped");
    emit(name, measures, "bytes");
    for (side, result) in [("small", &small), ("god", &god)] {
        assert!(
            rise(result) < CONNECTION_BUDGET_BYTES as u64,
            "{name} {side}: the rise is past the connection budget: {result}"
        );
    }
    measures.check(name, "stopped", false);
}
