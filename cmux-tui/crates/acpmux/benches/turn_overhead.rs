//! What our agent path costs a turn when the model costs nothing: a real `acpmux daemon run`, a
//! Claude Code stand-in (this binary again, speaking Claude Code's stream-json) that answers each
//! prompt the moment it reads it, and the cmux NEXT chat pane's client core
//! (`acpmux-client`, as `AcpmuxChatRowsHost` drives it) on the daemon's v2 chat surface. Each
//! turn is timed by stage, and the run reports the median and p95 of each over `--turns` turns
//! (Leo, 2026-11-19, on a published harness bench: a mock model over a 100-turn session).
//!
//! Stages of one turn, each in microseconds:
//!
//! - `send`: the client writes `session/prompt` until the stand-in reads the user line (the
//!   socket, the hub's prompt records, the Claude translator, the agent's stdin);
//! - `harness`: the stand-in reads the line until it has written its whole reply (a real
//!   harness's own cost goes here; this one's is the time to write a few lines);
//! - `store`: the store's appends of every record the turn wrote (`gauges` `recordWrites`,
//!   read around the turn); a part of `send` and `deliver`, not after them;
//! - `deliver`: the stand-in's reply is written until the prompting client reads its text
//!   (`session/update`);
//! - `render`: the stand-in's reply is written until the pane's client core gives the change
//!   that holds it (v2 chat bytes off the socket, `received`, `next_change`);
//! - `turn`: the client's send until the prompt's response (the turn's end);
//! - `shown`: the client's send until the pane's change.
//!
//! The stand-in and this process read one clock (`CLOCK_REALTIME`): the stand-in puts the times
//! it read the prompt and wrote the reply into the reply's text.
//!
//! `cargo bench -p acpmux --bench turn_overhead -- [--turns 100] [--warmup 5] [--summary FILE]
//! [--json FILE] [--daemon PATH] [--no-render]`. `--summary` appends the Markdown table (CI's
//! `$GITHUB_STEP_SUMMARY`); `--json` writes the rows cmux-bench reads
//! (`scripts/bench/benches/agent_turn.py`); `--daemon` runs another acpmux build (a base, for a
//! before and after from this same harness).

#![cfg(unix)]

#[path = "../tests/support/daemon_env.rs"]
mod daemon_env;
// The stand-in Claude is this binary; nothing else starts.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in();

#[path = "turn_overhead/render.rs"]
mod render;

use serde_json::{Value, json};
use std::collections::HashMap;
use std::io::{BufRead, Write as _};
use std::path::{Path, PathBuf};
use std::process::{Child, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

/// Set on the stand-in's environment: this binary is the harness, not the bench.
const STAND_IN: &str = "ACPMUX_TURN_BENCH_STAND_IN";
/// How long one turn may take before the run fails.
const TURN_LIMIT: Duration = Duration::from_secs(30);

fn main() {
    if std::env::var_os(STAND_IN).is_some() {
        stand_in();
        return;
    }
    let args = Args::parse();
    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build().unwrap();
    let samples = runtime.block_on(bench(&args));
    let table = table(&args, &samples);
    println!("{table}");
    // The line cmux-bench reads (`scripts/bench/benches/agent_turn.py`), from a log too.
    println!("AGENT-TURN {}", rows(&samples));
    if let Some(path) = &args.summary {
        let mut file = std::fs::OpenOptions::new().create(true).append(true).open(path).unwrap();
        writeln!(file, "{table}").unwrap();
    }
    if let Some(path) = &args.json {
        std::fs::write(path, rows(&samples).to_string()).unwrap();
    }
}

struct Args {
    turns: usize,
    warmup: usize,
    summary: Option<PathBuf>,
    json: Option<PathBuf>,
    daemon: Option<PathBuf>,
    render: bool,
}

impl Args {
    fn parse() -> Self {
        let mut args =
            Self { turns: 100, warmup: 5, summary: None, json: None, daemon: None, render: true };
        let mut it = std::env::args().skip(1);
        while let Some(arg) = it.next() {
            let mut value = || it.next().unwrap_or_else(|| panic!("{arg} needs a value"));
            match arg.as_str() {
                "--turns" => args.turns = value().parse().unwrap(),
                "--warmup" => args.warmup = value().parse().unwrap(),
                "--summary" => args.summary = Some(value().into()),
                "--json" => args.json = Some(value().into()),
                "--daemon" => args.daemon = Some(value().into()),
                "--no-render" => args.render = false,
                // `cargo bench` passes `--bench`.
                "--bench" => {}
                other => panic!("unknown argument {other}"),
            }
        }
        args
    }
}

/// Nanoseconds on `CLOCK_REALTIME`, the clock the stand-in reads too.
fn wall_ns() -> u64 {
    u64::try_from(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos()).unwrap()
}

/// Claude Code's stream-json protocol, as `tests/fake_claude_stream.py` speaks it, with no model:
/// each user line is answered at once with one short text reply whose text carries the prompt's
/// marker and the times it was read and answered (`r=<ns> w=<ns>`).
fn stand_in() {
    let session = std::env::args()
        .collect::<Vec<_>>()
        .windows(2)
        .find(|w| w[0] == "--session-id" || w[0] == "--resume")
        .map_or_else(|| "turn-bench-session".to_owned(), |w| w[1].clone());
    let stdin = std::io::stdin();
    let mut out = std::io::BufWriter::new(std::io::stdout().lock());
    let send = |out: &mut std::io::BufWriter<_>, v: Value| {
        serde_json::to_writer(&mut *out, &v).unwrap();
        out.write_all(b"\n").unwrap();
    };
    let mut n = 0u64;
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let read = wall_ns();
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        match msg["type"].as_str() {
            Some("control_request") => {
                let initialize = msg["request"]["subtype"] == "initialize";
                let response = if initialize {
                    json!({"commands": [], "models": [], "account": {}})
                } else {
                    json!({})
                };
                send(
                    &mut out,
                    json!({"type": "control_response", "response": {
                    "subtype": "success", "request_id": msg["request_id"], "response": response}}),
                );
                if initialize {
                    send(
                        &mut out,
                        json!({"type": "system", "subtype": "init",
                        "session_id": session, "model": "stand-in", "permissionMode": "default",
                        "tools": [], "mcp_servers": []}),
                    );
                }
                out.flush().unwrap();
            }
            Some("user") => {
                n += 1;
                let marker = marker_of(&msg).unwrap_or_default();
                let id = format!("msg_{n:016x}");
                let start = |kind: &str, body: Value| {
                    let mut event = json!({"type": kind});
                    event.as_object_mut().unwrap().extend(body.as_object().unwrap().clone());
                    json!({"type": "stream_event", "event": event, "session_id": session})
                };
                send(
                    &mut out,
                    start(
                        "message_start",
                        json!({"message": {"id": id,
                    "type": "message", "role": "assistant", "model": "stand-in", "content": [],
                    "usage": {"input_tokens": 1, "output_tokens": 1}}}),
                    ),
                );
                send(
                    &mut out,
                    start(
                        "content_block_start",
                        json!({"index": 0, "content_block": {"type": "text", "text": ""}}),
                    ),
                );
                // The write time is read last, just before the reply's text goes out.
                let text = format!("ok {marker} r={read} w={}", wall_ns());
                send(
                    &mut out,
                    start(
                        "content_block_delta",
                        json!({"index": 0, "delta": {"type": "text_delta", "text": text}}),
                    ),
                );
                send(&mut out, start("content_block_stop", json!({"index": 0})));
                send(
                    &mut out,
                    start(
                        "message_delta",
                        json!({"delta": {"stop_reason": "end_turn"}, "usage": {"output_tokens": 8}}),
                    ),
                );
                send(&mut out, start("message_stop", json!({})));
                send(
                    &mut out,
                    json!({"type": "assistant", "message": {"id": id,
                    "role": "assistant", "model": "stand-in",
                    "content": [{"type": "text", "text": text}], "stop_reason": "end_turn",
                    "usage": {"input_tokens": 1, "output_tokens": 8}}, "session_id": session}),
                );
                send(
                    &mut out,
                    json!({"type": "result", "subtype": "success", "result": text,
                    "num_turns": 1, "duration_api_ms": 0, "session_id": session,
                    "usage": {"input_tokens": 1, "output_tokens": 8}}),
                );
                out.flush().unwrap();
            }
            _ => {}
        }
    }
}

/// The `turn-<n>` word of a user line's text.
fn marker_of(msg: &Value) -> Option<String> {
    let content = &msg["message"]["content"];
    let text = match content {
        Value::String(s) => s.clone(),
        Value::Array(parts) => {
            parts.iter().filter_map(|p| p["text"].as_str()).collect::<Vec<_>>().join(" ")
        }
        _ => return None,
    };
    text.split_whitespace().find(|w| w.starts_with("turn-")).map(str::to_owned)
}

/// `r=` and `w=` of a reply's text.
fn reply_times(text: &str) -> Option<(u64, u64)> {
    let field = |key: &str| {
        text.split_whitespace().find_map(|w| w.strip_prefix(key)).and_then(|v| v.parse().ok())
    };
    Some((field("r=")?, field("w=")?))
}

/// The daemon, killed on drop by the pid it was started with.
struct Daemon {
    child: Child,
    socket: PathBuf,
    _scratch: daemon_env::Scratch,
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Daemon {
    fn start(binary: &Path) -> Self {
        let scratch = daemon_env::Scratch::new("turn-bench");
        let home = scratch.path().join("acpmux");
        std::fs::create_dir_all(&home).unwrap();
        let me = std::env::current_exe().unwrap();
        let config = json!({
            // The surfaces the pane's chat reads (`render.rs`).
            "acpmux.v2": render::SURFACES,
            "harnesses": {"stand-in": {
                "kind": "claude-stdio",
                "argv": [me],
                // Already hermetic: its own start does not start it again (`daemon_env::enter`).
                "env": {STAND_IN: "1", "ACPMUX_TEST_HERMETIC": "1"},
            }},
            "defaultHarness": "stand-in",
            "permissionPolicy": "approve-all",
        });
        std::fs::write(home.join("config.json"), config.to_string()).unwrap();
        let socket = scratch.path().join("s.sock");
        let mut command =
            daemon_env::command_at(binary, scratch.path(), daemon_env::Agents::StandIn, &[]);
        command
            .args(["daemon", "run", "--log", "warn"])
            .env("ACPMUX_HOME", &home)
            .env("ACPMUX_SOCKET", &socket)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::inherit());
        let mut child = command.spawn().unwrap();
        let started = Instant::now();
        while std::os::unix::net::UnixStream::connect(&socket).is_err() {
            if started.elapsed() > Duration::from_secs(60) || child.try_wait().unwrap().is_some() {
                let _ = child.kill();
                let _ = child.wait();
                panic!("the daemon did not bind {}", socket.display());
            }
            std::thread::sleep(Duration::from_millis(5));
        }
        Self { child, socket, _scratch: scratch }
    }
}

/// One v1 connection, as the pane's prompt path and the CLI speak it.
struct Rpc {
    read: tokio::io::Lines<BufReader<OwnedReadHalf>>,
    write: OwnedWriteHalf,
    next: i64,
}

impl Rpc {
    async fn open(socket: &Path) -> Self {
        let (read, write) = UnixStream::connect(socket).await.unwrap().into_split();
        let mut rpc = Self { read: BufReader::new(read).lines(), write, next: 0 };
        rpc.call("initialize", json!({"protocolVersion": 1, "clientInfo": {"name": "turn-bench"}}))
            .await;
        rpc
    }

    async fn send(&mut self, method: &str, params: Value) -> i64 {
        self.next += 1;
        let line = json!({"jsonrpc": "2.0", "id": self.next, "method": method, "params": params});
        self.write.write_all(format!("{line}\n").as_bytes()).await.unwrap();
        self.next
    }

    async fn line(&mut self) -> Value {
        let line = tokio::time::timeout(TURN_LIMIT, self.read.next_line())
            .await
            .expect("the daemon went quiet")
            .unwrap()
            .expect("the daemon closed the connection");
        serde_json::from_str(&line).unwrap()
    }

    async fn call(&mut self, method: &str, params: Value) -> Value {
        let id = self.send(method, params).await;
        loop {
            let v = self.line().await;
            if v["id"] == id && v.get("method").is_none() {
                assert!(v.get("error").is_none(), "{method}: {v}");
                return v["result"].clone();
            }
        }
    }

    /// `gauges.recordWrites` of `_acpmux/status`: (records, store ns).
    async fn writes(&mut self) -> (u64, u64) {
        let status = self.call("_acpmux/status", json!({})).await;
        let w = &status["gauges"]["recordWrites"];
        (w["records"].as_u64().unwrap_or(0), w["storeNs"].as_u64().unwrap_or(0))
    }
}

/// One turn's stages, in microseconds (see the module text); `render` and `shown` are None with
/// `--no-render`.
#[derive(Default, Clone)]
struct Turn {
    send: f64,
    harness: f64,
    store: f64,
    records: f64,
    deliver: f64,
    render: Option<f64>,
    turn: f64,
    shown: Option<f64>,
}

async fn bench(args: &Args) -> Vec<Turn> {
    let binary = args.daemon.clone().unwrap_or_else(|| daemon_env::bin().to_path_buf());
    let daemon = Daemon::start(&binary);
    let mut rpc = Rpc::open(&daemon.socket).await;
    let cwd = daemon._scratch.path().join("work");
    std::fs::create_dir_all(&cwd).unwrap();
    let chat = rpc
        .call(
            "session/new",
            json!({"cwd": cwd, "mcpServers": [],
            "_meta": {"acpmux": {"harness": "stand-in", "name": "turn-bench"}}}),
        )
        .await["sessionId"]
        .as_str()
        .unwrap()
        .to_owned();
    let mut pane = if args.render {
        Some(render::ChatRender::open(&daemon.socket, &chat).await.expect("the pane's chat open"))
    } else {
        None
    };
    let mut samples = Vec::with_capacity(args.turns);
    for round in 0..args.warmup + args.turns {
        let turn = one_turn(&mut rpc, pane.as_mut(), &chat, round).await;
        if round >= args.warmup {
            samples.push(turn);
        }
    }
    drop(pane);
    drop(daemon);
    samples
}

async fn one_turn(
    rpc: &mut Rpc,
    pane: Option<&mut render::ChatRender>,
    chat: &str,
    round: usize,
) -> Turn {
    let marker = format!("turn-{round}");
    let (records_before, store_before) = rpc.writes().await;
    let sent_wall = wall_ns();
    let sent = Instant::now();
    let id = rpc
        .send(
            "session/prompt",
            json!({"sessionId": chat,
            "prompt": [{"type": "text", "text": format!("{marker} hello")}]}),
        )
        .await;
    let shown = async {
        match pane {
            // The reply's text, not the prompt's (the pane draws both).
            Some(pane) => Some(
                pane.wait_for_text(&format!("ok {marker} "), TURN_LIMIT)
                    .await
                    .expect("pane change"),
            ),
            None => None,
        }
    };
    let replied = async {
        let mut delivered = None;
        loop {
            let v = rpc.line().await;
            if v["id"] == id && v.get("method").is_none() {
                assert!(v.get("error").is_none(), "session/prompt: {v}");
                let ended = Instant::now();
                return (delivered.expect("the turn ended with no reply text"), ended);
            }
            let update = &v["params"]["update"];
            if delivered.is_none()
                && v["method"] == "session/update"
                && update["sessionUpdate"] == "agent_message_chunk"
                && let Some(text) = update["content"]["text"].as_str()
                && text.contains(&format!("ok {marker} "))
            {
                delivered = Some((wall_ns(), reply_times(text).expect("the reply's times")));
            }
        }
    };
    let (shown, ((delivered, (read, wrote)), ended)) = tokio::join!(shown, replied);
    let (records_after, store_after) = rpc.writes().await;
    let us = |ns: u64| ns as f64 / 1000.0;
    // `wrote` on the wall clock, as an Instant of this process.
    let wrote_at = sent + Duration::from_nanos(wrote.saturating_sub(sent_wall));
    let after_wrote = |t: Instant| t.saturating_duration_since(wrote_at).as_secs_f64() * 1e6;
    Turn {
        send: us(read.saturating_sub(sent_wall)),
        harness: us(wrote.saturating_sub(read)),
        store: us(store_after - store_before),
        records: (records_after - records_before) as f64,
        deliver: us(delivered.saturating_sub(wrote)),
        render: shown.map(|(_, change)| after_wrote(change)),
        turn: ended.duration_since(sent).as_secs_f64() * 1e6,
        shown: shown.map(|(_, change)| change.duration_since(sent).as_secs_f64() * 1e6),
    }
}

fn quantile(values: &mut [f64], q: f64) -> f64 {
    values.sort_by(f64::total_cmp);
    if values.is_empty() {
        return f64::NAN;
    }
    values[((values.len() as f64 - 1.0) * q).round() as usize]
}

/// (stage, its samples), in the table's order.
fn stages(samples: &[Turn]) -> Vec<(&'static str, Vec<f64>)> {
    let pick = |f: fn(&Turn) -> Option<f64>| samples.iter().filter_map(f).collect::<Vec<_>>();
    vec![
        ("send", pick(|t| Some(t.send))),
        ("harness", pick(|t| Some(t.harness))),
        ("store", pick(|t| Some(t.store))),
        ("deliver", pick(|t| Some(t.deliver))),
        ("render", pick(|t| t.render)),
        ("turn", pick(|t| Some(t.turn))),
        ("shown", pick(|t| t.shown)),
    ]
}

fn table(args: &Args, samples: &[Turn]) -> String {
    let mut records: Vec<f64> = samples.iter().map(|t| t.records).collect();
    let mut out = format!(
        "### acpmux turn overhead ({} turns after {} warm-up, stand-in model answers at once)\n\n\
         | stage | median ms | p95 ms |\n|---|---:|---:|\n",
        samples.len(),
        args.warmup
    );
    for (name, mut values) in stages(samples) {
        if values.is_empty() {
            continue;
        }
        let (p50, p95) = (quantile(&mut values, 0.5), quantile(&mut values, 0.95));
        out += &format!("| {name} | {:.3} | {:.3} |\n", p50 / 1000.0, p95 / 1000.0);
    }
    out += &format!(
        "\nRecords written per turn: median {}. `store` is part of `send` and `deliver`; \
         `turn` and `shown` run from the send.\n",
        quantile(&mut records, 0.5)
    );
    out
}

/// One row per stage: `{metric, unit, p50, p95, n, samples}` (µs), for cmux-bench.
fn rows(samples: &[Turn]) -> Value {
    let rows: Vec<Value> = stages(samples)
        .into_iter()
        .filter(|(_, v)| !v.is_empty())
        .map(|(name, mut values)| {
            let raw = values.clone();
            json!({"metric": name, "unit": "us", "n": values.len(),
                "p50": quantile(&mut values, 0.5), "p95": quantile(&mut values, 0.95),
                "samples": raw})
        })
        .collect();
    let mut env: HashMap<&str, String> = HashMap::new();
    env.insert("os", std::env::consts::OS.into());
    json!({"bench": "agent_turn", "rows": rows, "env": env})
}
