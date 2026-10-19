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
use std::time::Duration;

use base64::Engine;
use serde_json::{Value, json};

/// One request's wait: the owner's server may rebuild a stale index first.
const STEP_TIMEOUT: Duration = Duration::from_secs(110);
/// The process deadline the owner's daemon enforces.
const PROCESS_TIMEOUT_MS: u64 = 105_000;
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
    conn: Option<Conn>,
}

struct Conn {
    child: Child,
    stdin: ChildStdin,
    lines: Receiver<String>,
    stderr: Arc<Mutex<String>>,
    workspace: Value,
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
            conn: None,
        }
    }

    /// The owner's answer to one JSON-RPC message. A broken connection is
    /// reopened once (an ssh carrier that dropped while idle).
    pub fn call(&mut self, message: &Value) -> Result<Value, String> {
        match self.call_once(message) {
            Ok(answer) => Ok(answer),
            Err(first) => {
                self.conn = None;
                self.call_once(message)
                    .map_err(|second| format!("{second} (first try: {first})"))
            }
        }
    }

    fn call_once(&mut self, message: &Value) -> Result<Value, String> {
        if self.conn.is_none() {
            self.conn = Some(self.connect()?);
        }
        let result = self.run(message);
        if result.is_err() {
            self.conn = None;
        }
        result
    }

    fn connect(&self) -> Result<Conn, String> {
        let mut child = Command::new(&self.cmux)
            .args(["remote", "rpc", &self.route])
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
        std::thread::spawn(move || {
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
            workspace: Value::Null,
        };
        let opened = conn.request(&json!({"type": "open-workspace", "root": WORKSPACE_ROOT}))?;
        conn.workspace = expect(&opened, "workspace", "id")?;
        Ok(conn)
    }

    fn run(&mut self, message: &Value) -> Result<Value, String> {
        let argv = self.argv.clone();
        let conn = self.conn.as_mut().ok_or("not connected")?;
        let started = conn.request(&json!({
            "type": "spawn-process",
            "workspace": conn.workspace,
            "argv": argv,
            "cwd": null,
            "env": BTreeMap::<String, String>::new(),
            "io": {"type": "pipes", "stdin": true},
            "lifetime": "workspace",
            "timeout_ms": PROCESS_TIMEOUT_MS,
        }))?;
        let process = expect(&started, "process-started", "process")?;
        let line = format!("{message}\n");
        conn.request(&json!({
            "type": "write-process",
            "process": process,
            "write_id": 1,
            "data": base64::engine::general_purpose::STANDARD.encode(line.as_bytes()),
            "eof": true,
        }))?;
        let exit = conn.request(&json!({"type": "wait-process", "process": process}))?;
        expect(&exit, "process-exit", "process")?;
        let (stdout, stderr) = conn.output(&process)?;
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
}

impl Conn {
    /// One request line, one response line.
    fn request(&mut self, request: &Value) -> Result<Value, String> {
        writeln!(self.stdin, "{request}")
            .and_then(|()| self.stdin.flush())
            .map_err(|e| format!("cmux remote rpc: {e}{}", self.why()))?;
        match self.lines.recv_timeout(STEP_TIMEOUT) {
            Ok(line) => serde_json::from_str(&line)
                .map_err(|e| format!("cmux remote rpc answered {line:?}: {e}")),
            Err(RecvTimeoutError::Timeout) => Err(format!(
                "cmux remote rpc took longer than {}s",
                STEP_TIMEOUT.as_secs()
            )),
            Err(RecvTimeoutError::Disconnected) => {
                // Let the stderr reader catch the reason.
                let _ = self.child.wait();
                std::thread::sleep(Duration::from_millis(50));
                Err(format!("cmux remote rpc ended{}", self.why()))
            }
        }
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
            let page = self.request(&json!({
                "type": "read-process-events",
                "process": process,
                "after_sequence": after,
                "limit": 256,
            }))?;
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
        std::fs::write(&fake, FAKE_CMUX).unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
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
        std::fs::write(
            &fake,
            "#!/bin/sh\necho 'ssh: connect to host owner: refused' >&2\nexit 1\n",
        )
        .unwrap();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&fake, std::fs::Permissions::from_mode(0o755)).unwrap();
        let mut relay = Relay::new("ssh://owner".into(), vec![], vec![], fake);
        let error = relay.call(&json!({"id": 1})).unwrap_err();
        assert!(error.contains("refused"), "{error}");
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
