//! Codex's background terminals as the hub's background processes
//! (`hub/processes.rs`, docs/background-processes.md).
//!
//! The cmux-codex-acp translator shows a `commandExecution` item as a tool
//! call and drops its `processId`. This watches the same app-server lines:
//! an exec item with a process id that is still open when its turn
//! completes (not interrupted), or whose item completes while it runs (unified exec handing
//! back a session id), is a background terminal. It is reported the way
//! Claude Code's shells are, as a `background_task_update` session update
//! (`toolCallId` the item, `taskId` the process id), so the hub's registry
//! takes it unchanged. Its end is the item's later completion, or the
//! answer to a kill's `thread/backgroundTerminals/terminate`, which this
//! sends under its own request ids; an item end while a terminate waits is
//! the kill's. `terminated: false` refuses the kill. The app-server's exit is the hub's
//! (`processes_lost`).
//!
//! Codex does not always send that later completion: a terminal it dropped (its thread unloaded or
//! closed, or the process gone unseen) stayed `running` here, so the chat read `commandsRunning` and
//! `indicator: working` for hours with no shell left under Codex (2026-11-27:
//! three ready Codex chats whose turns ended 07:02Z to 14:48Z, each with only `codex-code-mode-host`
//! under it, kept a held VM from draining). So at each turn's start and end, and when the thread's
//! status changes, a thread with terminals running asks `thread/backgroundTerminals/list`, and each
//! one that was running when it asked and is not listed ends (`completed`, [`GONE`]); a closed or
//! unloaded thread (`thread/closed`, status `notLoaded`) ends all of its own at once. An error
//! answer (an older Codex) or a list with more pages changes nothing.
//!
//! Not built: the list at session load (the hub rebuilds its table from the session log) and
//! output.

use cmux_codex_acp::Out;
use cmux_json::JsonGet as _;
use serde_json::{Value, json};

/// The app-server method that stops a background terminal, and the method
/// the hub sends the bridge for it (`{threadId, processId}`).
pub const TERMINATE: &str = "thread/backgroundTerminals/terminate";

/// A terminate's answer when Codex had no such process.
const GONE: &str = "Codex no longer had this background terminal";

/// The prefix of this bridge's own request ids to the app-server; the
/// translator's are numbers.
const ID_PREFIX: &str = "acpmux-terminate-";

/// The app-server method that lists a thread's background terminals.
const LIST: &str = "thread/backgroundTerminals/list";

/// The prefix of this bridge's own list request ids.
const LIST_PREFIX: &str = "acpmux-bg-list-";

/// The most terminals one list asks for: more pages than one changes nothing.
const LIST_LIMIT: u64 = 1000;

/// Why a terminal ended when its thread closed.
const CLOSED: &str = "Codex closed this thread and its background terminals";

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
    /// Terminate requests waiting for their answer.
    asked: Vec<Asked>,
    /// List requests waiting for their answer.
    listing: Vec<Listing>,
    next: u64,
}

/// A list sent and not answered yet.
struct Listing {
    id: String,
    thread: String,
    /// The processes running on `thread` when it was sent: only these may end by its answer (one
    /// announced after it was sent may not be in it yet).
    processes: Vec<String>,
}

/// A terminate sent and not answered yet.
struct Asked {
    /// Our request id, and the hub's.
    id: String,
    client: Value,
    thread: String,
    process: String,
    /// Its item completed before the answer: it ended as asked.
    ended: bool,
}

/// A JSON-RPC error answer to the hub's request `client`.
fn error(client: Value, message: &str) -> Out {
    let error = json!({"code": -32603, "message": message});
    Out::Client(json!({"jsonrpc": "2.0", "id": client, "error": error}))
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
    pub(super) fn request(&mut self, msg: &Value) -> Option<Vec<Out>> {
        if msg.get("method").and_then(Value::as_str) != Some(TERMINATE) {
            return None;
        }
        let client = msg.get("id")?.clone();
        let params = msg.get("params").cloned().unwrap_or(Value::Null);
        self.next += 1;
        let id = format!("{ID_PREFIX}{}", self.next);
        let thread = params.get_nonempty_str("threadId").unwrap_or("").to_owned();
        let process = params.get_nonempty_str("processId").unwrap_or("").to_owned();
        self.asked.push(Asked { id: id.clone(), client, thread, process, ended: false });
        let line = json!({"jsonrpc": "2.0", "id": id, "method": TERMINATE, "params": params});
        Some(vec![Out::Server(line)])
    }

    /// The answer to one of our terminates, for the hub, after the process's
    /// end. None for any other line.
    pub(super) fn response(&mut self, raw: &Value) -> Option<Vec<Out>> {
        if raw.get("method").is_some() {
            return None;
        }
        let id = raw.get("id").and_then(Value::as_str)?;
        if id.starts_with(LIST_PREFIX) {
            let at = self.listing.iter().position(|l| l.id == id)?;
            let listing = self.listing.remove(at);
            return Some(self.listed(listing, raw));
        }
        let id = Some(id).filter(|id| id.starts_with(ID_PREFIX))?;
        let at = self.asked.iter().position(|a| a.id == id)?;
        let Asked { client, thread, process, ended, .. } = self.asked.remove(at);
        if let Some(error) = raw.get("error") {
            return Some(vec![Out::Client(
                json!({"jsonrpc": "2.0", "id": client, "error": error}),
            )]);
        }
        let result = raw.get("result").cloned().unwrap_or(Value::Null);
        let terminated = result.get("terminated").and_then(Value::as_bool) == Some(true);
        let i = self.running.iter().position(|e| e.thread == thread && e.process == process);
        let exec = i.map(|i| self.running.remove(i));
        let answer = Out::Client(json!({"jsonrpc": "2.0", "id": client, "result": result}));
        if ended {
            return Some(vec![answer]);
        }
        Some(match (exec, terminated) {
            (Some(exec), true) => vec![update(&exec, "stopped", json!({})), answer],
            (None, true) => vec![answer],
            // Codex has no such process: it ended unseen, and the caller
            // hears that nothing was stopped.
            (Some(exec), false) => {
                vec![update(&exec, "completed", json!({"reason": GONE})), error(client, GONE)]
            }
            (None, false) => vec![error(client, GONE)],
        })
    }

    /// The background updates one app-server line makes, which go out
    /// before what the translator made of it (a turn's end after its
    /// processes).
    pub(super) fn observe(&mut self, raw: &Value) -> Vec<Out> {
        let p = raw.get("params").unwrap_or(&Value::Null);
        let thread = p.get_nonempty_str("threadId").unwrap_or("");
        match raw.get("method").and_then(Value::as_str) {
            Some("turn/started") => self.list(thread).into_iter().collect(),
            Some("thread/closed") => self.end_thread(thread),
            Some("thread/status/changed") => {
                match p.pointer("/status/type").and_then(Value::as_str) {
                    Some("notLoaded") => self.end_thread(thread),
                    _ => self.list(thread).into_iter().collect(),
                }
            }
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
                // An interrupted or failed turn left its commands open
                // without handing them to the background.
                let mut out = Vec::new();
                if p.pointer("/turn/status").and_then(Value::as_str) == Some("completed") {
                    out.extend(left.into_iter().map(|exec| self.announce(exec)));
                }
                out.extend(self.list(thread));
                out
            }
            _ => Vec::new(),
        }
    }

    fn completed(&mut self, thread: &str, item: Option<&Value>) -> Vec<Out> {
        let Some(item) = item.filter(|i| i.get_nonempty_str("type") == Some("commandExecution"))
        else {
            return Vec::new();
        };
        let Some(id) = item.get_nonempty_str("id") else { return Vec::new() };
        let still_running = item.get_nonempty_str("status") == Some("inProgress");
        if let Some(i) = self.running.iter().position(|e| e.thread == thread && e.item == id) {
            if still_running {
                return Vec::new();
            }
            let exec = self.running.remove(i);
            // A terminate waits for its answer: this end is the kill's.
            let asked = self
                .asked
                .iter_mut()
                .find(|a| a.thread == exec.thread && a.process == exec.process);
            if let Some(asked) = asked {
                asked.ended = true;
                return vec![update(&exec, "stopped", json!({}))];
            }
            let state = if item.get_nonempty_str("status") == Some("completed") {
                "completed"
            } else {
                "failed"
            };
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

    /// A `thread/backgroundTerminals/list` for `thread`, when it has terminals running and no list
    /// of its own in flight.
    fn list(&mut self, thread: &str) -> Option<Out> {
        if thread.is_empty() || self.listing.iter().any(|l| l.thread == thread) {
            return None;
        }
        let processes: Vec<String> =
            self.running.iter().filter(|e| e.thread == thread).map(|e| e.process.clone()).collect();
        if processes.is_empty() {
            return None;
        }
        self.next += 1;
        let id = format!("{LIST_PREFIX}{}", self.next);
        self.listing.push(Listing { id: id.clone(), thread: thread.to_owned(), processes });
        let params = json!({"threadId": thread, "limit": LIST_LIMIT});
        Some(Out::Server(json!({"jsonrpc": "2.0", "id": id, "method": LIST, "params": params})))
    }

    /// A list's answer: each terminal running when it was asked, still running here, with no
    /// terminate in flight, and not listed, ended unseen.
    fn listed(&mut self, listing: Listing, raw: &Value) -> Vec<Out> {
        let Some(result) = raw.get("result") else { return Vec::new() };
        if result.get("nextCursor").is_some_and(|c| !c.is_null()) {
            return Vec::new();
        }
        let Some(data) = result.get("data").and_then(Value::as_array) else { return Vec::new() };
        let live: Vec<&str> = data.iter().filter_map(|t| t.get_nonempty_str("processId")).collect();
        let thread = listing.thread;
        let gone = |e: &Exec| {
            e.thread == thread
                && listing.processes.contains(&e.process)
                && !live.contains(&e.process.as_str())
        };
        let asked = &self.asked;
        let (ended, running) =
            std::mem::take(&mut self.running).into_iter().partition::<Vec<_>, _>(|e| {
                gone(e) && !asked.iter().any(|a| a.thread == e.thread && a.process == e.process)
            });
        self.running = running;
        ended.iter().map(|e| update(e, "completed", json!({"reason": GONE}))).collect()
    }

    /// `thread` closed or unloaded: its terminals went with it.
    fn end_thread(&mut self, thread: &str) -> Vec<Out> {
        if thread.is_empty() {
            return Vec::new();
        }
        let (ended, running) = std::mem::take(&mut self.running)
            .into_iter()
            .partition::<Vec<_>, _>(|e| e.thread == thread);
        self.running = running;
        self.open.retain(|e| e.thread != thread);
        self.listing.retain(|l| l.thread != thread);
        ended.iter().map(|e| update(e, "completed", json!({"reason": CLOSED}))).collect()
    }

    /// The app-server is gone, and its processes with it (the hub marks
    /// them lost): each terminate still waiting is answered with `why`.
    pub(super) fn closed(&mut self, why: &str) -> Vec<Out> {
        let asked = std::mem::take(&mut self.asked);
        *self = Background { next: self.next, ..Background::default() };
        let message = format!("codex app-server stopped: {why}");
        asked.into_iter().map(|a| error(a.client, &message)).collect()
    }
}

/// An exec item that names its process.
fn exec_of(thread: &str, item: Option<&Value>) -> Option<Exec> {
    let item = item.filter(|i| i.get_nonempty_str("type") == Some("commandExecution"))?;
    Some(Exec {
        thread: thread.to_owned(),
        item: item.get_nonempty_str("id")?.to_owned(),
        process: item.get_nonempty_str("processId")?.to_owned(),
        command: item.get_nonempty_str("command").unwrap_or("").to_owned(),
    })
}
