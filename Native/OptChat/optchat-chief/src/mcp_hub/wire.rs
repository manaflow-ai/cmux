//! The two MCP transports the hub speaks: a local process (stdio,
//! newline-delimited JSON-RPC) and Streamable HTTP (JSON or an SSE stream per
//! POST, plus one long-lived stream for server-pushed notifications). A
//! message that is not the answer to a request (a notification, or a request
//! from the server) goes to the `OnMessage` handler; a server request is
//! answered here (`ping`, an empty `roots/list`, else "method not found").

use std::collections::HashMap;
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{Child, ChildStdin, Command, Stdio as PipeMode};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{Sender, channel};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

/// Where notifications and server requests go.
pub type OnMessage = Arc<dyn Fn(Value) + Send + Sync>;

/// The headers each HTTP request carries (auth is read fresh every time, so
/// a refreshed token is used at once).
pub type Headers = Arc<dyn Fn() -> Vec<(String, String)> + Send + Sync>;

/// The largest message the hub reads (a tool result past it is an error).
pub const MAX_MESSAGE_BYTES: usize = 8 << 20;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum WireError {
    /// HTTP 401: the `WWW-Authenticate` header (maybe empty).
    Auth(String),
    /// The server forgot the session (HTTP 404 with a session id): connect again.
    Gone,
    Timeout,
    Other(String),
}

impl std::fmt::Display for WireError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            WireError::Auth(_) => f.write_str("the server needs a sign-in (HTTP 401)"),
            WireError::Gone => f.write_str("the server ended the session"),
            WireError::Timeout => f.write_str("the server did not answer in time"),
            WireError::Other(e) => f.write_str(e),
        }
    }
}

pub trait Wire: Send + Sync {
    /// Sends a JSON-RPC request and answers the server's response message.
    fn request(&self, msg: &Value, timeout: Duration) -> Result<Value, WireError>;
    /// Sends a notification or a response.
    fn notify(&self, msg: &Value) -> Result<(), WireError>;
    /// Holds the server-push stream open until it ends (HTTP: a GET, or the
    /// POST of `open`, a 2026 `subscriptions/listen`). Stdio has one channel
    /// for everything: `open` is just sent and this returns at once.
    fn stream(&self, open: Option<&Value>) -> Result<(), WireError>;
    fn alive(&self) -> bool;
    fn close(&self);
    fn is_stdio(&self) -> bool;
    /// Sets the `MCP-Protocol-Version` header (HTTP) after the handshake.
    fn set_protocol(&self, _version: &str) {}
}

fn id_key(v: &Value) -> String {
    v.get("id").map(Value::to_string).unwrap_or_default()
}

fn is_response(v: &Value) -> bool {
    v.get("method").is_none() && (v.get("result").is_some() || v.get("error").is_some())
}

/// The answer to a request the server sent the client.
pub fn answer_server_request(v: &Value) -> Value {
    let id = v.get("id").cloned().unwrap_or(Value::Null);
    match v.get("method").and_then(Value::as_str).unwrap_or("") {
        "ping" => json!({"jsonrpc": "2.0", "id": id, "result": {}}),
        "roots/list" => json!({"jsonrpc": "2.0", "id": id, "result": {"roots": []}}),
        m => json!({"jsonrpc": "2.0", "id": id,
            "error": {"code": -32601, "message": format!("cmux Chief does not serve {m}")}}),
    }
}

// ---- stdio ----

type Pending = Arc<Mutex<HashMap<String, Sender<Value>>>>;

/// A local server process. Dropping it ends the process group it started.
pub struct StdioWire {
    child: Mutex<Child>,
    stdin: Arc<Mutex<ChildStdin>>,
    pending: Pending,
    alive: Arc<AtomicBool>,
}

impl StdioWire {
    pub fn start(
        command: &str,
        args: &[String],
        env: &[(String, String)],
        cwd: Option<&str>,
        log: &Path,
        on_message: OnMessage,
    ) -> Result<Self, WireError> {
        if let Some(dir) = log.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        let stderr = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(log)
            .map(PipeMode::from)
            .unwrap_or_else(|_| PipeMode::null());
        let mut cmd = Command::new(command);
        cmd.args(args)
            .envs(env.iter().map(|(k, v)| (k, v)))
            .stdin(PipeMode::piped())
            .stdout(PipeMode::piped())
            .stderr(stderr)
            .process_group(0);
        if let Some(dir) = cwd {
            cmd.current_dir(dir);
        }
        let mut child = cmd
            .spawn()
            .map_err(|e| WireError::Other(format!("could not start `{command}`: {e}")))?;
        let stdin = Arc::new(Mutex::new(child.stdin.take().expect("piped stdin")));
        let stdout = child.stdout.take().expect("piped stdout");
        let pending: Pending = Arc::default();
        let alive = Arc::new(AtomicBool::new(true));
        {
            let (pending, alive, stdin) = (pending.clone(), alive.clone(), stdin.clone());
            std::thread::Builder::new()
                .name("mcp-stdio".into())
                .spawn(move || {
                    let mut reader = BufReader::new(stdout);
                    let mut line = String::new();
                    loop {
                        line.clear();
                        match reader.read_line(&mut line) {
                            Ok(0) | Err(_) => break,
                            Ok(_) => {}
                        }
                        if line.len() > MAX_MESSAGE_BYTES {
                            continue;
                        }
                        let Ok(v) = serde_json::from_str::<Value>(line.trim()) else {
                            continue;
                        };
                        if is_response(&v) {
                            if let Some(tx) = pending.lock().unwrap().remove(&id_key(&v)) {
                                let _ = tx.send(v);
                            }
                        } else if v.get("id").is_some() && v.get("method").is_some() {
                            let answer = answer_server_request(&v);
                            let _ = writeln!(stdin.lock().unwrap(), "{answer}");
                        } else {
                            on_message(v);
                        }
                    }
                    alive.store(false, Ordering::SeqCst);
                    // Wake every waiter: the process is gone.
                    pending.lock().unwrap().clear();
                })
                .map_err(|e| WireError::Other(e.to_string()))?;
        }
        Ok(Self {
            child: Mutex::new(child),
            stdin,
            pending,
            alive,
        })
    }

    fn write(&self, msg: &Value) -> Result<(), WireError> {
        let mut stdin = self.stdin.lock().unwrap();
        writeln!(stdin, "{msg}")
            .and_then(|()| stdin.flush())
            .map_err(|e| WireError::Other(format!("the server process closed its input: {e}")))
    }
}

impl Wire for StdioWire {
    fn request(&self, msg: &Value, timeout: Duration) -> Result<Value, WireError> {
        let (tx, rx) = channel();
        let key = id_key(msg);
        self.pending.lock().unwrap().insert(key.clone(), tx);
        if let Err(e) = self.write(msg) {
            self.pending.lock().unwrap().remove(&key);
            return Err(e);
        }
        match rx.recv_timeout(timeout) {
            Ok(v) => Ok(v),
            Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {
                self.pending.lock().unwrap().remove(&key);
                Err(WireError::Timeout)
            }
            Err(_) => Err(WireError::Other("the server process exited".into())),
        }
    }

    fn notify(&self, msg: &Value) -> Result<(), WireError> {
        self.write(msg)
    }

    fn stream(&self, open: Option<&Value>) -> Result<(), WireError> {
        match open {
            Some(msg) => self.write(msg),
            None => Ok(()),
        }
    }

    fn alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    fn close(&self) {
        let mut child = self.child.lock().unwrap();
        // The group this wire started (process_group(0) above), never another.
        unsafe {
            libc::kill(-(child.id() as i32), libc::SIGTERM);
        }
        let _ = child.kill();
        let _ = child.wait();
        self.alive.store(false, Ordering::SeqCst);
    }

    fn is_stdio(&self) -> bool {
        true
    }
}

impl Drop for StdioWire {
    fn drop(&mut self) {
        if self.alive() {
            self.close();
        }
    }
}

// ---- Streamable HTTP ----

pub struct HttpWire {
    url: String,
    agent: ureq::Agent,
    stream_agent: ureq::Agent,
    headers: Headers,
    session: Mutex<Option<String>>,
    protocol: Mutex<Option<String>>,
    on_message: OnMessage,
    alive: Arc<AtomicBool>,
}

impl HttpWire {
    pub fn new(url: &str, headers: Headers, on_message: OnMessage) -> Self {
        let agent = ureq::AgentBuilder::new()
            .redirects(0)
            .timeout_connect(Duration::from_secs(15))
            .build();
        let stream_agent = ureq::AgentBuilder::new()
            .redirects(0)
            .timeout_connect(Duration::from_secs(15))
            .build();
        Self {
            url: url.to_owned(),
            agent,
            stream_agent,
            headers,
            session: Mutex::new(None),
            protocol: Mutex::new(None),
            on_message,
            alive: Arc::new(AtomicBool::new(true)),
        }
    }

    fn prepare(&self, req: ureq::Request, msg: Option<&Value>) -> ureq::Request {
        let mut req = req;
        for (k, v) in (self.headers)() {
            req = req.set(&k, &v);
        }
        if let Some(s) = self.session.lock().unwrap().as_deref() {
            req = req.set("Mcp-Session-Id", s);
        }
        if let Some(p) = self.protocol.lock().unwrap().as_deref() {
            req = req.set("MCP-Protocol-Version", p);
        }
        if let Some(msg) = msg {
            if let Some(m) = msg.get("method").and_then(Value::as_str) {
                req = req.set("Mcp-Method", m);
            }
            let p = &msg["params"];
            if let Some(n) = p["name"].as_str().or_else(|| p["uri"].as_str()) {
                req = req.set("Mcp-Name", n);
            }
        }
        req
    }

    fn post(
        &self,
        agent: &ureq::Agent,
        msg: &Value,
        timeout: Option<Duration>,
    ) -> Result<ureq::Response, WireError> {
        let mut req = self
            .prepare(agent.post(&self.url), Some(msg))
            .set("Content-Type", "application/json")
            .set("Accept", "application/json, text/event-stream");
        if let Some(t) = timeout {
            req = req.timeout(t);
        }
        let resp = req
            .send_string(&msg.to_string())
            .map_err(|e| self.error(e))?;
        self.after(&resp)?;
        Ok(resp)
    }

    fn after(&self, resp: &ureq::Response) -> Result<(), WireError> {
        if (300..400).contains(&resp.status()) {
            return Err(WireError::Other(format!(
                "the server redirects to {}; add that URL instead",
                resp.header("location").unwrap_or("another address")
            )));
        }
        if let Some(s) = resp.header("mcp-session-id") {
            *self.session.lock().unwrap() = Some(s.to_owned());
        }
        Ok(())
    }

    fn error(&self, e: ureq::Error) -> WireError {
        match e {
            ureq::Error::Status(401, resp) => {
                WireError::Auth(resp.header("www-authenticate").unwrap_or("").to_owned())
            }
            ureq::Error::Status(404, _) if self.session.lock().unwrap().is_some() => {
                *self.session.lock().unwrap() = None;
                WireError::Gone
            }
            ureq::Error::Status(code, resp) => {
                let mut body = String::new();
                let _ = resp.into_reader().take(400).read_to_string(&mut body);
                WireError::Other(format!("HTTP {code}: {}", body.trim()))
            }
            ureq::Error::Transport(t) => {
                if t.to_string().contains("timed out") {
                    WireError::Timeout
                } else {
                    WireError::Other(crate::mcp_hub::redact(&t.to_string()))
                }
            }
        }
    }

    /// Reads one response body: JSON, or an SSE stream until the answer to
    /// `want` (None: until the stream ends, every message to the handler).
    fn read_body(&self, resp: ureq::Response, want: Option<&str>) -> Result<Value, WireError> {
        let json_body = resp
            .header("content-type")
            .is_some_and(|c| c.contains("application/json"));
        let reader = resp.into_reader().take(MAX_MESSAGE_BYTES as u64 + 1);
        if json_body {
            let v: Value = serde_json::from_reader(reader)
                .map_err(|e| WireError::Other(format!("the server sent bad JSON: {e}")))?;
            // A batch is not sent by any server we know; take its answer.
            if let Value::Array(items) = v {
                for item in items {
                    if is_response(&item) && Some(id_key(&item).as_str()) == want {
                        return Ok(item);
                    }
                    self.dispatch(item);
                }
                return Err(WireError::Other("no answer in the batch".into()));
            }
            return Ok(v);
        }
        let mut data = String::new();
        for line in BufReader::new(reader).lines() {
            let line = line.map_err(|e| WireError::Other(format!("the stream broke: {e}")))?;
            if line.is_empty() {
                if !data.is_empty() {
                    let event = std::mem::take(&mut data);
                    if let Ok(v) = serde_json::from_str::<Value>(&event) {
                        if is_response(&v) && want.is_some_and(|w| id_key(&v) == w) {
                            return Ok(v);
                        }
                        self.dispatch(v);
                    }
                }
                continue;
            }
            if let Some(rest) = line.strip_prefix("data:") {
                if !data.is_empty() {
                    data.push('\n');
                }
                data.push_str(rest.strip_prefix(' ').unwrap_or(rest));
            }
            if !self.alive() {
                break;
            }
        }
        match want {
            Some(_) => Err(WireError::Other("the stream ended with no answer".into())),
            None => Ok(Value::Null),
        }
    }

    fn dispatch(&self, v: Value) {
        if v.get("id").is_some() && v.get("method").is_some() {
            let _ = self.notify(&answer_server_request(&v));
        } else if !is_response(&v) {
            (self.on_message)(v);
        } else {
            // The closing answer of a long-lived stream request.
            (self.on_message)(json!({"method": "cmux/stream_closed", "params": v}));
        }
    }
}

impl Wire for HttpWire {
    fn request(&self, msg: &Value, timeout: Duration) -> Result<Value, WireError> {
        let resp = self.post(&self.agent, msg, Some(timeout))?;
        if resp.status() == 202 {
            return Err(WireError::Other(
                "the server accepted the request but sent no answer".into(),
            ));
        }
        self.read_body(resp, Some(&id_key(msg)))
    }

    fn notify(&self, msg: &Value) -> Result<(), WireError> {
        self.post(&self.agent, msg, Some(Duration::from_secs(30)))
            .map(|_| ())
    }

    fn stream(&self, open: Option<&Value>) -> Result<(), WireError> {
        let resp = match open {
            Some(msg) => self.post(&self.stream_agent, msg, None)?,
            None => {
                let resp = self
                    .prepare(self.stream_agent.get(&self.url), None)
                    .set("Accept", "text/event-stream")
                    .call()
                    .map_err(|e| self.error(e))?;
                self.after(&resp)?;
                resp
            }
        };
        if !resp
            .header("content-type")
            .is_some_and(|c| c.contains("text/event-stream"))
        {
            return Err(WireError::Other("the server offers no event stream".into()));
        }
        self.read_body(resp, None).map(|_| ())
    }

    fn alive(&self) -> bool {
        self.alive.load(Ordering::SeqCst)
    }

    fn close(&self) {
        self.alive.store(false, Ordering::SeqCst);
        let session = self.session.lock().unwrap().take();
        if let Some(s) = session {
            // Ends the server's session (spec: DELETE with the session id).
            let mut req = self.agent.delete(&self.url).set("Mcp-Session-Id", &s);
            for (k, v) in (self.headers)() {
                req = req.set(&k, &v);
            }
            let _ = req.timeout(Duration::from_secs(5)).call();
        }
    }

    fn is_stdio(&self) -> bool {
        false
    }

    fn set_protocol(&self, version: &str) {
        *self.protocol.lock().unwrap() = Some(version.to_owned());
    }
}
