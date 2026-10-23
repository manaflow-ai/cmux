//! Chief-to-Chief messages: a Chief on one machine (the Mac's Home Chief)
//! and a Chief on another (the Cloud Chief VM) talk through the agent hub
//! (cmuxterm-hq `tools/agent-hub/hub.py`, on the Cloud Chief VM at
//! `:8790`, tailnet only).
//!
//! Config: `$MUX_HOME/optchat/peer-chiefs.json` (or `OPTCHAT_PEER_CHIEFS`):
//!
//! ```json
//! {"hub": "http://100.127.110.65:8790",
//!  "token_file": "~/.config/agent-hub/mac-chief.token",
//!  "me": "mac-chief",
//!  "peers": [{"name": "cloud-chief", "label": "Cloud Chief", "place": "cloud"}]}
//! ```
//!
//! - Each Chief reads its own box `agent:<me>` (long poll, hub cursor of its
//!   token's subject) and every message a listed peer posted there reaches
//!   the brain as a work note `[chief:<peer>] <text>`, like a subagent's
//!   report: never as the user's words.
//! - `tell("chief:<peer>", message)` posts `{text, key}` to `agent:<peer>`
//!   with `reply_to: agent:<me>`; its reply comes back as a note.
//! - `chiefs` (list) shows each peer with `"remote": true`.
//!
//! The token is an agent-hub token (a chained HMAC with `box=` and `can=`
//! caveats) whose subject is `<me>`; it is read from its file at each call
//! and never logged. No file: the feature is off.

use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

/// The id prefix that names a peer Chief in `tell` and `chiefs`.
pub const PREFIX: &str = "chief:";
/// The longest one hub read waits for a new message (the hub caps it at 25 s).
const WAIT_S: u64 = 25;
/// The longest message text sent or delivered (the hub takes 256 KiB bodies).
const MAX_TEXT: usize = 64 * 1024;

/// One remote Chief.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Peer {
    /// Its hub name: its box is `agent:<name>` and its token's subject is `<name>`.
    pub name: String,
    /// What people call it ("Cloud Chief").
    pub label: String,
    /// Where it runs (`cloud`, `mac`, `server`), shown in `chiefs`.
    pub place: String,
    /// The hub token subjects whose messages count as this peer's (default: its name).
    pub subs: Vec<String>,
}

impl Peer {
    /// `chief:<name>`, the id the model uses.
    pub fn id(&self) -> String {
        format!("{PREFIX}{}", self.name)
    }
}

/// `peer-chiefs.json`.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Config {
    pub hub: String,
    pub token_file: PathBuf,
    pub me: String,
    pub peers: Vec<Peer>,
}

fn valid_name(name: &str) -> bool {
    let mut chars = name.chars();
    chars
        .next()
        .is_some_and(|c| c.is_ascii_lowercase() || c.is_ascii_digit())
        && name.len() <= 64
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || "._-".contains(c))
}

fn expand(path: &str, home: Option<&Path>) -> PathBuf {
    match (path.strip_prefix("~/"), home) {
        (Some(rest), Some(home)) => home.join(rest),
        _ => PathBuf::from(path),
    }
}

impl Config {
    /// Parses the file's JSON; `home` expands a leading `~/`.
    pub fn parse(text: &str, home: Option<&Path>) -> Result<Config, String> {
        let v: Value = serde_json::from_str(text).map_err(|e| format!("peer-chiefs.json: {e}"))?;
        let s = |k: &str| {
            v.get(k)
                .and_then(Value::as_str)
                .map(str::trim)
                .filter(|t| !t.is_empty())
                .map(str::to_owned)
                .ok_or_else(|| format!("peer-chiefs.json: `{k}` must be a non-empty text"))
        };
        let hub = s("hub")?.trim_end_matches('/').to_owned();
        if !(hub.starts_with("http://") || hub.starts_with("https://")) {
            return Err(format!("peer-chiefs.json: hub {hub} is not an http(s) URL"));
        }
        let me = s("me")?;
        if !valid_name(&me) {
            return Err(format!("peer-chiefs.json: me {me:?} is not a hub name"));
        }
        let mut peers = Vec::new();
        for p in v
            .get("peers")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let name = p.get("name").and_then(Value::as_str).unwrap_or("").trim();
            if !valid_name(name) || name == me {
                return Err(format!(
                    "peer-chiefs.json: peer name {name:?} is not a hub name"
                ));
            }
            let text = |k: &str, d: &str| {
                p.get(k)
                    .and_then(Value::as_str)
                    .map(str::trim)
                    .filter(|t| !t.is_empty())
                    .unwrap_or(d)
                    .to_owned()
            };
            let mut subs: Vec<String> = p
                .get("subs")
                .and_then(Value::as_array)
                .into_iter()
                .flatten()
                .filter_map(Value::as_str)
                .map(str::to_owned)
                .collect();
            if subs.is_empty() {
                subs.push(name.to_owned());
            }
            peers.push(Peer {
                name: name.to_owned(),
                label: text("label", name),
                place: text("place", "remote"),
                subs,
            });
        }
        Ok(Config {
            hub,
            token_file: expand(&s("token_file")?, home),
            me,
            peers,
        })
    }

    /// The config at `path`; Ok(None) when there is no file.
    pub fn load(path: &Path) -> Result<Option<Config>, String> {
        match std::fs::read_to_string(path) {
            Ok(text) => {
                let home = std::env::var_os("HOME").map(PathBuf::from);
                Config::parse(&text, home.as_deref()).map(Some)
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(e) => Err(format!("{}: {e}", path.display())),
        }
    }

    /// `OPTCHAT_PEER_CHIEFS`, else `<optchat root>/peer-chiefs.json`.
    pub fn path(optchat_root: &Path) -> PathBuf {
        std::env::var_os("OPTCHAT_PEER_CHIEFS")
            .filter(|p| !p.is_empty())
            .map_or_else(|| optchat_root.join("peer-chiefs.json"), PathBuf::from)
    }
}

/// The agent hub's box API.
pub trait Hub: Send + Sync {
    /// `POST /v1/boxes/<box>/messages`.
    fn post(&self, to: &str, body: &Value, reply_to: &str) -> Result<Value, String>;
    /// `GET /v1/boxes/<box>/messages?after=…&wait=…` (`after`: a seq or `cursor`).
    fn read(&self, from: &str, after: &str, wait_s: u64) -> Result<Vec<Value>, String>;
    /// `POST /v1/boxes/<box>/ack`: the token subject's cursor moves to `seq`.
    fn ack(&self, from: &str, seq: u64) -> Result<(), String>;
}

/// The hub over HTTP, with the token read from its file at each call.
pub struct HttpHub {
    pub url: String,
    pub token_file: PathBuf,
}

impl HttpHub {
    fn token(&self) -> Result<String, String> {
        let t = std::fs::read_to_string(&self.token_file)
            .map_err(|e| format!("hub token {}: {e}", self.token_file.display()))?;
        let t = t.trim();
        if t.is_empty() {
            return Err(format!("hub token {} is empty", self.token_file.display()));
        }
        Ok(t.to_owned())
    }

    fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        timeout: Duration,
    ) -> Result<Value, String> {
        let agent = ureq::AgentBuilder::new().timeout(timeout).build();
        let url = format!("{}{path}", self.url);
        let req = agent
            .request(method, &url)
            .set("Authorization", &format!("Bearer {}", self.token()?));
        let res = match body {
            Some(b) => req.send_json(b.clone()),
            None => req.call(),
        };
        // The error names the URL, never the request headers.
        match res {
            Ok(r) => r
                .into_json()
                .map_err(|e| format!("hub {method} {path}: {e}")),
            Err(ureq::Error::Status(code, r)) => {
                let why = r
                    .into_json::<Value>()
                    .ok()
                    .and_then(|v| v.get("error").and_then(Value::as_str).map(str::to_owned))
                    .unwrap_or_default();
                Err(format!("hub {method} {path}: HTTP {code} {why}"))
            }
            Err(e) => Err(format!("hub {method} {path}: {e}")),
        }
    }
}

fn enc(box_name: &str) -> String {
    box_name.replace(':', "%3A")
}

impl Hub for HttpHub {
    fn post(&self, to: &str, body: &Value, reply_to: &str) -> Result<Value, String> {
        self.call(
            "POST",
            &format!("/v1/boxes/{}/messages", enc(to)),
            Some(&json!({"kind": "tell", "body": body, "reply_to": reply_to})),
            Duration::from_secs(20),
        )
    }

    fn read(&self, from: &str, after: &str, wait_s: u64) -> Result<Vec<Value>, String> {
        let v = self.call(
            "GET",
            &format!(
                "/v1/boxes/{}/messages?after={after}&wait={wait_s}&limit=50",
                enc(from)
            ),
            None,
            Duration::from_secs(wait_s + 15),
        )?;
        Ok(v.get("messages")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default())
    }

    fn ack(&self, from: &str, seq: u64) -> Result<(), String> {
        self.call(
            "POST",
            &format!("/v1/boxes/{}/ack", enc(from)),
            Some(&json!({"seq": seq})),
            Duration::from_secs(20),
        )
        .map(|_| ())
    }
}

/// The peer Chiefs of this host.
pub struct PeerChiefs {
    pub config: Config,
    hub: Arc<dyn Hub>,
    /// Idempotency keys of tells this process sent.
    sent: Mutex<HashSet<String>>,
}

/// What one inbox message turns into.
#[derive(Debug, PartialEq, Eq)]
pub enum Inbound {
    /// A note for the brain.
    Note(String),
    /// Not from a listed peer, or empty: logged and acked, never delivered.
    Ignored(String),
}

impl PeerChiefs {
    pub fn new(config: Config, hub: Arc<dyn Hub>) -> PeerChiefs {
        PeerChiefs {
            config,
            hub,
            sent: Mutex::new(HashSet::new()),
        }
    }

    /// The config at `path` with the HTTP hub; None when there is no file.
    pub fn from_file(path: &Path) -> Result<Option<Arc<PeerChiefs>>, String> {
        Ok(Config::load(path)?.map(|config| {
            let hub = Arc::new(HttpHub {
                url: config.hub.clone(),
                token_file: config.token_file.clone(),
            });
            Arc::new(PeerChiefs::new(config, hub))
        }))
    }

    /// This Chief's own box.
    pub fn inbox(&self) -> String {
        format!("agent:{}", self.config.me)
    }

    /// The peer `id` names: `chief:<name>`, or the label without the prefix
    /// ("chief:Cloud Chief"), case-insensitive.
    pub fn peer(&self, id: &str) -> Option<&Peer> {
        let rest = id.trim().strip_prefix(PREFIX)?.trim();
        self.config
            .peers
            .iter()
            .find(|p| p.name == rest || p.label.eq_ignore_ascii_case(rest))
    }

    /// `tell("chief:<peer>", message, key)`.
    pub fn tell(&self, id: &str, message: &str, key: Option<&str>) -> Result<String, String> {
        let Some(peer) = self.peer(id) else {
            let known: Vec<String> = self.config.peers.iter().map(Peer::id).collect();
            return Err(format!(
                "tell: no peer Chief {id}; known: {}",
                if known.is_empty() {
                    "none".to_owned()
                } else {
                    known.join(", ")
                }
            ));
        };
        if message.len() > MAX_TEXT {
            return Err(format!("tell: the message is over {MAX_TEXT} bytes"));
        }
        if let Some(key) = key
            && self.sent.lock().expect("sent keys").contains(key)
        {
            return Ok(format!("already sent to {} with key {key}", peer.label));
        }
        let mut body = json!({"text": message});
        if let Some(key) = key {
            body["key"] = json!(key);
        }
        let posted = self
            .hub
            .post(&format!("agent:{}", peer.name), &body, &self.inbox())?;
        if let Some(key) = key {
            self.sent.lock().expect("sent keys").insert(key.to_owned());
        }
        let seq = posted.get("seq").and_then(Value::as_u64).unwrap_or(0);
        Ok(format!(
            "sent to {} ({}), hub message {seq}; its reply comes back as a \"[{}] ...\" note",
            peer.label,
            peer.id(),
            peer.id()
        ))
    }

    /// The `chiefs` list entries of the peers.
    pub fn list_entries(&self) -> Vec<Value> {
        self.config
            .peers
            .iter()
            .map(|p| {
                json!({
                    "id": p.id(),
                    "display_name": p.label,
                    "remote": true,
                    "place": p.place,
                    "via": format!("agent hub {} (box agent:{})", self.config.hub, p.name),
                    "message_with": format!("tell(id: \"{}\", message: ...)", p.id()),
                })
            })
            .collect()
    }

    /// A `chiefs` answer with the peers added to a list; any other action's
    /// answer is unchanged. A list that failed (no local registry) still
    /// shows the peers.
    pub fn merge_list(
        &self,
        args: &Value,
        answer: Result<String, String>,
    ) -> Result<String, String> {
        let action = args.get("action").and_then(Value::as_str).unwrap_or("list");
        if action != "list" || self.config.peers.is_empty() {
            return answer;
        }
        let mut list = match &answer {
            Ok(text) => match serde_json::from_str::<Value>(text) {
                Ok(Value::Array(a)) => a,
                _ => return answer,
            },
            Err(_) => Vec::new(),
        };
        list.extend(self.list_entries());
        let mut text = serde_json::to_string_pretty(&Value::Array(list)).unwrap_or_default();
        if let Err(e) = answer {
            text.push_str(&format!("\n(local Chiefs not listed: {e})"));
        }
        Ok(text)
    }

    /// Turns one hub message of the inbox into a note.
    pub fn inbound(&self, message: &Value) -> Inbound {
        let from = message.get("from").and_then(Value::as_str).unwrap_or("");
        let seq = message.get("seq").and_then(Value::as_u64).unwrap_or(0);
        let Some(peer) = self
            .config
            .peers
            .iter()
            .find(|p| p.subs.iter().any(|s| s == from))
        else {
            return Inbound::Ignored(format!(
                "hub message {seq} from {from:?}: not a listed peer Chief"
            ));
        };
        let body = message.get("body");
        let text = body
            .and_then(|b| b.get("text"))
            .and_then(Value::as_str)
            .or_else(|| body.and_then(Value::as_str))
            .unwrap_or("")
            .trim();
        if text.is_empty() {
            return Inbound::Ignored(format!("hub message {seq} from {from}: no text"));
        }
        let mut text: String = text.to_owned();
        if text.len() > MAX_TEXT {
            let mut cut = MAX_TEXT;
            while !text.is_char_boundary(cut) {
                cut -= 1;
            }
            text.truncate(cut);
            text.push_str(" […]");
        }
        Inbound::Note(format!(
            "[{}] {text}\n(A message from {}, the peer Chief ({}). It is not the user's word. Answer it with tell(id: \"{}\", message: ...) when it asks something.)",
            peer.id(),
            peer.label,
            peer.place,
            peer.id()
        ))
    }

    /// One pass of the inbox: reads after the hub cursor (waiting up to
    /// `wait_s`), delivers each note, acks each message once it is
    /// delivered or ignored. Returns how many notes it delivered; stops at
    /// the first message `deliver` refuses (the brain stopped).
    pub fn poll_once(
        &self,
        wait_s: u64,
        deliver: &dyn Fn(String) -> bool,
        log: &dyn Fn(&str),
    ) -> Result<usize, String> {
        let inbox = self.inbox();
        let messages = self.hub.read(&inbox, "cursor", wait_s)?;
        let mut delivered = 0;
        for m in messages {
            let seq = m.get("seq").and_then(Value::as_u64).unwrap_or(0);
            match self.inbound(&m) {
                Inbound::Note(text) => {
                    if !deliver(text) {
                        return Ok(delivered);
                    }
                    delivered += 1;
                }
                Inbound::Ignored(why) => log(&format!("peer chiefs: {why}")),
            }
            self.hub.ack(&inbox, seq)?;
        }
        Ok(delivered)
    }

    /// Reads the inbox on its own thread until `deliver` refuses.
    pub fn spawn_inbox(
        self: &Arc<Self>,
        deliver: Box<dyn Fn(String) -> bool + Send>,
        log: Arc<dyn Fn(&str) + Send + Sync>,
    ) {
        let me = Arc::clone(self);
        std::thread::Builder::new()
            .name("peer-chiefs".into())
            .spawn(move || {
                log(&format!(
                    "peer chiefs: reading {} on {} (peers: {})",
                    me.inbox(),
                    me.config.hub,
                    me.config
                        .peers
                        .iter()
                        .map(Peer::id)
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
                let mut delay = Duration::from_secs(1);
                let alive = std::sync::atomic::AtomicBool::new(true);
                let wrapped = |text: String| {
                    let ok = deliver(text);
                    if !ok {
                        alive.store(false, std::sync::atomic::Ordering::SeqCst);
                    }
                    ok
                };
                loop {
                    match me.poll_once(WAIT_S, &wrapped, &*log) {
                        Ok(_) => delay = Duration::from_secs(1),
                        Err(e) => {
                            log(&format!("peer chiefs: {e}"));
                            std::thread::sleep(delay);
                            delay = (delay * 2).min(Duration::from_secs(60));
                        }
                    }
                    if !alive.load(std::sync::atomic::Ordering::SeqCst) {
                        return;
                    }
                }
            })
            .expect("spawn peer chiefs");
    }
}

/// Where a forward of one hub message ended.
#[derive(Debug, PartialEq, Eq)]
pub enum Forwarded {
    /// The brain took it (or had it already): ack.
    Done,
    /// Refused for good (a bad message): ack, log.
    Dropped(String),
    /// Try again later (the network, the API, a chief that does not answer now): keep it.
    Later(String),
}

/// Sorts a forward's answer: only a message the API refuses as such (400, 413, 422) drops; anything
/// else waits: 401/403 (fix the install), 404 (the route is not deployed yet), 409 (the chief does
/// not answer now), 429, 5xx and the network.
pub fn forwarded(answer: Result<Value, String>) -> Forwarded {
    match answer {
        Ok(_) => Forwarded::Done,
        Err(e) => {
            let code = e
                .split(": HTTP ")
                .nth(1)
                .and_then(|r| r.get(..3))
                .and_then(|c| c.parse::<u16>().ok());
            match code {
                Some(400 | 413 | 422) => Forwarded::Dropped(e),
                _ => Forwarded::Later(e),
            }
        }
    }
}

impl PeerChiefs {
    /// One pass of the hosted-brain bridge: each message a listed peer posted to this box goes to
    /// `forward(from, text, key)` (POST /v1/chiefs/<agent>/peer); acked when it is done or dropped.
    /// Stops at the first message that must wait, so the order holds.
    pub fn bridge_once(
        &self,
        wait_s: u64,
        forward: &dyn Fn(&str, &str, &str) -> Forwarded,
        log: &dyn Fn(&str),
    ) -> Result<usize, String> {
        let inbox = self.inbox();
        let mut done = 0;
        for m in self.hub.read(&inbox, "cursor", wait_s)? {
            let seq = m.get("seq").and_then(Value::as_u64).unwrap_or(0);
            let from = m.get("from").and_then(Value::as_str).unwrap_or("");
            let id = m.get("id").and_then(Value::as_str).unwrap_or("");
            let text = m
                .pointer("/body/text")
                .and_then(Value::as_str)
                .or_else(|| m.get("body").and_then(Value::as_str))
                .unwrap_or("")
                .trim();
            let peer = self
                .config
                .peers
                .iter()
                .find(|p| p.subs.iter().any(|s| s == from));
            match peer {
                Some(peer) if !text.is_empty() => {
                    match forward(&peer.name, text, &format!("hub-{seq}-{id}")) {
                        Forwarded::Done => done += 1,
                        Forwarded::Dropped(why) => {
                            log(&format!("peer bridge: hub message {seq} dropped: {why}"))
                        }
                        Forwarded::Later(why) => {
                            return Err(format!("hub message {seq} waits: {why}"));
                        }
                    }
                }
                _ => log(&format!(
                    "peer bridge: hub message {seq} from {from:?} ignored (not a listed peer, or no text)"
                )),
            }
            self.hub.ack(&inbox, seq)?;
        }
        Ok(done)
    }
}

/// `optchat-chief peer-chiefs bridge --install FILE --chief agent_… [--config FILE] [--once]`: runs on
/// the hub host for a hosted Cloud Chief (the Durable Object brain, which cannot read the hub): each
/// peer message in this box goes to the chief through POST /v1/chiefs/<chief>/peer as the owner's
/// paired install. `--list` prints the account's chiefs (id, name, placement) instead.
fn bridge_cli(
    config: &Path,
    install: &Path,
    chief: Option<&str>,
    once: bool,
    list: bool,
) -> Result<String, String> {
    use crate::cloud::auth::{self, InstallFile, InstallTokens, TokenSource, UreqHttp};
    let file = InstallFile::load(install)?;
    let api = file.api_base_url.trim_end_matches('/').to_owned();
    let http: Arc<dyn crate::cloud::auth::Http> = Arc::new(UreqHttp);
    let tokens = InstallTokens::new(file, http.clone());
    if list {
        let lease = tokens.mint(None)?;
        let v = auth::read(&*http, &api, &lease.access_token, "chief.list", json!({}))?;
        let rows: Vec<Value> = v
            .get("chiefs")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
            .map(|c| {
                json!({
                    "id": c.get("id"), "display_name": c.get("display_name"),
                    "is_default": c.get("is_default"), "archived_at": c.get("archived_at"),
                    "brain_place": c.get("brain_place"),
                })
            })
            .collect();
        return Ok(serde_json::to_string_pretty(&rows).unwrap_or_default());
    }
    // --chief, else the config's "chief" (the unit names no account id).
    let from_config = std::fs::read_to_string(config)
        .ok()
        .and_then(|t| serde_json::from_str::<Value>(&t).ok())
        .and_then(|v| v.get("chief").and_then(Value::as_str).map(str::to_owned));
    let chief = chief
        .map(str::to_owned)
        .or(from_config)
        .ok_or("bridge needs --chief agent_… or \"chief\" in the config (see --list)")?;
    let peers = PeerChiefs::from_file(config)?
        .ok_or_else(|| format!("{}: no peer Chiefs configured", config.display()))?;
    let lease: Mutex<Option<crate::cloud::auth::Lease>> = Mutex::new(None);
    let now = || {
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as u64)
    };
    let forward = |from: &str, text: &str, key: &str| -> Forwarded {
        let mut held = lease.lock().expect("lease");
        if held.as_ref().is_none_or(|l| l.expires_at <= now() + 60_000) {
            match tokens.mint(None) {
                Ok(l) => *held = Some(l),
                Err(e) => return Forwarded::Later(format!("minting the install token: {e}")),
            }
        }
        let token = held
            .as_ref()
            .map(|l| l.access_token.clone())
            .unwrap_or_default();
        drop(held);
        forwarded(http.post(
            &format!("{api}/v1/chiefs/{chief}/peer"),
            &json!({"from": from, "text": text, "key": key}),
            Some(&token),
        ))
    };
    let log = |line: &str| eprintln!("{line}");
    eprintln!(
        "peer bridge: {} -> {api}/v1/chiefs/{chief}/peer",
        peers.inbox()
    );
    let mut delay = Duration::from_secs(2);
    loop {
        match peers.bridge_once(if once { 0 } else { WAIT_S }, &forward, &log) {
            Ok(n) => {
                if n > 0 {
                    eprintln!("peer bridge: forwarded {n}");
                }
                delay = Duration::from_secs(2);
                if once {
                    return Ok(format!("forwarded {n}"));
                }
            }
            Err(e) => {
                if once {
                    return Err(e);
                }
                eprintln!("peer bridge: {e}");
                std::thread::sleep(delay);
                delay = (delay * 2).min(Duration::from_secs(120));
            }
        }
    }
}

/// `optchat-chief peer-chiefs …`: the same route from a shell (a450, tests,
/// the end-to-end proof). `--config FILE` (default: `$MUX_HOME/optchat/peer-chiefs.json`).
///
/// ```text
/// optchat-chief peer-chiefs list
/// optchat-chief peer-chiefs tell chief:cloud-chief "text" [--key K]
/// optchat-chief peer-chiefs read [--after N] [--wait S]   (never moves the cursor)
/// ```
pub fn cli(args: &[String]) -> Result<String, String> {
    let mut rest: Vec<String> = Vec::new();
    let mut config: Option<PathBuf> = None;
    let (mut key, mut after, mut wait) = (None, "0".to_owned(), 0_u64);
    let (mut install, mut chief, mut once, mut list) = (None, None, false, false);
    let mut i = 0;
    while i < args.len() {
        let next = |i: usize| {
            args.get(i + 1)
                .cloned()
                .ok_or(format!("{} needs a value", args[i]))
        };
        match args[i].as_str() {
            "--config" => config = Some(PathBuf::from(next(i)?)),
            "--key" => key = Some(next(i)?),
            "--after" => after = next(i)?,
            "--wait" => wait = next(i)?.parse().map_err(|_| "--wait takes seconds")?,
            "--install" => install = Some(PathBuf::from(next(i)?)),
            "--chief" => chief = Some(next(i)?),
            "--once" | "--list" => {
                if args[i] == "--once" {
                    once = true;
                } else {
                    list = true;
                }
                i += 1;
                continue;
            }
            _ => {
                rest.push(args[i].clone());
                i += 1;
                continue;
            }
        }
        i += 2;
    }
    let path = config.unwrap_or_else(|| Config::path(&crate::paths::mux_home().join("optchat")));
    if rest.first().is_some_and(|w| w == "bridge") {
        let install =
            install.ok_or("bridge needs --install FILE (the paired install of this host)")?;
        return bridge_cli(&path, &install, chief.as_deref(), once, list);
    }
    let peers = PeerChiefs::from_file(&path)?
        .ok_or_else(|| format!("{}: no peer Chiefs configured", path.display()))?;
    match rest.iter().map(String::as_str).collect::<Vec<_>>().as_slice() {
        ["list"] | [] => Ok(serde_json::to_string_pretty(&Value::Array(peers.list_entries()))
            .unwrap_or_default()),
        ["tell", id, message] => peers.tell(id, message, key.as_deref()),
        ["read"] => {
            let messages = peers.hub.read(&peers.inbox(), &after, wait.min(WAIT_S))?;
            Ok(serde_json::to_string_pretty(&Value::Array(messages)).unwrap_or_default())
        }
        _ => Err("usage: optchat-chief peer-chiefs list | tell chief:NAME TEXT [--key K] | read [--after N] [--wait S] | bridge --install FILE (--chief agent_… [--once] | --list) [--config FILE]".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[derive(Default)]
    struct FakeHub {
        boxes: Mutex<Vec<(String, Value)>>,
        acks: Mutex<Vec<(String, u64)>>,
    }

    impl Hub for FakeHub {
        fn post(&self, to: &str, body: &Value, reply_to: &str) -> Result<Value, String> {
            let mut b = self.boxes.lock().unwrap();
            b.push((to.to_owned(), json!({"body": body, "reply_to": reply_to})));
            Ok(json!({"seq": b.len()}))
        }
        fn read(&self, _from: &str, _after: &str, _wait: u64) -> Result<Vec<Value>, String> {
            Ok(vec![
                json!({"seq": 7, "from": "cloud-chief", "body": {"text": "pong"}}),
                json!({"seq": 8, "from": "stranger", "body": {"text": "hi"}}),
            ])
        }
        fn ack(&self, from: &str, seq: u64) -> Result<(), String> {
            self.acks.lock().unwrap().push((from.to_owned(), seq));
            Ok(())
        }
    }

    fn config() -> Config {
        Config::parse(
            r#"{"hub":"http://hub:8790/","token_file":"~/t","me":"mac-chief",
                "peers":[{"name":"cloud-chief","label":"Cloud Chief","place":"cloud"}]}"#,
            Some(Path::new("/home/u")),
        )
        .unwrap()
    }

    #[test]
    fn parses_and_expands() {
        let c = config();
        assert_eq!(c.hub, "http://hub:8790");
        assert_eq!(c.token_file, PathBuf::from("/home/u/t"));
        assert_eq!(c.peers[0].id(), "chief:cloud-chief");
        assert!(Config::parse(r#"{"hub":"x","token_file":"t","me":"m"}"#, None).is_err());
        assert!(
            Config::parse(
                r#"{"hub":"http://h","token_file":"t","me":"m","peers":[{"name":"m"}]}"#,
                None
            )
            .is_err()
        );
    }

    #[test]
    fn tell_posts_to_the_peer_box_with_reply_box_and_dedupes_keys() {
        let hub = Arc::new(FakeHub::default());
        let p = PeerChiefs::new(config(), hub.clone());
        assert!(
            p.tell("chief:cloud-chief", "ping", Some("k1"))
                .unwrap()
                .contains("Cloud Chief")
        );
        assert!(
            p.tell("chief:Cloud Chief", "ping", Some("k1"))
                .unwrap()
                .contains("already sent")
        );
        assert!(p.tell("chief:nobody", "ping", None).is_err());
        assert!(p.peer("a12").is_none());
        let boxes = hub.boxes.lock().unwrap();
        assert_eq!(boxes.len(), 1);
        assert_eq!(boxes[0].0, "agent:cloud-chief");
        assert_eq!(boxes[0].1["reply_to"], "agent:mac-chief");
        assert_eq!(boxes[0].1["body"]["text"], "ping");
    }

    #[test]
    fn list_marks_peers_remote_and_survives_a_failed_local_list() {
        let p = PeerChiefs::new(config(), Arc::new(FakeHub::default()));
        let args = json!({"action": "list"});
        let merged = p
            .merge_list(
                &args,
                Ok(r#"[{"id":"agent_1","display_name":"Chief"}]"#.into()),
            )
            .unwrap();
        let v: Value = serde_json::from_str(&merged).unwrap();
        assert_eq!(v.as_array().unwrap().len(), 2);
        assert_eq!(v[1]["id"], "chief:cloud-chief");
        assert_eq!(v[1]["remote"], true);
        let failed = p.merge_list(&args, Err("no record".into())).unwrap();
        assert!(failed.contains("chief:cloud-chief") && failed.contains("no record"));
        let get = json!({"action": "get"});
        assert_eq!(p.merge_list(&get, Ok("x".into())).unwrap(), "x");
    }

    #[test]
    fn inbox_delivers_peer_notes_ignores_strangers_and_acks_both() {
        let hub = Arc::new(FakeHub::default());
        let p = PeerChiefs::new(config(), hub.clone());
        let got = Mutex::new(Vec::new());
        let n = p
            .poll_once(
                0,
                &|t| {
                    got.lock().unwrap().push(t);
                    true
                },
                &|_| {},
            )
            .unwrap();
        assert_eq!(n, 1);
        let got = got.lock().unwrap();
        assert!(got[0].starts_with("[chief:cloud-chief] pong"));
        assert!(got[0].contains("not the user's word"));
        assert_eq!(
            *hub.acks.lock().unwrap(),
            vec![
                ("agent:mac-chief".to_owned(), 7),
                ("agent:mac-chief".to_owned(), 8)
            ]
        );
    }

    #[test]
    fn forward_answers_sort_into_done_drop_and_later() {
        assert_eq!(forwarded(Ok(json!({}))), Forwarded::Done);
        assert!(matches!(
            forwarded(Err("u: HTTP 400: bad".into())),
            Forwarded::Dropped(_)
        ));
        assert!(matches!(
            forwarded(Err("u: HTTP 403: no".into())),
            Forwarded::Later(_)
        ));
        assert!(matches!(
            forwarded(Err("u: HTTP 404: none".into())),
            Forwarded::Later(_)
        ));
        assert!(matches!(
            forwarded(Err("u: HTTP 413: big".into())),
            Forwarded::Dropped(_)
        ));
        assert!(matches!(
            forwarded(Err("u: HTTP 409: off".into())),
            Forwarded::Later(_)
        ));
        assert!(matches!(
            forwarded(Err("u: HTTP 503: x".into())),
            Forwarded::Later(_)
        ));
        assert!(matches!(
            forwarded(Err("u: Connection Failed".into())),
            Forwarded::Later(_)
        ));
    }

    #[test]
    fn the_bridge_forwards_peer_messages_and_keeps_one_that_must_wait() {
        let hub = Arc::new(FakeHub::default());
        let p = PeerChiefs::new(config(), hub.clone());
        let seen = Mutex::new(Vec::new());
        let n = p
            .bridge_once(
                0,
                &|from, text, key| {
                    seen.lock()
                        .unwrap()
                        .push((from.to_owned(), text.to_owned(), key.to_owned()));
                    Forwarded::Done
                },
                &|_| {},
            )
            .unwrap();
        assert_eq!(n, 1);
        assert_eq!(seen.lock().unwrap()[0].0, "cloud-chief");
        assert_eq!(seen.lock().unwrap()[0].1, "pong");
        assert_eq!(
            hub.acks.lock().unwrap().len(),
            2,
            "the stranger's message is acked and ignored"
        );
        let hub = Arc::new(FakeHub::default());
        let p = PeerChiefs::new(config(), hub.clone());
        assert!(
            p.bridge_once(0, &|_, _, _| Forwarded::Later("409".into()), &|_| {})
                .is_err()
        );
        assert!(hub.acks.lock().unwrap().is_empty());
    }

    #[test]
    fn a_peer_answers_for_its_listed_subjects() {
        let c = Config::parse(
            r#"{"hub":"http://h","token_file":"t","me":"mac-chief",
                "peers":[{"name":"cloud-chief","subs":["cloud-chief","hosted-cc"]}]}"#,
            None,
        )
        .unwrap();
        let p = PeerChiefs::new(c, Arc::new(FakeHub::default()));
        let m = json!({"seq": 1, "from": "hosted-cc", "body": {"text": "hi"}});
        assert!(
            matches!(p.inbound(&m), Inbound::Note(t) if t.starts_with("[chief:cloud-chief] hi"))
        );
    }

    #[test]
    fn a_refused_delivery_is_not_acked() {
        let hub = Arc::new(FakeHub::default());
        let p = PeerChiefs::new(config(), hub.clone());
        assert_eq!(p.poll_once(0, &|_| false, &|_| {}).unwrap(), 0);
        assert!(hub.acks.lock().unwrap().is_empty());
    }
}
