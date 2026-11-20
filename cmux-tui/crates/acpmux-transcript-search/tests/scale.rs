//! `acpmux search` at the size that broke grep: one 500 MB Claude Code transcript (the desktop
//! coordinator's was 542 MB, 134K lines, 2026-11-18) and a machine's worth of others, before and
//! after the index, in one harness.
//!
//! Before: what a search costs with no index, the best a grep can do: one pass over the raw
//! file's bytes (`memmem`, no JSON parse, so it also misses a phrase JSON-escaped in the file), and
//! a correct pass (each line parsed, its text searched). After: the cold index of the transcript,
//! one appended turn caught up (the constant cost per new turn), and query p50/p95 for one
//! session and across every session.
//!
//! Bars: a one-session query p95 under 200 ms, an every-session query p95 under 1 s, and an
//! appended turn's catch-up p95 under 50 ms.
//!
//! Run by hand (minutes; needs ~3 GB of disk at the defaults):
//! `cargo test -p acpmux-transcript-search --release --test scale -- --ignored --nocapture`.
//! `SCALE_MB=500` sets the big transcript's size, `SCALE_HOST_FILES=200` and
//! `SCALE_HOST_FILE_MB=5` the other sessions'.

use std::io::{BufWriter, Write as _};
use std::path::Path;
use std::time::{Duration, Instant};

use acpmux_transcript_search::{Harness, Index, Query, Role, Source};
use serde_json::json;

const ROUNDS: usize = 40;
const NEEDLE: &str = "four agent pages";

fn env_num(key: &str, default: u64) -> u64 {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

/// A deterministic word stream with English-like trigrams.
struct Words(u64);

const VOCAB: &[&str] = &[
    "the",
    "agent",
    "session",
    "transcript",
    "search",
    "index",
    "turn",
    "page",
    "build",
    "merge",
    "test",
    "linux",
    "daemon",
    "peer",
    "query",
    "result",
    "commit",
    "branch",
    "review",
    "fix",
    "render",
    "sidebar",
    "chat",
    "prompt",
    "reply",
    "tool",
    "file",
    "line",
    "check",
    "green",
    "nightly",
    "cache",
    "store",
    "reader",
    "writer",
    "window",
    "scroll",
    "row",
    "column",
    "snippet",
    "context",
    "compaction",
    "summary",
    "and",
    "of",
    "to",
    "in",
    "is",
    "for",
    "with",
    "on",
    "that",
    "this",
    "it",
    "as",
    "we",
    "run",
    "time",
    "ms",
    "bytes",
    "open",
    "close",
    "state",
    "path",
];

impl Words {
    fn next(&mut self) -> &'static str {
        self.0 =
            self.0.wrapping_mul(6_364_136_223_846_793_005).wrapping_add(1_442_695_040_888_963_407);
        VOCAB[((self.0 >> 33) % VOCAB.len() as u64) as usize]
    }

    fn text(&mut self, bytes: usize) -> String {
        let mut out = String::with_capacity(bytes + 16);
        let mut n = 0;
        while out.len() < bytes {
            if n > 0 {
                out.push(if n % 14 == 0 { '\n' } else { ' ' });
            }
            out.push_str(self.next());
            n += 1;
        }
        out
    }
}

fn at(i: u64) -> String {
    let s = 1_790_000_000 + i;
    let (d, r) = (s / 86_400, s % 86_400);
    // Days since 1970 to a civil date (inverse of Hinnant's days_from_civil).
    let z = d as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let day = doy - (153 * mp + 2) / 5 + 1;
    let month = if mp < 10 { mp + 3 } else { mp - 9 };
    let year = yoe + era * 400 + i64::from(month <= 2);
    format!("{year:04}-{month:02}-{day:02}T{:02}:{:02}:{:02}.000Z", r / 3600, r % 3600 / 60, r % 60)
}

/// One turn's lines, shaped as Claude Code writes them, about `filler` bytes of bookkeeping
/// (`api-request-blob`, attachments) for each ~6 KB said.
fn turn(w: &mut Words, i: u64, filler: usize, out: &mut Vec<String>) {
    let t = at(i * 10);
    out.push(json!({"type": "user", "timestamp": t, "message": {"role": "user", "content": w.text(500)}}).to_string());
    for k in 0..3 {
        out.push(json!({"type": "assistant", "timestamp": t, "message": {"content": [
            {"type": "tool_use", "id": format!("t{i}-{k}"), "name": "Bash", "input": {"command": w.text(150)}}]}})
        .to_string());
        out.push(
            json!({"type": "user", "timestamp": t, "message": {"content": [
            {"type": "tool_result", "tool_use_id": format!("t{i}-{k}"), "content": w.text(1500)}]}})
            .to_string(),
        );
    }
    out.push(json!({"type": "assistant", "timestamp": t, "message": {"content": [{"type": "text", "text": w.text(1000)}]}}).to_string());
    out.push(
        json!({"type": "api-request-blob", "timestamp": t, "blob": w.text(filler)}).to_string(),
    );
}

/// Writes a transcript of about `mb` MB to `path`; `needle_at` plants [`NEEDLE`] in that turn's
/// reply. Returns the turns written.
fn write_transcript(path: &Path, mb: u64, seed: u64, needle_at: Option<u64>) -> u64 {
    let mut w = Words(seed);
    let mut f = BufWriter::new(std::fs::File::create(path).unwrap());
    let (mut bytes, mut i, mut lines) = (0u64, 0u64, Vec::new());
    while bytes < mb << 20 {
        turn(&mut w, i, 48 * 1024, &mut lines);
        if needle_at == Some(i) {
            let text = format!("Next: the {NEEDLE}, then\nthe \"index\" itself.");
            lines.push(json!({"type": "assistant", "timestamp": at(i * 10), "message": {"content": [{"type": "text", "text": text}]}}).to_string());
            // What a compaction leaves after it: the turns before stay in the file.
            lines.push(json!({"type": "user", "isCompactSummary": true, "timestamp": at(i * 10 + 1), "message": {"content": "This session is being continued from a previous conversation."}}).to_string());
        }
        for l in lines.drain(..) {
            bytes += l.len() as u64 + 1;
            writeln!(f, "{l}").unwrap();
        }
        i += 1;
    }
    f.flush().unwrap();
    i
}

fn pct(mut v: Vec<Duration>, p: f64) -> f64 {
    v.sort();
    let i = ((v.len() as f64 - 1.0) * p).round() as usize;
    v[i].as_secs_f64() * 1000.0
}

fn timed(rounds: usize, mut f: impl FnMut()) -> (f64, f64) {
    let mut v = Vec::with_capacity(rounds);
    for _ in 0..rounds {
        let t = Instant::now();
        f();
        v.push(t.elapsed());
    }
    (pct(v.clone(), 0.5), pct(v, 0.95))
}

#[test]
#[ignore = "scale bench: minutes and gigabytes; run by hand"]
fn search_at_500_mb_and_across_a_machine() {
    let dir = tempfile::tempdir().unwrap();
    let big = dir.path().join("big.jsonl");
    let mb = env_num("SCALE_MB", 500);
    let turns = write_transcript(&big, mb, 7, Some(5));
    let size = std::fs::metadata(&big).unwrap().len();
    println!("transcript: {} MB, {turns} turns", size >> 20);

    // Before: no index.
    let t = Instant::now();
    let raw = std::fs::read(&big).unwrap();
    let raw_hits = memchr::memmem::find_iter(&raw, NEEDLE.as_bytes()).count();
    let raw_ms = t.elapsed().as_secs_f64() * 1000.0;
    drop(raw);
    let t = Instant::now();
    let mut parsed_hits = 0;
    let mut state = Default::default();
    for line in std::fs::read(&big).unwrap().split(|b| *b == b'\n') {
        let got = acpmux_transcript_search::parse::line(Harness::Claude, line, &mut state);
        parsed_hits +=
            got.docs.iter().filter(|d| d.text.to_ascii_lowercase().contains(NEEDLE)).count();
    }
    let parsed_ms = t.elapsed().as_secs_f64() * 1000.0;
    println!(
        "before: raw byte scan {raw_ms:.0} ms ({raw_hits} hits), parse-and-search {parsed_ms:.0} ms ({parsed_hits} hits)"
    );

    // After.
    let db = dir.path().join("index.sqlite");
    let index = Index::open(&db).unwrap();
    let src = Source {
        path: big.clone(),
        harness: Harness::Claude,
        session: "big".into(),
        subagent: false,
    };
    let t = Instant::now();
    let cold = index.catch_up(&src).unwrap();
    let cold_ms = t.elapsed().as_secs_f64() * 1000.0;
    println!(
        "cold index: {cold_ms:.0} ms, {} docs, index {} MB",
        cold.docs,
        std::fs::metadata(&db).unwrap().len() >> 20
    );

    let mut session = Query::new(NEEDLE);
    session.sessions = Some(vec!["big".into()]);
    let hits = index.search(&session).unwrap();
    assert_eq!(hits.len(), 1, "the planted phrase, before the compaction");
    assert_eq!(hits[0].role, Role::Assistant);
    assert!(
        hits[0].snippet.contains("then\nthe \"index\" itself."),
        "unescaped: {:?}",
        hits[0].snippet
    );

    let mut common = Query::new("the agent");
    common.sessions = Some(vec!["big".into()]);
    let mut absent = Query::new("zqxj vkwp");
    absent.sessions = Some(vec!["big".into()]);
    let rare = timed(ROUNDS, || assert_eq!(index.search(&session).unwrap().len(), 1));
    let many = timed(ROUNDS, || assert_eq!(index.search(&common).unwrap().len(), 20));
    let none = timed(ROUNDS, || assert!(index.search(&absent).unwrap().is_empty()));
    println!(
        "one session: rare p50 {:.1} / p95 {:.1} ms; common p50 {:.1} / p95 {:.1} ms; absent p50 {:.1} / p95 {:.1} ms",
        rare.0, rare.1, many.0, many.1, none.0, none.1
    );

    // An appended turn: catch-up plus a search, as `acpmux search` runs it.
    let mut w = Words(99);
    let mut appends = Vec::new();
    for i in 0..ROUNDS as u64 {
        let mut lines = Vec::new();
        turn(&mut w, turns + i, 48 * 1024, &mut lines);
        let mut f = std::fs::OpenOptions::new().append(true).open(&big).unwrap();
        for l in &lines {
            writeln!(f, "{l}").unwrap();
        }
        drop(f);
        let t = Instant::now();
        let (hits, done) =
            acpmux_transcript_search::search(&index, std::slice::from_ref(&src), &session).unwrap();
        appends.push(t.elapsed());
        assert_eq!(hits.len(), 1);
        assert_eq!(done.caught_up.docs, 8);
    }
    let append = (pct(appends.clone(), 0.5), pct(appends, 0.95));
    println!("appended turn caught up and searched: p50 {:.1} / p95 {:.1} ms", append.0, append.1);

    // A machine's other sessions.
    let files = env_num("SCALE_HOST_FILES", 200);
    let file_mb = env_num("SCALE_HOST_FILE_MB", 5);
    let mut sources = vec![src];
    for k in 0..files {
        let path = dir.path().join(format!("s{k}.jsonl"));
        write_transcript(&path, file_mb, 1000 + k, (k % 50 == 0).then_some(3));
        sources.push(Source {
            path,
            harness: Harness::Claude,
            session: format!("s{k}"),
            subagent: false,
        });
    }
    let t = Instant::now();
    for s in &sources[1..] {
        index.catch_up(s).unwrap();
    }
    println!(
        "host: {} more sessions ({} MB) indexed in {:.0} ms; index {} MB",
        files,
        files * file_mb,
        t.elapsed().as_secs_f64() * 1000.0,
        std::fs::metadata(&db).unwrap().len() >> 20
    );
    let host = Query::new(NEEDLE);
    let expect = 1 + files.div_ceil(50) as usize;
    let host_rare =
        timed(ROUNDS, || assert_eq!(index.search(&host).unwrap().len(), expect.min(20)));
    let host_common =
        timed(ROUNDS, || assert_eq!(index.search(&Query::new("the agent")).unwrap().len(), 20));
    let host_absent =
        timed(ROUNDS, || assert!(index.search(&Query::new("zqxj vkwp")).unwrap().is_empty()));
    // What `acpmux search` with no session costs when nothing changed: a catch-up of every file.
    let host_full = timed(10, || {
        acpmux_transcript_search::search(&index, &sources, &host).unwrap();
    });
    println!(
        "every session: rare p50 {:.1} / p95 {:.1} ms; common p50 {:.1} / p95 {:.1} ms; absent p50 {:.1} / p95 {:.1} ms; with catch-up of {} files p50 {:.1} / p95 {:.1} ms",
        host_rare.0,
        host_rare.1,
        host_common.0,
        host_common.1,
        host_absent.0,
        host_absent.1,
        sources.len(),
        host_full.0,
        host_full.1
    );

    for (what, p95, bar) in [
        ("one-session rare", rare.1, 200.0),
        ("one-session common", many.1, 200.0),
        ("one-session absent", none.1, 200.0),
        ("appended turn", append.1, 50.0),
        ("every-session rare", host_rare.1, 1000.0),
        ("every-session common", host_common.1, 1000.0),
        ("every-session absent", host_absent.1, 1000.0),
        ("every-session with catch-up", host_full.1, 1000.0),
    ] {
        assert!(p95 < bar, "{what}: p95 {p95:.1} ms is over {bar} ms");
    }
}
