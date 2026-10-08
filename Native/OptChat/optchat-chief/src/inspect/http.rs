//! The inspector's HTTP server: loopback only, GET only, one per-launch
//! token, no secret in any URL.
//!
//! - It binds 127.0.0.1 (a non-loopback address is refused), drops a peer
//!   that is not loopback, and answers 403 to a request whose Host is not
//!   this server's loopback address (a page on another site cannot reach it
//!   through DNS rebinding).
//! - Every answer needs the token: `Authorization: Bearer <token>` (the app,
//!   which reads it from `optchat/inspector.json`, mode 0600), or the session
//!   cookie a one-time ticket buys. The app asks `/api/ticket` with the
//!   token, then opens `/?ticket=T`: the ticket works once, within a minute,
//!   and the page then runs on an HttpOnly, SameSite=Strict cookie. A URL in
//!   the browser's history holds only a spent ticket.
//! - It serves the page (built into this binary, `inspector/index.html`) and
//!   `Inspector::answer`; everything else is 404, every method but GET and
//!   HEAD is 405. Nothing it does writes the memory.

use std::collections::HashMap;
use std::io::{self, BufRead, BufReader, Read, Write};
use std::net::{IpAddr, SocketAddr, TcpListener, TcpStream};
use std::path::Path;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde_json::json;

use super::Inspector;

/// The React page, one self-contained file (scripts/cmux-next/build-optchat-inspector-web.sh),
/// copied into OUT_DIR by build.rs; a placeholder when the bundle was not built.
pub const PAGE: &str = include_str!(concat!(env!("OUT_DIR"), "/inspector.html"));
/// Whether this binary carries the placeholder page instead of the inspector
/// (build.rs set `optchat_inspector_placeholder`: nothing built the bundle).
pub const PAGE_IS_PLACEHOLDER: bool = cfg!(optchat_inspector_placeholder);

/// The session cookie's name, with the port in it: a browser sends a
/// 127.0.0.1 cookie to every port, so two Chiefs (two tags) must not share it.
fn cookie_name(port: u16) -> String {
    format!("optchat_inspector_{port}")
}
/// How long a session cookie stays valid.
const SESSION_LIFE: Duration = Duration::from_secs(12 * 3600);
struct Ticket {
    minted: Instant,
    spent: Option<(String, Instant)>,
}

/// How long a spent ticket still answers with the session it bought: the
/// app's browser loads the ticket URL again when it moves the new tab into
/// its column, before the first load's redirect lands.
const RESPEND: Duration = Duration::from_secs(10);
/// How long a ticket from `/api/ticket` can be spent.
const TICKET_LIFE: Duration = Duration::from_secs(60);
/// Connections served at once; more are answered 503.
const MAX_CONNECTIONS: usize = 32;
const MAX_HEAD: usize = 16 * 1024;
/// The whole request head must arrive within this (not each read).
const IO_TIMEOUT: Duration = Duration::from_secs(10);

/// A running server.
#[derive(Clone)]
pub struct Running {
    pub addr: SocketAddr,
    pub token: String,
}

impl Running {
    /// `http://127.0.0.1:<port>/`, no secret in it.
    pub fn url(&self) -> String {
        format!("http://{}/", self.addr)
    }
}

struct Shared {
    inspector: Arc<Inspector>,
    token: String,
    port: u16,
    /// Each ticket: when it was minted, and the session it bought once spent.
    tickets: Mutex<HashMap<String, Ticket>>,
    sessions: Mutex<Vec<(String, Instant)>>,
    live: AtomicUsize,
}

/// 32 random bytes as hex, from the system's random source.
pub fn new_secret() -> io::Result<String> {
    use ring::rand::SecureRandom;
    let mut bytes = [0u8; 32];
    ring::rand::SystemRandom::new()
        .fill(&mut bytes)
        .map_err(|_| io::Error::other("no system randomness"))?;
    Ok(bytes.iter().map(|b| format!("{b:02x}")).collect())
}

/// Starts serving `inspector` on `bind` (port 0 picks one). Refuses an
/// address that is not loopback.
pub fn start(inspector: Arc<Inspector>, bind: SocketAddr, token: String) -> io::Result<Running> {
    if !bind.ip().is_loopback() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            format!("the inspector serves loopback only, not {}", bind.ip()),
        ));
    }
    if token.len() < 32 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "token too short",
        ));
    }
    let listener = TcpListener::bind(bind)?;
    let addr = listener.local_addr()?;
    let shared = Arc::new(Shared {
        inspector,
        token: token.clone(),
        port: addr.port(),
        tickets: Mutex::new(HashMap::new()),
        sessions: Mutex::new(Vec::new()),
        live: AtomicUsize::new(0),
    });
    std::thread::Builder::new()
        .name("optchat-inspector".into())
        .spawn(move || {
            for conn in listener.incoming() {
                let conn = match conn {
                    Ok(conn) => conn,
                    Err(_) => {
                        // Out of descriptors (EMFILE) or the like: an accept
                        // loop that retries at once would spin a core.
                        std::thread::sleep(Duration::from_millis(200));
                        continue;
                    }
                };
                let shared = shared.clone();
                if shared.live.fetch_add(1, Ordering::SeqCst) >= MAX_CONNECTIONS {
                    shared.live.fetch_sub(1, Ordering::SeqCst);
                    let _ = respond(&conn, 503, "text/plain", b"busy", &[]);
                    continue;
                }
                let spawned = std::thread::Builder::new()
                    .name("optchat-inspector-conn".into())
                    .spawn({
                        let shared = shared.clone();
                        move || {
                            serve(conn, &shared);
                            shared.live.fetch_sub(1, Ordering::SeqCst);
                        }
                    });
                if spawned.is_err() {
                    shared.live.fetch_sub(1, Ordering::SeqCst);
                }
            }
        })?;
    Ok(Running { addr, token })
}

/// Writes `{"url", "token"}` to `file` (0600, through a rename) for the app.
pub fn publish(file: &Path, running: &Running) -> io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt;
    let body = json!({"url": running.url(), "token": running.token, "pid": std::process::id()});
    let tmp = file.with_extension("json.tmp");
    let mut f = std::fs::OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .mode(0o600)
        .open(&tmp)?;
    f.write_all(body.to_string().as_bytes())?;
    f.sync_all()?;
    std::fs::rename(&tmp, file)
}

/// One parsed request head.
#[derive(Debug, Default)]
pub struct Request {
    pub method: String,
    pub path: String,
    pub query: Vec<(String, String)>,
    pub headers: Vec<(String, String)>,
}

impl Request {
    pub fn header(&self, name: &str) -> Option<&str> {
        self.headers
            .iter()
            .find(|(k, _)| k.eq_ignore_ascii_case(name))
            .map(|(_, v)| v.as_str())
    }
    fn query(&self, key: &str) -> Option<&str> {
        self.query
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }
}

fn read_head(conn: &TcpStream) -> io::Result<Request> {
    let deadline = Instant::now() + IO_TIMEOUT;
    // Each read may wait only what is left of the head's deadline, so a
    // client that trickles bytes cannot hold a connection thread.
    let left = || {
        let rest = deadline.saturating_duration_since(Instant::now());
        if rest.is_zero() {
            Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "request head too slow",
            ))
        } else {
            conn.set_read_timeout(Some(rest))
        }
    };
    let mut reader = BufReader::new(conn.take(MAX_HEAD as u64));
    let mut line = String::new();
    left()?;
    reader.read_line(&mut line)?;
    let mut words = line.split_whitespace();
    let (Some(method), Some(target), Some(version)) = (words.next(), words.next(), words.next())
    else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "bad request line",
        ));
    };
    if !version.starts_with("HTTP/1.") {
        return Err(io::Error::new(io::ErrorKind::InvalidData, "not HTTP/1"));
    }
    let (path, query) = target.split_once('?').unwrap_or((target, ""));
    let mut req = Request {
        method: method.to_owned(),
        path: decode(path),
        query: parse_query(query),
        headers: Vec::new(),
    };
    loop {
        let mut h = String::new();
        left()?;
        if reader.read_line(&mut h)? == 0 {
            return Err(io::Error::new(
                io::ErrorKind::UnexpectedEof,
                "head cut short",
            ));
        }
        let h = h.trim_end_matches(['\r', '\n']);
        if h.is_empty() {
            return Ok(req);
        }
        if let Some((k, v)) = h.split_once(':') {
            req.headers.push((k.trim().to_owned(), v.trim().to_owned()));
        }
    }
}

/// `a=1&b=x%20y` decoded (`+` is a space).
pub fn parse_query(query: &str) -> Vec<(String, String)> {
    query
        .split('&')
        .filter(|p| !p.is_empty())
        .map(|p| {
            let (k, v) = p.split_once('=').unwrap_or((p, ""));
            (decode(&k.replace('+', " ")), decode(&v.replace('+', " ")))
        })
        .collect()
}

fn decode(text: &str) -> String {
    let bytes = text.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).ok();
            if let Some(b) = hex.and_then(|h| u8::from_str_radix(h, 16).ok()) {
                out.push(b);
                i += 3;
                continue;
            }
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Equal without an early exit on the first differing byte.
fn same(a: &str, b: &str) -> bool {
    a.len() == b.len()
        && a.bytes()
            .zip(b.bytes())
            .fold(0u8, |acc, (x, y)| acc | (x ^ y))
            == 0
}

fn cookie<'a>(req: &'a Request, name: &str) -> Option<&'a str> {
    req.header("cookie")?
        .split(';')
        .filter_map(|c| c.trim().split_once('='))
        .find(|(k, _)| *k == name)
        .map(|(_, v)| v)
}

impl Shared {
    fn bearer_ok(&self, req: &Request) -> bool {
        req.header("authorization")
            .and_then(|v| v.strip_prefix("Bearer "))
            .is_some_and(|t| same(t.trim(), &self.token))
    }

    fn authorized(&self, req: &Request) -> bool {
        if self.bearer_ok(req) {
            return true;
        }
        let name = cookie_name(self.port);
        let Some(session) = cookie(req, &name) else {
            return false;
        };
        let mut sessions = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        sessions.retain(|(_, at)| at.elapsed() < SESSION_LIFE);
        sessions.iter().any(|(s, _)| same(s, session))
    }

    fn host_ok(&self, req: &Request) -> bool {
        let port = self.port;
        req.header("host").is_some_and(|h| {
            h == format!("127.0.0.1:{port}")
                || h == format!("localhost:{port}")
                || h == format!("[::1]:{port}")
        })
    }

    /// No `Origin` (a navigation or a same-origin GET) or exactly this
    /// server's own loopback origin. A foreign or `null` Origin is a web page
    /// reading the inspector (cross-site, or a DNS-rebound name on another
    /// port), refused even when the request carries the token or a session.
    fn origin_ok(&self, req: &Request) -> bool {
        let port = self.port;
        let mut origins = req
            .headers
            .iter()
            .filter(|(k, _)| k.eq_ignore_ascii_case("origin"));
        match (origins.next(), origins.next()) {
            (None, _) => true,
            (Some((_, origin)), None) => {
                let origin = origin.trim().to_ascii_lowercase();
                let origin = origin.strip_suffix('/').unwrap_or(&origin);
                origin == format!("http://127.0.0.1:{port}")
                    || origin == format!("http://localhost:{port}")
                    || origin == format!("http://[::1]:{port}")
            }
            (Some(_), Some(_)) => false,
        }
    }

    fn mint_ticket(&self) -> io::Result<String> {
        let ticket = new_secret()?;
        let mut tickets = self
            .tickets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        tickets.retain(|_, t| t.minted.elapsed() < TICKET_LIFE);
        tickets.insert(
            ticket.clone(),
            Ticket {
                minted: Instant::now(),
                spent: None,
            },
        );
        Ok(ticket)
    }

    /// Spends `ticket` (within its life) for a new session id. A ticket
    /// works once; the same ticket again within `RESPEND` of its first use
    /// (a reload of the same URL) gets the same session, never a new one.
    fn spend_ticket(&self, ticket: &str) -> Option<String> {
        let mut tickets = self
            .tickets
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        tickets.retain(|_, t| t.minted.elapsed() < TICKET_LIFE);
        let key = tickets.keys().find(|k| same(k, ticket)).cloned()?;
        let entry = tickets.get_mut(&key)?;
        if let Some((session, at)) = &entry.spent {
            return (at.elapsed() < RESPEND).then(|| session.clone());
        }
        let session = new_secret().ok()?;
        entry.spent = Some((session.clone(), Instant::now()));
        drop(tickets);
        let mut sessions = self
            .sessions
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        sessions.push((session.clone(), Instant::now()));
        let excess = sessions.len().saturating_sub(16);
        sessions.drain(..excess);
        Some(session)
    }
}

/// What one request gets: status, content type, body, extra headers.
pub struct Reply {
    pub status: u16,
    pub kind: &'static str,
    pub body: Vec<u8>,
    pub headers: Vec<(String, String)>,
}

fn reply(status: u16, kind: &'static str, body: impl Into<Vec<u8>>) -> Reply {
    Reply {
        status,
        kind,
        body: body.into(),
        headers: Vec::new(),
    }
}

fn text(status: u16, why: &str) -> Reply {
    reply(
        status,
        "application/json",
        json!({"error": why}).to_string(),
    )
}

const LOCKED: &str = "<!doctype html><meta charset=utf-8><title>Memory Inspector</title><body style=\"font:14px -apple-system,sans-serif;margin:24px\"><p>Open the Memory Inspector from cmux: Command-Shift-P, then <b>Chief: Open Memory Inspector</b>.</p>";

/// Routes one request (no I/O: the tests call it directly).
fn route(shared: &Shared, req: &Request) -> Reply {
    if !shared.host_ok(req) {
        return text(403, "the Host header is not this loopback server");
    }
    if !shared.origin_ok(req) {
        return text(403, "the Origin is not this loopback server");
    }
    if req.method != "GET" && req.method != "HEAD" {
        let mut r = text(405, "the inspector is read-only: GET only");
        r.headers.push(("Allow".into(), "GET, HEAD".into()));
        return r;
    }
    match req.path.as_str() {
        "/api/ticket" => {
            if !shared.bearer_ok(req) {
                return text(401, "a ticket needs the token");
            }
            match shared.mint_ticket() {
                Ok(t) => reply(200, "application/json", json!({"ticket": t}).to_string()),
                Err(e) => text(500, &e.to_string()),
            }
        }
        "/" | "/index.html" => {
            // Only a GET spends a ticket (a HEAD, a prefetch check, does not).
            if let Some(ticket) = req.query("ticket").filter(|_| req.method == "GET") {
                return match shared.spend_ticket(ticket) {
                    Some(session) => {
                        let mut r = reply(303, "text/plain", "");
                        r.headers.push(("Location".into(), "/".into()));
                        r.headers.push((
                            "Set-Cookie".into(),
                            format!(
                                "{}={session}; Path=/; HttpOnly; SameSite=Strict",
                                cookie_name(shared.port)
                            ),
                        ));
                        r
                    }
                    None => reply(401, "text/html; charset=utf-8", LOCKED),
                };
            }
            if !shared.authorized(req) {
                return reply(401, "text/html; charset=utf-8", LOCKED);
            }
            reply(200, "text/html; charset=utf-8", PAGE)
        }
        path if path.starts_with("/api/") => {
            if !shared.authorized(req) {
                return text(401, "missing or wrong token");
            }
            match shared.inspector.answer(path, &req.query) {
                Ok(v) => reply(200, "application/json", v.to_string()),
                Err((status, why)) => text(status, &why),
            }
        }
        _ => text(404, "not found"),
    }
}

fn serve(conn: TcpStream, shared: &Shared) {
    let peer_ok = conn.peer_addr().is_ok_and(|a| loopback(a.ip()));
    if !peer_ok {
        return;
    }
    let _ = conn.set_write_timeout(Some(IO_TIMEOUT));
    let Ok(req) = read_head(&conn) else {
        let _ = respond(&conn, 400, "text/plain", b"bad request", &[]);
        return;
    };
    let r = route(shared, &req);
    let body: &[u8] = if req.method == "HEAD" { &[] } else { &r.body };
    let _ = respond_len(&conn, r.status, r.kind, body, r.body.len(), &r.headers);
}

fn loopback(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_loopback(),
        IpAddr::V6(v6) => {
            v6.is_loopback() || v6.to_ipv4_mapped().is_some_and(|v4| v4.is_loopback())
        }
    }
}

fn respond(
    conn: &TcpStream,
    status: u16,
    kind: &str,
    body: &[u8],
    headers: &[(String, String)],
) -> io::Result<()> {
    respond_len(conn, status, kind, body, body.len(), headers)
}

fn respond_len(
    mut conn: &TcpStream,
    status: u16,
    kind: &str,
    body: &[u8],
    len: usize,
    headers: &[(String, String)],
) -> io::Result<()> {
    let reason = match status {
        200 => "OK",
        303 => "See Other",
        400 => "Bad Request",
        401 => "Unauthorized",
        403 => "Forbidden",
        404 => "Not Found",
        405 => "Method Not Allowed",
        503 => "Service Unavailable",
        _ => "Error",
    };
    let mut head = format!(
        "HTTP/1.1 {status} {reason}\r\nContent-Type: {kind}\r\nContent-Length: {len}\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nX-Frame-Options: DENY\r\nContent-Security-Policy: default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data:; connect-src 'self'; frame-ancestors 'none'\r\nConnection: close\r\n"
    );
    for (k, v) in headers {
        head.push_str(&format!("{k}: {v}\r\n"));
    }
    head.push_str("\r\n");
    conn.write_all(head.as_bytes())?;
    conn.write_all(body)?;
    conn.flush()
}
