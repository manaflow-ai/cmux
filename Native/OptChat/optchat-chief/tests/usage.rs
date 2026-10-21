//! Chief usage analytics (plans/cmux-next/chief-usage-analytics-DESIGN.md):
//! the trace's billable events become ledger lines (one per Chief turn,
//! compactor node and subagent prompt), the ledger is backfilled once from
//! old traces, pruned by age and size, and folded into the summary the
//! `optchat-chief usage` CLI, `cmux chief usage` and the Chief Usage page read.

use std::path::Path;

use optchat_chief::trace::Trace;
use optchat_chief::usage::{self, Bucket, By, Chief, Fold, Line, Query};
use serde_json::{Value, json};

const DAY: u64 = 86_400_000;
/// 2026-10-18 00:00:00 UTC.
const T0: u64 = 1_792_281_600_000;

fn turn_end(ts: u64, key: &str, usd: f64, ms: u64, read: u64, write: u64, input: u64) -> Value {
    json!({"ts": ts, "ev": "turn.end", "turn": key, "status": "ok", "harness": "claude",
        "model": null, "ms": ms, "start_ms": 1200, "ttft_ms": 5000, "cost_usd": usd,
        "usage": {"input": input, "cache_read": read, "cache_write": write, "output": 100}})
}

fn request(ts: u64, scope: (&str, &str), model: &str) -> Value {
    let mut e = json!({"ts": ts, "ev": "request", "n": 1, "model": model,
        "usage": {"input": 1, "cache_read": 2, "cache_write": 3, "output": 4}});
    e[scope.0] = json!(scope.1);
    e
}

fn node(ts: u64, usd: f64) -> Value {
    json!({"ts": ts, "ev": "node", "node": "5236+4", "harness": "claude", "model": "claude-haiku-5-5",
        "ms": 9000, "ok": true, "cost_usd": usd,
        "timing": {"session_start_ms": 800, "ttft_ms": [2000, 900]},
        "usage": {"input": 10, "cache_read": 900, "cache_write": 0, "output": 50}})
}

fn answer(ts: u64, id: &str, cum: f64) -> Value {
    json!({"ts": ts, "ev": "subagent.answer", "id": id, "spawn": "s1", "stop": "end_turn", "cost_usd": cum,
        "usage": {"input": 6, "cache_read": 1000, "cache_write": 20, "output": 300}})
}

fn fold_all(events: &[Value]) -> Vec<Line> {
    let mut fold = Fold::new();
    events
        .iter()
        .filter_map(|e| fold.observe(e, "trace"))
        .collect()
}

#[test]
fn billable_events_become_ledger_lines() {
    let lines = fold_all(&[
        request(T0, ("turn", "turn:optchat:7:x"), "claude-opus-5-5"),
        turn_end(T0 + 1, "turn:optchat:7:x", 0.25, 6000, 900, 10, 90),
        node(T0 + 2, 0.002),
        json!({"ts": T0 + 3, "ev": "tool", "turn": "turn:optchat:7:x", "name": "spawn"}),
        request(T0 + 4, ("subagent", "a7"), "claude-opus-5-5"),
        answer(T0 + 5, "a7", 1.5),
        answer(T0 + 6, "a7", 2.0),
        // The subagent's process restarted: its running total starts again.
        answer(T0 + 7, "a7", 0.4),
    ]);
    let kinds: Vec<&str> = lines.iter().map(|l| l.kind.as_str()).collect();
    assert_eq!(
        kinds,
        ["turn", "compactor", "subagent", "subagent", "subagent"]
    );

    let turn = &lines[0];
    assert_eq!(
        turn.model.as_deref(),
        Some("claude-opus-5-5"),
        "model from the turn's requests"
    );
    assert_eq!(turn.harness.as_deref(), Some("claude"));
    assert_eq!(
        (turn.input, turn.cache_read, turn.cache_write, turn.output),
        (90, 900, 10, 100)
    );
    assert_eq!(turn.usd, Some(0.25));
    assert_eq!(
        (turn.ms, turn.start_ms, turn.ttft_ms),
        (Some(6000), Some(1200), Some(5000))
    );
    assert_eq!(turn.key, "turn:optchat:7:x");
    assert_eq!(turn.src, "trace");

    let node = &lines[1];
    assert_eq!(node.model.as_deref(), Some("claude-haiku-5-5"));
    assert_eq!((node.start_ms, node.ttft_ms), (Some(800), Some(2000)));
    assert_eq!(node.key, "5236+4");

    let usd: Vec<f64> = lines[2..].iter().map(|l| l.usd.unwrap()).collect();
    assert_eq!(usd.len(), 3);
    assert!(
        (usd[0] - 1.5).abs() < 1e-9,
        "first prompt: the whole running total"
    );
    assert!((usd[1] - 0.5).abs() < 1e-9, "second prompt: the difference");
    assert!(
        (usd[2] - 0.4).abs() < 1e-9,
        "after a restart: the new running total"
    );
    assert_eq!(lines[2].agent.as_deref(), Some("a7"));
    assert_eq!(lines[2].model.as_deref(), Some("claude-opus-5-5"));
    assert_eq!(lines[3].usd_cum, Some(2.0));
}

#[test]
fn a_traced_host_writes_its_ledger() {
    let dir = tempfile::tempdir().unwrap();
    let trace = Trace::open(&dir.path().join("traces"), false).unwrap();
    trace.emit(
        "request",
        json!({"turn": "k1", "n": 1, "model": "claude-opus-5-5", "usage": {}}),
    );
    trace.emit(
        "turn.end",
        json!({"turn": "k1", "status": "ok", "harness": "claude", "ms": 4000, "cost_usd": 0.1,
            "usage": {"input": 1, "cache_read": 99, "cache_write": 0, "output": 7}}),
    );
    trace.emit("tool", json!({"turn": "k1", "name": "spawn"}));
    let ledger = usage::dir(dir.path());
    let lines = usage::read(&ledger, 0, u64::MAX).unwrap();
    assert_eq!(lines.len(), 1, "{lines:?}");
    assert_eq!(lines[0].src, "live");
    assert_eq!(lines[0].model.as_deref(), Some("claude-opus-5-5"));
    assert_eq!(lines[0].cache_read, 99);
    // The ledger is private: 0700 directory, 0600 files.
    use std::os::unix::fs::PermissionsExt;
    let mode = std::fs::metadata(&ledger).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o700);
    for f in std::fs::read_dir(&ledger).unwrap().flatten() {
        if f.path().extension().is_some_and(|x| x == "jsonl") {
            assert_eq!(f.metadata().unwrap().permissions().mode() & 0o777, 0o600);
        }
    }
}

fn lines_fixture() -> Vec<Line> {
    fold_all(&[
        // Day 1: two turns, one cold (cache write heavy), one node.
        request(T0, ("turn", "t1"), "claude-opus-5-5"),
        turn_end(T0 + 1000, "t1", 0.50, 10_000, 1000, 9000, 0),
        request(T0 + 2000, ("turn", "t2"), "claude-opus-5-5"),
        turn_end(T0 + 3000, "t2", 0.10, 4_000, 9000, 1000, 0),
        node(T0 + 4000, 0.01),
        // Day 2: one warm turn and a subagent prompt.
        request(T0 + DAY, ("turn", "t3"), "claude-sonnet-5-5"),
        turn_end(T0 + DAY + 10, "t3", 0.05, 2_000, 10_000, 0, 0),
        request(T0 + DAY + 20, ("subagent", "a9"), "claude-opus-5-5"),
        answer(T0 + DAY + 30, "a9", 3.0),
    ])
}

fn chief(lines: Vec<Line>) -> Vec<(Chief, Vec<Line>)> {
    vec![(
        Chief {
            id: "default".into(),
            label: "Chief".into(),
            home: "/h".into(),
        },
        lines,
    )]
}

#[test]
fn the_summary_totals_buckets_and_ranks() {
    let q = Query {
        since_ms: T0,
        until_ms: T0 + 2 * DAY,
        bucket: Bucket::Day,
        by: By::Model,
        top: 2,
        offset_s: 0,
    };
    let s = usage::summarize(&chief(lines_fixture()), &q);
    assert_eq!(s["v"], 1);
    assert_eq!(s["bucket"], "day");
    let t = &s["totals"];
    assert_eq!(t["units"], 5);
    assert_eq!(t["turns"], 3);
    assert!((t["usd"].as_f64().unwrap() - 3.66).abs() < 1e-9, "{t}");
    // Hit rate over every unit: read / (read + write + input).
    let read = 1000 + 9000 + 900 + 10_000 + 1000;
    let all = read + 9000 + 1000 + 10 + 6 + 20;
    assert!((t["hit"].as_f64().unwrap() - read as f64 / all as f64).abs() < 1e-9);
    // Latency over turns only: 2000, 4000, 10000.
    assert_eq!(t["ms_p50"], 4000);
    assert_eq!(t["ms_p95"], 10_000);

    let series = s["series"].as_array().unwrap();
    assert_eq!(series.len(), 2, "one point per day, empty days included");
    assert_eq!(series[0]["t"], T0);
    assert_eq!(series[0]["turns"], 2);
    assert_eq!(series[1]["t"], T0 + DAY);
    assert!((series[1]["usd"].as_f64().unwrap() - 3.05).abs() < 1e-9);

    let by = s["by"].as_array().unwrap();
    let keys: Vec<&str> = by.iter().map(|b| b["key"].as_str().unwrap()).collect();
    assert_eq!(
        keys,
        ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"],
        "most expensive first"
    );

    let top = s["top"].as_array().unwrap();
    assert_eq!(top.len(), 2);
    assert_eq!(top[0]["kind"], "subagent");
    assert_eq!(top[0]["agent"], "a9");
    assert_eq!(top[1]["key"], "t1");
    assert_eq!(top[1]["chief"], "default");
}

#[test]
fn the_summary_breaks_down_by_chief_agent_and_kind() {
    let base = Query {
        since_ms: T0,
        until_ms: T0 + 2 * DAY,
        bucket: Bucket::Day,
        by: By::Kind,
        top: 0,
        offset_s: 0,
    };
    let s = usage::summarize(&chief(lines_fixture()), &base);
    let keys: Vec<&str> = s["by"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| b["key"].as_str().unwrap())
        .collect();
    assert_eq!(keys, ["subagent", "turn", "compactor"]);

    let s = usage::summarize(
        &chief(lines_fixture()),
        &Query {
            by: By::Agent,
            ..base
        },
    );
    let keys: Vec<&str> = s["by"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| b["key"].as_str().unwrap())
        .collect();
    assert_eq!(
        keys,
        ["a9", "chief", "compactor"],
        "the Chief's own turns and its compactor are rows too"
    );

    let two = vec![
        (
            Chief {
                id: "a".into(),
                label: "Alpha".into(),
                home: "/a".into(),
            },
            lines_fixture(),
        ),
        (
            Chief {
                id: "b".into(),
                label: "Beta".into(),
                home: "/b".into(),
            },
            lines_fixture()[..1].to_vec(),
        ),
    ];
    let s = usage::summarize(
        &two,
        &Query {
            by: By::Chief,
            ..base
        },
    );
    let by = s["by"].as_array().unwrap();
    assert_eq!(by[0]["key"], "a");
    assert_eq!(by[0]["label"], "Alpha");
    assert_eq!(by[1]["label"], "Beta");
    assert_eq!(s["chiefs"].as_array().unwrap().len(), 2);
}

#[test]
fn hour_week_and_month_buckets_follow_local_time() {
    let lines = lines_fixture();
    // UTC+2: T0 is 02:00 local, so the local day starts two hours earlier.
    let q = Query {
        since_ms: T0,
        until_ms: T0 + 2 * DAY,
        bucket: Bucket::Day,
        by: By::Model,
        top: 0,
        offset_s: 7200,
    };
    let s = usage::summarize(&chief(lines.clone()), &q);
    assert_eq!(s["series"][0]["t"], T0 - 7_200_000);

    let q = Query {
        bucket: Bucket::Hour,
        offset_s: 0,
        ..q
    };
    let s = usage::summarize(&chief(lines.clone()), &q);
    assert_eq!(s["series"].as_array().unwrap().len(), 48);

    // 2026-10-18 is a Sunday: its week starts Monday 2026-10-12.
    let q = Query {
        bucket: Bucket::Week,
        ..q
    };
    let s = usage::summarize(&chief(lines.clone()), &q);
    assert_eq!(s["series"][0]["t"], T0 - 6 * DAY);
    assert_eq!(s["series"].as_array().unwrap().len(), 2);

    let q = Query {
        bucket: Bucket::Month,
        ..q
    };
    let s = usage::summarize(&chief(lines), &q);
    assert_eq!(s["series"].as_array().unwrap().len(), 1);
    // 2026-10-01 00:00 UTC.
    assert_eq!(s["series"][0]["t"], T0 - 17 * DAY);
}

fn write_trace(dir: &Path, day: &str, events: &[Value]) {
    std::fs::create_dir_all(dir).unwrap();
    let text: String = events.iter().map(|e| format!("{e}\n")).collect();
    std::fs::write(dir.join(format!("{day}.jsonl")), text).unwrap();
}

#[test]
fn backfill_reads_old_traces_once() {
    let root = tempfile::tempdir().unwrap();
    let traces = root.path().join("traces");
    write_trace(
        &traces,
        "2026-10-18",
        &[
            request(T0, ("turn", "t1"), "m"),
            turn_end(T0 + 1, "t1", 0.5, 10, 1, 1, 1),
        ],
    );
    write_trace(
        &traces,
        "2026-10-19",
        &[node(T0 + DAY, 0.01), answer(T0 + DAY + 1, "a1", 1.0)],
    );

    let first = usage::backfill(root.path(), false).unwrap();
    assert_eq!(first.lines, 3);
    let lines = usage::read(&usage::dir(root.path()), 0, u64::MAX).unwrap();
    assert_eq!(lines.len(), 3);
    assert!(lines.iter().all(|l| l.src == "trace"));

    let again = usage::backfill(root.path(), false).unwrap();
    assert_eq!(again.lines, 0, "a second backfill adds nothing");
    assert_eq!(
        usage::read(&usage::dir(root.path()), 0, u64::MAX)
            .unwrap()
            .len(),
        3
    );
}

#[test]
fn backfill_stops_where_the_live_ledger_starts() {
    let root = tempfile::tempdir().unwrap();
    let traces = root.path().join("traces");
    // The host wrote day 2 itself (live); the trace has both days.
    let trace = Trace::open(&traces, false).unwrap();
    trace.emit(
        "turn.end",
        json!({"turn": "live", "status": "ok", "cost_usd": 0.2, "usage": {"input": 1}}),
    );
    let live_ts = usage::read(&usage::dir(root.path()), 0, u64::MAX).unwrap()[0].ts;
    write_trace(
        &traces,
        "2000-01-01",
        &[turn_end(live_ts - DAY, "old", 0.5, 10, 1, 1, 1)],
    );
    // A copy of the live line in the trace is not converted again.
    write_trace(
        &traces,
        "2999-01-01",
        &[turn_end(live_ts, "live", 0.2, 10, 1, 1, 1)],
    );
    let report = usage::backfill(root.path(), false).unwrap();
    assert_eq!(report.lines, 1);
    let keys: Vec<String> = usage::read(&usage::dir(root.path()), 0, u64::MAX)
        .unwrap()
        .into_iter()
        .map(|l| l.key)
        .collect();
    assert_eq!(keys, ["old", "live"]);
}

#[test]
fn backfill_waits_for_no_other_backfill() {
    let root = tempfile::tempdir().unwrap();
    write_trace(
        &root.path().join("traces"),
        "2026-10-18",
        &[turn_end(T0, "t", 0.5, 10, 1, 1, 1)],
    );
    let ledger = usage::dir(root.path());
    std::fs::create_dir_all(&ledger).unwrap();
    std::fs::write(ledger.join("backfill.lock"), "").unwrap();
    assert!(
        usage::backfill(root.path(), false).is_err(),
        "another backfill holds the lock"
    );
    assert!(usage::read(&ledger, 0, u64::MAX).unwrap().is_empty());
}

#[test]
fn retention_drops_old_months_then_caps_the_size() {
    let dir = tempfile::tempdir().unwrap();
    for month in ["2024-12", "2025-09", "2025-10", "2026-09", "2026-10"] {
        std::fs::write(dir.path().join(format!("{month}.jsonl")), vec![b'x'; 100]).unwrap();
    }
    std::fs::write(dir.path().join("backfill.json"), "{}").unwrap();
    let removed = usage::prune(dir.path(), "2026-10", 13, u64::MAX);
    assert_eq!(removed.len(), 2, "{removed:?}");
    let mut left: Vec<String> = std::fs::read_dir(dir.path())
        .unwrap()
        .flatten()
        .map(|e| e.file_name().to_string_lossy().into_owned())
        .collect();
    left.sort();
    assert_eq!(
        left,
        [
            "2025-10.jsonl",
            "2026-09.jsonl",
            "2026-10.jsonl",
            "backfill.json"
        ]
    );

    // Over 250 bytes: the oldest month goes until it fits; the current month stays.
    usage::prune(dir.path(), "2026-10", 13, 250);
    assert!(!dir.path().join("2025-10.jsonl").exists());
    assert!(dir.path().join("2026-09.jsonl").exists());
    usage::prune(dir.path(), "2026-10", 13, 10);
    assert!(
        dir.path().join("2026-10.jsonl").exists(),
        "never the month being written"
    );
}

#[test]
fn the_cli_reads_every_home_and_backfills_first() {
    let homes = tempfile::tempdir().unwrap();
    let now = chrono::Utc::now().timestamp_millis() as u64;
    let day = chrono::Local::now().format("%Y-%m-%d").to_string();
    let a = homes.path().join("a");
    let b = homes.path().join("b");
    write_trace(
        &a.join("optchat/traces"),
        &day,
        &[turn_end(now - 60_000, "ta", 0.5, 1000, 9, 1, 0)],
    );
    write_trace(
        &b.join("optchat/traces"),
        &day,
        &[turn_end(now - 30_000, "tb", 0.25, 3000, 1, 9, 0)],
    );
    std::fs::write(b.join("chief-id"), "agent_01M5A0X7FW3AGR73KR0D4BS6C3").unwrap();

    let args: Vec<String> = [
        "--mux-home",
        a.to_str().unwrap(),
        "--mux-home",
        b.to_str().unwrap(),
        "--since",
        "1d",
        "--by",
        "chief",
        "--json",
    ]
    .iter()
    .map(|s| s.to_string())
    .collect();
    let out = usage::run(&args).unwrap();
    let s: Value = serde_json::from_str(&out).unwrap();
    assert_eq!(s["totals"]["turns"], 2);
    assert_eq!(s["bucket"], "hour", "a one-day window charts hours");
    let labels: Vec<&str> = s["by"]
        .as_array()
        .unwrap()
        .iter()
        .map(|b| b["key"].as_str().unwrap())
        .collect();
    assert_eq!(labels, ["default", "agent_01M5A0X7FW3AGR73KR0D4BS6C3"]);

    // Plain text names the totals.
    let text = usage::run(&args[..args.len() - 1]).unwrap();
    assert!(text.contains("$0.75"), "{text}");
    assert!(text.contains("2 turns"), "{text}");

    assert!(usage::run(&["--by".into(), "nope".into()]).is_err());
}
