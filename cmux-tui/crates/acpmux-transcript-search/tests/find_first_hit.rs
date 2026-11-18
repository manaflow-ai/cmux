//! Find in Chat's find-to-first-hit at Leo's scale (one 500 MB Claude Code session; 201 sessions,
//! about 1.5 GB in all), before and after the transcript index, in one harness (Leo, 2026-11-18:
//! "shouldn't you be able to like have better tools for finding stuff?").
//!
//! Before (feat-cmux-next today): Find in Chat matches only the rows the pane holds. A phrase in a
//! turn not loaded is found only once the reader pages older history in, so its cost is the pages
//! read back from the tail until one holds it. This crate cannot reach the real page reader
//! (`acpmux::adopt_replay::claude_page_with_turns_open`, crate-private, and `acpmux` is not a
//! dev-dependency here), so [`page`] is a line-for-line port of `claude_page_open`
//! (`cmux-tui/crates/acpmux/src/adopt_replay_page.rs`): 1 MiB backward reads, the same
//! `"user"`/`"assistant"` prefilter and `serde_json` parse of each line once. Two page rules:
//! - native: `_acpmux/native_history` (an adopted Claude chat): a page stops at its oldest prompt
//!   once it has read `PAGE_BYTES` (8 MiB), at `PAGE_TURNS` (200) prompts, or at `PAGE_MAX_BYTES`
//!   (16 MiB);
//! - events: `_acpmux/events` pages of `OLDER_PAGE_BYTES` (1 MiB, webviews `direct.ts`), modelled
//!   as 1 MiB of the same transcript lines.
//!
//! Each page is also encoded to JSON and decoded again (the JSON-RPC reply and the webview's
//! parse of it), then its rows' text is lowercased and searched as `chatFind.ts` does. Nothing is
//! rendered, no IPC is crossed and the file is in the page cache, so "before" is a lower bound.
//! The newest page is the one the pane opened with: it is already parsed and only searched.
//!
//! After: `acpmux_transcript_search::search` scoped to the session (catch-up of its transcripts,
//! then the index query), as `_acpmux/transcript_search` runs it. Cold: an empty index, so the
//! first search reads the whole session (a one-time cost the daemon pays in the background at
//! start). Warm: the index holds the session and the 200 others. Then one page read: the native
//! page ending just after the hit's line, the read a reveal needs when it knows where the hit is.
//!
//! Run by hand (minutes; ~3 GB of disk at the defaults), on the fleet:
//! `cargo test -p acpmux-transcript-search --release --test find_first_hit -- --ignored --nocapture`.
//! `SCALE_MB` (500), `SCALE_SUBAGENT_MB` (20), `SCALE_HOST_FILES` (200), `SCALE_HOST_FILE_MB` (5),
//! `BEFORE_ROUNDS` (7), `AFTER_ROUNDS` (100). JSON lines go to stdout and, when `FAST_CHECKS_OUT`
//! is set, to `$FAST_CHECKS_OUT/find_first_hit.jsonl`.

use std::fs::File;
use std::io::{BufWriter, Read as _, Seek as _, SeekFrom, Write as _};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use acpmux_transcript_search::{Harness, Index, Query, Source};
use serde_json::{Value, json};

fn env_num(key: &str, default: u64) -> u64 {
    std::env::var(key).ok().and_then(|v| v.parse().ok()).unwrap_or(default)
}

// ---- The generator: `tests/scale.rs`'s, copied (an integration test cannot import another). ----

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

/// A rare phrase planted once in a transcript, in the first turn written at or past `target`
/// bytes; `compact` follows it with a compaction's summary line (the turns before stay in the
/// file, as Claude Code leaves them).
struct Plant {
    label: &'static str,
    phrase: &'static str,
    target: u64,
    compact: bool,
    /// Where its line starts, and where the next line starts.
    offset: Option<(u64, u64)>,
}

/// Writes about `mb` MB of `scale.rs`'s turns to `path`, planting `plants`. Returns the turns.
fn write_transcript(path: &Path, mb: u64, seed: u64, plants: &mut [Plant]) -> u64 {
    let mut w = Words(seed);
    let mut f = BufWriter::new(File::create(path).unwrap());
    let (mut bytes, mut i, mut lines) = (0u64, 0u64, Vec::<(String, Option<usize>)>::new());
    let mut batch = Vec::new();
    while bytes < mb << 20 {
        turn(&mut w, i, 48 * 1024, &mut batch);
        lines.extend(batch.drain(..).map(|l| (l, None)));
        for (k, p) in plants.iter_mut().enumerate() {
            if p.offset.is_none() && bytes >= p.target {
                let text = format!("Earlier: the {}, then\nthe \"index\" itself.", p.phrase);
                lines.push((json!({"type": "assistant", "timestamp": at(i * 10), "message": {"content": [{"type": "text", "text": text}]}}).to_string(), Some(k)));
                if p.compact {
                    lines.push((json!({"type": "user", "isCompactSummary": true, "timestamp": at(i * 10 + 1), "message": {"content": "This session is being continued from a previous conversation."}}).to_string(), None));
                }
                p.offset = Some((0, 0));
            }
        }
        for (l, plant) in lines.drain(..) {
            let len = l.len() as u64 + 1;
            if let Some(k) = plant {
                plants[k].offset = Some((bytes, bytes + len));
            }
            bytes += len;
            writeln!(f, "{l}").unwrap();
        }
        i += 1;
    }
    f.flush().unwrap();
    i
}

// ---- Before: the page reader, ported from `adopt_replay_page.rs::claude_page_open`. ----

const CHUNK: u64 = 1 << 20;

#[derive(Clone, Copy)]
struct PageRule {
    name: &'static str,
    /// Once read and holding a prompt, stop at the oldest prompt (`PAGE_BYTES`); 0: never.
    soft: u64,
    /// The most a page reads (`PAGE_MAX_BYTES`).
    hard: u64,
    /// The most prompts a page holds (`PAGE_TURNS`).
    want: usize,
}

const NATIVE: PageRule =
    PageRule { name: "native_history", soft: 8 << 20, hard: 16 << 20, want: 200 };
const EVENTS: PageRule = PageRule { name: "events", soft: 0, hard: 1 << 20, want: usize::MAX };

struct Page {
    /// Its parsed lines, newest first.
    records: Vec<Value>,
    start: u64,
    read: u64,
}

/// `adopt_replay_page.rs::parse`.
fn parse(line: &[u8]) -> Option<Value> {
    let finder = |needle: &[u8]| memchr::memmem::find(line, needle).is_some();
    if !finder(b"\"user\"") && !finder(b"\"assistant\"") {
        return None;
    }
    serde_json::from_slice(line).ok()
}

/// `claude_steps`' prompt rule, as `parse.rs` reads it: a user line with text of its own.
fn is_prompt(record: &Value) -> bool {
    if record.get("type").and_then(Value::as_str) != Some("user")
        || record.get("isMeta").and_then(Value::as_bool) == Some(true)
        || record.get("isCompactSummary").and_then(Value::as_bool) == Some(true)
    {
        return false;
    }
    match record.pointer("/message/content") {
        Some(Value::String(_)) => true,
        Some(Value::Array(blocks)) => {
            blocks.iter().any(|b| b.get("type").and_then(Value::as_str) == Some("text"))
        }
        _ => false,
    }
}

/// The page of `f` ending at `end` under `rule`: `claude_page_open`'s loop, keeping the parsed
/// lines instead of folding them into turns.
fn page(f: &mut File, end: u64, rule: PageRule) -> Page {
    let mut lines: Vec<(u64, Value)> = Vec::new();
    let (mut prompts, mut oldest_prompt) = (0usize, None);
    let mut pos = end;
    let mut head: Vec<u8> = Vec::new();
    let (mut skip, mut whole) = (true, false);
    let start = 'scan: loop {
        if pos == 0 {
            if let Some(record) = parse(&head) {
                lines.push((0, record));
            }
            break 'scan 0;
        }
        let take = CHUNK.min(pos);
        pos -= take;
        let mut buf = vec![0u8; take as usize];
        f.seek(SeekFrom::Start(pos)).unwrap();
        f.read_exact(&mut buf).unwrap();
        buf.extend_from_slice(&head);
        if skip {
            match memchr::memrchr(b'\n', &buf) {
                Some(i) => {
                    buf.truncate(i + 1);
                    skip = false;
                }
                None => {
                    head = Vec::new();
                    if end - pos >= rule.hard {
                        break 'scan pos;
                    }
                    continue;
                }
            }
        }
        let first_break = memchr::memchr(b'\n', &buf);
        let whole_from = first_break.map_or(buf.len(), |i| i + 1);
        let mut line_end = buf.len();
        while line_end > whole_from {
            let body_end = line_end - 1;
            let before = &buf[..body_end];
            let line_start = memchr::memrchr(b'\n', before).map_or(0, |i| i + 1);
            let offset = pos + line_start as u64;
            whole = true;
            if let Some(record) = parse(&before[line_start..]) {
                let prompt = is_prompt(&record);
                lines.push((offset, record));
                if prompt {
                    prompts += 1;
                    oldest_prompt = Some(offset);
                    if prompts >= rule.want {
                        break 'scan offset;
                    }
                }
            }
            line_end = line_start;
        }
        head = buf[..whole_from].to_vec();
        if pos == 0 {
            continue;
        }
        let read = end - pos;
        if rule.soft > 0
            && let Some(prompt) = oldest_prompt.filter(|_| read >= rule.soft)
        {
            break 'scan prompt;
        }
        if read >= rule.hard {
            let oldest_line = if whole { pos + head.len() as u64 } else { pos };
            break 'scan if rule.soft > 0 {
                oldest_prompt.unwrap_or(oldest_line)
            } else {
                oldest_line
            };
        }
    };
    let records = lines.into_iter().filter(|(o, _)| *o >= start).map(|(_, r)| r).collect();
    Page { records, start, read: end - pos }
}

/// The text a row shows for `record` (its prompt, answer, tool input or output).
fn row_texts<'a>(record: &'a Value, out: &mut Vec<std::borrow::Cow<'a, str>>) {
    match record.pointer("/message/content") {
        Some(Value::String(s)) => out.push(s.as_str().into()),
        Some(Value::Array(blocks)) => {
            for b in blocks {
                match b.get("type").and_then(Value::as_str) {
                    Some("text") => {
                        if let Some(t) = b.get("text").and_then(Value::as_str) {
                            out.push(t.into());
                        }
                    }
                    Some("tool_use") => {
                        out.push(b.get("input").map(Value::to_string).unwrap_or_default().into());
                    }
                    Some("tool_result") => match b.get("content") {
                        Some(Value::String(s)) => out.push(s.as_str().into()),
                        Some(other) => out.push(other.to_string().into()),
                        None => {}
                    },
                    _ => {}
                }
            }
        }
        _ => {}
    }
}

/// `chatFind.ts` over loaded rows: each row's text lowercased, searched for the lowercased query.
fn rows_hold(records: &[Value], needle: &str) -> bool {
    let needle = needle.to_lowercase();
    let mut texts: Vec<std::borrow::Cow<'_, str>> = Vec::new();
    for r in records {
        texts.clear();
        row_texts(r, &mut texts);
        if texts.iter().any(|t| t.to_lowercase().contains(&needle)) {
            return true;
        }
    }
    false
}

/// A page as the pane gets it: encoded as the reply, decoded by the webview.
fn over_the_wire(records: Vec<Value>) -> Vec<Value> {
    let wire = serde_json::to_vec(&Value::Array(records)).unwrap();
    match serde_json::from_slice(&wire).unwrap() {
        Value::Array(v) => v,
        _ => unreachable!(),
    }
}

struct Before {
    found: bool,
    pages: u64,
    bytes: u64,
}

/// Find in Chat today: the newest page (`loaded`) searched, then pages read back from its start
/// until one holds `needle`, or the file's start.
fn before(
    path: &Path,
    rule: PageRule,
    loaded: &[Value],
    loaded_start: u64,
    needle: &str,
) -> Before {
    let mut done = Before { found: rows_hold(loaded, needle), pages: 0, bytes: 0 };
    let mut f = File::open(path).unwrap();
    let mut cursor = loaded_start;
    while !done.found && cursor > 0 {
        let p = page(&mut f, cursor, rule);
        done.pages += 1;
        done.bytes += p.read;
        assert!(p.start < cursor, "a page moves back");
        cursor = p.start;
        done.found = rows_hold(&over_the_wire(p.records), needle);
    }
    done
}

// ---- Stats and output. ----

fn pct(v: &[Duration], p: f64) -> f64 {
    let mut v = v.to_vec();
    v.sort();
    let i = ((v.len() as f64 - 1.0) * p).round() as usize;
    v[i].as_secs_f64() * 1000.0
}

fn timed<T>(rounds: usize, mut f: impl FnMut() -> T) -> (f64, f64, T) {
    let mut v = Vec::with_capacity(rounds);
    let mut last = None;
    for _ in 0..rounds {
        let t = Instant::now();
        last = Some(f());
        v.push(t.elapsed());
    }
    (pct(&v, 0.5), pct(&v, 0.95), last.unwrap())
}

struct Out(Option<File>);

impl Out {
    fn line(&mut self, v: Value) {
        let s = v.to_string();
        println!("JSON {s}");
        if let Some(f) = self.0.as_mut() {
            writeln!(f, "{s}").unwrap();
        }
    }
}

fn host() -> Value {
    let cpu = std::fs::read_to_string("/proc/cpuinfo")
        .ok()
        .and_then(|c| {
            c.lines()
                .find(|l| l.starts_with("model name"))
                .and_then(|l| l.split(':').nth(1))
                .map(|s| s.trim().to_owned())
        })
        .unwrap_or_else(|| {
            std::process::Command::new("sysctl")
                .args(["-n", "machdep.cpu.brand_string"])
                .output()
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
                .unwrap_or_default()
        });
    let uname = std::process::Command::new("uname")
        .arg("-a")
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_owned())
        .unwrap_or_default();
    let threads = std::thread::available_parallelism().map(|n| n.get()).unwrap_or(0);
    json!({"cpu": cpu, "threads": threads, "uname": uname,
        "runner": std::env::var("RUNNER_NAME").unwrap_or_default()})
}

#[test]
#[ignore = "scale bench: minutes and gigabytes; run by hand on the fleet"]
fn find_to_first_hit_before_and_after_the_index() {
    let mut out = Out(std::env::var_os("FAST_CHECKS_OUT").map(|d| {
        std::fs::create_dir_all(&d).unwrap();
        File::create(PathBuf::from(d).join("find_first_hit.jsonl")).unwrap()
    }));
    let host = host();
    println!("host: {host}");
    out.line(json!({"bench": "find_first_hit", "kind": "host", "host": host}));

    let dir = tempfile::tempdir().unwrap();
    let mb = env_num("SCALE_MB", 500);
    let sub_mb = env_num("SCALE_SUBAGENT_MB", 20);
    let before_rounds = env_num("BEFORE_ROUNDS", 7) as usize;
    let after_rounds = env_num("AFTER_ROUNDS", 100) as usize;
    let total = mb << 20;
    let back = |frac: f64| (total as f64 * (1.0 - frac)) as u64;

    // The session: its transcript and one subagent's (`<id>/subagents/agent-*.jsonl`).
    let big = dir.path().join("big.jsonl");
    let mut plants = vec![
        Plant {
            label: "newest page",
            phrase: "quokka newest beacon",
            target: total - (512 << 10),
            compact: false,
            offset: None,
        },
        Plant {
            label: "10% back",
            phrase: "quokka tenth beacon",
            target: back(0.10),
            compact: false,
            offset: None,
        },
        Plant {
            label: "50% back",
            phrase: "quokka middle beacon",
            target: back(0.50),
            compact: false,
            offset: None,
        },
        Plant {
            label: "70% back, before a compaction",
            phrase: "quokka compacted beacon",
            target: back(0.70),
            compact: true,
            offset: None,
        },
        Plant {
            label: "90% back",
            phrase: "quokka ninety beacon",
            target: back(0.90),
            compact: false,
            offset: None,
        },
    ];
    let t = Instant::now();
    let turns = write_transcript(&big, mb, 7, &mut plants);
    let size = std::fs::metadata(&big).unwrap().len();
    let sub = dir.path().join("agent-a1.jsonl");
    let mut sub_plants = vec![Plant {
        label: "only in a subagent",
        phrase: "quokka subagent beacon",
        target: (sub_mb << 20) / 2,
        compact: false,
        offset: None,
    }];
    write_transcript(&sub, sub_mb, 11, &mut sub_plants);
    println!(
        "transcript: {} MB, {turns} turns; subagent {} MB; written in {:.0} s",
        size >> 20,
        std::fs::metadata(&sub).unwrap().len() >> 20,
        t.elapsed().as_secs_f64()
    );
    let session = vec![
        Source {
            path: big.clone(),
            harness: Harness::Claude,
            session: "big".into(),
            subagent: false,
        },
        Source {
            path: sub.clone(),
            harness: Harness::Claude,
            session: "big".into(),
            subagent: true,
        },
    ];

    // The machine's other 200 sessions; every 50th also says the 50% phrase, so the session
    // scope is what keeps its answer to one hit.
    let files = env_num("SCALE_HOST_FILES", 200);
    let file_mb = env_num("SCALE_HOST_FILE_MB", 5);
    let mut others = Vec::new();
    for k in 0..files {
        let path = dir.path().join(format!("s{k}.jsonl"));
        let mut p = [Plant {
            label: "",
            phrase: "quokka middle beacon",
            target: (file_mb << 20) / 2,
            compact: false,
            offset: None,
        }];
        write_transcript(&path, file_mb, 1000 + k, if k % 50 == 0 { &mut p[..] } else { &mut [] });
        others.push(Source {
            path,
            harness: Harness::Claude,
            session: format!("s{k}"),
            subagent: false,
        });
    }
    let corpus_mb = (size >> 20) + sub_mb + files * file_mb;
    println!("corpus: {} sessions, about {corpus_mb} MB", files + 1);

    // The page the pane opened with (not timed: it was loaded before Find in Chat was).
    let mut f = File::open(&big).unwrap();
    let opened: Vec<(PageRule, Page)> = [NATIVE, EVENTS].map(|r| (r, page(&mut f, size, r))).into();
    for (rule, p) in &opened {
        println!(
            "{} newest page: {} KiB, {} lines, starts at {}",
            rule.name,
            p.read >> 10,
            p.records.len(),
            p.start
        );
    }

    // After, cold: an empty index; the first scoped search reads the whole session.
    let db = dir.path().join("index.sqlite");
    let index = Index::open(&db).unwrap();
    let mut q = Query::new(plants[0].phrase);
    q.sessions = Some(vec!["big".into()]);
    let t = Instant::now();
    let (hits, done) = acpmux_transcript_search::search(&index, &session, &q).unwrap();
    let cold_ms = t.elapsed().as_secs_f64() * 1000.0;
    assert_eq!(hits.len(), 1);
    println!(
        "cold: first scoped search {cold_ms:.0} ms ({} MB read, {} docs; catch-up {} ms, query {} ms)",
        done.caught_up.bytes >> 20,
        done.caught_up.docs,
        done.catch_up_ms,
        done.query_ms
    );
    out.line(json!({"bench": "find_first_hit", "kind": "cold_session", "ms": cold_ms,
        "bytes": done.caught_up.bytes, "docs": done.caught_up.docs,
        "catch_up_ms": done.catch_up_ms, "query_ms": done.query_ms}));
    let t = Instant::now();
    for s in &others {
        index.catch_up(s).unwrap();
    }
    let others_ms = t.elapsed().as_secs_f64() * 1000.0;
    let index_mb = std::fs::metadata(&db).unwrap().len() >> 20;
    println!(
        "cold: the other {files} sessions ({} MB) indexed in {others_ms:.0} ms; index {index_mb} MB",
        files * file_mb
    );
    out.line(json!({"bench": "find_first_hit", "kind": "cold_corpus", "sessions": files + 1,
        "corpus_mb": corpus_mb, "others_ms": others_ms, "index_mb": index_mb,
        "total_ms": cold_ms + others_ms}));

    let mut rows = Vec::new();
    let cases = plants.iter().map(|p| (p, &big)).chain(sub_plants.iter().map(|p| (p, &sub)));
    let absent = Plant {
        label: "absent (no hit)",
        phrase: "quokka absent beacon",
        target: 0,
        compact: false,
        offset: None,
    };
    for (p, file) in cases.chain(std::iter::once((&absent, &big))) {
        let depth = p
            .offset
            .map(|(o, _)| if file == &big { (size - o) as f64 / size as f64 } else { f64::NAN });
        let mut row = json!({"bench": "find_first_hit", "kind": "case", "case": p.label,
            "phrase": p.phrase, "depth_from_tail": depth, "subagent": file == &sub});
        for (rule, opened) in &opened {
            let (p50, p95, b) = timed(before_rounds, || {
                before(&big, *rule, &opened.records, opened.start, p.phrase)
            });
            let expect = p.offset.is_some() && file == &big;
            assert_eq!(b.found, expect, "{}: before found {} via {}", p.label, b.found, rule.name);
            row[format!("before_{}", rule.name)] = json!({"p50_ms": p50, "p95_ms": p95,
                "found": b.found, "pages": b.pages, "mb_read": b.bytes as f64 / (1 << 20) as f64,
                "rounds": before_rounds});
        }
        let mut q = Query::new(p.phrase);
        q.sessions = Some(vec!["big".into()]);
        let (p50, p95, hits) = timed(after_rounds, || {
            acpmux_transcript_search::search(&index, &session, &q).unwrap().0
        });
        let (qp50, qp95, _) = timed(after_rounds, || index.search(&q).unwrap());
        assert_eq!(hits.len(), usize::from(p.offset.is_some()), "{}: after hits", p.label);
        if let Some(h) = hits.first() {
            assert_eq!(h.subagent, file == &sub);
            assert!(h.snippet.contains(p.phrase));
        }
        row["after_warm"] = json!({"p50_ms": p50, "p95_ms": p95, "rounds": after_rounds,
            "query_only_p50_ms": qp50, "query_only_p95_ms": qp95});
        if let Some((_, next)) = p.offset {
            let (p50, p95, pg) = timed(20, || page(&mut File::open(file).unwrap(), next, NATIVE));
            assert!(rows_hold(&pg.records, p.phrase), "{}: the page holds the hit", p.label);
            row["after_page_read"] = json!({"p50_ms": p50, "p95_ms": p95, "rounds": 20,
                "mb_read": pg.read as f64 / (1 << 20) as f64});
        }
        out.line(row.clone());
        rows.push(row);
    }

    let ms = |v: &Value, k: &str| {
        v.get(k).and_then(Value::as_f64).map_or("-".into(), |x| format!("{x:.1}"))
    };
    println!();
    println!(
        "find-to-first-hit, one {} MB session (corpus {} sessions / {corpus_mb} MB), ms p50/p95",
        size >> 20,
        files + 1
    );
    println!(
        "{:<32} {:>7} | {:>22} | {:>22} | {:>15} | {:>13} | {:>13}",
        "case",
        "depth",
        "before native_history",
        "before events 1MiB",
        "after warm",
        "+ page read",
        "after total p50"
    );
    for r in &rows {
        let d = r["depth_from_tail"]
            .as_f64()
            .filter(|d| !d.is_nan())
            .map_or("-".into(), |d| format!("{:.0}%", d * 100.0));
        let b = |k: &str| {
            let v = &r[k];
            if v["found"] == json!(true) {
                format!("{}/{} ({}p)", ms(v, "p50_ms"), ms(v, "p95_ms"), v["pages"])
            } else {
                format!("miss {}/{} ({}p)", ms(v, "p50_ms"), ms(v, "p95_ms"), v["pages"])
            }
        };
        let a = &r["after_warm"];
        let pr = &r["after_page_read"];
        let total = a["p50_ms"].as_f64().unwrap() + pr["p50_ms"].as_f64().unwrap_or(0.0);
        println!(
            "{:<32} {:>7} | {:>22} | {:>22} | {:>15} | {:>13} | {:>13.1}",
            r["case"].as_str().unwrap(),
            d,
            b("before_native_history"),
            b("before_events"),
            format!("{}/{}", ms(a, "p50_ms"), ms(a, "p95_ms")),
            if pr.is_null() {
                "-".into()
            } else {
                format!("{}/{}", ms(pr, "p50_ms"), ms(pr, "p95_ms"))
            },
            total
        );
    }
    println!(
        "cold (one-time, empty index): this session {cold_ms:.0} ms; the other {files} sessions {others_ms:.0} ms; index {index_mb} MB"
    );
    println!(
        "'miss' = Find in Chat never finds it: paged to the file's start (a subagent's transcript is never paged in)."
    );
}
