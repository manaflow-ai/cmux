//! A tool call on the machine that owns the index, through cmux's own remote
//! transport: one `cmux remote rpc ROUTE` child per server, kept for its
//! life, speaking `WorkspaceRequest` lines (cmux-remote-protocol `rpc.rs`).
//! Per call: spawn this server on the owner (`agent-memory mcp --local`),
//! write the one JSON-RPC line with EOF, wait for its exit, read its stdout.
//!
//! The route is any `cmux remote` route (`ssh://HOST` uses the user's own
//! ssh config and keys; enrolled, relay, Iroh and WireGuard routes need no
//! sshd at all), so no host needs a hand-edited `authorized_keys` entry.
//! Nothing new is allowed on the owner: the caller already holds the
//! owner's full workspace authority over that route, and the only process
//! this spawns is the fixed memory server.

use std::collections::BTreeMap;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::mpsc::{Receiver, RecvTimeoutError};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use base64::Engine;
use serde_json::{Value, json};

/// The whole relayed call, every step and the one retry: Codex stops
/// waiting for an MCP tool after 60s (ACP's `McpServer` cannot raise its
/// `tool_timeout_sec`), so this leaves room for the local fallback.
const CALL_BUDGET: Duration = Duration::from_secs(40);
/// The wait for the owner's server to finish: it may rebuild a stale index
/// first. Capped by what is left of the budget.
const PROCESS_STEP_TIMEOUT: Duration = Duration::from_secs(35);
/// The process deadline the owner's daemon enforces.
const PROCESS_TIMEOUT_MS: u64 = 30_000;
/// Every other request's wait (open, spawn, write, read events).
const STEP_TIMEOUT: Duration = Duration::from_secs(15);
/// Route options that keep a dead owner from holding a call: `cmux remote
/// rpc` otherwise waits 90s to connect and reconnects forever. Given before
/// `ownerArgs`, so the user's own values win.
const CONNECT_ARGS: [&str; 4] = [
    "--connect-timeout-seconds",
    "15",
    "--reconnect-attempts",
    "1",
];
/// How long a failed owner is answered for locally without trying again.
const DOWN_FOR: Duration = Duration::from_secs(60);
/// The workspace a call runs in: any directory exists there; the server
/// works on its own files.
const WORKSPACE_ROOT: &str = "/tmp";

/// Finds `optchat-chief` on the owner the way this crate ships: the shell's
/// PATH, then the cmux apps' bundles, then `~/.local/bin`.
const FIND_SERVER: &str = r#"for c in "${OPTCHAT_CHIEF:-}" "$(command -v optchat-chief 2>/dev/null)" "/Applications/cmux NEXT.app/Contents/Resources/bin/optchat-chief" "/Applications/cmux NIGHTLY.app/Contents/Resources/bin/optchat-chief" "/Applications/cmux.app/Contents/Resources/bin/optchat-chief" "$HOME/.local/bin/optchat-chief"; do
  if [ -n "$c" ] && [ -x "$c" ]; then exec "$c" agent-memory mcp --local; fi
done
echo "agent memory: no optchat-chief on the owner (set agents.memory.ownerCommand)" >&2
exit 127"#;

/// The owner's argv: `ownerCommand` + `agent-memory mcp --local`, else the
/// lookup above.
pub fn owner_argv(owner_command: &[String]) -> Vec<String> {
    if owner_command.is_empty() {
        vec!["/bin/sh".into(), "-c".into(), FIND_SERVER.into()]
    } else {
        let mut argv = owner_command.to_vec();
        argv.extend(["agent-memory", "mcp", "--local"].map(String::from));
        argv
    }
}

/// The local cmux CLI: `cmux` next to this executable (the app's
/// `Contents/Resources/bin`), else `cmux` or `cmux-tui` (the name a Linux
/// install and a remote sidecar use) on PATH.
pub fn cmux_cli() -> PathBuf {
    let sibling = std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(|d| d.join("cmux")))
        .filter(|p| p.is_file());
    let on_path = || {
        let path = std::env::var_os("PATH")?;
        ["cmux", "cmux-tui"].iter().find_map(|name| {
            std::env::split_paths(&path)
                .map(|dir| dir.join(name))
                .find(|p| p.is_file())
        })
    };
    sibling
        .or_else(on_path)
        .unwrap_or_else(|| PathBuf::from("cmux"))
}

pub struct Relay {
    pub route: String,
    pub args: Vec<String>,
    pub argv: Vec<String>,
    pub cmux: PathBuf,
    /// How long one call may take in all (see [`CALL_BUDGET`]).
    pub budget: Duration,
    conn: Option<Conn>,
    /// Until when the owner counts as down, and why.
    down: Option<(Instant, String)>,
    /// Whether the last failed call may have run on the owner.
    ran: bool,
}

/// A failed call, and whether it may be retried on a new connection: only
/// when a kept connection broke before the owner's server was started, so
/// a retry never runs a call (a remember) twice. `ran`: the call was sent
/// to the owner's server, which may have run it.
struct Failure {
    message: String,
    retry: bool,
    ran: bool,
}

impl Failure {
    fn fatal(message: String) -> Failure {
        Failure {
            message,
            retry: false,
            ran: false,
        }
    }
}

struct Conn {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    stderr: Arc<Mutex<String>>,
    /// Closes when the stderr reader has read the child's last line.
    stderr_done: Receiver<()>,
    workspace: Value,
    /// When the current call's budget runs out, and the budget.
    deadline: Instant,
    budget: Duration,
}

impl Drop for Conn {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
    }
}

impl Relay {
    pub fn new(route: String, args: Vec<String>, argv: Vec<String>, cmux: PathBuf) -> Relay {
        Relay {
            route,
            args,
            argv,
            cmux,
            budget: CALL_BUDGET,
            conn: None,
            down: None,
            ran: false,
        }
    }

    /// Whether the last failed call may have run on the owner: its message
    /// reached the owner's server before the failure.
    pub fn may_have_run(&self) -> bool {
        self.ran
    }

    /// The owner's answer to one JSON-RPC message. A kept connection that
    /// broke before the owner's server started (an ssh carrier that dropped
    /// while idle) is reopened once. After a failure the owner counts as
    /// down for a minute, so calls in that time fail at once.
    pub fn call(&mut self, message: &Value) -> Result<Value, String> {
        self.ran = false;
        if let Some((until, why)) = &self.down {
            if Instant::now() < *until {
                return Err(format!("{why} (not retried for {}s)", DOWN_FOR.as_secs()));
            }
            self.down = None;
        }
        let deadline = Instant::now() + self.budget;
        let result = match self.call_once(message, deadline) {
            Ok(answer) => Ok(answer),
            Err(first) if first.retry => self.call_once(message, deadline).map_err(|second| {
                self.ran = second.ran;
                format!("{} (first try: {})", second.message, first.message)
            }),
            Err(first) => {
                self.ran = first.ran;
                Err(first.message)
            }
        };
        if let Err(why) = &result {
            self.down = Some((Instant::now() + DOWN_FOR, why.clone()));
        }
        result
    }

    fn call_once(&mut self, message: &Value, deadline: Instant) -> Result<Value, Failure> {
        let kept = self.conn.is_some();
        if !kept {
            self.conn = Some(self.connect(deadline).map_err(Failure::fatal)?);
        }
        if let Some(conn) = self.conn.as_mut() {
            conn.deadline = deadline;
        }
        match self.run(message) {
            Err(failure) => {
                self.conn = None;
                // A fresh connection that failed is not retried either.
                Err(Failure {
                    retry: failure.retry && kept,
                    ..failure
                })
            }
            ok => ok,
        }
    }

    fn connect(&self, deadline: Instant) -> Result<Conn, String> {
        let mut child = Command::new(&self.cmux)
            .args(["remote", "rpc", &self.route])
            .args(CONNECT_ARGS)
            .args(&self.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(|e| format!("starting {} remote rpc: {e}", self.cmux.display()))?;
        let stdin = child.stdin.take().ok_or("no stdin")?;
        let stdout = child.stdout.take().ok_or("no stdout")?;
        let stderr_pipe = child.stderr.take().ok_or("no stderr")?;
        let (tx, lines) = std::sync::mpsc::channel();
        std::thread::spawn(move || {
            for line in BufReader::new(stdout).lines() {
                let Ok(line) = line else { break };
                if tx.send(line).is_err() {
                    break;
                }
            }
        });
        let stderr = Arc::new(Mutex::new(String::new()));
        let kept = stderr.clone();
        let (stderr_tx, stderr_done) = std::sync::mpsc::channel::<()>();
        std::thread::spawn(move || {
            let _done = stderr_tx;
            for line in BufReader::new(stderr_pipe).lines() {
                let Ok(line) = line else { break };
                if let Ok(mut text) = kept.lock() {
                    text.push_str(&line);
                    text.push('\n');
                    // The last few lines are enough to say why it failed.
                    if text.len() > 4096 {
                        let cut = text.len() - 2048;
                        let cut = (cut..text.len())
                            .find(|i| text.is_char_boundary(*i))
                            .unwrap_or(0);
                        text.drain(..cut);
                    }
                }
            }
        });
        let mut conn = Conn {
            child,
            stdin,
            lines,
            stderr,
            stderr_done,
            workspace: Value::Null,
            deadline,
            budget: self.budget,
        };
        let opened = conn.request(
            &json!({"type": "open-workspace", "root": WORKSPACE_ROOT}),
            STEP_TIMEOUT,
        )?;
        conn.workspace = expect(&opened, "workspace", "id")?;
        Ok(conn)
    }

    fn run(&mut self, message: &Value) -> Result<Value, Failure> {
        let argv = self.argv.clone();
        let conn = self
            .conn
            .as_mut()
            .ok_or_else(|| Failure::fatal("not connected".into()))?;
        let spawn = json!({
            "type": "spawn-process",
            "workspace": conn.workspace,
            "argv": argv,
            "cwd": null,
            "env": BTreeMap::<String, String>::new(),
            "io": {"type": "pipes", "stdin": true},
            "lifetime": "workspace",
            "timeout_ms": PROCESS_TIMEOUT_MS,
        });
        // A request that may not have reached the owner: safe to retry.
        let started = conn
            .request(&spawn, STEP_TIMEOUT)
            .map_err(|message| Failure {
                message,
                retry: true,
                ran: false,
            })?;
        let process = expect(&started, "process-started", "process").map_err(Failure::fatal)?;
        // From here the owner may have run the call: no retry.
        conn.finish(&process, message).map_err(|message| Failure {
            message,
            retry: false,
            ran: true,
        })
    }
}

impl Conn {
    /// Writes the message to the started server and reads its answer.
    fn finish(&mut self, process: &Value, message: &Value) -> Result<Value, String> {
        let line = format!("{message}\n");
        self.request(
            &json!({
                "type": "write-process",
                "process": process,
                "write_id": 1,
                "data": base64::engine::general_purpose::STANDARD.encode(line.as_bytes()),
                "eof": true,
            }),
            STEP_TIMEOUT,
        )?;
        let exit = self.request(
            &json!({"type": "wait-process", "process": process}),
            PROCESS_STEP_TIMEOUT,
        )?;
        expect(&exit, "process-exit", "process")?;
        let (stdout, stderr) = self.output(process)?;
        let id = message.get("id");
        stdout
            .lines()
            .filter_map(|l| serde_json::from_str::<Value>(l).ok())
            .find(|answer| answer.get("id") == id)
            .ok_or_else(|| {
                let code = exit.get("code").cloned().unwrap_or(Value::Null);
                format!(
                    "the owner's memory server gave no answer (exit {code}): {}",
                    last_line(&stderr)
                )
            })
    }

    /// One request line, one response line.
    fn request(&mut self, request: &Value, timeout: Duration) -> Result<Value, String> {
        writeln!(self.stdin, "{request}")
            .and_then(|()| self.stdin.flush())
            .map_err(|e| {
                // A child that exits before it reads the request breaks the
                // pipe; its stderr still says why.
                self.end();
                format!("cmux remote rpc: {e}{}", self.why())
            })?;
        let left = self.deadline.saturating_duration_since(Instant::now());
        match self.lines.recv_timeout(timeout.min(left)) {
            Ok(line) => serde_json::from_str(&line)
                .map_err(|e| format!("cmux remote rpc answered {line:?}: {e}")),
            Err(RecvTimeoutError::Timeout) if left <= timeout => Err(format!(
                "the owner did not answer within the call's {}s budget",
                self.budget.as_secs()
            )),
            Err(RecvTimeoutError::Timeout) => Err(format!(
                "cmux remote rpc took longer than {}s",
                timeout.as_secs()
            )),
            Err(RecvTimeoutError::Disconnected) => {
                self.end();
                Err(format!("cmux remote rpc ended{}", self.why()))
            }
        }
    }

    /// Ends the child and lets the stderr reader catch its reason. Kill
    /// bounds a child that lingers; the timeout bounds a grandchild that
    /// keeps stderr open.
    fn end(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = self.stderr_done.recv_timeout(Duration::from_secs(1));
    }

    fn why(&self) -> String {
        let text = self.stderr.lock().map(|t| t.clone()).unwrap_or_default();
        let last = last_line(&text);
        if last.is_empty() {
            String::new()
        } else {
            format!(": {last}")
        }
    }

    /// The process's whole stdout and stderr, every page of its events.
    fn output(&mut self, process: &Value) -> Result<(String, String), String> {
        let mut after = 0u64;
        let (mut stdout, mut stderr) = (Vec::new(), Vec::new());
        loop {
            let page = self.request(
                &json!({
                    "type": "read-process-events",
                    "process": process,
                    "after_sequence": after,
                    "limit": 256,
                }),
                STEP_TIMEOUT,
            )?;
            let events = expect(&page, "process-events", "events")?;
            for event in events.as_array().into_iter().flatten() {
                let inner = &event["event"];
                let data = inner
                    .get("data")
                    .and_then(Value::as_str)
                    .and_then(|d| base64::engine::general_purpose::STANDARD.decode(d).ok());
                match (inner.get("type").and_then(Value::as_str), data) {
                    (Some("stdout"), Some(bytes)) => stdout.extend(bytes),
                    (Some("stderr"), Some(bytes)) => stderr.extend(bytes),
                    _ => {}
                }
            }
            match page.get("next_cursor").and_then(Value::as_u64) {
                Some(next) if next > after => after = next,
                _ => break,
            }
        }
        Ok((
            String::from_utf8_lossy(&stdout).into_owned(),
            String::from_utf8_lossy(&stderr).into_owned(),
        ))
    }
}

/// `response[field]` when the response is of `kind`, else why not.
fn expect(response: &Value, kind: &str, field: &str) -> Result<Value, String> {
    if response.get("type").and_then(Value::as_str) == Some(kind)
        && let Some(value) = response.get(field)
    {
        return Ok(value.clone());
    }
    Err(format!("cmux remote rpc: expected {kind}, got {response}"))
}

fn last_line(text: &str) -> &str {
    text.lines()
        .rev()
        .find(|l| !l.trim().is_empty())
        .unwrap_or("")
        .trim()
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Writes an executable fake. Another test's child forked while the
    /// write was open holds the file until it execs, and running the fake
    /// then fails with ETXTBSY: wait (by trying) until no child holds it.
    fn install(path: &std::path::Path, script: &str) {
        use std::os::unix::fs::PermissionsExt;
        std::fs::write(path, script).unwrap();
        std::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755)).unwrap();
        for _ in 0..10_000 {
            match Command::new(path)
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
            {
                Ok(mut child) => {
                    let _ = child.wait();
                    return;
                }
                Err(e) if e.raw_os_error() == Some(libc::ETXTBSY) => std::thread::yield_now(),
                Err(e) => panic!("{}: {e}", path.display()),
            }
        }
        panic!("{} stayed busy", path.display());
    }

    #[test]
    fn owner_argv_appends_the_server_verb() {
        assert_eq!(owner_argv(&[])[..2], ["/bin/sh", "-c"]);
        assert_eq!(
            owner_argv(&["/opt/optchat-chief".into()]),
            ["/opt/optchat-chief", "agent-memory", "mcp", "--local"]
        );
    }

    #[test]
    fn expect_names_the_mismatch() {
        let ok = json!({"type": "workspace", "id": "w1", "root": "/tmp"});
        assert_eq!(expect(&ok, "workspace", "id").unwrap(), json!("w1"));
        assert!(expect(&ok, "process-started", "process").is_err());
    }

    /// A fake `cmux` that answers every WorkspaceRequest the way the real
    /// one does, and runs the "owner" command locally.
    #[test]
    fn relays_one_call_through_a_fake_cmux() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("cmux");
        install(&fake, FAKE_CMUX);
        let mut relay = Relay::new(
            "ssh://owner".into(),
            vec![],
            vec!["owner".into()],
            fake.clone(),
        );
        let message = json!({"jsonrpc": "2.0", "id": 7, "method": "tools/call"});
        let answer = relay.call(&message).unwrap();
        assert_eq!(answer["id"], json!(7));
        assert_eq!(answer["result"]["echo"], json!("tools/call"));
        // The connection is kept for the next call.
        assert_eq!(relay.call(&message).unwrap()["id"], json!(7));
    }

    #[test]
    fn a_dead_route_is_an_error_with_its_reason() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("cmux");
        install(
            &fake,
            "#!/bin/sh\necho 'ssh: connect to host owner: refused' >&2\nexit 1\n",
        );
        let mut relay = Relay::new("ssh://owner".into(), vec![], vec![], fake);
        let error = relay.call(&json!({"id": 1})).unwrap_err();
        assert!(error.contains("refused"), "{error}");
    }

    /// A carrier that drops after the owner's server started: the call is
    /// not repeated (a remember would be saved twice), and the owner then
    /// counts as down without another connection attempt.
    #[test]
    fn a_call_is_never_rerun_after_its_server_started() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("cmux");
        let count = dir.path().join("spawns");
        let script = FAKE_CMUX.replace(
            "        a = {\"type\": \"process-started\", \"process\": \"p\", \"pid\": 1}\n",
            &format!(
                "        open({count:?}, \"a\").write(\"x\")\n        if len(open({count:?}).read()) == 2: print(json.dumps({{\"type\": \"process-started\", \"process\": \"p\", \"pid\": 1}}), flush=True); sys.exit(1)\n        a = {{\"type\": \"process-started\", \"process\": \"p\", \"pid\": 1}}\n",
                count = count.display().to_string()
            ),
        );
        assert_ne!(script, FAKE_CMUX);
        install(&fake, &script);
        let mut relay = Relay::new("ssh://owner".into(), vec![], vec!["owner".into()], fake);
        let message = json!({"jsonrpc": "2.0", "id": 3, "method": "tools/call"});
        relay.call(&message).unwrap();
        assert!(relay.call(&message).is_err());
        assert_eq!(std::fs::read_to_string(&count).unwrap(), "xx");
        let error = relay.call(&message).unwrap_err();
        assert!(error.contains("not retried"), "{error}");
        assert_eq!(std::fs::read_to_string(&count).unwrap(), "xx");
    }

    /// An owner whose server never exits: the call gives up within the
    /// relay's budget (Codex stops waiting for a tool after 60s, and ACP
    /// cannot raise that), and says the call may have run there.
    #[test]
    fn a_hung_owner_is_given_up_within_the_call_budget() {
        let dir = tempfile::tempdir().unwrap();
        let fake = dir.path().join("cmux");
        let script = FAKE_CMUX.replace(
            "    elif t == \"wait-process\":\n",
            "    elif t == \"wait-process\":\n        import time; time.sleep(30)\n",
        );
        assert_ne!(script, FAKE_CMUX);
        install(&fake, &script);
        let mut relay = Relay::new("ssh://owner".into(), vec![], vec!["owner".into()], fake);
        relay.budget = Duration::from_secs(2);
        let started = Instant::now();
        let message = json!({"jsonrpc": "2.0", "id": 4, "method": "tools/call"});
        let error = relay.call(&message).unwrap_err();
        assert!(
            started.elapsed() < Duration::from_secs(6),
            "{:?}",
            started.elapsed()
        );
        assert!(error.contains("2s"), "{error}");
        assert!(relay.may_have_run());
        // A failure before the server started never ran the call.
        let error = relay.call(&message).unwrap_err();
        assert!(error.contains("not retried"), "{error}");
        assert!(!relay.may_have_run());
    }

    /// The budget covers every step: a CLI or tool caller waits at most
    /// this long before the local fallback answers.
    #[test]
    fn the_call_budget_leaves_room_under_codexs_tool_timeout() {
        const CODEX_TOOL_TIMEOUT: Duration = Duration::from_secs(60);
        assert!(CALL_BUDGET + Duration::from_secs(15) <= CODEX_TOOL_TIMEOUT);
        assert!(Duration::from_millis(PROCESS_TIMEOUT_MS) < CALL_BUDGET);
    }

    /// Python stands in for `cmux remote rpc`: the owner's server is an echo
    /// that answers the JSON-RPC line on stdin with its method.
    const FAKE_CMUX: &str = r#"#!/usr/bin/env python3
import base64, json, sys
out = {}
for line in sys.stdin:
    r = json.loads(line)
    t = r["type"]
    if t == "open-workspace":
        a = {"type": "workspace", "id": "w", "root": r["root"]}
    elif t == "spawn-process":
        a = {"type": "process-started", "process": "p", "pid": 1}
    elif t == "write-process":
        msg = json.loads(base64.b64decode(r["data"]))
        out["p"] = json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"echo": msg["method"]}}) + "\n"
        a = {"type": "process-write-accepted", "process": "p", "write_id": r["write_id"]}
    elif t == "wait-process":
        a = {"type": "process-exit", "process": "p", "code": 0, "signal": None}
    elif t == "read-process-events":
        data = base64.b64encode(out["p"].encode()).decode()
        events = [] if r["after_sequence"] else [{"sequence": 1, "event": {"type": "stdout", "process": "p", "sequence": 1, "data": data}}]
        a = {"type": "process-events", "process": "p", "range": {"first_available": 1, "last_produced": 1, "exited": True}, "events": events}
    print(json.dumps(a), flush=True)
"#;
}
