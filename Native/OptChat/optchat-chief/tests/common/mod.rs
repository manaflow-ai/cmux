#![allow(dead_code)]
//! In-process fakes of the two owners (the conversation owner and acpmux) and
//! a compactor model, so the brain runs end to end without a daemon.

use std::collections::{BTreeMap, VecDeque};
use std::path::Path;
use std::sync::mpsc::{Receiver, Sender, channel};
use std::sync::{Arc, Condvar, Mutex};
use std::time::Duration;

use cmux_chief::acp::AcpmuxEvent;
use cmux_conversation::{Change, Message, Op, Part, Summary};
use optchat_chief::acpmux::{AgentEvent, AgentPort, SessionSpec, TurnSignal};
use optchat_chief::brain::{Brain, Engine, Input, PARENT, Settings};
use optchat_chief::daemon::{ConversationPort, DaemonEvent, OpError, participants};
use optchat_chief::state::StateFile;
use optchat_host::{
    CompactModel, CompactRequest, Config, Followup, ModelError, OptChat, Reply, SystemClock,
};
use serde_json::{Value, json};

pub const CONV: &str = "conv_chief";
pub const WAIT: Duration = Duration::from_secs(30);
/// The turn session names' prefix of the test home (`optchat-<home id>`).
pub const TURN_PREFIX: &str = "optchat-h0me";
/// The turn sessions' acpmux preset of the test home.
pub const TURN_PRESET: &str = "optchat-chief-h0me";

/// What Claude Code answers through acpmux when the request has more than
/// four cache breakpoints (checked live: Claude Code uses three itself).
pub const MARKER_LIMIT: &str = "API Error: 400 {\"type\":\"error\",\"error\":{\"type\":\"invalid_request_error\",\"message\":\"A maximum of 4 blocks with cache_control may be provided. Found 5.\"}}";

/// A compactor that answers every node with a short line.
pub struct Model;

impl CompactModel for Model {
    fn call(&self, request: &CompactRequest, _: &[Followup]) -> Result<Reply, ModelError> {
        Ok(Reply::text(format!("summary of {}", request.node.name())))
    }
}

pub fn open_chat(dir: &Path) -> Arc<OptChat> {
    let config = Config {
        reporter: Arc::new(|_| {}),
        ..Config::default()
    };
    Arc::new(OptChat::open_with(dir, config, Arc::new(Model), Arc::new(SystemClock)).unwrap())
}

pub fn message(seq: u64, author: &str, text: &str) -> Message {
    Message {
        id: format!("msg_{seq}"),
        conversation: CONV.into(),
        seq,
        client_msg_id: format!("c{seq}"),
        author: author.into(),
        parts: vec![Part::Text {
            text: text.into(),
            runs: None,
        }],
        reply_to: None,
        created_at: String::new(),
        edited_at: None,
        retracted_at: None,
        reactions: Vec::new(),
        origin: None,
    }
}

pub fn summary() -> Summary {
    Summary {
        id: CONV.into(),
        owner: "local".into(),
        title: "mux".into(),
        participants: participants("Ada"),
        last_seq: 0,
        rev: 0,
        created_at: String::new(),
        updated_at: String::new(),
        last_message: None,
        read_cursors: BTreeMap::new(),
    }
}

/// The conversation owner's state as the fake keeps it.
#[derive(Default)]
pub struct Owner {
    pub summary: Option<Summary>,
    pub messages: Vec<Message>,
    /// Every op the brain sent, in order: (idempotency key, op).
    pub ops: Vec<(String, Op)>,
    pub typing: Vec<bool>,
    /// Rejections for the next `message.send` ops, in order (None: accept).
    pub rejects: VecDeque<Option<String>>,
    pub reconnects: usize,
    /// When set, `message.send` keys are remembered as the real owner does:
    /// a reused key with the same text replays (posts nothing), with other
    /// text it is refused with `idempotency_conflict`.
    pub ledger: Option<BTreeMap<String, String>>,
    /// Rejections for the next `read_cursor.set` ops, in order (None: accept).
    pub cursor_rejects: VecDeque<Option<String>>,
}

impl Owner {
    pub fn sends(&self) -> Vec<(String, String)> {
        self.ops
            .iter()
            .filter_map(|(key, op)| match op {
                Op::MessageSend { parts, .. } => match &parts[0] {
                    Part::Text { text, .. } => Some((key.clone(), text.clone())),
                    _ => None,
                },
                _ => None,
            })
            .collect()
    }

    pub fn cursors(&self) -> Vec<u64> {
        self.ops
            .iter()
            .filter_map(|(_, op)| match op {
                Op::ReadCursorSet { seq } => Some(*seq),
                _ => None,
            })
            .collect()
    }
}

#[derive(Clone)]
pub struct FakeDaemon(pub Arc<Mutex<Owner>>);

impl ConversationPort for FakeDaemon {
    fn snapshot(&mut self, _: &str, tail: u32) -> Result<(Summary, Vec<Message>), OpError> {
        let owner = self.0.lock().unwrap();
        let messages = owner
            .messages
            .iter()
            .rev()
            .take(tail as usize)
            .rev()
            .cloned()
            .collect();
        Ok((owner.summary.clone().unwrap(), messages))
    }

    fn history(&mut self, _: &str, before_seq: u64, limit: u32) -> Result<Vec<Message>, OpError> {
        let owner = self.0.lock().unwrap();
        let older: Vec<Message> = owner
            .messages
            .iter()
            .filter(|m| m.seq < before_seq)
            .cloned()
            .collect();
        let skip = older.len().saturating_sub(limit as usize);
        Ok(older.into_iter().skip(skip).collect())
    }

    fn op(&mut self, _: &str, key: &str, op: &Op) -> Result<Option<Change>, OpError> {
        let mut owner = self.0.lock().unwrap();
        owner.ops.push((key.to_owned(), op.clone()));
        match op {
            Op::ReadCursorSet { seq } => {
                if let Some(Some(reason)) = owner.cursor_rejects.pop_front() {
                    return Err(OpError::Rejected(reason));
                }
                owner
                    .summary
                    .as_mut()
                    .unwrap()
                    .read_cursors
                    .insert("agent_mux".into(), *seq);
                Ok(None)
            }
            Op::MessageSend { parts, .. } => {
                if let Some(Some(reason)) = owner.rejects.pop_front() {
                    return Err(OpError::Rejected(reason));
                }
                let text = match &parts[0] {
                    Part::Text { text, .. } => text.clone(),
                    _ => String::new(),
                };
                if let Some(ledger) = owner.ledger.as_mut() {
                    match ledger.get(key) {
                        Some(old) if *old == text => return Ok(None),
                        Some(_) => {
                            return Err(OpError::Rejected("idempotency_conflict".into()));
                        }
                        None => {
                            ledger.insert(key.to_owned(), text);
                        }
                    }
                }
                let seq = owner.messages.len() as u64 + 1;
                let mut m = message(seq, "agent_mux", "");
                m.parts = parts.clone();
                owner.messages.push(m.clone());
                Ok(Some(Change::Message { message: m }))
            }
            _ => Ok(None),
        }
    }

    fn typing(&mut self, _: &str, on: bool) -> Result<(), OpError> {
        self.0.lock().unwrap().typing.push(on);
        Ok(())
    }
}

/// What one fake turn does: its events, given the turn's prompt blocks.
pub type Script = Box<dyn Fn(usize, &[Value]) -> Vec<Value> + Send + Sync>;

/// The default turn: a reply, a tool call and its result, a final reply.
pub fn default_script() -> Script {
    Box::new(|turn, _| {
        vec![
            json!({"dir": "mux", "kind": "turn_started", "msg": {}}),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": "Checking."}}),
            ),
            update(
                "tool_call",
                json!({"toolCallId": format!("t{turn}"), "title": "Bash", "rawInput": {"command": "ls"}, "_meta": {"claude": {"tool": "Bash"}}}),
            ),
            update(
                "tool_call_update",
                json!({"toolCallId": format!("t{turn}"), "status": "completed", "content": [{"type": "content", "content": {"type": "text", "text": "a.txt"}}]}),
            ),
            update(
                "agent_message_chunk",
                json!({"content": {"type": "text", "text": format!("answer {turn}")}}),
            ),
            json!({"dir": "mux", "kind": "turn_end", "msg": {}}),
        ]
    })
}

pub fn update(kind: &str, mut update: Value) -> Value {
    update["sessionUpdate"] = json!(kind);
    json!({"dir": "in", "kind": kind, "msg": {"method": "session/update", "params": {"update": update}}})
}

#[derive(Default)]
pub struct Agents {
    pub specs: Vec<SessionSpec>,
    /// Each session's system prompt when it started: the text its preset
    /// carried (acpmux `systemPrompt`), None without one.
    pub systems: Vec<Option<String>>,
    /// Presets acpmux installed with a system prompt (a daemon that knows
    /// `systemPrompt`): the cached layout.
    pub system_prompts: bool,
    /// Each preset's current system prompt text.
    pub preset_prompts: BTreeMap<String, String>,
    /// Every `set_system_prompt` call: (preset, text).
    pub prompt_sets: Vec<(String, String)>,
    /// Each turn's prompt blocks.
    pub prompts: Vec<Vec<Value>>,
    pub prompt_ids: Vec<String>,
    pub events: BTreeMap<String, Vec<AcpmuxEvent>>,
    pub ended: Vec<String>,
    /// Turns held before they run, released by `release`.
    pub hold: bool,
    pub released: usize,
    /// The next turn loses its acpmux connection instead of answering.
    pub lose: bool,
    /// `events` fails with this error while set.
    pub events_error: Option<String>,
    /// Sessions whose turn was cancelled, in order.
    pub cancels: Vec<String>,
    /// The next prompt's answer (default `{"stopReason": "end_turn"}`), used once.
    pub answer: Option<Value>,
    /// The next prompt fails with this JSON-RPC error message, used once
    /// (acpmux answers a refused or failed Claude turn this way).
    pub answer_error: Option<String>,
    /// Names looked up with `find`, in order.
    pub finds: Vec<String>,
    /// The next this many `cancel` calls are recorded but change nothing
    /// (a cancel that reached acpmux before the prompt did).
    pub ignore_cancels: usize,
    /// The prompt's answer comes this long after its events (acpmux records
    /// `turn_end` before it answers the prompt).
    pub answer_delay: Option<Duration>,
    /// Each session's turn signals, for `push_events`.
    pub signals: BTreeMap<String, Sender<TurnSignal>>,
    /// The `_acpmux/harnesses` answer; None: `catalog()` (claude-sr and
    /// claude on acpmux's own Claude Code adapter, codex on its ACP adapter).
    pub catalog: Option<Value>,
    /// The harness acpmux reports a new session on (`session`); None: the
    /// one the spec asked for.
    pub session_harness: Option<String>,
}

/// An `_acpmux/harnesses` answer as a machine with `sr` and `claude` on
/// PATH and no `~/.acpx` gets (cmux-lawrence-2, 2026-10-05).
pub fn catalog() -> Value {
    json!({"harnesses": {
        "claude": {"kind": "claude-stdio", "argv": ["/Users/cmux/.local/bin/claude"], "fallback": "claude-sr", "family": "claude"},
        "claude-sr": {"kind": "claude-stdio", "argv": ["/Users/cmux/bin/sr", "claude", "proxy"], "fallback": "claude", "family": "claude"},
        "codex": {"argv": ["/opt/homebrew/bin/npx", "-y", "@agentclientprotocol/codex-acp@1.10.0"], "family": "codex"},
    }, "defaultHarness": "claude"})
}

/// The answer of Lawrence's laptop tagged daemons on 2026-10-05: `~/.acpx`
/// maps `claude` to the claude-acp ACP adapter, and `sr claude proxy
/// --version` failed, so acpmux replaced claude-sr with a copy of that
/// `claude` routed through the subrouter server.
pub fn acpx_catalog() -> Value {
    let acp = "/Users/lawrence/.local/share/cmux-acp/current/bin/claude-acp";
    json!({"harnesses": {
        "claude": {"argv": [acp], "fallback": "claude-sr", "description": "imported from ~/.acpx", "family": "claude"},
        "claude-sr": {"argv": [acp], "env": {"ANTHROPIC_BASE_URL": "http://cmux-lawrences-mac-mini.tail137216.ts.net:31415"}, "description": "Claude through the subrouter server http://cmux-lawrences-mac-mini.tail137216.ts.net:31415", "family": "claude"},
        "codex": {"argv": ["/Users/lawrence/.local/share/cmux-acp/current/bin/codex-acp"], "description": "imported from ~/.acpx", "family": "codex"},
    }, "defaultHarness": "claude"})
}

pub struct FakeAgents {
    pub inner: Mutex<Agents>,
    pub changed: Condvar,
    script: Script,
    me: std::sync::Weak<FakeAgents>,
}

impl FakeAgents {
    pub fn new(script: Script) -> Arc<FakeAgents> {
        Arc::new_cyclic(|me| FakeAgents {
            inner: Mutex::new(Agents::default()),
            changed: Condvar::new(),
            script,
            me: me.clone(),
        })
    }

    pub fn hold(&self, on: bool) {
        self.inner.lock().unwrap().hold = on;
    }

    /// Lets one held turn run.
    pub fn release(&self) {
        self.inner.lock().unwrap().released += 1;
        self.changed.notify_all();
    }

    /// Waits until `n` prompts were sent.
    pub fn wait_prompts(&self, n: usize) {
        let deadline = std::time::Instant::now() + WAIT;
        let mut inner = self.inner.lock().unwrap();
        while inner.prompts.len() < n {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(!left.is_zero(), "no prompt {n}");
            inner = self.changed.wait_timeout(inner, left).unwrap().0;
        }
    }

    /// Adds a prompt's events after the session's earlier ones (acpmux
    /// numbers a session's events on, across its prompts).
    pub fn append_events(&self, session: &str, events: Vec<Value>) {
        let mut inner = self.inner.lock().unwrap();
        let list = inner.events.entry(session.to_owned()).or_default();
        let base = list.last().map_or(0, |e| e.seq);
        for (i, mut e) in events.into_iter().enumerate() {
            e["seq"] = json!(base + i as u64 + 1);
            list.push(serde_json::from_value(e).unwrap());
        }
    }

    /// Adds events to a running turn and tells its runner, as acpmux's
    /// notifications do.
    pub fn push_events(&self, session: &str, events: Vec<Value>) {
        self.append_events(session, events);
        let signals = self.inner.lock().unwrap().signals.get(session).cloned();
        if let Some(tx) = signals {
            let _ = tx.send(TurnSignal::Changed);
        }
    }

    /// Waits until `n` cancels were recorded.
    pub fn wait_cancels(&self, n: usize) {
        let deadline = std::time::Instant::now() + WAIT;
        let mut inner = self.inner.lock().unwrap();
        while inner.cancels.len() < n {
            let left = deadline.saturating_duration_since(std::time::Instant::now());
            assert!(!left.is_zero(), "no cancel {n}");
            inner = self.changed.wait_timeout(inner, left).unwrap().0;
        }
    }

    pub fn set_events(&self, session: &str, events: Vec<Value>) {
        let parsed = events.into_iter().enumerate().map(|(i, mut e)| {
            e["seq"] = json!(i as u64 + 1);
            serde_json::from_value(e).unwrap()
        });
        self.inner
            .lock()
            .unwrap()
            .events
            .insert(session.to_owned(), parsed.collect());
    }
}

impl AgentPort for FakeAgents {
    fn new_session(&self, spec: &SessionSpec) -> Result<String, String> {
        let mut inner = self.inner.lock().unwrap();
        let system = spec
            .preset
            .as_ref()
            .and_then(|p| inner.preset_prompts.get(p))
            .cloned();
        inner.systems.push(system);
        inner.specs.push(spec.clone());
        Ok(format!("s{}", inner.specs.len()))
    }

    fn start_prompt(
        &self,
        session: &str,
        blocks: Vec<Value>,
        prompt_id: &str,
        signals: Sender<TurnSignal>,
    ) -> Result<(), String> {
        let turn = {
            let mut inner = self.inner.lock().unwrap();
            inner.prompts.push(blocks.clone());
            inner.prompt_ids.push(prompt_id.to_owned());
            inner.signals.insert(session.to_owned(), signals.clone());
            inner.prompts.len() - 1
        };
        self.changed.notify_all();
        self.append_events(session, (self.script)(turn, &blocks));
        let me = self.me.upgrade().expect("alive");
        std::thread::spawn(move || {
            {
                let mut inner = me.inner.lock().unwrap();
                while inner.hold && inner.released <= turn {
                    inner = me.changed.wait(inner).unwrap();
                }
            }
            let (lose, answer, error, delay) = {
                let mut inner = me.inner.lock().unwrap();
                (
                    std::mem::take(&mut inner.lose),
                    inner.answer.take(),
                    inner.answer_error.take(),
                    inner.answer_delay,
                )
            };
            let _ = signals.send(TurnSignal::Changed);
            if let Some(delay) = delay {
                std::thread::sleep(delay);
            }
            if lose {
                let _ = signals.send(TurnSignal::Lost);
            } else if let Some(error) = error {
                let _ = signals.send(TurnSignal::Done(Err(error)));
            } else {
                let answer = answer.unwrap_or_else(|| json!({"stopReason": "end_turn"}));
                let _ = signals.send(TurnSignal::Done(Ok(answer)));
            }
        });
        Ok(())
    }

    fn events(&self, session: &str, after: u64) -> Result<Vec<AcpmuxEvent>, String> {
        let inner = self.inner.lock().unwrap();
        if let Some(e) = &inner.events_error {
            return Err(e.clone());
        }
        Ok(inner
            .events
            .get(session)
            .into_iter()
            .flatten()
            .filter(|e| e.seq > after)
            .cloned()
            .collect())
    }

    fn end_session(&self, session: &str) -> Result<(), String> {
        self.inner.lock().unwrap().ended.push(session.to_owned());
        Ok(())
    }

    fn find(&self, name: &str) -> Result<Option<String>, String> {
        self.inner.lock().unwrap().finds.push(name.to_owned());
        Ok(None)
    }

    fn harness_catalog(&self) -> Result<Value, String> {
        Ok(self
            .inner
            .lock()
            .unwrap()
            .catalog
            .clone()
            .unwrap_or_else(catalog))
    }

    fn session(&self, id: &str) -> Result<Option<cmux_chief::acp::SessionSummary>, String> {
        let inner = self.inner.lock().unwrap();
        let Some(n) = id.strip_prefix('s').and_then(|n| n.parse::<usize>().ok()) else {
            return Ok(None);
        };
        let Some(spec) = inner.specs.get(n.wrapping_sub(1)) else {
            return Ok(None);
        };
        let harness = inner
            .session_harness
            .clone()
            .unwrap_or_else(|| spec.harness.clone());
        Ok(Some(serde_json::from_value(json!({
            "sessionId": id, "name": spec.name, "harness": harness, "cwd": spec.cwd, "status": "running",
        })).unwrap()))
    }

    fn system_prompt(&self, _preset: &str) -> bool {
        self.inner.lock().unwrap().system_prompts
    }

    fn set_system_prompt(&self, preset: &str, text: &str) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        if !inner.system_prompts {
            return Err("unknown preset key \"systemPrompt\"".into());
        }
        inner.prompt_sets.push((preset.to_owned(), text.to_owned()));
        inner
            .preset_prompts
            .insert(preset.to_owned(), text.to_owned());
        Ok(())
    }

    /// Ends the held turn with stop reason `cancelled`, as acpmux answers a
    /// prompt that `session/cancel` interrupted.
    fn cancel(&self, session: &str) -> Result<(), String> {
        let mut inner = self.inner.lock().unwrap();
        inner.cancels.push(session.to_owned());
        if inner.ignore_cancels > 0 {
            inner.ignore_cancels -= 1;
            drop(inner);
            self.changed.notify_all();
            return Ok(());
        }
        inner.answer = Some(json!({"stopReason": "cancelled"}));
        inner.released += 1;
        drop(inner);
        self.changed.notify_all();
        Ok(())
    }
}

pub struct Harness {
    pub dir: tempfile::TempDir,
    pub chat: Arc<OptChat>,
    pub owner: Arc<Mutex<Owner>>,
    pub agents: Arc<FakeAgents>,
    pub brain: Brain,
    pub rx: Receiver<Input>,
    /// The brain's input channel (what the host's workers send on).
    pub tx: Sender<Input>,
}

pub fn settings(dir: &Path) -> Settings {
    Settings {
        session_dir: dir.join("session"),
        harness: "claude-sr".into(),
        policy: "approve-all".into(),
        model: None,
        effort: Some("medium".into()),
        parent: PARENT.into(),
        turn_prefix: TURN_PREFIX.into(),
        agent_gap: Duration::from_millis(30),
        turn_limit: None,
        engine: Engine::Acpmux,
        turn_preset: Some(TURN_PRESET.into()),
        chief_id: "h0me".into(),
        system_text: optchat_chief::prompt::claude_md(None),
    }
}

impl Harness {
    pub fn new(script: Script) -> Harness {
        let dir = tempfile::tempdir().unwrap();
        Harness::in_dir(
            dir,
            script,
            Arc::new(Mutex::new(Owner {
                summary: Some(summary()),
                ..Owner::default()
            })),
        )
    }

    /// A brain over an existing directory and owner (a restart).
    pub fn in_dir(dir: tempfile::TempDir, script: Script, owner: Arc<Mutex<Owner>>) -> Harness {
        Harness::in_dir_with(dir, script, owner, Engine::Acpmux)
    }

    /// A brain whose turns run on `engine`.
    pub fn with_engine(engine: Engine) -> Harness {
        let dir = tempfile::tempdir().unwrap();
        let owner = Arc::new(Mutex::new(Owner {
            summary: Some(summary()),
            ..Owner::default()
        }));
        Harness::in_dir_with(dir, default_script(), owner, engine)
    }

    pub fn in_dir_with(
        dir: tempfile::TempDir,
        script: Script,
        owner: Arc<Mutex<Owner>>,
        engine: Engine,
    ) -> Harness {
        let settings = Settings {
            engine,
            ..settings(dir.path())
        };
        Harness::configured(dir, script, owner, settings, Arc::new(|_: &str| {}))
    }

    /// A brain with these settings and host.log sink.
    pub fn configured(
        dir: tempfile::TempDir,
        script: Script,
        owner: Arc<Mutex<Owner>>,
        settings: Settings,
        log: optchat_chief::brain::Log,
    ) -> Harness {
        let chat = open_chat(&dir.path().join("chat"));
        let agents = FakeAgents::new(script);
        let (tx, rx) = channel();
        let brain = Brain::new(
            chat.clone(),
            agents.clone(),
            settings,
            StateFile::new(&dir.path().join("host.json")),
            tx.clone(),
            log,
        );
        Harness {
            dir,
            chat,
            owner,
            agents,
            brain,
            rx,
            tx,
        }
    }

    /// Both owners connected.
    pub fn connect(&mut self) {
        self.brain.step(Input::from(AgentEvent::Up(Vec::new())));
        let owner = self.owner.clone();
        let summary = owner.lock().unwrap().summary.clone().unwrap();
        let reconnects = owner.clone();
        self.brain.step(Input::from(DaemonEvent::Up {
            port: Box::new(FakeDaemon(owner)),
            conversation: summary,
            reconnect: Box::new(move || reconnects.lock().unwrap().reconnects += 1),
        }));
    }

    /// A new message in the conversation, as the subscription delivers it.
    pub fn say(&mut self, author: &str, text: &str) -> Message {
        let m = {
            let mut owner = self.owner.lock().unwrap();
            let seq = owner.messages.len() as u64 + 1;
            let m = message(seq, author, text);
            owner.messages.push(m.clone());
            m
        };
        self.brain.step(Input::from(DaemonEvent::Changed {
            conversation: CONV.into(),
            change: Change::Message { message: m.clone() },
        }));
        m
    }

    /// Steps the brain until it is idle (no turn, nothing queued).
    pub fn settle(&mut self) {
        while !self.brain.is_idle() {
            let input = self.rx.recv_timeout(WAIT).expect("the brain got no input");
            self.brain.step(input);
        }
    }

    /// Steps one input.
    pub fn step(&mut self) {
        let input = self.rx.recv_timeout(WAIT).expect("the brain got no input");
        self.brain.step(input);
    }

    /// The whole memory log: (kind, text).
    pub fn log(&self) -> Vec<(String, String)> {
        let n = self.chat.status().messages;
        (0..n)
            .map(|i| {
                let (kind, text) = self.chat.message(i).unwrap();
                (kind.as_str().to_owned(), text)
            })
            .collect()
    }
}
