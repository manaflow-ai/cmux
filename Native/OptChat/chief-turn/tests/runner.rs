//! The real `chief-turn-runner` binary against a fake Worker (a local HTTP
//! server that records the notes posts) and a fake Claude Code (a shell
//! script that prints stream-json), through the runner's test seams.

#![cfg(feature = "runner")]

use std::fs;
use std::io::{BufRead, BufReader, Read, Write};
use std::net::TcpListener;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};

use serde_json::{Value, json};

/// A fake Worker: answers every POST with `answer(body)` and keeps the bodies.
fn worker(answer: fn(&Value) -> (u16, Value)) -> (String, Arc<Mutex<Vec<Value>>>) {
    let l = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/v1/chief-cc/a/c/notes", l.local_addr().unwrap());
    let seen = Arc::new(Mutex::new(Vec::new()));
    let keep = seen.clone();
    thread::spawn(move || {
        for conn in l.incoming().flatten() {
            let keep = keep.clone();
            thread::spawn(move || {
                let mut r = BufReader::new(conn.try_clone().unwrap());
                let mut len = 0usize;
                let mut auth = String::new();
                let mut line = String::new();
                r.read_line(&mut line).unwrap();
                loop {
                    let mut h = String::new();
                    if r.read_line(&mut h).unwrap() == 0 || h.trim().is_empty() {
                        break;
                    }
                    let lower = h.to_ascii_lowercase();
                    if let Some(v) = lower.strip_prefix("content-length:") {
                        len = v.trim().parse().unwrap();
                    }
                    if lower.starts_with("authorization:") {
                        auth = h.trim().to_owned();
                    }
                }
                let mut body = vec![0u8; len];
                r.read_exact(&mut body).unwrap();
                let v: Value = serde_json::from_slice(&body).unwrap();
                assert_eq!(auth.to_ascii_lowercase(), "authorization: bearer tok-1");
                let (status, out) = answer(&v);
                keep.lock().unwrap().push(v);
                let text = out.to_string();
                let mut c = conn;
                write!(c, "HTTP/1.1 {status} X\r\ncontent-type: application/json\r\ncontent-length: {}\r\nconnection: close\r\n\r\n{text}", text.len()).unwrap();
            });
        }
    });
    (url, seen)
}

fn free_port() -> u16 {
    TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}

struct Turn {
    root: PathBuf,
    run_dir: PathBuf,
    home: PathBuf,
}

fn setup(name: &str, claude_script: &str) -> Turn {
    let root = std::env::temp_dir().join(format!("chief-turn-{name}-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let run_dir = root.join("run");
    let home = root.join("home");
    fs::create_dir_all(&run_dir).unwrap();
    fs::create_dir_all(home.join("work")).unwrap();
    let claude = root.join("claude");
    fs::write(&claude, claude_script).unwrap();
    fs::set_permissions(&claude, fs::Permissions::from_mode(0o755)).unwrap();
    Turn {
        root,
        run_dir,
        home,
    }
}

fn run(t: &Turn, run: &str, input: &Value, port: u16) -> std::process::Output {
    fs::write(t.run_dir.join(format!("{run}.in")), input.to_string()).unwrap();
    Command::new(env!("CARGO_BIN_EXE_chief-turn-runner"))
        .arg(run)
        .env("CHIEF_RUN_DIR", &t.run_dir)
        .env("CHIEF_HOME", &t.home)
        .env("CHIEF_PORT", port.to_string())
        .env("CHIEF_CLAUDE", t.root.join("claude"))
        .output()
        .unwrap()
}

fn events(posts: &[Value]) -> Vec<Value> {
    posts
        .iter()
        .filter_map(|p| p.get("events"))
        .flat_map(|e| e.as_array().unwrap().clone())
        .collect()
}

fn mode(p: &Path) -> u32 {
    fs::metadata(p).unwrap().permissions().mode() & 0o777
}

#[test]
fn a_turn_streams_its_events_then_its_result() {
    let (url, posts) = worker(|body| {
        if body.get("net").is_some() {
            (
                200,
                json!({"net": {"internet": "off"}, "script": "echo net ok"}),
            )
        } else {
            (200, json!({}))
        }
    });
    let port = free_port();
    // The fake Claude Code: keeps its arguments, prompt and environment, uses chief-net (GET and PUT
    // /net) like the agent would, then prints a two-message turn and its result.
    let script = format!(
        r#"#!/bin/sh
printf '%s\n' "$@" > "$HOME/args"
cat > "$HOME/prompt"
env > "$HOME/env"
curl -s http://127.0.0.1:{port}/net > "$HOME/net-get.json"
curl -s -X PUT --data '{{"internet":"off"}}' http://127.0.0.1:{port}/net > "$HOME/net-put.json"
curl -s -o /dev/null -w '%{{http_code}}' http://127.0.0.1:{port}/other > "$HOME/other-code"
e() {{ printf '{{"type":"stream_event","event":%s}}\n' "$1"; }}
echo '{{"type":"system","subtype":"init"}}'
e '{{"type":"message_start","message":{{"id":"m1"}}}}'
e '{{"type":"content_block_start","index":0,"content_block":{{"type":"tool_use","id":"toolu_1","name":"Bash"}}}}'
e '{{"type":"content_block_delta","index":0,"delta":{{"type":"input_json_delta","partial_json":"{{\"command\":\"ls\"}}"}}}}'
e '{{"type":"content_block_stop","index":0}}'
e '{{"type":"message_stop"}}'
echo 'not json'
echo '{{"type":"user","message":{{"content":[{{"type":"tool_result","tool_use_id":"toolu_1"}}]}}}}'
e '{{"type":"message_start","message":{{"id":"m2"}}}}'
e '{{"type":"content_block_start","index":0,"content_block":{{"type":"text"}}}}'
e '{{"type":"content_block_delta","index":0,"delta":{{"type":"text_delta","text":"Hello"}}}}'
e '{{"type":"content_block_stop","index":0}}'
e '{{"type":"message_stop"}}'
echo '{{"type":"result","subtype":"success","is_error":false,"result":"Hello","usage":{{"input_tokens":3,"output_tokens":4}}}}'
"#
    );
    let t = setup("ok", &script);
    let input = json!({
        "notes_url": url, "token": "tok-1", "prompt": "the view\nand new messages", "system": "SYS",
        "model": "claude-opus-4", "max_ms": 60_000, "net": {"internet": "on"}, "provider": {"vm": "vm-1"},
        "files": {".local/bin/hub": "#!/bin/sh\n", ".config/agent-hub/token": "t", "../escape": "x"},
        "github_token": "ghp_x"
    });
    let out = run(&t, "run_42", &input, port);
    assert!(out.status.success(), "{out:?}");

    // The input (it holds the token) is gone; the result file is the result.
    assert!(!t.run_dir.join("run_42.in").exists());
    let result: Value =
        serde_json::from_slice(&fs::read(t.run_dir.join("run_42.out")).unwrap()).unwrap();
    assert_eq!(result["status"], "done", "{result}");
    assert_eq!(result["reply"], "Hello");
    assert_eq!(result["model"], "claude-opus-4");
    assert_eq!(
        result["usage"],
        json!({"input":3,"output":4,"cache_read":0,"cache_write":0})
    );
    assert_eq!(result["last_gen"], 1);
    assert!(result["first_token_ms"].is_u64());
    assert_eq!(mode(&t.run_dir.join("run_42.out")), 0o600);

    // Claude Code got the prompt on stdin and the turn's arguments; the token is not in its environment.
    assert_eq!(
        fs::read_to_string(t.home.join("prompt")).unwrap(),
        "the view\nand new messages"
    );
    let args = fs::read_to_string(t.home.join("args")).unwrap();
    assert_eq!(
        args.lines().collect::<Vec<_>>(),
        [
            "-p",
            "--output-format",
            "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--dangerously-skip-permissions",
            "--model",
            "claude-opus-4",
            "--append-system-prompt",
            "SYS"
        ]
    );
    let env = fs::read_to_string(t.home.join("env")).unwrap();
    assert!(env.contains("ANTHROPIC_BASE_URL=http://127.0.0.1:4017"));
    assert!(!env.contains("tok-1"));

    // The agent user's files: mode 600, its commands 700, nothing outside its home.
    assert_eq!(mode(&t.home.join(".config/agent-hub/token")), 0o600);
    assert_eq!(mode(&t.home.join(".local/bin/hub")), 0o700);
    assert_eq!(mode(&t.home.join(".config")), 0o700);
    assert!(!t.root.join("escape").exists());
    assert!(
        fs::read_to_string(t.home.join(".config/gh/hosts.yml"))
            .unwrap()
            .contains("oauth_token: ghp_x")
    );

    // chief-net through the runner.
    let got: Value =
        serde_json::from_str(&fs::read_to_string(t.home.join("net-get.json")).unwrap()).unwrap();
    assert_eq!(
        got,
        json!({"net": {"internet": "on"}, "provider": {"vm": "vm-1"}})
    );
    let put: Value =
        serde_json::from_str(&fs::read_to_string(t.home.join("net-put.json")).unwrap()).unwrap();
    assert_eq!(
        put,
        json!({"net": {"internet": "off"}, "provider": {"vm": "vm-1"}})
    );
    assert_eq!(
        fs::read_to_string(t.home.join("other-code")).unwrap(),
        "404"
    );

    // The Worker got the events in order, then the result last.
    let posts = posts.lock().unwrap().clone();
    assert!(posts.iter().all(|p| p["run"] == "run_42"));
    assert_eq!(
        posts.iter().find_map(|p| p.get("net")),
        Some(&json!({"internet": "off"}))
    );
    let types: Vec<String> = events(&posts)
        .iter()
        .map(|e| format!("{}:{}", e["gen"], e["type"].as_str().unwrap()))
        .collect();
    assert_eq!(
        types,
        [
            "0:tool",
            "0:done",
            "0:tool_done",
            "1:text_start",
            "1:text_delta",
            "1:text_done",
            "1:done"
        ]
    );
    assert_eq!(posts.last().unwrap()["result"], result);
    let _ = fs::remove_dir_all(&t.root);
}

#[test]
fn the_time_limit_stops_claude_code_and_everything_it_started() {
    let (url, posts) = worker(|_| (200, json!({})));
    // Leaves a grandchild that holds stdout open, then hangs.
    let t = setup("limit", "#!/bin/sh\n(sleep 120 &)\nsleep 120\n");
    let started = Instant::now();
    let input = json!({"notes_url": url, "token": "tok-1", "prompt": "", "system": "", "model": "m", "max_ms": 1500});
    let out = run(&t, "run_7", &input, free_port());
    assert!(out.status.success());
    assert!(
        started.elapsed() < Duration::from_secs(20),
        "{:?}",
        started.elapsed()
    );
    let result: Value =
        serde_json::from_slice(&fs::read(t.run_dir.join("run_7.out")).unwrap()).unwrap();
    assert_eq!(result["status"], "failed");
    assert_eq!(result["reason"], "timeout");
    assert!(
        result["error"]
            .as_str()
            .unwrap()
            .starts_with("claude exited on signal 9"),
        "{result}"
    );
    assert_eq!(posts.lock().unwrap().last().unwrap()["result"], result);
    let _ = fs::remove_dir_all(&t.root);
}

/// Result posts the fake Worker refused (503) before it took one.
static REFUSED: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

#[test]
fn a_turn_the_time_limit_stops_posts_what_it_wrote_through_a_failing_worker() {
    // The Worker answers 503 to the first two result posts (a deploy, an overloaded isolate).
    let (url, posts) = worker(|body| {
        if body.get("result").is_some()
            && REFUSED.fetch_add(1, std::sync::atomic::Ordering::SeqCst) < 2
        {
            (503, json!({}))
        } else {
            (200, json!({}))
        }
    });
    let script = r#"#!/bin/sh
e() { printf '{"type":"stream_event","event":%s}\n' "$1"; }
e '{"type":"message_start","message":{"id":"m1"}}'
e '{"type":"content_block_start","index":0,"content_block":{"type":"text"}}'
e '{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Half way: the fix is pushed"}}'
sleep 120
"#;
    let t = setup("partial", script);
    let input = json!({"notes_url": url, "token": "tok-1", "prompt": "", "system": "", "model": "m", "max_ms": 1500});
    let out = run(&t, "run_8", &input, free_port());
    assert!(out.status.success());
    let result: Value =
        serde_json::from_slice(&fs::read(t.run_dir.join("run_8.out")).unwrap()).unwrap();
    assert_eq!(result["status"], "partial", "{result}");
    assert_eq!(result["reason"], "timeout");
    assert_eq!(result["reply"], "Half way: the fix is pushed");
    let posts = posts.lock().unwrap().clone();
    let results: Vec<&Value> = posts.iter().filter_map(|p| p.get("result")).collect();
    assert_eq!(results.len(), 3, "two refused, the third taken");
    assert_eq!(results[2], &result);
    let _ = fs::remove_dir_all(&t.root);
}

#[test]
fn a_bad_run_id_does_nothing() {
    let out = Command::new(env!("CARGO_BIN_EXE_chief-turn-runner"))
        .arg("../x")
        .output()
        .unwrap();
    assert_eq!(out.status.code(), Some(2));
}
