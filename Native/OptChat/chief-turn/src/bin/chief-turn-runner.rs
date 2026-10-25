//! One Cloud Chief turn in its VM (`apps/api/src/chief-brain-cc/turn.ts` starts
//! it with `backend/chief-cc/image/start.sh`; it replaced `run.mjs`).
//!
//! Runs as root: reads `/run/chief/<run>.in` (the Worker wrote it with exec
//! stdin, mode 600), starts a fresh `claude -p` as the unprivileged `chief`
//! user (stream-json, partial messages), and sends the model stream as events
//! (text and thinking deltas, tool calls, one generation per model message;
//! `chief_turn::cloud`) to the Worker in batches, then the result. The result
//! also goes to `/run/chief/<run>.out`, which the Worker reads when a post is
//! lost. The per-turn token never reaches the `chief` user: it stays in this
//! process and in the root-only input file, which is removed at start.
//!
//! It also serves the Chief's network tool (`chief-net`, GET/PUT /net) and its
//! sandbox VMs and own tools (`chief-vm`, `chief-tools`, POST /vm) on
//! 127.0.0.1:4018, the one local port besides the model forward that the
//! agent's table (`net.ts`) leaves open.
//!
//! Test seams (never set in the image): `CHIEF_RUN_DIR`, `CHIEF_HOME`,
//! `CHIEF_PORT`, and `CHIEF_CLAUDE` (run that program with Claude Code's
//! arguments directly, without `runuser`).

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Receiver, RecvTimeoutError, Sender, channel};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use chief_turn::cloud::{Exit, Note, TurnStream, tail_chars};
use serde_json::{Value, json};

const BATCH: Duration = Duration::from_millis(60);
const BATCH_MAX: usize = 200;
const POST_TIMEOUT: Duration = Duration::from_secs(15);
const VM_TIMEOUT: Duration = Duration::from_secs(330);
/// Waits before a stream or result post is tried again (no answer, or a 5xx).
const POST_RETRIES: [Duration; 2] = [Duration::from_secs(1), Duration::from_secs(3)];

fn main() {
    let run = std::env::args().nth(1).unwrap_or_default();
    if !valid_run(&run) {
        std::process::exit(2);
    }
    let dir = PathBuf::from(env_or("CHIEF_RUN_DIR", "/run/chief"));
    let home = PathBuf::from(env_or("CHIEF_HOME", "/home/chief"));
    let port: u16 = env_or("CHIEF_PORT", "4018").parse().unwrap_or(4018);
    let input_path = dir.join(format!("{run}.in"));
    let input: Value = match fs::read(&input_path)
        .ok()
        .and_then(|b| serde_json::from_slice(&b).ok())
    {
        Some(v) => v,
        None => std::process::exit(3),
    };
    let _ = fs::remove_file(&input_path);
    let t0 = Instant::now();
    let s = |k: &str| {
        input
            .get(k)
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned()
    };
    let worker = Worker {
        url: s("notes_url"),
        token: s("token"),
        run: run.clone(),
    };
    let model = s("model");
    let max_ms = input
        .get("max_ms")
        .and_then(Value::as_u64)
        .unwrap_or(540_000);

    // The agent user's tools for this turn (turn.ts `files`, `github_token`).
    let owner = user_ids("chief");
    if let Some(files) = input.get("files").and_then(Value::as_object) {
        for (rel, text) in files {
            if let Some(text) = text.as_str() {
                write_home(&home, owner, rel, text);
            }
        }
    }
    if let Some(t) = input
        .get("github_token")
        .and_then(Value::as_str)
        .filter(|t| !t.is_empty())
    {
        write_home(
            &home,
            owner,
            ".config/gh/hosts.yml",
            &format!(
                "github.com:\n    git_protocol: https\n    users:\n        cloud-chief:\n            oauth_token: {t}\n    oauth_token: {t}\n    user: cloud-chief\n"
            ),
        );
        write_home(
            &home,
            owner,
            ".gitconfig",
            "[user]\n\tname = Cloud Chief\n\temail = cloud-chief@manaflow.ai\n[credential \"https://github.com\"]\n\thelper =\n\thelper = !/usr/bin/gh auth git-credential\n",
        );
    }

    let notes = Notes::start(worker.clone());
    serve_local(
        port,
        worker.clone(),
        input.get("net").cloned().unwrap_or(Value::Null),
        input.get("provider").cloned().unwrap_or(Value::Null),
    );

    let system = s("system");
    let claude_args: Vec<String> = [
        "-p",
        "--output-format",
        "stream-json",
        "--verbose",
        "--include-partial-messages",
        "--dangerously-skip-permissions",
        "--model",
        &model,
        "--append-system-prompt",
        &system,
    ]
    .iter()
    .map(|a| a.to_string())
    .collect();
    let mut cmd = match std::env::var("CHIEF_CLAUDE") {
        Ok(program) if !program.is_empty() => {
            let mut c = Command::new(program);
            c.args(&claude_args).current_dir(home.join("work"));
            c
        }
        _ => {
            let mut c = Command::new("/usr/sbin/runuser");
            c.args(["-u", "chief", "--", "/usr/local/bin/claude"])
                .args(&claude_args)
                .current_dir("/home/chief/work");
            c
        }
    };
    let env: [(&str, &str); 14] = [
        ("HOME", "/home/chief"),
        (
            "PATH",
            "/home/chief/.local/bin:/opt/node/bin:/usr/local/bin:/usr/bin:/bin",
        ),
        ("AGENT_HUB_URL", "http://100.127.110.65:8790"),
        (
            "AGENT_HUB_TOKEN_FILE",
            "/home/chief/.config/agent-hub/token",
        ),
        (
            "MAC_GATE_TOKEN_FILE",
            "/home/chief/.config/cloud-chief/mac.token",
        ),
        ("LANG", "C.UTF-8"),
        ("ANTHROPIC_BASE_URL", "http://127.0.0.1:4017"),
        // The gateway authenticates the VM by its tailnet identity; Claude Code only needs a non-empty value.
        ("ANTHROPIC_AUTH_TOKEN", "subrouter"),
        ("CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"),
        ("DISABLE_TELEMETRY", "1"),
        ("DISABLE_ERROR_REPORTING", "1"),
        ("DISABLE_AUTOUPDATER", "1"),
        ("IS_SANDBOX", "1"),
        ("CHIEF_TURN_RUNNER", "rust"),
    ];
    cmd.env_clear()
        .envs(env)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if std::env::var_os("CHIEF_HOME").is_some() {
        // Tests: the fake Claude Code runs as this user, with this home.
        cmd.env("HOME", &home);
    }
    // Its own process group, so the time limit stops Claude Code and everything it started, not only runuser.
    cmd.process_group(0);

    let mut stream = TurnStream::new();
    let timed_out = Arc::new(AtomicBool::new(false));
    let (code, signal, stderr) = match cmd.spawn() {
        Err(e) => (Some(127), None, format!("spawn: {e}")),
        Ok(mut child) => {
            let pgid = child.id() as i32;
            let prompt = s("prompt");
            let mut stdin = child.stdin.take().expect("piped stdin");
            thread::spawn(move || {
                let _ = stdin.write_all(prompt.as_bytes());
            });
            let stderr_tail = Arc::new(Mutex::new(String::new()));
            let mut err_pipe = child.stderr.take().expect("piped stderr");
            let tail = stderr_tail.clone();
            let err_reader = thread::spawn(move || {
                let mut buf = [0u8; 4096];
                while let Ok(n) = err_pipe.read(&mut buf) {
                    if n == 0 {
                        break;
                    }
                    let mut t = tail.lock().unwrap();
                    t.push_str(&String::from_utf8_lossy(&buf[..n]));
                    let keep = tail_chars(&t, 2000).to_owned();
                    *t = keep;
                }
            });
            let stdout = child.stdout.take().expect("piped stdout");
            // The time limit, and the group kill 3 s after runuser exits (a process Claude Code
            // left behind may hold its output open).
            let (exited_tx, exited_rx) = channel::<Option<std::process::ExitStatus>>();
            let deadline = t0 + Duration::from_millis(max_ms);
            let limit_hit = timed_out.clone();
            let waiter = thread::spawn(move || {
                let (status_tx, status_rx) = channel();
                thread::spawn(move || {
                    let _ = status_tx.send(child.wait().ok());
                });
                let status = match status_rx
                    .recv_timeout(deadline.saturating_duration_since(Instant::now()))
                {
                    Ok(s) => s,
                    Err(_) => {
                        limit_hit.store(true, Ordering::SeqCst);
                        kill_group(pgid);
                        status_rx.recv().ok().flatten()
                    }
                };
                let _ = exited_tx.send(status);
                thread::sleep(Duration::from_secs(3));
                kill_group(pgid);
            });
            for line in BufReader::new(stdout).split(b'\n') {
                let Ok(line) = line else { break };
                let Ok(v) = serde_json::from_slice::<Value>(&line) else {
                    continue;
                };
                for n in stream.line(&v, t0.elapsed().as_millis() as u64) {
                    notes.note(n);
                }
            }
            let status = exited_rx.recv().ok().flatten();
            drop(waiter);
            let _ = err_reader.join();
            let stderr = stderr_tail.lock().unwrap().clone();
            (
                status.and_then(|s| s.code()),
                status.and_then(|s| s.signal()),
                stderr,
            )
        }
    };
    let out = stream.finish(Exit {
        run: &run,
        model: &model,
        code,
        timed_out: timed_out.load(Ordering::SeqCst),
        signal,
        stderr: &stderr,
        total_ms: t0.elapsed().as_millis() as u64,
    });
    // The live events first, then the result file (the Worker may end the turn as soon as it reads it), then the result.
    notes.flush();
    let tmp = dir.join(format!("{run}.out.tmp"));
    let written = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)
        .and_then(|mut f| f.write_all(out.to_string().as_bytes()));
    if written.is_ok() {
        let _ = fs::rename(&tmp, dir.join(format!("{run}.out")));
    }
    let _ = worker.post_retrying(&json!({"run": run, "result": out}));
    std::process::exit(0);
}

fn env_or(k: &str, default: &str) -> String {
    std::env::var(k)
        .ok()
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| default.to_owned())
}

/// `run_` and 1 to 15 digits.
fn valid_run(run: &str) -> bool {
    run.strip_prefix("run_")
        .is_some_and(|d| (1..=15).contains(&d.len()) && d.bytes().all(|b| b.is_ascii_digit()))
}

fn kill_group(pgid: i32) {
    if pgid > 0 {
        // SAFETY: a plain syscall on our own child's process group.
        unsafe {
            libc::kill(-pgid, libc::SIGKILL);
        }
    }
}

/// The uid and gid of `name` in /etc/passwd.
fn user_ids(name: &str) -> Option<(u32, u32)> {
    let passwd = fs::read_to_string("/etc/passwd").ok()?;
    let line = passwd.lines().find(|l| l.split(':').next() == Some(name))?;
    let f: Vec<&str> = line.split(':').collect();
    Some((f.get(2)?.parse().ok()?, f.get(3)?.parse().ok()?))
}

fn own(path: &Path, owner: Option<(u32, u32)>) {
    if let Some((uid, gid)) = owner {
        let _ = std::os::unix::fs::chown(path, Some(uid), Some(gid));
    }
}

/// A relative path of plain segments (`[A-Za-z0-9_.-]+`, no `..`).
fn safe_rel(rel: &str) -> bool {
    !rel.is_empty()
        && rel.split('/').all(|seg| {
            !seg.is_empty()
                && seg != ".."
                && seg
                    .bytes()
                    .all(|b| b.is_ascii_alphanumeric() || b"_.-".contains(&b))
        })
}

/// One of the agent user's files under its home: owned by it, mode 600 (700
/// for its commands), its new directories 700.
fn write_home(home: &Path, owner: Option<(u32, u32)>, rel: &str, text: &str) {
    if !safe_rel(rel) {
        return;
    }
    let path = home.join(rel);
    let mut made = Vec::new();
    let mut d = path.parent();
    while let Some(dir) = d {
        if dir == home || !dir.starts_with(home) {
            break;
        }
        made.push(dir.to_path_buf());
        d = dir.parent();
    }
    for dir in made.iter().rev() {
        if !dir.exists() {
            let _ = fs::create_dir_all(dir);
            let _ = fs::set_permissions(dir, fs::Permissions::from_mode(0o700));
        }
        own(dir, owner);
    }
    let _ = fs::remove_file(&path);
    let ok = fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&path)
        .and_then(|mut f| f.write_all(text.as_bytes()));
    if ok.is_err() {
        return;
    }
    // The Chief's commands (chief-tools, tools.ts) run as commands.
    if rel.starts_with(".local/bin/") || rel.starts_with(".chief/tools/") {
        let _ = fs::set_permissions(&path, fs::Permissions::from_mode(0o700));
    }
    own(&path, owner);
}

/// The Worker's notes endpoint with this turn's token.
#[derive(Clone)]
struct Worker {
    url: String,
    token: String,
    run: String,
}

impl Worker {
    /// POST a JSON body; the status and the JSON answer (None: no answer).
    fn post(&self, body: &Value, timeout: Duration) -> Option<(u16, Option<Value>)> {
        let agent = ureq::AgentBuilder::new()
            .timeout(timeout)
            .redirects(0)
            .build();
        let res = agent
            .post(&self.url)
            .set("authorization", &format!("Bearer {}", self.token))
            .set("content-type", "application/json")
            .send_string(&body.to_string());
        let resp = match res {
            Ok(r) => r,
            Err(ureq::Error::Status(_, r)) => r,
            Err(_) => return None,
        };
        let status = resp.status();
        Some((status, resp.into_json::<Value>().ok()))
    }

    /// A stream or result post, tried again after no answer or a 5xx (a
    /// deploy, an overloaded isolate); a 4xx is final (the turn is over).
    fn post_retrying(&self, body: &Value) -> Option<(u16, Option<Value>)> {
        let mut answer = self.post(body, POST_TIMEOUT);
        for wait in POST_RETRIES {
            if answer.as_ref().is_some_and(|(s, _)| *s < 500) {
                break;
            }
            thread::sleep(wait);
            answer = self.post(body, POST_TIMEOUT);
        }
        answer
    }
}

enum NoteMsg {
    Note(Note),
    Flush(Sender<()>),
}

/// The batched event posts: a step boundary goes at once, the rest within
/// 60 ms (or at 200 events); posts go one after another, in order.
struct Notes {
    tx: Sender<NoteMsg>,
}

impl Notes {
    fn start(worker: Worker) -> Notes {
        let (tx, rx) = channel();
        thread::spawn(move || Notes::pump(&worker, &rx));
        Notes { tx }
    }

    fn note(&self, n: Note) {
        let _ = self.tx.send(NoteMsg::Note(n));
    }

    /// Sends what is queued and waits until every post so far is done.
    fn flush(&self) {
        let (done_tx, done_rx) = channel();
        if self.tx.send(NoteMsg::Flush(done_tx)).is_ok() {
            let _ = done_rx.recv();
        }
    }

    fn pump(worker: &Worker, rx: &Receiver<NoteMsg>) {
        let mut queue: Vec<Value> = Vec::new();
        let mut due: Option<Instant> = None;
        let send = |queue: &mut Vec<Value>| {
            if !queue.is_empty() {
                let events = std::mem::take(queue);
                let _ = worker.post_retrying(&json!({"run": worker.run, "events": events}));
            }
        };
        loop {
            let msg = match due {
                Some(at) => match rx.recv_timeout(at.saturating_duration_since(Instant::now())) {
                    Ok(m) => Some(m),
                    Err(RecvTimeoutError::Timeout) => None,
                    Err(RecvTimeoutError::Disconnected) => return send(&mut queue),
                },
                None => match rx.recv() {
                    Ok(m) => Some(m),
                    Err(_) => return send(&mut queue),
                },
            };
            match msg {
                None => {
                    due = None;
                    send(&mut queue);
                }
                Some(NoteMsg::Flush(done)) => {
                    due = None;
                    send(&mut queue);
                    let _ = done.send(());
                }
                Some(NoteMsg::Note(n)) => {
                    queue.push(n.event);
                    if n.now || queue.len() >= BATCH_MAX {
                        due = None;
                        send(&mut queue);
                    } else if due.is_none() {
                        due = Some(Instant::now() + BATCH);
                    }
                }
            }
        }
    }
}

/// The settings `chief-net` shows (GET /net), changed by a PUT.
struct NetState {
    net: Value,
    provider: Value,
}

/// 127.0.0.1:PORT: GET/PUT /net (`chief-net`), POST /vm (`chief-vm`, `chief-tools`).
fn serve_local(port: u16, worker: Worker, net: Value, provider: Value) {
    let listener = match TcpListener::bind(("127.0.0.1", port)) {
        Ok(l) => l,
        Err(_) => return,
    };
    let state = Arc::new(Mutex::new(NetState { net, provider }));
    // One network change at a time (the Worker keeps them in order).
    let changing = Arc::new(Mutex::new(()));
    thread::spawn(move || {
        for conn in listener.incoming().flatten() {
            let (worker, state, changing) = (worker.clone(), state.clone(), changing.clone());
            thread::spawn(move || {
                let _ = handle(conn, &worker, &state, &changing);
            });
        }
    });
}

struct Request {
    method: String,
    path: String,
    body: Option<Vec<u8>>,
}

/// One HTTP/1.1 request; the body is None when it is over `limit` bytes.
fn read_request(conn: &mut TcpStream, limit: impl Fn(&str) -> usize) -> std::io::Result<Request> {
    conn.set_read_timeout(Some(Duration::from_secs(30)))?;
    let mut reader = BufReader::new(conn.try_clone()?);
    let mut first = String::new();
    reader.read_line(&mut first)?;
    let mut parts = first.split_whitespace();
    let method = parts.next().unwrap_or("").to_owned();
    let path = parts.next().unwrap_or("").to_owned();
    let mut length = 0usize;
    let mut chunked = false;
    loop {
        let mut h = String::new();
        if reader.read_line(&mut h)? == 0 || h.trim().is_empty() {
            break;
        }
        if let Some((k, v)) = h.split_once(':') {
            let k = k.trim().to_ascii_lowercase();
            if k == "content-length" {
                length = v.trim().parse().unwrap_or(0);
            } else if k == "transfer-encoding" && v.to_ascii_lowercase().contains("chunked") {
                chunked = true;
            } else if k == "expect" && v.trim().eq_ignore_ascii_case("100-continue") {
                // curl (chief-tools) waits for this before a larger body.
                conn.write_all(b"HTTP/1.1 100 Continue\r\n\r\n")?;
            }
        }
    }
    let max = limit(&path);
    let body = if chunked {
        let mut body = Vec::new();
        loop {
            let mut size = String::new();
            reader.read_line(&mut size)?;
            let n = usize::from_str_radix(size.trim().split(';').next().unwrap_or("0"), 16)
                .unwrap_or(0);
            if n == 0 {
                let mut end = String::new();
                let _ = reader.read_line(&mut end);
                break Some(body);
            }
            if body.len() + n > max {
                break None;
            }
            let mut chunk = vec![0u8; n + 2];
            reader.read_exact(&mut chunk)?;
            body.extend_from_slice(&chunk[..n]);
        }
    } else if length > max {
        None
    } else {
        let mut body = vec![0u8; length];
        reader.read_exact(&mut body)?;
        Some(body)
    };
    Ok(Request { method, path, body })
}

fn reply(conn: &mut TcpStream, status: u16, body: &Value) -> std::io::Result<()> {
    let text = format!(
        "{}\n",
        serde_json::to_string_pretty(body).unwrap_or_else(|_| "{}".into())
    );
    let reason = match status {
        200 => "OK",
        400 => "Bad Request",
        404 => "Not Found",
        405 => "Method Not Allowed",
        413 => "Payload Too Large",
        500 => "Internal Server Error",
        502 => "Bad Gateway",
        _ => "Status",
    };
    write!(
        conn,
        "HTTP/1.1 {status} {reason}\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}",
        text.len()
    )?;
    conn.flush()
}

fn handle(
    mut conn: TcpStream,
    worker: &Worker,
    state: &Mutex<NetState>,
    changing: &Mutex<()>,
) -> std::io::Result<()> {
    let req = read_request(
        &mut conn,
        |path| if path == "/vm" { 200_000 } else { 65_536 },
    )?;
    if req.path == "/vm" {
        if req.method != "POST" {
            return reply(&mut conn, 405, &json!({"error": "POST /vm"}));
        }
        let Some(body) = req.body else {
            return reply(&mut conn, 413, &json!({"error": "the call is too large"}));
        };
        let Ok(vm) = serde_json::from_slice::<Value>(&body) else {
            return reply(&mut conn, 400, &json!({"error": "the call must be JSON"}));
        };
        return match worker.post(&json!({"run": worker.run, "vm": vm}), VM_TIMEOUT) {
            None => reply(
                &mut conn,
                502,
                &json!({"error": "the Worker did not answer"}),
            ),
            Some((status, body)) => reply(
                &mut conn,
                status,
                &body.unwrap_or_else(|| json!({"error": format!("HTTP {status}")})),
            ),
        };
    }
    if req.path != "/net" {
        return reply(
            &mut conn,
            404,
            &json!({"error": "GET or PUT /net, POST /vm"}),
        );
    }
    if req.method == "GET" {
        let s = state.lock().unwrap();
        return reply(
            &mut conn,
            200,
            &json!({"net": s.net, "provider": s.provider}),
        );
    }
    if req.method != "PUT" {
        return reply(&mut conn, 405, &json!({"error": "GET or PUT /net"}));
    }
    let Some(body) = req.body else {
        return reply(&mut conn, 413, &json!({"error": "the change is too large"}));
    };
    let Ok(patch) = serde_json::from_slice::<Value>(&body) else {
        return reply(&mut conn, 400, &json!({"error": "the change must be JSON"}));
    };
    let _one = changing.lock().unwrap();
    let (status, body) = change_net(worker, state, patch);
    reply(&mut conn, status, &body)
}

/// A `chief-net` change: the Worker checks and keeps it and answers the
/// script, which root applies here at once.
fn change_net(worker: &Worker, state: &Mutex<NetState>, patch: Value) -> (u16, Value) {
    let answer = worker.post(&json!({"run": worker.run, "net": patch}), POST_TIMEOUT);
    let (status, body) = match &answer {
        Some((s, b)) => (Some(*s), b.clone()),
        None => (None, None),
    };
    let ok = status.is_some_and(|s| (200..300).contains(&s));
    let net = body
        .as_ref()
        .and_then(|b| b.get("net"))
        .filter(|n| !n.is_null())
        .cloned();
    let Some(net) = net.filter(|_| ok) else {
        let error = body
            .as_ref()
            .and_then(|b| b.get("error"))
            .and_then(Value::as_str)
            .map(str::to_owned)
            .unwrap_or_else(|| {
                format!(
                    "the change was not saved ({})",
                    status
                        .map(|s| s.to_string())
                        .unwrap_or_else(|| "no answer".into())
                )
            });
        return (
            if status == Some(400) { 400 } else { 502 },
            json!({"error": error}),
        );
    };
    let script = body
        .as_ref()
        .and_then(|b| b.get("script"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_owned();
    let (applied, err) = apply_net(&script);
    if !applied {
        return (
            500,
            json!({"error": format!("saved for the next turns, but not applied now: {err}"), "net": net}),
        );
    }
    let mut s = state.lock().unwrap();
    s.net = net.clone();
    let mut out = json!({"net": net, "provider": s.provider});
    if !err.is_empty() {
        out["warnings"] = json!(err);
    }
    (200, out)
}

/// Runs the Worker's network script as root (`bash -s`); applied when it
/// exits 0 and printed "net ok". The end of its stderr either way.
fn apply_net(script: &str) -> (bool, String) {
    let child = Command::new("/bin/bash")
        .arg("-s")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn();
    let Ok(mut child) = child else {
        return (false, "bash did not start".into());
    };
    let mut stdin = child.stdin.take().expect("piped stdin");
    let script = script.to_owned();
    let writer = thread::spawn(move || {
        let _ = stdin.write_all(script.as_bytes());
    });
    let out = child.wait_with_output();
    let _ = writer.join();
    match out {
        Err(e) => (false, e.to_string()),
        Ok(o) => {
            let err = String::from_utf8_lossy(&o.stderr);
            let err = tail_chars(&err, 1000).trim().to_owned();
            (
                o.status.success() && String::from_utf8_lossy(&o.stdout).contains("net ok"),
                err,
            )
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn run_ids() {
        assert!(valid_run("run_1"));
        assert!(valid_run("run_123456789012345"));
        assert!(!valid_run("run_1234567890123456"));
        assert!(!valid_run("run_"));
        assert!(!valid_run("run_1a"));
        assert!(!valid_run("../run_1"));
    }

    #[test]
    fn relative_paths() {
        assert!(safe_rel(".local/bin/hub"));
        assert!(safe_rel(".claude/skills/x/SKILL.md"));
        assert!(!safe_rel("../etc/passwd"));
        assert!(!safe_rel("a//b"));
        assert!(!safe_rel("/abs"));
        assert!(!safe_rel("a b"));
        assert!(!safe_rel(""));
    }
}
