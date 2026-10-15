//! Codex's background terminals as the hub's background processes
//! (`hub/processes.rs`, docs/background-processes.md).
//!
//! The cmux-codex-acp translator shows a `commandExecution` item as a tool
//! call and drops its `processId`. This watches the same app-server lines:
//! an exec item with a process id that is still open when its turn
//! completes, or whose item completes while it runs (unified exec handing
//! back a session id), is a background terminal. It is reported the way
//! Claude Code's shells are, as a `background_task_update` session update
//! (`toolCallId` the item, `taskId` the process id), so the hub's registry
//! takes it unchanged. Its end is the item's later completion, or the
//! answer to a kill's `thread/backgroundTerminals/terminate`, which this
//! sends under its own request ids. The app-server's exit is the hub's
//! (`processes_lost`).
//!
//! Not built: `thread/backgroundTerminals/list` at session load (the hub
//! rebuilds its table from the session log) and output.

use cmux_codex_acp::Out;
use serde_json::{Value, json};

/// The app-server method that stops a background terminal, and the method
/// the hub sends the bridge for it (`{threadId, processId}`).
pub const TERMINATE: &str = "thread/backgroundTerminals/terminate";

/// The prefix of this bridge's own request ids to the app-server; the
/// translator's are numbers.
const ID_PREFIX: &str = "acpmux-terminate-";

/// One exec item with a process.
struct Exec {
    thread: String,
    item: String,
    process: String,
    command: String,
}

#[derive(Default)]
pub(super) struct Background {
    /// Exec items started with a process and not completed, in order.
    open: Vec<Exec>,
    /// Those reported running and not ended.
    running: Vec<Exec>,
    /// Terminate requests sent: our id, the hub's id, the thread and process.
    asked: Vec<(String, Value, String, String)>,
    next: u64,
}

fn text<'a>(v: &'a Value, k: &str) -> Option<&'a str> {
    v.get(k).and_then(Value::as_str).filter(|s| !s.is_empty())
}

/// A `background_task_update` for `exec` in `state`, with `extra` fields.
fn update(exec: &Exec, state: &str, extra: Value) -> Out {
    let mut u = json!({
        "sessionUpdate": "background_task_update",
        "toolCallId": exec.item,
        "taskId": exec.process,
        "command": exec.command,
        "state": state,
    });
    if let (Some(u), Some(extra)) = (u.as_object_mut(), extra.as_object()) {
        u.extend(extra.clone());
    }
    Out::Client(json!({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {"sessionId": exec.thread, "update": u},
    }))
}

impl Background {
    /// A hub request the bridge sends itself: a terminate, under an id of
    /// its own. None for any other message.
    pub(super) fn from_client(&mut self, msg: &Value) -> Option<Vec<Out>> {
        if msg.get("method").and_then(Value::as_str) != Some(TERMINATE) {
            return None;
        }
        let client = msg.get("id")?.clone();
        let params = msg.get("params").cloned().unwrap_or(Value::Null);
        self.next += 1;
        let id = format!("{ID_PREFIX}{}", self.next);
        let thread = text(&params, "threadId").unwrap_or("").to_owned();
        let process = text(&params, "processId").unwrap_or("").to_owned();
        self.asked.push((id.clone(), client, thread, process));
        let line = json!({"jsonrpc": "2.0", "id": id, "method": TERMINATE, "params": params});
        Some(vec![Out::Server(line)])
    }

    /// The answer to one of our terminates, for the hub, after the process's
    /// end. None for any other line.
    pub(super) fn response(&mut self, raw: &Value) -> Option<Vec<Out>> {
        if raw.get("method").is_some() {
            return None;
        }
        let id = raw.get("id").and_then(Value::as_str).filter(|id| id.starts_with(ID_PREFIX))?;
        let at = self.asked.iter().position(|a| a.0 == id)?;
        let (_, client, thread, process) = self.asked.remove(at);
        let mut out = Vec::new();
        if let Some(error) = raw.get("error") {
            out.push(Out::Client(json!({"jsonrpc": "2.0", "id": client, "error": error})));
            return Some(out);
        }
        let result = raw.get("result").cloned().unwrap_or(Value::Null);
        let i = self.running.iter().position(|e| e.thread == thread && e.process == process);
        if let Some(exec) = i.map(|i| self.running.remove(i)) {
            let terminated = result.get("terminated").and_then(Value::as_bool) == Some(true);
            out.push(if terminated {
                update(&exec, "stopped", json!({}))
            } else {
                update(&exec, "completed", json!({"reason": "Codex no longer had this process"}))
            });
        }
        out.push(Out::Client(json!({"jsonrpc": "2.0", "id": client, "result": result})));
        Some(out)
    }

    /// The background updates one app-server line makes, which go out
    /// before what the translator made of it (a turn's end after its
    /// processes).
    pub(super) fn observe(&mut self, raw: &Value) -> Vec<Out> {
        let p = raw.get("params").unwrap_or(&Value::Null);
        let thread = text(p, "threadId").unwrap_or("");
        match raw.get("method").and_then(Value::as_str) {
            Some("item/started") => {
                if let Some(exec) = exec_of(thread, p.get("item")) {
                    self.open.push(exec);
                }
                Vec::new()
            }
            Some("item/completed") => self.completed(thread, p.get("item")),
            Some("turn/completed") => {
                let (left, open) = std::mem::take(&mut self.open)
                    .into_iter()
                    .partition::<Vec<_>, _>(|e| e.thread == thread);
                self.open = open;
                left.into_iter().map(|exec| self.announce(exec)).collect()
            }
            _ => Vec::new(),
        }
    }

    fn completed(&mut self, thread: &str, item: Option<&Value>) -> Vec<Out> {
        let Some(item) = item.filter(|i| text(i, "type") == Some("commandExecution")) else {
            return Vec::new();
        };
        let Some(id) = text(item, "id") else { return Vec::new() };
        let still_running = text(item, "status") == Some("inProgress");
        if let Some(i) = self.running.iter().position(|e| e.thread == thread && e.item == id) {
            if still_running {
                return Vec::new();
            }
            let exec = self.running.remove(i);
            let state =
                if text(item, "status") == Some("completed") { "completed" } else { "failed" };
            return vec![update(&exec, state, json!({"exitCode": item.get("exitCode")}))];
        }
        let open = self.open.iter().position(|e| e.thread == thread && e.item == id);
        let exec = match open {
            Some(i) => Some(self.open.remove(i)),
            None => exec_of(thread, Some(item)),
        };
        match exec {
            Some(exec) if still_running => vec![self.announce(exec)],
            _ => Vec::new(),
        }
    }

    /// `exec` runs in the background now.
    fn announce(&mut self, exec: Exec) -> Out {
        let out = update(&exec, "running", json!({"origin": "background"}));
        self.running.push(exec);
        out
    }

    /// The app-server is gone, and its processes with it (the hub marks
    /// them lost): each terminate still waiting is answered with `why`.
    pub(super) fn closed(&mut self, why: &str) -> Vec<Out> {
        let asked = std::mem::take(&mut self.asked);
        *self = Background { next: self.next, ..Background::default() };
        let message = format!("codex app-server stopped: {why}");
        asked
            .into_iter()
            .map(|(_, client, _, _)| {
                let error = json!({"code": -32603, "message": message});
                Out::Client(json!({"jsonrpc": "2.0", "id": client, "error": error}))
            })
            .collect()
    }
}

/// An exec item that names its process.
fn exec_of(thread: &str, item: Option<&Value>) -> Option<Exec> {
    let item = item.filter(|i| text(i, "type") == Some("commandExecution"))?;
    Some(Exec {
        thread: thread.to_owned(),
        item: text(item, "id")?.to_owned(),
        process: text(item, "processId")?.to_owned(),
        command: text(item, "command").unwrap_or("").to_owned(),
    })
}
