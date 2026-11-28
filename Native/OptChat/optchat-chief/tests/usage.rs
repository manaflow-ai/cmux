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

#[test]
fn credit_meter_preserves_identity_route_and_prompt_keys() {
    let lines = fold_all(&[
        json!({"ev":"turn.start", "turn":"t", "person":"user_alice", "team":"team_one", "chief":"chief_one", "harness":"native", "base_url":"https://coderouter.dev/v1"}),
        turn_end(T0, "t", 0.1, 1, 3, 0, 2),
        json!({"ev":"subagent.start", "id":"a1", "session":"s", "harness":"codex", "peer":"cloud-vm-1", "person":"user_alice", "chief":"chief_one"}),
        json!({"ev":"subagent.answer", "id":"a1", "prompt_id":"p1", "ts":T0+1, "usage":{"input":1}}),
        json!({"ev":"subagent.answer", "id":"a1", "prompt_id":"p2", "ts":T0+2, "usage":{"input":1}}),
    ]);
    let a = serde_json::to_value(&lines[0]).unwrap();
    assert_eq!(a["person"], "user_alice");
    assert_eq!(a["team"], "team_one");
    assert_eq!(a["chief"], "chief_one");
    assert_eq!(a["payer"], "platform");
    assert_eq!(a["provider"], "cmux-router");
    let sub = serde_json::to_value(&lines[1]).unwrap();
    assert_eq!(sub["machine"], "cloud-vm-1");
    assert_eq!(sub["harness"], "codex");
    assert_eq!(sub["payer"], "own");
    assert_ne!(lines[1].key, lines[2].key);
}

#[test]
fn credit_export_and_person_summary_are_cli_json() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    std::fs::write(home.join("chief-id"), "chief_one").unwrap();
    let trace = Trace::open(&home.join("optchat/traces"), false).unwrap();
    trace.emit("turn.end", json!({"turn":"k", "person":"user_alice", "team":"team_one", "chief":"chief_one", "harness":"claude", "model":"opus", "status":"ok", "cost_usd":0.1, "usage":{"input":2,"cache_read":3,"cache_write":4,"output":5}}));
    let args = |extra: &[&str]| {
        let mut a: Vec<String> = extra.iter().map(|s| (*s).into()).collect();
        a.extend([
            "--mux-home".into(),
            home.display().to_string(),
            "--since".into(),
            "30d".into(),
        ]);
        a
    };
    let text = usage::run(&args(&["export", "--json", "--person", "user_alice"])).unwrap();
    let row: Value = serde_json::from_str(text.trim()).unwrap();
    assert_eq!(row["stack_user_id"], "user_alice");
    assert_eq!(row["team_id"], "team_one");
    assert_eq!(row["provider"], "anthropic");
    assert_eq!(row["agent"], "claude");
    assert_eq!(row["cached_input_tokens"], 3);
    assert_eq!(row["input_tokens"], 9);
    assert_eq!(row["output_tokens"], 5);
    assert_eq!(row["total_tokens"], 14);
    assert_eq!(row["api_equivalent_usd"], 0.1);
    assert_eq!(row["request_id"], "chief:chief_one:turn:k");
    assert!(chrono::DateTime::parse_from_rfc3339(row["event_time"].as_str().unwrap()).is_ok());
    assert_eq!(usage::run(&args(&["export", "--json"])).unwrap(), text);
    assert!(
        usage::run(&args(&["export", "--person", "user_bob"]))
            .unwrap()
            .is_empty()
    );
    let summary: Value =
        serde_json::from_str(&usage::run(&args(&["--by", "person", "--json"])).unwrap()).unwrap();
    assert_eq!(summary["by_kind"], "person");
    assert_eq!(summary["by"][0]["key"], "user_alice");
}

#[test]
fn credit_meter_old_v1_and_secrets_do_not_leak() {
    let old: Line =
        serde_json::from_str(r#"{"v":1,"ts":1,"kind":"turn","key":"old","input":1}"#).unwrap();
    assert!(serde_json::to_value(old).unwrap()["person"].is_null());
    let tmp = tempfile::tempdir().unwrap();
    let trace = Trace::open(&tmp.path().join("traces"), false).unwrap();
    let secret = "sk-secret-do-not-record";
    trace.emit("turn.end", json!({"turn":"t", "harness":"native", "base_url":format!("https://user:{secret}@coderouter.dev/v1?key={secret}"), "api_key":secret, "token":secret, "usage":{"input":1}}));
    let lines = usage::read(&usage::dir(tmp.path()), 0, u64::MAX).unwrap();
    assert_eq!(lines.len(), 1);
    let written = std::fs::read_dir(usage::dir(tmp.path()))
        .unwrap()
        .flatten()
        .find(|e| e.path().extension().is_some_and(|s| s == "jsonl"))
        .unwrap();
    let text = std::fs::read_to_string(written.path()).unwrap();
    assert!(!text.contains(secret));
    assert!(!text.contains("base_url"));
    assert!(!text.contains("api_key"));
    assert!(!text.contains("\"token\""));
}

#[test]
fn credit_meter_payer_uses_harness_and_parsed_host() {
    for (harness, base, payer, provider) in [
        ("claude", "", "own", "anthropic"),
        ("codex", "", "own", "openai"),
        ("cmux", "", "platform", "cmux-router"),
        (
            "native",
            "https://coderouter.dev/v1",
            "platform",
            "cmux-router",
        ),
        ("native", "https://api.anthropic.com", "own", "anthropic"),
        (
            "native",
            "https://api.deepinfra.com/v1/openai",
            "own",
            "deepinfra",
        ),
        (
            "native",
            "https://coderouter.dev.evil.test/v1",
            "own",
            "unknown",
        ),
        (
            "claude",
            "https://coderouter.dev",
            "platform",
            "cmux-router",
        ),
    ] {
        let line =
            fold_all(&[json!({"ev":"turn.end","turn":"t","harness":harness,"base_url":base})])
                .pop()
                .unwrap();
        let row = serde_json::to_value(line).unwrap();
        assert_eq!(row["payer"], payer, "{harness} {base}");
        assert_eq!(row["provider"], provider, "{harness} {base}");
    }
}

#[test]
fn credit_backfill_preserves_unknown_people_and_existing_month_bytes() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let root = home.join("optchat");
    let trace = Trace::open(&root.join("traces"), false).unwrap();
    trace.emit(
        "usage.identity",
        json!({"person":"user_owner", "chief":"chief_one"}),
    );
    trace.emit("turn.end", json!({"turn":"old", "harness":"claude"}));
    trace.emit(
        "turn.end",
        json!({"turn":"other", "person":"user_other", "harness":"claude"}),
    );
    // Simulate a pre-identity line in a private month file.
    let file = std::fs::read_dir(usage::dir(&root))
        .unwrap()
        .flatten()
        .find(|e| e.path().extension().is_some_and(|s| s == "jsonl"))
        .unwrap()
        .path();
    let text = std::fs::read_to_string(&file).unwrap();
    let mut rows: Vec<Value> = text
        .lines()
        .map(|s| serde_json::from_str(s).unwrap())
        .collect();
    rows[0].as_object_mut().unwrap().remove("person");
    std::fs::write(
        &file,
        rows.iter().map(|r| format!("{r}\n")).collect::<String>(),
    )
    .unwrap();
    let before = std::fs::read(&file).unwrap();
    usage::run(&[
        "backfill".into(),
        "--mux-home".into(),
        home.display().to_string(),
    ])
    .unwrap();
    let rows = usage::read(&usage::dir(&root), 0, u64::MAX).unwrap();
    assert_eq!(
        serde_json::to_value(&rows[0]).unwrap()["person"],
        Value::Null
    );
    assert_eq!(
        serde_json::to_value(&rows[1]).unwrap()["person"],
        "user_other"
    );
    assert_eq!(std::fs::read(&file).unwrap(), before);
}

#[test]
fn credit_meter_multiplayer_keeps_queued_spawn_owner_and_machine() {
    let rows = fold_all(&[
        json!({"ev":"usage.identity", "person":"user_owner", "chief":"chief_one"}),
        json!({"ev":"usage.message", "id":"m1", "person":"user_guest"}),
        json!({"ev":"turn.start", "turn":"t1", "message_keys":["m1"], "harness":"claude"}),
        json!({"ev":"spawn", "ids":["a1","a2"], "peers":[null,"vm-one"], "harness":"codex"}),
        turn_end(T0, "t1", 0.1, 1, 0, 0, 2),
        json!({"ev":"turn.start", "turn":"t2", "harness":"claude"}),
        json!({"ev":"subagent.start", "id":"a2", "session":"s2", "harness":"codex", "peer":"vm-one"}),
        answer(T0 + 1, "a2", 0.1),
        turn_end(T0 + 2, "t2", 0.1, 1, 0, 0, 2),
    ]);
    let rows: Vec<Value> = rows
        .iter()
        .map(|r| serde_json::to_value(r).unwrap())
        .collect();
    assert_eq!(rows[0]["person"], "user_guest");
    assert_eq!(rows[1]["person"], "user_guest");
    assert_eq!(rows[1]["machine"], "vm-one");
    assert_eq!(rows[2]["person"], "user_owner");
}

#[test]
fn credit_meter_native_route_does_not_change_harness_subscriptions() {
    let rows = fold_all(&[
        json!({"ev":"usage.native_route", "payer":"platform", "provider":"cmux-router"}),
        json!({"ev":"turn.start", "turn":"native", "harness":"native"}),
        json!({"ev":"turn.end", "turn":"native", "usage":{"input":1}}),
        json!({"ev":"turn.start", "turn":"own", "harness":"claude"}),
        json!({"ev":"turn.end", "turn":"own", "usage":{"input":1}}),
    ]);
    assert_eq!(serde_json::to_value(&rows[0]).unwrap()["payer"], "platform");
    assert_eq!(serde_json::to_value(&rows[1]).unwrap()["payer"], "own");
}

#[test]
fn credit_meter_cli_backfill_never_copies_credential_environment() {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("optchat");
    let ts = chrono::Utc::now().timestamp_millis() as u64;
    write_trace(
        &root.join("traces"),
        "2026-11-03",
        &[json!({"ev":"turn.end", "ts":ts, "turn":"t", "harness":"claude", "usage":{"input":1}})],
    );
    let secret = "sk-test-env-token-not-for-the-ledger";
    let out = std::process::Command::new(env!("CARGO_BIN_EXE_optchat-chief"))
        .args([
            "usage",
            "backfill",
            "--mux-home",
            tmp.path().to_str().unwrap(),
        ])
        .env("ANTHROPIC_API_KEY", secret)
        .env("OPENAI_API_KEY", secret)
        .env("CMUX_CLOUD_SESSION_TOKEN", secret)
        .output()
        .unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stderr)
    );
    let lines = usage::read(&usage::dir(&root), 0, u64::MAX).unwrap();
    assert_eq!(lines.len(), 1);
    for entry in std::fs::read_dir(usage::dir(&root)).unwrap().flatten() {
        if entry.path().extension().is_some_and(|s| s == "jsonl") {
            assert!(
                !std::fs::read_to_string(entry.path())
                    .unwrap()
                    .contains(secret)
            );
        }
    }
}

#[test]
fn credit_meter_resumed_subagent_keeps_the_original_person_and_route() {
    let tmp = tempfile::tempdir().unwrap();
    let path = tmp.path().join("traces");
    {
        let trace = Trace::open(&path, false).unwrap();
        trace.emit("usage.identity", json!({"person":"user_owner"}));
        trace.emit(
            "subagent.start",
            json!({"id":"a1","session":"s1","person":"user_guest","harness":"cmux","peer":"vm1"}),
        );
        trace.emit(
            "subagent.answer",
            json!({"id":"a1","cost_usd":1.0,"usage":{"input":1}}),
        );
        trace.emit("subagent.answer", json!({"id":"a1","usage":{"input":1}}));
    }
    let trace = Trace::open(&path, false).unwrap();
    trace.emit("usage.identity", json!({"person":"user_owner"}));
    trace.emit(
        "subagent.answer",
        json!({"id":"a1","cost_usd":2.0,"usage":{"input":1}}),
    );
    let rows = usage::read(&usage::dir(tmp.path()), 0, u64::MAX).unwrap();
    let row = serde_json::to_value(rows.last().unwrap()).unwrap();
    assert_eq!(row["person"], "user_guest");
    assert_eq!(row["harness"], "cmux");
    assert_eq!(row["payer"], "platform");
    assert_eq!(row["machine"], "vm1");
    assert_eq!(row["usd"], 1.0);
}

#[test]
fn legacy_resumed_subagent_never_inherits_the_current_owner() {
    let tmp = tempfile::tempdir().unwrap();
    let dir = usage::dir(tmp.path());
    std::fs::create_dir_all(&dir).unwrap();
    std::fs::write(
        dir.join("2026-10.jsonl"),
        format!(
            "{}\n",
            json!({"v":1,"ts":T0,"kind":"subagent","key":"old","agent":"a1","harness":"cmux","usd_cum":1.0})
        ),
    )
    .unwrap();
    let ledger = usage::Ledger::open(&dir).unwrap();
    ledger.observe(&json!({"ev":"usage.identity","person":"account-owner"}));
    ledger.observe(&answer(T0 + 1, "a1", 2.0));
    let rows = usage::read(&dir, 0, u64::MAX).unwrap();
    let line = rows.last().unwrap();
    assert_eq!(line.person.as_deref(), Some("unknown"));
    assert_eq!(line.usd, Some(1.0));
    let chief = Chief {
        id: "c".into(),
        label: "Chief".into(),
        home: "/h".into(),
    };
    let row = usage::export_row(&chief, line);
    assert_eq!(row["stack_user_id"], "unknown");
    assert_eq!(row["billable"], false);
}

#[test]
fn credit_backfill_history_does_not_lock_out_live_turns() {
    let tmp = tempfile::tempdir().unwrap();
    let traces = tmp.path().join("traces");
    let trace = Trace::open(&traces, false).unwrap();
    let fifo = traces.join("2026-11-03.jsonl");
    assert!(
        std::process::Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success()
    );
    let root = tmp.path().to_owned();
    let backfill = std::thread::spawn(move || usage::backfill(&root, false));
    // Opening the writer proves backfill is now blocked reading history.
    let writer = std::fs::OpenOptions::new().write(true).open(&fifo).unwrap();
    let (sent, received) = std::sync::mpsc::channel();
    // Use a separate trace date file, so the test's live event cannot write
    // into the historical FIFO itself.
    let live = usage::Ledger::open(&usage::dir(tmp.path())).unwrap();
    let thread = std::thread::spawn(move || {
        live.observe(&json!({"ev":"turn.end","ts":T0,"turn":"live","usage":{"input":1}}));
        sent.send(()).unwrap();
    });
    let responsive = received
        .recv_timeout(std::time::Duration::from_secs(2))
        .is_ok();
    drop(writer);
    backfill.join().unwrap().unwrap();
    thread.join().unwrap();
    drop(trace);
    assert!(responsive, "historical scanning blocked a live Chief event");
}

#[test]
fn unresolved_accounts_are_unknown_and_never_billable() {
    for person in [
        None,
        Some("user_local"),
        Some("remote_install"),
        Some("unknown"),
        Some(""),
    ] {
        let line = fold_all(&[json!({"ev":"turn.end", "turn":"t", "person":person, "harness":"cmux", "usage":{"input":1}})]).pop().unwrap();
        assert_eq!(serde_json::to_value(&line).unwrap()["person"], "unknown");
        let chief = Chief {
            id: "c".into(),
            label: "Chief".into(),
            home: "/h".into(),
        };
        let row = usage::export_row(&chief, &line);
        assert_eq!(row["stack_user_id"], "unknown");
        assert_eq!(row["billable"], false);
    }
    let chief = Chief {
        id: "c".into(),
        label: "Chief".into(),
        home: "/h".into(),
    };
    let legacy: Line = serde_json::from_str(r#"{"v":1,"kind":"turn","key":"old"}"#).unwrap();
    assert_eq!(usage::export_row(&chief, &legacy)["billable"], false);
    let line =
        fold_all(&[json!({"ev":"turn.end", "turn":"t", "person":"account-id", "harness":"cmux"})])
            .pop()
            .unwrap();
    assert_eq!(usage::export_row(&chief, &line)["billable"], true);
}

#[test]
fn legacy_export_ids_are_scoped_to_each_chief_home() {
    let a = tempfile::tempdir().unwrap();
    let b = tempfile::tempdir().unwrap();
    let line: Line =
        serde_json::from_value(json!({"v":1,"kind":"compactor","key":"5236+4"})).unwrap();
    let chief = |home: &Path| Chief {
        id: "default".into(),
        label: "Chief".into(),
        home: home.display().to_string(),
    };
    let first = usage::export_row(&chief(a.path()), &line);
    let again = usage::export_row(&chief(a.path()), &line);
    let other = usage::export_row(&chief(b.path()), &line);
    assert_eq!(first["request_id"], again["request_id"]);
    assert_ne!(first["request_id"], other["request_id"]);
}

#[test]
fn compactor_probe_and_description_exports_are_unique_per_unit() {
    let chief = Chief {
        id: "c".into(),
        label: "Chief".into(),
        home: "/h".into(),
    };
    for key in ["probe", "describe", "5236+4"] {
        let a: Line =
            serde_json::from_value(json!({"v":1,"kind":"compactor","key":key,"ts":1})).unwrap();
        let b = Line { ts: 2, ..a.clone() };
        assert_eq!(usage::export_row(&chief, &a), usage::export_row(&chief, &a));
        assert_ne!(
            usage::export_row(&chief, &a)["request_id"],
            usage::export_row(&chief, &b)["request_id"]
        );
    }
}

#[test]
fn concurrent_compactor_units_keep_their_trace_unit_keys() {
    let rows = fold_all(&[
        json!({"ev":"node","ts":T0,"node":"describe","usage_key":"node1:session1","usage":{"input":1}}),
        json!({"ev":"node","ts":T0,"node":"describe","usage_key":"node2:session2","usage":{"input":1}}),
    ]);
    assert_ne!(rows[0].key, rows[1].key);
    let chief = Chief {
        id: "c".into(),
        label: "Chief".into(),
        home: "/h".into(),
    };
    assert_ne!(
        usage::export_row(&chief, &rows[0])["request_id"],
        usage::export_row(&chief, &rows[1])["request_id"]
    );
}

#[test]
fn unknown_message_sender_never_falls_back_to_the_owner() {
    for person in [Value::Null, json!("user_local"), json!("remote_install")] {
        let rows = fold_all(&[
            json!({"ev":"usage.identity","person":"account-owner"}),
            json!({"ev":"usage.message","id":"first","person":person}),
            json!({"ev":"usage.message","id":"later","person":"account-guest"}),
            json!({"ev":"turn.start","turn":"t","message_keys":["first","later"],"harness":"cmux"}),
            json!({"ev":"spawn","ids":["a1"],"harness":"cmux"}),
            json!({"ev":"turn.end","turn":"t"}),
            json!({"ev":"subagent.answer","id":"a1","usage":{"input":1}}),
        ]);
        for line in rows {
            assert_eq!(serde_json::to_value(line).unwrap()["person"], "unknown");
        }
    }
    let row = fold_all(&[
        json!({"ev":"usage.identity","person":"account-owner"}),
        json!({"ev":"turn.start","turn":"t","message_keys":["unseen"],"harness":"cmux"}),
        json!({"ev":"turn.end","turn":"t"}),
    ])
    .pop()
    .unwrap();
    assert_eq!(serde_json::to_value(row).unwrap()["person"], "unknown");
}

#[test]
fn legacy_native_payer_is_unknown_and_current_identity_cannot_backfill_history() {
    let chief = Chief {
        id: "c".into(),
        label: "Chief".into(),
        home: "/h".into(),
    };
    let line: Line = serde_json::from_value(
        json!({"v":1,"kind":"turn","key":"t","harness":"native","person":"account-owner"}),
    )
    .unwrap();
    let row = usage::export_row(&chief, &line);
    assert_eq!(row["payer"], "unknown");
    assert_eq!(row["billable"], false);
    let tmp = tempfile::tempdir().unwrap();
    std::fs::create_dir_all(usage::dir(tmp.path())).unwrap();
    std::fs::write(
        usage::dir(tmp.path()).join("identity.json"),
        r#"{"person":"current-owner"}"#,
    )
    .unwrap();
    write_trace(
        &tmp.path().join("traces"),
        "2026-10-18",
        &[turn_end(T0, "old", 0.1, 1, 0, 0, 1)],
    );
    usage::backfill(tmp.path(), false).unwrap();
    let rows = usage::read(&usage::dir(tmp.path()), 0, u64::MAX).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(serde_json::to_value(&rows[0]).unwrap()["person"], "unknown");
    assert_eq!(usage::export_row(&chief, &rows[0])["billable"], false);
}
