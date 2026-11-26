//! Instruction counts of acpmux's hot paths, read by Callgrind, so a pull request that makes
//! one costlier fails CI (`ci/steps.toml` step `acpmux-icount`). An instruction count does
//! not move with the runner's load the way a time does: the same code on the same runner
//! class counts within a fraction of a percent, so a 2% rise is a real one.
//!
//! Cases, each a deterministic run of one path:
//!
//! - `mcp_connect`: a chat's MCP connect to acpmux's own tool servers as the gateway answers
//!   it: the servers made, then `initialize` and `tools/list` of each parsed, answered and
//!   serialized (`acpmux::icount::mcp_connect`, `post_tools` in `mcp_gateway.rs`).
//! - `chat_frame`: the chat pane's client core (`acpmux-client`, as `AcpmuxChatRowsHost`
//!   drives it) taking v2 chat delta frames (a settled row and an open row's text each) to
//!   its changes, after the chat's window.
//! - `jsonrpc_round`: one JSON-RPC `session/update` (an agent's text chunk, ~2 KB) parsed and
//!   serialized again.
//!
//! Only the measured function (`icount_measured`) counts: Callgrind starts with collection
//! off and turns it on inside it (`--toggle-collect`), so setup costs nothing.
//!
//! ```text
//! cargo bench -p acpmux --bench icount -- check            # every case under Callgrind
//! cargo bench -p acpmux --bench icount -- check --update   # rewrite the baseline
//! cargo bench -p acpmux --bench icount -- case NAME        # one case, no Callgrind
//! ```
//!
//! `check` compares each case's total instructions (Ir) to
//! `benches/icount_baseline.json` and fails when one is more than its `tolerance_pct` over.
//! It writes a Markdown table to `$GITHUB_STEP_SUMMARY` when that is set.

use std::hint::black_box;
use std::path::{Path, PathBuf};
use std::process::{Command, ExitCode};

use acpmux_client::Client;
use acpmux_client::chat::ChatSubRequest;
use acpmux_client::wire::{
    ChatDelta, ChatOp, ChatWindow, Frame, FrameKind, HelloReply, Limits, QueueHead, RawJson,
};
use serde_json::{Value, json};

const CASES: [&str; 3] = ["mcp_connect", "chat_frame", "jsonrpc_round"];

/// Repeats of each case in the measured run: enough that one run's fixed costs vanish.
const MCP_CONNECTS: usize = 20;
const CHAT_DELTAS: u64 = 2_000;
const JSONRPC_ROUNDS: usize = 500;

const BASELINE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/benches/icount_baseline.json");

/// The one function Callgrind counts in.
#[inline(never)]
fn icount_measured(run: &mut dyn FnMut() -> usize) -> usize {
    black_box(run())
}

fn run_case(name: &str) -> Result<usize, String> {
    match name {
        "mcp_connect" => Ok(icount_measured(&mut || {
            (0..MCP_CONNECTS).map(|_| acpmux::icount::mcp_connect()).sum()
        })),
        "chat_frame" => {
            let (mut client, frames) = chat_setup();
            Ok(icount_measured(&mut || chat_frames(&mut client, &frames)))
        }
        "jsonrpc_round" => {
            let update = session_update();
            Ok(icount_measured(&mut || {
                (0..JSONRPC_ROUNDS).map(|_| jsonrpc_round(black_box(&update))).sum()
            }))
        }
        other => Err(format!("unknown case {other}; cases: {}", CASES.join(", "))),
    }
}

fn row(id: u64) -> RawJson {
    let text = format!(
        r#"{{"id":{id},"rev":1,"kind":"agent","body":{{"text":"row {id}: the agent's reply, a sentence or two long, as a chat row holds it."}}}}"#
    );
    RawJson::from_bytes(text.as_bytes()).expect("row json")
}

/// A ready client subscribed to chat `c1` with its first window (rows 1..=100) taken, and the
/// encoded delta frames the measured run feeds it.
fn chat_setup() -> (Client<Value>, Vec<Vec<u8>>) {
    let mut client = Client::<Value>::connected_v2();
    let hello = Frame::json(
        FrameKind::Hello,
        &HelloReply { daemon_id: "d".into(), limits: Limits::default() },
    )
    .expect("hello")
    .encode();
    client.received(&hello);
    while client.take_send().is_some() {}
    client
        .subscribe_chat(ChatSubRequest {
            sid: "c".into(),
            chat: "c1".into(),
            anchor: None,
            window: None,
        })
        .expect("subscribe");
    while client.take_send().is_some() {}
    let window = Frame::json(
        FrameKind::Window,
        &ChatWindow {
            sid: "c".into(),
            cursor: 100,
            edition: 1,
            rows: (1..=100).map(row).collect(),
            has_before: false,
            has_after: false,
            open: Vec::new(),
            queue: QueueHead::default(),
            seen: None,
            folds: Vec::new(),
            refused: Vec::new(),
        },
    )
    .expect("window")
    .encode();
    feed(&mut client, &window);
    let text = RawJson::from_bytes(br#"" and a few more words""#).expect("text json");
    let frames = (0..CHAT_DELTAS)
        .map(|step| {
            let seq = 101 + step;
            let ops = vec![
                ChatOp::Text { seq: seq - 1, row_id: seq, text: text.clone() },
                ChatOp::Row { seq, row: row(seq), body_len: None },
            ];
            Frame::json(FrameKind::Delta, &ChatDelta { sid: "c".into(), replay: None, ops })
                .expect("delta")
                .encode()
        })
        .collect();
    (client, frames)
}

/// Feeds `bytes` as a socket reads them and takes every change; returns the changes.
fn feed(client: &mut Client<Value>, bytes: &[u8]) -> usize {
    let (mut at, mut changes) = (0, 0);
    while at < bytes.len() {
        let read = client.received(bytes.get(at..).unwrap_or_default());
        while let Some(change) = client.next_change() {
            black_box(&change);
            changes += 1;
        }
        while client.take_send().is_some() {}
        if read == 0 && changes == 0 {
            break;
        }
        at += read;
    }
    changes
}

fn chat_frames(client: &mut Client<Value>, frames: &[Vec<u8>]) -> usize {
    frames.iter().map(|frame| feed(client, frame)).sum()
}

/// An agent's text chunk as acpmux sends it to a client: ~2 KB of `session/update`.
fn session_update() -> Vec<u8> {
    let text = "The change keeps the window's rows in one place and reads them once. ".repeat(24);
    serde_json::to_vec(&json!({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {
            "sessionId": "0f6d3c1e-5b2a-4c8e-9a71-2d4f6b8c0e13",
            "update": {
                "sessionUpdate": "agent_message_chunk",
                "content": {"type": "text", "text": text},
                "_meta": {"cmux/seq": 4182, "cmux/rowId": 977, "cmux/turn": 41}
            }
        }
    }))
    .expect("update json")
}

fn jsonrpc_round(bytes: &[u8]) -> usize {
    let Ok(message) = serde_json::from_slice::<Value>(bytes) else { return 0 };
    serde_json::to_vec(&message).map(|out| out.len()).unwrap_or(0)
}

struct Baseline {
    tolerance_pct: f64,
    cases: serde_json::Map<String, Value>,
}

fn read_baseline(path: &Path) -> Result<Baseline, String> {
    let text = std::fs::read_to_string(path).map_err(|e| format!("{}: {e}", path.display()))?;
    let value: Value =
        serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    Ok(Baseline {
        tolerance_pct: value["tolerance_pct"].as_f64().unwrap_or(2.0),
        cases: value["cases"].as_object().cloned().unwrap_or_default(),
    })
}

/// Total instructions Callgrind counted for `case` run by this binary.
fn callgrind_ir(case: &str, scratch: &Path) -> Result<u64, String> {
    let exe = std::env::current_exe().map_err(|e| format!("current_exe: {e}"))?;
    let out = scratch.join(format!("callgrind.{case}.out"));
    let status = Command::new("valgrind")
        .args([
            "--tool=callgrind",
            "--collect-atstart=no",
            "--toggle-collect=*icount_measured*",
            "--dump-instr=no",
            "--compress-strings=no",
        ])
        .arg(format!("--callgrind-out-file={}", out.display()))
        .arg(&exe)
        .args(["case", case])
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
        .map_err(|e| format!("valgrind: {e} (is valgrind installed?)"))?;
    if !status.success() {
        return Err(format!("valgrind on case {case}: {status}"));
    }
    let text = std::fs::read_to_string(&out).map_err(|e| format!("{}: {e}", out.display()))?;
    text.lines()
        .find_map(|line| line.strip_prefix("totals:").or_else(|| line.strip_prefix("summary:")))
        .and_then(|rest| rest.split_whitespace().next())
        .and_then(|n| n.parse().ok())
        .filter(|&n: &u64| n > 0)
        .ok_or_else(|| format!("{}: no instruction total", out.display()))
}

fn check(update: bool, baseline_path: &Path, only: Option<&str>) -> Result<bool, String> {
    let baseline = read_baseline(baseline_path)
        .unwrap_or(Baseline { tolerance_pct: 2.0, cases: serde_json::Map::new() });
    let scratch = tempfile::tempdir().map_err(|e| format!("tempdir: {e}"))?;
    let mut rows = Vec::new();
    let mut now_cases = serde_json::Map::new();
    let mut ok = true;
    for case in CASES.iter().filter(|case| only.is_none_or(|only| only == **case)) {
        let now = callgrind_ir(case, scratch.path())?;
        now_cases.insert((*case).to_owned(), json!(now));
        let was = baseline.cases.get(*case).and_then(Value::as_u64);
        let (delta, verdict) = match was {
            Some(was) => {
                let pct = (now as f64 - was as f64) * 100.0 / was as f64;
                let over = pct > baseline.tolerance_pct;
                ok &= update || !over;
                (format!("{pct:+.2}%"), if over { "over" } else { "ok" })
            }
            None => {
                ok &= update;
                ("new".to_owned(), "no baseline")
            }
        };
        let was = was.map_or("-".to_owned(), |was| was.to_string());
        println!("{case}: baseline {was} Ir, now {now} Ir, {delta} ({verdict})");
        rows.push(format!("| `{case}` | {was} | {now} | {delta} | {verdict} |"));
    }
    let mut summary = format!(
        "### acpmux instruction counts (Callgrind)\n\nA case fails more than {}% over its baseline \
         (`cmux-tui/crates/acpmux/benches/icount_baseline.json`).\n\n\
         | case | baseline Ir | now Ir | delta | |\n|---|---:|---:|---:|---|\n{}\n",
        baseline.tolerance_pct,
        rows.join("\n")
    );
    if update {
        let mut cases = baseline.cases.clone();
        cases.extend(now_cases);
        let file = json!({
            "about": "Callgrind instruction counts (Ir) of benches/icount.rs's cases on the cmux-linux \
                      runners; `cargo bench -p acpmux --bench icount -- check --update` rewrites them.",
            "tolerance_pct": baseline.tolerance_pct,
            "cases": cases,
        });
        let text = serde_json::to_string_pretty(&file).map_err(|e| e.to_string())? + "\n";
        std::fs::write(baseline_path, text)
            .map_err(|e| format!("{}: {e}", baseline_path.display()))?;
        summary.push_str(&format!("\nBaseline rewritten: {}\n", baseline_path.display()));
        println!("wrote {}", baseline_path.display());
    }
    if let Some(path) = std::env::var_os("GITHUB_STEP_SUMMARY") {
        use std::io::Write;
        let _ = std::fs::OpenOptions::new()
            .append(true)
            .create(true)
            .open(path)
            .and_then(|mut file| file.write_all(summary.as_bytes()));
    }
    Ok(ok)
}

fn main() -> ExitCode {
    // cargo bench passes `--bench`; it means nothing here.
    let args: Vec<String> = std::env::args().skip(1).filter(|arg| arg != "--bench").collect();
    let result = match args.first().map(String::as_str) {
        Some("case") => match args.get(1) {
            Some(name) => run_case(name).map(|out| {
                println!("{name}: {out}");
                true
            }),
            None => Err("case NAME".to_owned()),
        },
        Some("check") => {
            let mut update = false;
            let mut baseline = PathBuf::from(BASELINE);
            let mut only = None;
            let mut rest = args.iter().skip(1);
            let mut bad = None;
            while let Some(arg) = rest.next() {
                match arg.as_str() {
                    "--update" => update = true,
                    "--baseline" => match rest.next() {
                        Some(path) => baseline = PathBuf::from(path),
                        None => bad = Some("--baseline FILE".to_owned()),
                    },
                    "--only" => only = rest.next().cloned(),
                    other => bad = Some(format!("unknown argument {other}")),
                }
            }
            match bad {
                Some(bad) => Err(bad),
                None => check(update, &baseline, only.as_deref()),
            }
        }
        // A bare `cargo bench` runs every case once, uncounted: a smoke run.
        None => CASES.iter().try_for_each(|case| run_case(case).map(drop)).map(|()| true),
        Some(other) => Err(format!("unknown mode {other}; modes: check [--update], case NAME")),
    };
    match result {
        Ok(true) => ExitCode::SUCCESS,
        Ok(false) => {
            eprintln!("icount: a case is over its baseline (or has none); see above");
            ExitCode::FAILURE
        }
        Err(e) => {
            eprintln!("icount: {e}");
            ExitCode::from(2)
        }
    }
}
