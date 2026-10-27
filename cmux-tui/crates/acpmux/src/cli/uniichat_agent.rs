//! `acpmux uniichat-agent` (also `cmux acp uniichat-agent`): an ACP agent on
//! stdin and stdout backed by a UniiChat server
//! (<https://github.com/VictorTaelin/UniiChat>; hosted at uniichat.com, or
//! your own `unii serve`). It speaks UniiChat's own wire protocol, the one
//! its web page and its `unii` terminal use (View.ts, wire 2):
//!
//! - a WebSocket `/ws?tab=…&wire=2` with `Authorization: Bearer <token>`
//!   carries the chat's events (`state`, `delta`, `entry`, `live`, `note`,
//!   `ack`) and the acts without a body (`stop`);
//! - a message is a POST `/api/act?$=say&sizes=…&id=…` whose body is its
//!   images' bytes, then its text.
//!
//! The socket names no device, so UniiChat's agent gets no shell or screen
//! on this computer: it is a chat backend, not a remote hand.
//!
//! Sign-in is UniiChat's own: the token `unii login` keeps at
//! `$UNII_HOME/<host>/token` (default `~/.unii`). No token, or one the
//! server refuses, fails the session with the setup steps.
//!
//! Memory: UniiChat keeps one chat per account that never ends, so by
//! default a prompt sends only its last text block (a Chief turn's new
//! messages); `--whole-prompt` sends every text block. Every session id
//! maps to that same account chat, and `session/load` accepts any id.
//!
//! Streaming: `delta` events stream as `agent_message_chunk` (UniiChat's
//! words) and `agent_thought_chunk` (its thoughts); its tool calls show as
//! `tool_call` updates. A turn ends when the chat is no longer busy.
//! `session/cancel` sends the `stop` act for UniiChat's turn.

use anyhow::Result;
use futures_util::{SinkExt, StreamExt};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::sync::{Mutex, mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;

/// The hosted UniiChat, used when neither `--url` nor `$UNII_URL` names one.
pub const HOSTED: &str = "https://uniichat.com";

/// The UniiChat wire version this adapter reads (View.ts `WIRE`).
pub const WIRE: u32 = 2;

/// The name a stop gives UniiChat's own turn (View.ts `TURN`).
pub const TURN: &str = "Unii's turn";

/// How to install the `unii` terminal and sign in, shown when the adapter
/// has no sign-in to use.
pub const SETUP: &str = "Install the unii terminal (curl -fsSL https://uniichat.com/install.sh | sh), then sign in with `unii login`";

/// The adapter's command line flags.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Options {
    /// The server (`https://uniichat.com`, `http://127.0.0.1:8788`); none:
    /// `$UNII_URL`, else the hosted one.
    pub url: Option<String>,
    /// Where `unii` keeps its sign-ins; none: `$UNII_HOME`, else `~/.unii`.
    pub home: Option<PathBuf>,
    /// Send every text block of a prompt, not only the last one.
    pub whole_prompt: bool,
}

/// One UniiChat server and the sign-in this computer holds for it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Endpoint {
    /// `http(s)://host[:port]`, no trailing slash.
    pub base: String,
    /// The WebSocket origin (`ws(s)://host[:port]`).
    pub ws: String,
    /// `host[:port]`, the folder `unii` keeps this server's token in.
    pub host: String,
    /// The token file `unii login` writes.
    pub token_file: PathBuf,
}

impl Endpoint {
    /// The server and token file from the flags, then the environment
    /// values given (`UNII_URL`, `UNII_HOME`, the home folder), the way the
    /// `unii` terminal finds them (Term.ts `SERVER`, `TOKEN`).
    pub fn resolve(
        options: &Options,
        env_url: Option<String>,
        env_home: Option<String>,
        user_home: Option<PathBuf>,
    ) -> Result<Endpoint, String> {
        let url = options
            .url
            .clone()
            .or(env_url.filter(|u| !u.trim().is_empty()))
            .unwrap_or_else(|| HOSTED.to_owned());
        let base = url.trim().trim_end_matches('/').to_owned();
        let (scheme, rest) = base
            .split_once("://")
            .ok_or_else(|| format!("UniiChat url {base} needs http:// or https://"))?;
        let ws_scheme = match scheme {
            "https" => "wss",
            "http" => "ws",
            _ => return Err(format!("UniiChat url {base} needs http:// or https://")),
        };
        let host = rest.split(['/', '?', '#']).next().unwrap_or("").to_owned();
        if host.is_empty() {
            return Err(format!("UniiChat url {base} has no host"));
        }
        let base = format!("{scheme}://{host}");
        let home = options
            .home
            .clone()
            .or(env_home.filter(|h| !h.trim().is_empty()).map(PathBuf::from))
            .or(user_home.map(|h| h.join(".unii")))
            .ok_or("no home folder for the UniiChat sign-in")?;
        Ok(Endpoint {
            ws: format!("{ws_scheme}://{host}"),
            token_file: home.join(&host).join("token"),
            host,
            base,
        })
    }

    /// The sign-in token, or the setup steps when there is none.
    pub fn token(&self) -> Result<String, String> {
        match std::fs::read_to_string(&self.token_file) {
            Ok(t) if !t.trim().is_empty() => Ok(t.trim().to_owned()),
            _ => Err(format!(
                "UniiChat: this computer is not signed in to {}. {SETUP}{}.",
                self.host,
                self.login_suffix()
            )),
        }
    }

    /// The setup steps for a sign-in the server refused.
    pub fn signed_out(&self) -> String {
        format!(
            "UniiChat: {} refused this computer's sign-in (signed out or expired). Sign in again with `unii login{}`.",
            self.host,
            self.login_suffix()
        )
    }

    fn login_suffix(&self) -> String {
        if self.base == HOSTED { String::new() } else { format!(" {}", self.base) }
    }
}

/// The text one prompt sends: its last text block, or all of them. A paste
/// cmux's composer sent as its own block goes with it (`cli_agent::prompt_text`).
pub fn prompt_text(blocks: &[Value], whole: bool) -> String {
    super::cli_agent::prompt_text(blocks, !whole)
}

/// The images of a prompt (ACP `image` blocks), decoded; a block that does
/// not decode is skipped.
pub fn prompt_images(blocks: &[Value]) -> Vec<Vec<u8>> {
    use base64::Engine;
    blocks
        .iter()
        .filter(|b| b.get("type").and_then(Value::as_str) == Some("image"))
        .filter_map(|b| b.get("data").and_then(Value::as_str))
        .filter_map(|d| base64::engine::general_purpose::STANDARD.decode(d).ok())
        .collect()
}

/// The body and `sizes` field of a `say` act: the images' bytes, then the text.
pub fn say_body(text: &str, images: &[Vec<u8>]) -> (Vec<u8>, String) {
    let mut body = Vec::new();
    let mut sizes = Vec::new();
    for image in images {
        sizes.push(image.len().to_string());
        body.extend_from_slice(image);
    }
    body.extend_from_slice(text.as_bytes());
    (body, sizes.join(","))
}

/// What a turn's events become for the ACP client.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Out {
    /// UniiChat's words.
    Message(String),
    /// UniiChat's thoughts.
    Thought(String),
    /// A tool call UniiChat made (on its server or its own devices).
    ToolStart { id: String, title: String },
    /// That tool call's result.
    ToolDone { id: String, text: String },
}

/// How a turn ended.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Ended {
    /// The chat went idle after the message.
    Done,
    /// The chat went idle with no reply but a note (an error: out of
    /// credit, a model refused): its text.
    Failed(String),
}

/// One turn's view of the chat's main stream, fed the server's messages in
/// order. It streams what UniiChat says once, whether it comes as deltas
/// (live) or only as logged entries (a view that joined late), and decides
/// when the turn is over.
#[derive(Debug, Default)]
pub struct Turn {
    /// The chat is working (the last `state`).
    busy: bool,
    /// The chat was busy at some point since the message went.
    went_busy: bool,
    /// The server took the message (its `say` act answered without error).
    taken: bool,
    /// UniiChat's text of the message streaming now, as sent on.
    streamed: String,
    /// The streaming message's kind (`unii`, `mind`), if any.
    streaming: Option<String>,
    /// Some reply (words) went out.
    replied: bool,
    /// Notes logged since the message (why work ended).
    notes: Vec<String>,
    /// Tool calls started, not yet answered.
    open_tools: Vec<String>,
    tools: u64,
}

impl Turn {
    /// A turn; `busy` is the chat's state before the message.
    pub fn new(busy: bool) -> Turn {
        Turn { busy, ..Turn::default() }
    }

    /// The message was taken by the server.
    pub fn taken(&mut self) {
        self.taken = true;
    }

    /// Whether the chat is busy now.
    pub fn busy(&self) -> bool {
        self.busy
    }

    /// One server message of the main chat: what it sends on.
    pub fn hear(&mut self, msg: &Value) -> Vec<Out> {
        if msg.get("agent").and_then(Value::as_str).is_some() {
            return Vec::new();
        }
        let kind = msg.get("kind").and_then(Value::as_str).unwrap_or("");
        let text = msg.get("text").and_then(Value::as_str).unwrap_or("");
        match msg.get("$").and_then(Value::as_str).unwrap_or("") {
            "state" => {
                self.busy = msg.get("busy").and_then(Value::as_bool).unwrap_or(false);
                self.went_busy |= self.busy;
                Vec::new()
            }
            "delta" => {
                let fresh = msg.get("fresh").and_then(Value::as_bool).unwrap_or(false);
                let starts = self.streaming.as_deref() != Some(kind) || fresh;
                if starts {
                    self.streaming = Some(kind.to_owned());
                    self.streamed.clear();
                }
                self.streamed.push_str(text);
                self.out(kind, text.to_owned(), starts)
            }
            "live" => {
                // The stream told anew (a view joined, a reconnect): send
                // only what goes past what was already sent.
                let live = msg.get("live").and_then(Value::as_array).cloned().unwrap_or_default();
                let Some(last) = live.last() else { return Vec::new() };
                let kind = last.get("kind").and_then(Value::as_str).unwrap_or("");
                let text = last.get("text").and_then(Value::as_str).unwrap_or("");
                if !self.taken && !self.went_busy {
                    return Vec::new();
                }
                if self.streaming.as_deref() == Some(kind)
                    && let Some(more) = text.strip_prefix(self.streamed.as_str())
                {
                    let more = more.to_owned();
                    self.streamed = text.to_owned();
                    return if more.is_empty() { Vec::new() } else { self.out(kind, more, false) };
                }
                if kind == "unii" || kind == "mind" {
                    self.streaming = Some(kind.to_owned());
                    self.streamed = text.to_owned();
                    return self.out(kind, text.to_owned(), true);
                }
                Vec::new()
            }
            "entry" => {
                let out = match kind {
                    "unii" | "mind" => {
                        let was = if self.streaming.as_deref() == Some(kind) {
                            std::mem::take(&mut self.streamed)
                        } else {
                            String::new()
                        };
                        if let Some(more) =
                            text.strip_prefix(was.as_str()).filter(|_| !was.is_empty())
                        {
                            let more = more.to_owned();
                            if more.is_empty() { Vec::new() } else { self.out(kind, more, false) }
                        } else if was.is_empty() {
                            self.out(kind, text.to_owned(), true)
                        } else {
                            Vec::new()
                        }
                    }
                    "tool" => {
                        self.tools += 1;
                        let id = format!("unii-tool-{}", self.tools);
                        self.open_tools.push(id.clone());
                        let title =
                            text.lines().next().unwrap_or("tool").chars().take(120).collect();
                        vec![Out::ToolStart { id, title }]
                    }
                    "echo" => match self.open_tools.first().cloned() {
                        Some(id) => {
                            self.open_tools.remove(0);
                            vec![Out::ToolDone { id, text: text.to_owned() }]
                        }
                        None => Vec::new(),
                    },
                    "note" => {
                        self.notes.push(text.to_owned());
                        Vec::new()
                    }
                    _ => Vec::new(),
                };
                self.streaming = None;
                out
            }
            "note" => {
                self.notes.push(text.to_owned());
                Vec::new()
            }
            _ => Vec::new(),
        }
    }

    /// Whether the turn is over, and how: the server took the message, the
    /// chat is idle, and it either worked since or replied.
    pub fn ended(&self) -> Option<Ended> {
        if !self.taken || self.busy || !(self.went_busy || self.replied) {
            return None;
        }
        Some(self.end())
    }

    /// How the turn ended, called once it did (or at a deadline).
    pub fn end(&self) -> Ended {
        if !self.replied && !self.notes.is_empty() {
            return Ended::Failed(format!("UniiChat: {}", self.notes.join(" ")));
        }
        Ended::Done
    }

    /// Text of `kind` going out; `starts`: it begins a new message.
    fn out(&mut self, kind: &str, text: String, starts: bool) -> Vec<Out> {
        if text.is_empty() {
            return Vec::new();
        }
        match kind {
            "unii" => {
                // A new message after an earlier one this turn: a blank line between.
                let text = if self.replied && starts { format!("\n\n{text}") } else { text };
                self.replied = true;
                vec![Out::Message(text)]
            }
            "mind" => vec![Out::Thought(text)],
            _ => Vec::new(),
        }
    }
}

type Tx = mpsc::UnboundedSender<Value>;

#[derive(Default)]
struct State {
    sessions: HashMap<String, String>,
    running: HashMap<String, oneshot::Sender<()>>,
    next: u64,
}

/// Serves ACP on stdin and stdout until stdin closes.
pub async fn run(options: Options) -> Result<()> {
    let endpoint = Endpoint::resolve(
        &options,
        std::env::var("UNII_URL").ok(),
        std::env::var("UNII_HOME").ok(),
        dirs::home_dir(),
    )
    .map_err(anyhow::Error::msg)?;
    let _ = rustls::crypto::ring::default_provider().install_default();
    let (tx, mut rx) = mpsc::unbounded_channel::<Value>();
    let writer = tokio::spawn(async move {
        let mut stdout = tokio::io::stdout();
        while let Some(v) = rx.recv().await {
            let mut line = v.to_string();
            line.push('\n');
            if stdout.write_all(line.as_bytes()).await.is_err() || stdout.flush().await.is_err() {
                break;
            }
        }
    });
    let state = Arc::new(Mutex::new(State::default()));
    let ctx = Arc::new((options, endpoint));
    let mut lines = BufReader::new(tokio::io::stdin()).lines();
    while let Some(line) = lines.next_line().await? {
        let Ok(msg) = serde_json::from_str::<Value>(&line) else { continue };
        handle(msg, &ctx, &state, &tx).await;
    }
    drop(tx);
    let _ = writer.await;
    Ok(())
}

fn reply(tx: &Tx, id: &Value, result: Value) {
    let _ = tx.send(json!({"jsonrpc": "2.0", "id": id, "result": result}));
}

fn error(tx: &Tx, id: &Value, code: i64, message: String) {
    let _ =
        tx.send(json!({"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}}));
}

/// ACP's "authentication required" error code.
const AUTH_REQUIRED: i64 = -32000;

async fn handle(msg: Value, ctx: &Arc<(Options, Endpoint)>, state: &Arc<Mutex<State>>, tx: &Tx) {
    let method = msg.get("method").and_then(Value::as_str).unwrap_or("").to_owned();
    let params = msg.get("params").cloned().unwrap_or(Value::Null);
    let id = msg.get("id").cloned();
    let session_of =
        |p: &Value| p.get("sessionId").and_then(Value::as_str).unwrap_or("").to_owned();
    let endpoint = &ctx.1;
    match (method.as_str(), id) {
        ("initialize", Some(id)) => reply(
            tx,
            &id,
            json!({
                "protocolVersion": 1,
                "agentCapabilities": {
                    "loadSession": true,
                    "promptCapabilities": {"image": true, "audio": false, "embeddedContext": false},
                    "mcpCapabilities": {"http": false, "sse": false}
                },
                "agentInfo": {"name": "acpmux-uniichat-agent", "title": "UniiChat", "version": env!("CARGO_PKG_VERSION")},
                "authMethods": [{
                    "id": "unii-login",
                    "name": "Sign in to UniiChat",
                    "description": format!("{SETUP}.")
                }]
            }),
        ),
        ("authenticate", Some(id)) => match endpoint.token() {
            Ok(_) => reply(tx, &id, json!({})),
            Err(e) => error(tx, &id, AUTH_REQUIRED, e),
        },
        ("session/new", Some(id)) => {
            if let Err(e) = endpoint.token() {
                error(tx, &id, AUTH_REQUIRED, e);
                return;
            }
            let mut s = state.lock().await;
            s.next += 1;
            let sid = format!("uniichat-{}-{}-{}", endpoint.host, std::process::id(), s.next);
            let cwd = params.get("cwd").and_then(Value::as_str).unwrap_or(".").to_owned();
            s.sessions.insert(sid.clone(), cwd);
            reply(tx, &id, json!({"sessionId": sid}));
        }
        ("session/load" | "session/resume", Some(id)) => {
            let sid = session_of(&params);
            let cwd = params.get("cwd").and_then(Value::as_str).unwrap_or(".").to_owned();
            state.lock().await.sessions.insert(sid, cwd);
            reply(tx, &id, json!({}));
        }
        ("session/prompt", Some(id)) => {
            let sid = session_of(&params);
            let blocks =
                params.get("prompt").and_then(Value::as_array).cloned().unwrap_or_default();
            let (cancel_tx, cancel_rx) = oneshot::channel();
            {
                let mut s = state.lock().await;
                if !s.sessions.contains_key(&sid) {
                    error(tx, &id, -32602, format!("no session {sid}"));
                    return;
                }
                s.running.insert(sid.clone(), cancel_tx);
            }
            let (ctx, state, tx) = (ctx.clone(), state.clone(), tx.clone());
            tokio::spawn(async move {
                let outcome = run_prompt(&ctx.0, &ctx.1, &sid, &blocks, cancel_rx, &tx).await;
                state.lock().await.running.remove(&sid);
                match outcome {
                    Ok(stop) => reply(&tx, &id, json!({"stopReason": stop})),
                    Err((code, e)) => error(&tx, &id, code, e),
                }
            });
        }
        ("session/cancel", _) => {
            if let Some(cancel) = state.lock().await.running.remove(&session_of(&params)) {
                let _ = cancel.send(());
            }
        }
        ("session/set_mode" | "session/set_model" | "session/set_config_option", Some(id)) => {
            reply(tx, &id, json!({}))
        }
        (_, Some(id)) => error(tx, &id, -32601, format!("uniichat-agent has no method {method}")),
        (_, None) => {}
    }
}

fn send_out(tx: &Tx, session: &str, out: Out) {
    let update = match out {
        Out::Message(text) => json!({
            "sessionUpdate": "agent_message_chunk",
            "content": {"type": "text", "text": text}
        }),
        Out::Thought(text) => json!({
            "sessionUpdate": "agent_thought_chunk",
            "content": {"type": "text", "text": text}
        }),
        Out::ToolStart { id, title } => json!({
            "sessionUpdate": "tool_call",
            "toolCallId": id,
            "title": title,
            "kind": "other",
            "status": "in_progress"
        }),
        Out::ToolDone { id, text } => json!({
            "sessionUpdate": "tool_call_update",
            "toolCallId": id,
            "status": "completed",
            "content": [{"type": "content", "content": {"type": "text", "text": text}}]
        }),
    };
    let _ = tx.send(json!({
        "jsonrpc": "2.0",
        "method": "session/update",
        "params": {"sessionId": session, "update": update}
    }));
}

type Socket =
    tokio_tungstenite::WebSocketStream<tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>>;

/// Opens the chat's socket; the error code and text on failure.
async fn connect(endpoint: &Endpoint, token: &str) -> Result<Socket, (i64, String)> {
    let tab = uuid::Uuid::now_v7();
    let url = format!("{}/ws?tab={tab}&wire={WIRE}", endpoint.ws);
    let mut req = url.into_client_request().map_err(|e| (-32603, e.to_string()))?;
    req.headers_mut().insert(
        "authorization",
        format!("Bearer {token}").parse().map_err(|_| (AUTH_REQUIRED, endpoint.signed_out()))?,
    );
    match tokio::time::timeout(Duration::from_secs(20), tokio_tungstenite::connect_async(req)).await
    {
        Err(_) => Err((-32603, format!("UniiChat: {} did not answer in 20 s", endpoint.host))),
        Ok(Err(tokio_tungstenite::tungstenite::Error::Http(r)))
            if matches!(r.status().as_u16(), 401 | 403) =>
        {
            Err((AUTH_REQUIRED, endpoint.signed_out()))
        }
        Ok(Err(e)) => Err((-32603, format!("UniiChat: can't reach {}: {e}", endpoint.host))),
        Ok(Ok((ws, _))) => Ok(ws),
    }
}

/// Posts the `say` act; its answer (an error text, if refused).
async fn say(
    endpoint: &Endpoint,
    token: &str,
    act: &str,
    body: Vec<u8>,
    sizes: &str,
) -> Result<(), (i64, String)> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(120))
        .user_agent(concat!("acpmux-uniichat/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|e| (-32603, e.to_string()))?;
    let res = client
        .post(format!("{}/api/act?%24=say&sizes={sizes}&id={act}", endpoint.base))
        .bearer_auth(token)
        .body(body)
        .send()
        .await
        .map_err(|e| (-32603, format!("UniiChat: can't reach {}: {e}", endpoint.host)))?;
    let status = res.status().as_u16();
    if status == 401 {
        return Err((AUTH_REQUIRED, endpoint.signed_out()));
    }
    let answer: Value = res.json().await.unwrap_or(Value::Null);
    if let Some(e) = answer.get("error").and_then(Value::as_str) {
        return Err((-32603, format!("UniiChat refused the message: {e}")));
    }
    if !(200..300).contains(&status) {
        return Err((-32603, format!("UniiChat refused the message: HTTP {status}")));
    }
    Ok(())
}

/// Reads the socket until its first `state` (sent on join); that state's busy.
async fn joined(ws: &mut Socket, endpoint: &Endpoint) -> Result<bool, (i64, String)> {
    let deadline = tokio::time::Instant::now() + Duration::from_secs(20);
    loop {
        let next = tokio::time::timeout_at(deadline, ws.next())
            .await
            .map_err(|_| (-32603, format!("UniiChat: {} sent no chat in 20 s", endpoint.host)))?;
        match next {
            Some(Ok(Message::Text(t))) => {
                let Ok(v) = serde_json::from_str::<Value>(&t) else { continue };
                if v.get("$").and_then(Value::as_str) == Some("state") {
                    return Ok(v.get("busy").and_then(Value::as_bool).unwrap_or(false));
                }
            }
            Some(Ok(Message::Close(f))) => {
                let why = f.map(|f| f.reason.to_string()).unwrap_or_default();
                return Err((-32603, format!("UniiChat closed the chat: {why}")));
            }
            Some(Ok(_)) => {}
            Some(Err(e)) => return Err((-32603, format!("UniiChat: {e}"))),
            None => return Err((-32603, "UniiChat closed the chat".to_owned())),
        }
    }
}

/// Sends one prompt to the chat and streams the turn it starts.
async fn run_prompt(
    options: &Options,
    endpoint: &Endpoint,
    session: &str,
    blocks: &[Value],
    mut cancel: oneshot::Receiver<()>,
    tx: &Tx,
) -> Result<&'static str, (i64, String)> {
    let token = endpoint.token().map_err(|e| (AUTH_REQUIRED, e))?;
    let text = prompt_text(blocks, options.whole_prompt);
    let images = prompt_images(blocks);
    if text.trim().is_empty() && images.is_empty() {
        return Ok("end_turn");
    }
    let mut ws = connect(endpoint, &token).await?;
    let mut turn = Turn::new(joined(&mut ws, endpoint).await?);
    let act = uuid::Uuid::now_v7().to_string();
    let (body, sizes) = say_body(&text, &images);
    let post = say(endpoint, &token, &act, body, &sizes);
    tokio::pin!(post);
    let mut posted = false;
    let mut cancelled = false;
    let mut reconnects = 0u32;
    // UniiChat ticks every few seconds; a quiet socket is a lost one.
    let quiet = Duration::from_secs(30);
    // A message the chat took but never worked on (it joined a turn that
    // ended at once) ends the prompt after this long idle.
    let idle_end = Duration::from_secs(20);
    let mut idle_since: Option<tokio::time::Instant> = None;
    loop {
        if let Some(end) = turn.ended() {
            return match end {
                Ended::Done if cancelled => Ok("cancelled"),
                Ended::Done => Ok("end_turn"),
                Ended::Failed(_) if cancelled => Ok("cancelled"),
                Ended::Failed(e) => Err((-32603, e)),
            };
        }
        if posted && !turn.busy() {
            let since = *idle_since.get_or_insert_with(tokio::time::Instant::now);
            if since.elapsed() >= idle_end {
                return if cancelled { Ok("cancelled") } else { Ok("end_turn") };
            }
        } else {
            idle_since = None;
        }
        tokio::select! {
            answer = &mut post, if !posted => {
                answer?;
                posted = true;
                turn.taken();
            }
            Ok(()) = &mut cancel, if !cancelled => {
                cancelled = true;
                let stop = json!({"$": "stop", "id": uuid::Uuid::now_v7().to_string(), "name": TURN});
                let _ = ws.send(Message::Text(stop.to_string().into())).await;
                if !posted {
                    return Ok("cancelled");
                }
            }
            next = tokio::time::timeout(if cancelled { Duration::from_secs(5) } else { quiet }, ws.next()) => {
                match next {
                    Err(_) if cancelled => return Ok("cancelled"),
                    Ok(Some(Ok(Message::Text(t)))) => {
                        let Ok(v) = serde_json::from_str::<Value>(&t) else { continue };
                        for out in turn.hear(&v) {
                            send_out(tx, session, out);
                        }
                    }
                    Ok(Some(Ok(Message::Ping(p)))) => {
                        let _ = ws.send(Message::Pong(p)).await;
                    }
                    Ok(Some(Ok(_))) => {}
                    // Lost (quiet, closed, failed, or the chat moved to
                    // another process): the server keeps the turn, so join
                    // again and go on.
                    _ => {
                        reconnects += 1;
                        if reconnects > 5 {
                            return Err((-32603, format!("UniiChat: lost the chat with {} 5 times", endpoint.host)));
                        }
                        tokio::time::sleep(Duration::from_secs(1)).await; // UniiChat's own RETRY between sockets
                        ws = connect(endpoint, &token).await?;
                        let busy = joined(&mut ws, endpoint).await?;
                        turn.hear(&json!({"$": "state", "busy": busy}));
                    }
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn state(busy: bool) -> Value {
        json!({"$": "state", "busy": busy})
    }

    #[test]
    fn resolves_the_hosted_server_and_the_unii_token_file() {
        let e =
            Endpoint::resolve(&Options::default(), None, None, Some("/Users/me".into())).unwrap();
        assert_eq!(e.base, "https://uniichat.com");
        assert_eq!(e.ws, "wss://uniichat.com");
        assert_eq!(e.token_file, PathBuf::from("/Users/me/.unii/uniichat.com/token"));
    }

    #[test]
    fn resolves_a_self_hosted_server_with_its_port() {
        let e = Endpoint::resolve(
            &Options::default(),
            Some("http://127.0.0.1:8788/".into()),
            Some("/tmp/u".into()),
            None,
        )
        .unwrap();
        assert_eq!(e.base, "http://127.0.0.1:8788");
        assert_eq!(e.ws, "ws://127.0.0.1:8788");
        assert_eq!(e.token_file, PathBuf::from("/tmp/u/127.0.0.1:8788/token"));
        let flag = Options { url: Some("https://x.dev".into()), ..Options::default() };
        let e = Endpoint::resolve(&flag, Some("http://y".into()), None, Some("/h".into())).unwrap();
        assert_eq!(e.host, "x.dev");
        assert!(
            Endpoint::resolve(
                &Options { url: Some("ftp://x".into()), ..Options::default() },
                None,
                None,
                Some("/h".into())
            )
            .is_err()
        );
    }

    #[test]
    fn a_missing_sign_in_says_how_to_set_up() {
        let e =
            Endpoint::resolve(&Options::default(), None, Some("/nonexistent-unii".into()), None)
                .unwrap();
        let err = e.token().unwrap_err();
        assert!(err.contains("not signed in to uniichat.com"), "{err}");
        assert!(err.contains("unii login"), "{err}");
        assert!(err.contains("install.sh"), "{err}");
    }

    #[test]
    fn sends_the_last_text_block_unless_whole() {
        let blocks = vec![
            json!({"type": "text", "text": "view "}),
            json!({"type": "image", "data": "aGk=", "mimeType": "image/png"}),
            json!({"type": "text", "text": "new"}),
        ];
        assert_eq!(prompt_text(&blocks, false), "new");
        assert_eq!(prompt_text(&blocks, true), "view new");
        assert_eq!(prompt_images(&blocks), vec![b"hi".to_vec()]);
        let (body, sizes) = say_body("new", &prompt_images(&blocks));
        assert_eq!(body, b"hinew");
        assert_eq!(sizes, "2");
        assert_eq!(say_body("x", &[]).1, "");
    }

    /// A huge paste in cmux's composer goes as its own text block after the
    /// typed one (`_meta.cmux.pasted`): the message is the typed text and
    /// every paste, a blank line between them, never the paste alone.
    #[test]
    fn a_pasted_block_goes_with_the_typed_text() {
        let pasted =
            |text: &str| json!({"type": "text", "text": text, "_meta": {"cmux": {"pasted": true}}});
        let blocks = vec![
            json!({"type": "text", "text": "view "}),
            json!({"type": "text", "text": "why does this fail?"}),
            pasted("the log"),
        ];
        assert_eq!(prompt_text(&blocks, false), "why does this fail?\n\nthe log");
        assert_eq!(prompt_text(&blocks, true), "view why does this fail?\n\nthe log");
        assert_eq!(prompt_text(&[pasted("only a paste")], false), "only a paste");
    }

    #[test]
    fn streams_deltas_once_and_ends_when_idle() {
        let mut t = Turn::new(false);
        t.hear(&state(true));
        t.taken();
        assert_eq!(
            t.hear(&json!({"$": "delta", "kind": "mind", "text": "hm"})),
            vec![Out::Thought("hm".into())]
        );
        assert_eq!(
            t.hear(&json!({"$": "delta", "kind": "unii", "text": "Hel"})),
            vec![Out::Message("Hel".into())]
        );
        assert_eq!(
            t.hear(&json!({"$": "delta", "kind": "unii", "text": "lo"})),
            vec![Out::Message("lo".into())]
        );
        // The logged entry repeats what streamed: nothing new goes out.
        assert_eq!(
            t.hear(&json!({"$": "entry", "id": 9, "kind": "unii", "text": "Hello"})),
            vec![]
        );
        assert_eq!(t.ended(), None);
        t.hear(&state(false));
        assert_eq!(t.ended(), Some(Ended::Done));
    }

    #[test]
    fn an_entry_never_streamed_goes_out_whole() {
        let mut t = Turn::new(false);
        t.taken();
        t.hear(&state(true));
        assert_eq!(
            t.hear(&json!({"$": "entry", "kind": "unii", "text": "Hi"})),
            vec![Out::Message("Hi".into())]
        );
        // A second message of the same turn, after a blank line.
        assert_eq!(
            t.hear(&json!({"$": "delta", "kind": "unii", "text": "More", "fresh": true})),
            vec![Out::Message("\n\nMore".into())]
        );
    }

    #[test]
    fn tool_calls_show_and_complete() {
        let mut t = Turn::new(false);
        t.taken();
        assert_eq!(
            t.hear(&json!({"$": "entry", "kind": "tool", "text": "shell: ls\nmore"})),
            vec![Out::ToolStart { id: "unii-tool-1".into(), title: "shell: ls".into() }]
        );
        assert_eq!(
            t.hear(&json!({"$": "entry", "kind": "echo", "text": "a b"})),
            vec![Out::ToolDone { id: "unii-tool-1".into(), text: "a b".into() }]
        );
    }

    #[test]
    fn a_turn_with_only_a_note_fails_with_it() {
        let mut t = Turn::new(false);
        t.taken();
        t.hear(&state(true));
        t.hear(&json!({"$": "entry", "kind": "note", "text": "out of credit"}));
        t.hear(&state(false));
        assert_eq!(t.ended(), Some(Ended::Failed("UniiChat: out of credit".into())));
    }

    #[test]
    fn subagent_events_and_a_busy_chat_before_the_message_do_not_end_the_turn() {
        let mut t = Turn::new(true);
        assert_eq!(
            t.hear(&json!({"$": "delta", "agent": "a1", "kind": "unii", "text": "x"})),
            vec![]
        );
        t.hear(&state(false));
        // Not taken yet: an earlier turn ending is not this one.
        assert_eq!(t.ended(), None);
        t.taken();
        // Taken while idle and nothing ran yet: still waiting.
        assert_eq!(t.ended(), None);
        t.hear(&state(true));
        t.hear(&state(false));
        assert_eq!(t.ended(), Some(Ended::Done));
    }

    #[test]
    fn a_rejoin_sends_only_what_went_past_the_stream() {
        let mut t = Turn::new(false);
        t.taken();
        t.hear(&state(true));
        t.hear(&json!({"$": "delta", "kind": "unii", "text": "Hel"}));
        let live = json!({"$": "live", "live": [{"kind": "unii", "text": "Hello"}]});
        assert_eq!(t.hear(&live), vec![Out::Message("lo".into())]);
        assert_eq!(t.hear(&live), vec![]);
    }
}
