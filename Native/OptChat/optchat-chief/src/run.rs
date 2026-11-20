//! The run record of a turn (`conversation-runs-v1`): what the conversation
//! shows its participants of the Chief's work, written to the conversation
//! owner as the turn runs (`conversation-run-append`). The turn fold
//! (`fold.rs`) feeds it the same events it logs as `talk`, `tool` and `echo`,
//! so the run's steps are those entries with their full shape: a tool's
//! input, output, exit code and changed files, each reply segment, a thought
//! summary when the harness sends one. Display only: the posted reply stays
//! the authoritative answer, and a failed append never stops a turn.

use std::collections::{BTreeMap, BTreeSet};
use std::time::{Duration, Instant};

use serde_json::{Map, Value, json};

/// Most bytes of a step's text and of a tool's output (the owner's limit).
pub const MAX_TEXT: usize = 32 * 1024;
/// Most bytes of a tool's input as JSON.
pub const MAX_INPUT: usize = 16 * 1024;
/// Most bytes of one file's old and new text together kept in a step.
const MAX_FILE_TEXT: usize = 12 * 1024;
/// Most steps in one append (the owner's limit).
pub const MAX_APPEND: usize = 64;
/// Most bytes of the steps of one append: under the owner's 1 MiB with room to spare.
pub const MAX_APPEND_BYTES: usize = 768 * 1024;
/// A reply segment that keeps growing is sent at most this often.
pub const TALK_EVERY: Duration = Duration::from_secs(1);
/// Most characters of one live `step.delta` (the owner's limit).
pub const MAX_DELTA_CHARS: usize = 4096;
/// Most characters of a live "working on" line (the owner's limit).
pub const MAX_ACTIVITY_CHARS: usize = 80;

/// One append for the brain to send: the run's summary fields and the steps
/// that changed since the last append.
#[derive(Clone, Debug, PartialEq)]
pub struct RunUpdate {
    /// The turn key: the run id and its reply's client_msg_id.
    pub turn: String,
    pub run: Map<String, Value>,
    pub steps: Vec<Value>,
    /// Pictures the steps' tool calls returned: the brain uploads each as an
    /// attachment of the conversation and names it in its step.
    pub images: Vec<RunImage>,
    /// Live frames (`chief-live-v1`: `step.delta`, `run.activity`) without
    /// their conversation and run, which the brain adds; sent before the
    /// steps, so a step's last delta comes before its row.
    pub live: Vec<Value>,
}

/// One picture a tool call returned (an ACP `image` content block).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RunImage {
    pub step: String,
    pub mime_type: String,
    /// Base64, as the harness sent it.
    pub data: String,
}

/// Most pictures one tool call shows.
const MAX_STEP_IMAGES: usize = 4;

#[derive(Debug, Default)]
struct Step {
    value: Map<String, Value>,
    /// An open reply segment or thought: sent at most every [`TALK_EVERY`].
    open: bool,
    sent_at: Option<Instant>,
}

/// The steps of one turn and which changed since the last append.
#[derive(Debug, Default)]
pub struct RunSteps {
    steps: BTreeMap<String, Step>,
    /// Step ids in the order the turn did them: an append sends them so,
    /// and the owner numbers new steps in the order it receives them.
    order: Vec<String>,
    dirty: BTreeSet<String>,
    /// The thought being streamed (`thought:<n>`): a tool call or reply text ends it.
    thought: u64,
    /// Pictures not yet taken, and how many each step returned (each once).
    images: Vec<RunImage>,
    image_counts: BTreeMap<String, usize>,
    /// What the live frames sent of each talk and thought step.
    streamed: BTreeMap<String, Streamed>,
    /// The "working on" line and when that work began (ms), and whether it
    /// changed since the last live frames.
    activity: Option<(String, u64)>,
    /// The tool call the activity line names, if any: a call's later frames (its input
    /// arrived) sharpen the line but keep its start, so the elapsed time stays the call's.
    activity_tool: Option<String>,
    activity_dirty: bool,
    /// The tool calls announced and not ended, in announce order, each with its
    /// line and when it was announced (ms). Claude Code runs a message's calls in
    /// order, so a call announced while an earlier one runs waits for it: the line
    /// keeps naming the earlier one, and moves on when it ends.
    running: Vec<(String, String, u64)>,
}

/// One talk or thought step's live stream (`step.delta`): the text sent so
/// far and the next frame's `seq`. A step whose text stops extending what
/// was sent (a cut to its tail) streams no more; its row has the text.
#[derive(Debug, Default)]
struct Streamed {
    sent: String,
    seq: u64,
    ended: bool,
}

impl RunSteps {
    fn upsert(&mut self, id: &str, kind: &str) -> &mut Step {
        self.dirty.insert(id.to_owned());
        if !self.steps.contains_key(id) {
            self.order.push(id.to_owned());
        }
        let step = self.steps.entry(id.to_owned()).or_default();
        step.value.insert("id".into(), json!(id));
        step.value.insert("kind".into(), json!(kind));
        step
    }

    /// The reply segment `segment` so far (`open` while it streams).
    pub fn talk(&mut self, segment: u64, text: &str, open: bool) {
        let text = text.trim();
        if text.is_empty() {
            return;
        }
        let step = self.upsert(&format!("talk:{segment}"), "talk");
        set_text(&mut step.value, text);
        step.open = open;
        if open
            && self
                .activity
                .as_ref()
                .is_none_or(|(line, _)| line != "Writing the reply")
        {
            self.set_activity("Writing the reply".to_owned());
        }
    }

    /// A thought summary the harness streams (ACP `agent_thought_chunk`).
    pub fn thought(&mut self, chunk: &str) {
        if chunk.is_empty() {
            return;
        }
        let id = format!("thought:{}", self.thought);
        let step = self.upsert(&id, "thought");
        let mut text = step
            .value
            .get("text")
            .and_then(Value::as_str)
            .unwrap_or_default()
            .to_owned();
        text.push_str(chunk);
        set_text(&mut step.value, &text);
        step.open = true;
        if self
            .activity
            .as_ref()
            .is_none_or(|(line, _)| line != "Thinking")
        {
            self.set_activity("Thinking".to_owned());
        }
    }

    /// The run works on something new: the newest line wins.
    fn set_activity(&mut self, line: String) {
        self.activity = Some((line, epoch_ms()));
        self.activity_tool = None;
        self.activity_dirty = true;
    }

    /// The live frames since the last call (`chief-live-v1`): each talk or
    /// thought step's new text, in at most [`MAX_DELTA_CHARS`] per frame,
    /// the last one `final` when the step closed; then the "working on"
    /// line when it changed. A step that closed before any of it streamed
    /// sends nothing (its row follows at once).
    pub fn take_live(&mut self) -> Vec<Value> {
        let mut out = Vec::new();
        for id in &self.order {
            let Some(step) = self.steps.get(id) else {
                continue;
            };
            let kind = match step.value.get("kind").and_then(Value::as_str) {
                Some(kind @ ("talk" | "thought")) => kind,
                _ => continue,
            };
            let text = step
                .value
                .get("text")
                .and_then(Value::as_str)
                .unwrap_or_default();
            let fresh = !self.streamed.contains_key(id);
            if fresh && !step.open {
                continue;
            }
            let streamed = self.streamed.entry(id.clone()).or_default();
            if streamed.ended {
                continue;
            }
            if !text.starts_with(streamed.sent.as_str()) {
                streamed.ended = true;
                continue;
            }
            // An open step holds back its last character, so the frame that
            // ends it (`final`) always has text, even when nothing new came.
            let upto = if step.open {
                text.char_indices().last().map_or(0, |(at, _)| at)
            } else {
                text.len()
            };
            if upto <= streamed.sent.len() {
                continue;
            }
            let delta = &text[streamed.sent.len()..upto];
            let chunks = split_chars(delta, MAX_DELTA_CHARS);
            let count = chunks.len();
            for (index, chunk) in chunks.into_iter().enumerate() {
                let mut frame = json!({
                    "type": "step.delta",
                    "t": "step.delta",
                    "step": id,
                    "kind": kind,
                    "seq": streamed.seq,
                    "text": chunk,
                });
                if !step.open && index + 1 == count {
                    frame["final"] = json!(true);
                    streamed.ended = true;
                }
                streamed.seq += 1;
                out.push(frame);
            }
            streamed.sent = text[..upto].to_owned();
        }
        if std::mem::take(&mut self.activity_dirty)
            && let Some((line, since)) = &self.activity
        {
            let at = epoch_ms().max(*since);
            out.push(json!({"type": "run.activity", "t": "run.activity", "line": line, "since": since, "at": at}));
        }
        out
    }

    /// The turn is over: every talk and thought step still open closes, so
    /// its last live frame (`final`) goes before the run's end and the reply.
    pub fn close_all(&mut self) {
        let open: Vec<String> = self
            .steps
            .iter()
            .filter(|(_, step)| step.open)
            .map(|(id, _)| id.clone())
            .collect();
        for id in open {
            if let Some(step) = self.steps.get_mut(&id) {
                step.open = false;
            }
            self.dirty.insert(id);
        }
    }

    /// The streaming thought ended (a tool call or a reply began): the next one is a new step.
    pub fn close_thought(&mut self) {
        let id = format!("thought:{}", self.thought);
        if let Some(step) = self.steps.get_mut(&id)
            && step.open
        {
            step.open = false;
            self.dirty.insert(id);
            self.thought += 1;
        }
    }

    /// A tool call started or its input arrived (ACP `tool_call`).
    pub fn tool_call(&mut self, id: &str, name: &str, update: &Value, at: Option<u64>) {
        let doing = activity_line(name, update);
        match self.running.iter_mut().find(|(call, _, _)| call == id) {
            Some((_, line, _)) => line.clone_from(&doing),
            None => self
                .running
                .push((id.to_owned(), doing.clone(), epoch_ms())),
        }
        let holder_runs = self
            .activity_tool
            .as_ref()
            .is_some_and(|tool| self.running.iter().any(|(call, _, _)| call == tool));
        if self.activity.as_ref().is_none_or(|(old, _)| *old != doing) {
            match (&mut self.activity, self.activity_tool.as_deref()) {
                // The same call, its input known now: a sharper line, the same start.
                (Some((line, _)), Some(tool)) if tool == id => {
                    *line = doing;
                    self.activity_dirty = true;
                }
                // An earlier call still runs: this one waits for it (Leo's
                // "ToolSearch 3m 19s" was a ToolSearch queued behind a shell loop).
                _ if holder_runs => {}
                _ => {
                    self.set_activity(doing);
                    self.activity_tool = Some(id.to_owned());
                }
            }
        }
        let step = self.upsert(&step_id("tool", id), "tool");
        step.value
            .entry("status")
            .or_insert_with(|| json!("running"));
        let tool = tool_of(&mut step.value);
        tool.insert("name".into(), json!(tool_name(name)));
        if let Some(kind) = update.get("kind").and_then(Value::as_str) {
            tool.insert("kind".into(), json!(line(kind, 32)));
        }
        if let Some(title) = update
            .get("title")
            .and_then(Value::as_str)
            .filter(|t| !t.is_empty())
        {
            tool.insert("title".into(), json!(cut_head(title, 2000)));
        }
        if let Some(input) = update.get("rawInput").filter(|v| !is_empty(v)) {
            tool.insert("input".into(), capped_input(input));
        }
        if let Some(at) = at {
            tool.entry("started_at").or_insert_with(|| json!(at));
        }
        merge_locations(tool, update);
    }

    /// A tool call changed or ended (ACP `tool_call_update`).
    pub fn tool_update(
        &mut self,
        id: &str,
        name: &str,
        update: &Value,
        output: &str,
        at: Option<u64>,
    ) {
        let step = self.upsert(&step_id("tool", id), "tool");
        let status = match update.get("status").and_then(Value::as_str) {
            Some("completed") => Some("done"),
            Some("failed") => Some("failed"),
            Some("in_progress" | "pending") => Some("running"),
            _ => None,
        };
        if let Some(status) = status {
            step.value.insert("status".into(), json!(status));
        } else {
            step.value
                .entry("status")
                .or_insert_with(|| json!("running"));
        }
        let ended = matches!(status, Some("done" | "failed"));
        if ended {
            self.call_ended(id);
        }
        let step = self.upsert(&step_id("tool", id), "tool");
        let tool = tool_of(&mut step.value);
        if !name.is_empty() || !tool.contains_key("name") {
            tool.insert("name".into(), json!(tool_name(name)));
        }
        if let Some(kind) = update.get("kind").and_then(Value::as_str) {
            tool.insert("kind".into(), json!(line(kind, 32)));
        }
        if let Some(title) = update
            .get("title")
            .and_then(Value::as_str)
            .filter(|t| !t.is_empty())
        {
            tool.insert("title".into(), json!(cut_head(title, 2000)));
        }
        if let Some(input) = update.get("rawInput").filter(|v| !is_empty(v)) {
            tool.insert("input".into(), capped_input(input));
        }
        if !output.is_empty() {
            let (text, truncated) = head_and_tail(output, MAX_TEXT);
            tool.insert("output".into(), json!(text));
            if truncated {
                tool.insert("output_truncated".into(), json!(true));
            }
        }
        if let Some(code) = exit_code(update) {
            tool.insert("exit_code".into(), json!(code));
        }
        if ended && let Some(at) = at {
            tool.insert("ended_at".into(), json!(at));
        }
        merge_locations(tool, update);
        merge_diffs(tool, update);
        let step_id = step_id("tool", id);
        for (mime_type, data) in images_of(update) {
            let count = self.image_counts.entry(step_id.clone()).or_default();
            if *count >= MAX_STEP_IMAGES {
                break;
            }
            *count += 1;
            self.images.push(RunImage {
                step: step_id.clone(),
                mime_type,
                data,
            });
        }
    }

    /// Call `id` ended. When the line named it, the line moves to the earliest
    /// call still running, or to the model ("Thinking"), from now: a queued call's
    /// time waiting behind the one that ended is not its own, and the steps'
    /// starts never go back.
    fn call_ended(&mut self, id: &str) {
        self.running.retain(|(call, _, _)| call != id);
        if self.activity_tool.as_deref() != Some(id) {
            return;
        }
        match self.running.first().cloned() {
            Some((call, line, _)) => {
                self.set_activity(line);
                self.activity_tool = Some(call);
            }
            None => self.set_activity("Thinking".to_owned()),
        }
    }

    /// The pictures returned since the last call.
    pub fn take_images(&mut self) -> Vec<RunImage> {
        std::mem::take(&mut self.images)
    }

    /// The steps that changed since the last call. An open segment that was
    /// sent less than [`TALK_EVERY`] ago waits, unless `all`.
    pub fn take(&mut self, now: Instant, all: bool) -> Vec<Value> {
        let mut out = Vec::new();
        let mut held = BTreeSet::new();
        let dirty = std::mem::take(&mut self.dirty);
        for id in self.order.iter().filter(|id| dirty.contains(*id)) {
            let Some(step) = self.steps.get_mut(id) else {
                continue;
            };
            let recent = step
                .sent_at
                .is_some_and(|at| now.duration_since(at) < TALK_EVERY);
            if !all && step.open && recent {
                held.insert(id.clone());
                continue;
            }
            step.sent_at = Some(now);
            out.push(Value::Object(step.value.clone()));
        }
        self.dirty = held;
        out
    }

    pub fn has_pending(&self) -> bool {
        !self.dirty.is_empty()
    }
}

/// The owner's view of each streamed step (`chief-live-v1`): the seq it took
/// last and the text it holds. A frame the owner refused (a dropped socket, a
/// refusal) would make every later frame of that step a `seq_gap`, so the
/// step starts again at seq 0 with its whole text so far (the owner replaces
/// the step and sends its `run.live`), and streams on from there.
#[derive(Debug, Default)]
pub struct LiveStreams {
    steps: BTreeMap<(String, String), LiveStream>,
}

#[derive(Debug, Default)]
struct LiveStream {
    /// The step's text so far (its last 64 KiB).
    text: String,
    /// The next seq the owner takes.
    next: u64,
    /// The last frame did not reach the owner: start again at seq 0.
    broken: bool,
}

/// Most bytes of a step's text kept for a restart (the owner's buffer keeps as much).
const MAX_STREAM_BYTES: usize = 64 * 1024;

impl LiveStreams {
    /// Sends one live frame of `run` through `publish`, numbered as the owner
    /// expects; a step whose last frame failed starts again at seq 0 with its
    /// text so far. The first error is returned (the frame is not retried).
    pub fn send<E>(
        &mut self,
        run: &str,
        mut frame: Value,
        mut publish: impl FnMut(Value) -> Result<(), E>,
    ) -> Result<(), E> {
        let Some(step) = frame
            .get("step")
            .and_then(Value::as_str)
            .filter(|_| frame["type"] == "step.delta")
            .map(str::to_owned)
        else {
            return publish(frame);
        };
        // One turn at a time: a frame of another run drops the old streams.
        self.steps.retain(|(of, _), _| of == run);
        let key = (run.to_owned(), step);
        let stream = self.steps.entry(key.clone()).or_default();
        let piece = frame["text"].as_str().unwrap_or_default().to_owned();
        stream.text.push_str(&piece);
        if stream.text.len() > MAX_STREAM_BYTES {
            let mut cut = stream.text.len() - MAX_STREAM_BYTES;
            while !stream.text.is_char_boundary(cut) {
                cut += 1;
            }
            // Only a restart after a failure sends it again (the owner keeps its own tail).
            stream.text.drain(..cut);
        }
        let last = frame.get("final").and_then(Value::as_bool) == Some(true);
        let result = if stream.broken {
            let chunks = split_chars(&stream.text, MAX_DELTA_CHARS);
            let count = chunks.len();
            let mut result = Ok(());
            for (index, chunk) in chunks.into_iter().enumerate() {
                let mut again = frame.clone();
                again["seq"] = json!(index);
                again["text"] = json!(chunk);
                if let Some(object) = again.as_object_mut() {
                    object.remove("final");
                }
                if last && index + 1 == count {
                    again["final"] = json!(true);
                }
                if let Err(e) = publish(again) {
                    result = Err(e);
                    break;
                }
            }
            if result.is_ok() {
                stream.broken = false;
                stream.next = count as u64;
            }
            result
        } else {
            frame["seq"] = json!(stream.next);
            let result = publish(frame);
            match result {
                Ok(()) => stream.next += 1,
                Err(_) => stream.broken = true,
            }
            result
        };
        if last && result.is_ok() {
            self.steps.remove(&key);
        }
        result
    }
}

/// `text` in pieces of at most `max` characters.
fn split_chars(text: &str, max: usize) -> Vec<&str> {
    let mut out = Vec::new();
    let mut rest = text;
    while !rest.is_empty() {
        let end = rest
            .char_indices()
            .nth(max)
            .map_or(rest.len(), |(at, _)| at);
        out.push(&rest[..end]);
        rest = &rest[end..];
    }
    out
}

/// The "working on" line of a tool call: present tense, one line, at most
/// [`MAX_ACTIVITY_CHARS`] characters, e.g. `Running git log -1`,
/// `Editing notes.md`, `Reading shot.png`.
pub fn activity_line(name: &str, update: &Value) -> String {
    let title = update
        .get("title")
        .and_then(Value::as_str)
        .map(|t| t.replace('`', ""))
        .unwrap_or_default();
    let title = line(title.trim(), 200);
    let kind = update
        .get("kind")
        .and_then(Value::as_str)
        .unwrap_or_default();
    let verb = match kind {
        "read" => Some(("Reading", ["Read", "View"].as_slice())),
        "edit" => Some(("Editing", ["Edit", "Write", "MultiEdit"].as_slice())),
        "delete" => Some(("Deleting", ["Delete", "Remove"].as_slice())),
        "move" => Some(("Moving", ["Move"].as_slice())),
        "search" => Some(("Searching", ["Search", "Grep", "Glob", "Find"].as_slice())),
        "execute" => Some(("Running", ["Run", "Bash", "Execute"].as_slice())),
        "fetch" => Some(("Fetching", ["Fetch", "WebFetch"].as_slice())),
        "think" => Some(("Thinking", [].as_slice())),
        _ => None,
    };
    let input = update.get("rawInput");
    let described = input
        .and_then(|i| i.get("description"))
        .and_then(Value::as_str)
        .map(|d| line(d.trim(), 200))
        .filter(|d| !d.is_empty());
    let mcp = mcp_parts(name).or_else(|| mcp_parts(&title));
    let text = match verb {
        // A shell call that says what it does ("List cmux workspaces"): that, not the command.
        Some(("Running", _)) if described.is_some() => described.unwrap_or_default(),
        _ if mcp.is_some() => {
            let (server, tool) = mcp.unwrap_or_default();
            mcp_line(&server, &tool, input)
        }
        Some((verb, _)) if title.is_empty() => verb.to_owned(),
        Some((verb, words)) => {
            // "Edit notes.md" -> "Editing notes.md".
            let rest = words
                .iter()
                .find_map(|word| {
                    title
                        .strip_prefix(word)
                        .filter(|rest| rest.is_empty() || rest.starts_with(' '))
                })
                .unwrap_or(&title);
            format!("{verb} {}", rest.trim()).trim().to_owned()
        }
        None if !title.is_empty() => title,
        None => tool_name(name),
    };
    let text: String = text.chars().take(MAX_ACTIVITY_CHARS).collect();
    let text = text.trim_end_matches('.').trim().to_owned();
    if text.is_empty() {
        "Working".to_owned()
    } else {
        text
    }
}

/// `mcp__<server>__<tool>` (Claude Code's MCP tool names) as `(server, tool)`.
fn mcp_parts(name: &str) -> Option<(String, String)> {
    let rest = name.trim().strip_prefix("mcp__")?;
    let (server, tool) = rest.split_once("__")?;
    let tool = tool.trim();
    (!server.is_empty() && !tool.is_empty()).then(|| (server.to_owned(), tool.to_owned()))
}

/// A short string field of a tool's input, one line.
fn input_str(input: Option<&Value>, key: &str) -> Option<String> {
    input
        .and_then(|i| i.get(key))
        .and_then(Value::as_str)
        .map(|s| line(s.trim(), 60))
        .filter(|s| !s.is_empty())
}

/// The "working on" line of an MCP tool call: the Chief's own tools by what they do
/// ("Telling a31", "Starting 2 agents"), others as "Using <server>: <tool words>".
fn mcp_line(server: &str, tool: &str, input: Option<&Value>) -> String {
    if server == "optchat" {
        let line = match tool {
            "tell" => input_str(input, "id")
                .map_or("Telling an agent".to_owned(), |id| format!("Telling {id}")),
            "spawn" => match input
                .and_then(|i| i.get("tasks"))
                .and_then(Value::as_array)
                .map(Vec::len)
            {
                Some(1) => "Starting an agent".to_owned(),
                Some(n) if n > 1 => format!("Starting {n} agents"),
                _ => "Starting agents".to_owned(),
            },
            "zoom" => "Reading the chat history".to_owned(),
            "date" => "Checking a message's date".to_owned(),
            "version" => "Checking the cmux and Chief versions".to_owned(),
            "profile" => "Reading the Chief's profile".to_owned(),
            "react" => "Reacting to a message".to_owned(),
            "reply" => "Replying in a thread".to_owned(),
            "send" => "Sending a message".to_owned(),
            "transcript" => "Reading the chat as you see it".to_owned(),
            "stop" => "Ending the turn".to_owned(),
            "sleep" => "Setting a wake-up".to_owned(),
            "watch" => "Watching for a change".to_owned(),
            "remember" => "Saving a preference".to_owned(),
            "cloud_workspace" => "Starting a Cloud workspace".to_owned(),
            "control" => control_line(input),
            "peers" => "Looking up the other machines".to_owned(),
            "escalate_auth" => "Asking you to sign in".to_owned(),
            _ => String::new(),
        };
        if !line.is_empty() {
            return line;
        }
    }
    let words = tool.replace(['_', '-'], " ");
    let words = words.trim();
    let server = server.replace(['_', '-'], " ");
    match server.trim() {
        "" => format!("Using {words}"),
        server => format!("Using {server}: {words}"),
    }
}

/// The "working on" line of the Chief's `control(action, id)` call: what it does to which subagent
/// ("Checking on a31", "Answering a31's prompt"), not "Using optchat: control" (Leo 2026-10-20: that
/// line sat over the typing dots for six minutes and said nothing).
fn control_line(input: Option<&Value>) -> String {
    let id = input_str(input, "id");
    let who = id.as_deref();
    let action = input_str(input, "action").unwrap_or_default();
    match (action.as_str(), who) {
        ("status", Some(id)) => format!("Checking on {id}"),
        ("status", None) => "Checking on the agents".to_owned(),
        ("interrupt", Some(id)) => format!("Steering {id}"),
        ("answer", Some(id)) => format!("Answering {id}'s prompt"),
        ("pause", Some(id)) => format!("Pausing {id}"),
        ("resume", Some(id)) => format!("Resuming {id}"),
        ("cancel", Some(id)) => format!("Cancelling {id}"),
        ("restart", Some(id)) => format!("Restarting {id}"),
        ("priority", Some(id)) => format!("Putting {id} first"),
        ("show", Some(id)) => format!("Showing {id}'s workspace"),
        ("hide", Some(id)) => format!("Hiding {id}'s workspace"),
        ("cap", _) => "Setting how many agents work at once".to_owned(),
        ("cloud", _) => "Choosing where new agents run".to_owned(),
        (_, Some(id)) => format!("Managing {id}"),
        _ => "Managing the agents".to_owned(),
    }
}

fn tool_of(step: &mut Map<String, Value>) -> &mut Map<String, Value> {
    let tool = step.entry("tool").or_insert_with(|| json!({}));
    if !tool.is_object() {
        *tool = json!({});
    }
    tool.as_object_mut().expect("tool is an object")
}

fn set_text(step: &mut Map<String, Value>, text: &str) {
    if text.len() > MAX_TEXT {
        step.insert("text".into(), json!(cut_tail(text, MAX_TEXT)));
        step.insert("truncated".into(), json!(true));
    } else {
        step.insert("text".into(), json!(text));
        step.remove("truncated");
    }
}

fn is_empty(value: &Value) -> bool {
    match value {
        Value::Null => true,
        Value::Object(map) => map.is_empty(),
        _ => false,
    }
}

/// The input as JSON when it fits, else the head of its JSON text, cut until that string's own
/// JSON (quotes and backslashes escaped again) fits too.
fn capped_input(input: &Value) -> Value {
    let text = input.to_string();
    if text.len() <= MAX_INPUT {
        return input.clone();
    }
    let mut max = MAX_INPUT - 64;
    loop {
        let head = json!(cut_head(&text, max));
        if head.to_string().len() <= MAX_INPUT || max < 64 {
            return head;
        }
        max = max * 3 / 4;
    }
}

/// One line the owner accepts: control characters dropped, at most `max` characters.
fn line(text: &str, max: usize) -> String {
    text.chars().filter(|c| !c.is_control()).take(max).collect()
}

/// A tool name the owner accepts (a title can stand in for it: one line of at most 128).
fn tool_name(name: &str) -> String {
    let name = line(name.trim(), 128);
    if name.trim().is_empty() {
        "tool".to_owned()
    } else {
        name
    }
}

/// `<prefix>:<id>`, or `<prefix>:h<hash>` when the harness's id is not a key the owner takes
/// (1-128 of `[A-Za-z0-9_.:-]`).
fn step_id(prefix: &str, id: &str) -> String {
    let key = format!("{prefix}:{id}");
    let valid = key.len() <= 128
        && key
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b'.' | b':' | b'-'));
    if valid {
        return key;
    }
    // FNV-1a 64 of the raw id: stable for one call across its updates.
    let hash = id.bytes().fold(0xcbf2_9ce4_8422_2325_u64, |h, b| {
        (h ^ u64::from(b)).wrapping_mul(0x0100_0000_01b3)
    });
    format!("{prefix}:h{hash:016x}")
}

/// A shell tool's exit code, when the harness reports one.
fn exit_code(update: &Value) -> Option<i64> {
    let raw = update.get("rawOutput");
    raw.and_then(|r| {
        r.get("exit_code")
            .or_else(|| r.get("exitCode"))
            .or_else(|| r.get("code"))
    })
    .or_else(|| update.pointer("/_meta/claude/exitCode"))
    .and_then(Value::as_i64)
}

/// The `image` content blocks of a tool update (png, jpeg, gif, webp), in order.
fn images_of(update: &Value) -> Vec<(String, String)> {
    let Some(content) = update.get("content").and_then(Value::as_array) else {
        return Vec::new();
    };
    content
        .iter()
        .filter_map(|item| {
            let block = item.get("content").unwrap_or(item);
            if block.get("type").and_then(Value::as_str) != Some("image") {
                return None;
            }
            let mime = block.get("mimeType").and_then(Value::as_str)?;
            let data = block.get("data").and_then(Value::as_str)?;
            matches!(
                mime,
                "image/png" | "image/jpeg" | "image/gif" | "image/webp"
            )
            .then(|| (mime.to_owned(), data.to_owned()))
        })
        .collect()
}

/// ACP `locations`: files the call reads or writes, as paths with no text.
fn merge_locations(tool: &mut Map<String, Value>, update: &Value) {
    let Some(locations) = update.get("locations").and_then(Value::as_array) else {
        return;
    };
    for location in locations {
        let Some(path) = location
            .get("path")
            .and_then(Value::as_str)
            .filter(|p| !p.is_empty())
        else {
            continue;
        };
        let Some(file) = file_entry(tool, path) else {
            continue;
        };
        if let Some(line) = location.get("line").and_then(Value::as_u64) {
            file.entry("line").or_insert_with(|| json!(line));
        }
    }
}

/// ACP `diff` content blocks: the file's old and new text, with line counts.
fn merge_diffs(tool: &mut Map<String, Value>, update: &Value) {
    let Some(content) = update.get("content").and_then(Value::as_array) else {
        return;
    };
    for item in content {
        if item.get("type").and_then(Value::as_str) != Some("diff") {
            continue;
        }
        let Some(path) = item
            .get("path")
            .and_then(Value::as_str)
            .filter(|p| !p.is_empty())
        else {
            continue;
        };
        let old = item.get("oldText").and_then(Value::as_str);
        let new = item
            .get("newText")
            .and_then(Value::as_str)
            .unwrap_or_default();
        let (added, removed) = line_counts(old.unwrap_or_default(), new);
        let Some(file) = file_entry(tool, path) else {
            continue;
        };
        file.insert("added".into(), json!(added));
        file.insert("removed".into(), json!(removed));
        if old.map_or(0, str::len) + new.len() <= MAX_FILE_TEXT {
            if let Some(old) = old {
                file.insert("old_text".into(), json!(old));
            }
            file.insert("new_text".into(), json!(new));
        } else {
            file.remove("old_text");
            file.remove("new_text");
        }
    }
    // The owner keeps at most 32 KiB of file text in one step.
    let mut total = 0;
    if let Some(Value::Array(files)) = tool.get_mut("files") {
        for file in files.iter_mut().filter_map(Value::as_object_mut) {
            let size = ["old_text", "new_text"]
                .iter()
                .map(|key| file.get(*key).and_then(Value::as_str).map_or(0, str::len))
                .sum::<usize>();
            if total + size > MAX_TEXT {
                file.remove("old_text");
                file.remove("new_text");
            } else {
                total += size;
            }
        }
    }
}

/// The step's entry for `path` (one line of at most 4096 characters); None past 64 files.
fn file_entry<'a>(
    tool: &'a mut Map<String, Value>,
    path: &str,
) -> Option<&'a mut Map<String, Value>> {
    let path = line(path, 4096);
    if path.is_empty() {
        return None;
    }
    let files = tool.entry("files").or_insert_with(|| json!([]));
    if !files.is_array() {
        *files = json!([]);
    }
    let files = files.as_array_mut().expect("files is an array");
    let index = match files
        .iter()
        .position(|f| f.get("path").and_then(Value::as_str) == Some(path.as_str()))
    {
        Some(index) => index,
        None if files.len() >= 64 => return None,
        None => {
            files.push(json!({ "path": path }));
            files.len() - 1
        }
    };
    files[index].as_object_mut()
}

/// Lines added and removed from `old` to `new`, by line multiset (a
/// display count, not a diff).
fn line_counts(old: &str, new: &str) -> (u64, u64) {
    let mut left: BTreeMap<&str, i64> = BTreeMap::new();
    for line in old.lines() {
        *left.entry(line).or_default() += 1;
    }
    let mut added = 0;
    for line in new.lines() {
        match left.get_mut(line) {
            Some(count) if *count > 0 => *count -= 1,
            _ => added += 1,
        }
    }
    let removed = left.values().filter(|c| **c > 0).sum::<i64>();
    (added, removed.max(0) as u64)
}

/// The first `max` bytes of `text` at a character boundary.
pub fn cut_head(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut cut = max;
    while !text.is_char_boundary(cut) {
        cut -= 1;
    }
    text[..cut].to_owned()
}

/// The last `max` bytes of `text` at a character boundary.
fn cut_tail(text: &str, max: usize) -> String {
    if text.len() <= max {
        return text.to_owned();
    }
    let mut cut = text.len() - max;
    while !text.is_char_boundary(cut) {
        cut += 1;
    }
    text[cut..].to_owned()
}

/// `text` when it fits, else its head and tail around a marker.
fn head_and_tail(text: &str, max: usize) -> (String, bool) {
    if text.len() <= max {
        return (text.to_owned(), false);
    }
    let marker = "\n[...]\n";
    let half = (max - marker.len()) / 2;
    (
        format!("{}{marker}{}", cut_head(text, half), cut_tail(text, half)),
        true,
    )
}

/// The run summary when the turn's session starts.
pub fn started(
    session: &str,
    harness: &str,
    model: Option<&str>,
    started_at: u64,
) -> Map<String, Value> {
    let mut run = Map::new();
    run.insert("status".into(), json!("running"));
    run.insert("started_at".into(), json!(started_at));
    // A turn run again under its key (a retry) starts with no error.
    run.insert("error".into(), json!(""));
    run.insert("harness".into(), json!(line(harness, 64)));
    if let Some(model) = model.filter(|m| !m.is_empty()) {
        run.insert("model".into(), json!(line(model, 128)));
    }
    run.insert("session".into(), json!({"kind": "acpmux", "id": session}));
    run
}

/// The run summary when the turn ends.
pub fn ended(
    error: Option<&str>,
    cancelled: bool,
    usage: Option<crate::fold::Usage>,
    cost: Option<f64>,
    model: Option<&str>,
) -> Map<String, Value> {
    let mut run = Map::new();
    let status = match (cancelled, error) {
        (true, _) => "cancelled",
        (false, Some(_)) => "failed",
        (false, None) => "done",
    };
    run.insert("status".into(), json!(status));
    if let Some(error) = error.filter(|_| !cancelled) {
        run.insert("error".into(), json!(cut_head(error, 1800)));
    }
    if let Some(u) = usage {
        run.insert(
            "usage".into(),
            json!({"input": u.input, "output": u.output, "cache_read": u.cache_read, "cache_write": u.cache_write}),
        );
    }
    if let Some(cost) = cost.filter(|c| c.is_finite() && *c >= 0.0) {
        run.insert("cost_usd".into(), json!(cost));
    }
    if let Some(model) = model.filter(|m| !m.is_empty()) {
        run.insert("model".into(), json!(line(model, 128)));
    }
    run
}

/// Milliseconds since the epoch.
pub fn epoch_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_millis() as u64)
}

/// Splits steps into appends of at most [`MAX_APPEND`] steps and [`MAX_APPEND_BYTES`] bytes.
pub fn chunks(steps: Vec<Value>) -> Vec<Vec<Value>> {
    let mut out: Vec<Vec<Value>> = Vec::new();
    let mut current = Vec::new();
    let mut bytes = 0;
    for step in steps {
        let size = step.to_string().len();
        if !current.is_empty() && (current.len() >= MAX_APPEND || bytes + size > MAX_APPEND_BYTES) {
            out.push(std::mem::take(&mut current));
            bytes = 0;
        }
        bytes += size;
        current.push(step);
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

/// A dedicated completed record for reports from one assignment. It never shares the original
/// turn's id, so a late report cannot revive a pruned turn or finish an active one.
pub fn report_run_id(assignment: &str) -> String {
    step_id("reports", assignment)
}

/// A report as bounded note steps. The generation keeps follow-up replies distinct;
/// re-reading the same report upserts the same ids, including after a host restart.
pub fn report_notes(
    agent: &str,
    session: &str,
    started: u64,
    floor: u64,
    text: &str,
) -> Vec<Value> {
    let prefix = format!("[{agent}] ");
    let limit = MAX_TEXT.saturating_sub(prefix.len());
    let mut remaining = text;
    let mut notes = Vec::new();
    loop {
        let mut end = remaining.len().min(limit);
        while !remaining.is_char_boundary(end) {
            end -= 1;
        }
        let id = step_id(
            "report",
            &format!("{agent}:{session}:{started}:{floor}:{}", notes.len()),
        );
        notes.push(
            json!({"id": id, "kind": "note", "text": format!("{prefix}{}", &remaining[..end])}),
        );
        remaining = &remaining[end..];
        if remaining.is_empty() {
            break;
        }
    }
    notes
}

#[cfg(test)]
mod report_tests {
    use super::*;

    #[test]
    fn report_notes_preserve_multibyte_text_and_redelivery_identity() {
        let text = "🦀 verified\n".repeat(4000);
        let notes = report_notes("a1", "session", 100, 42, &text);
        assert!(notes.len() > 1);
        assert_eq!(notes, report_notes("a1", "session", 100, 42, &text));
        let restored: String = notes
            .iter()
            .map(|note| {
                let text = note["text"].as_str().unwrap();
                assert!(text.len() <= MAX_TEXT);
                text.strip_prefix("[a1] ").unwrap()
            })
            .collect();
        assert_eq!(restored, text);
        assert_ne!(
            notes[0]["id"],
            report_notes("a1", "session", 101, 42, "next")[0]["id"]
        );
        assert_ne!(
            notes[0]["id"],
            report_notes("a1", "new-session", 100, 42, "next")[0]["id"]
        );
    }
}
