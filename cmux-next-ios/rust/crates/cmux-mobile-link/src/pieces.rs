//! The phone's kill switch file: the I/O around `cmux_web_pieces::phone` (cmuxterm-hq
//! docs/design/ship-without-update.md, "iOS"; cmux-next-ios/SECURITY.md "What the phone takes
//! remotely").
//!
//! The file is signed data that names pieces of the app to switch **off**, back to the
//! fallback already compiled into the app. This module fetches it (one GET, no redirect, a
//! bounded body), keeps what `phone::evaluate` says to keep between reads in
//! `<dir>/ios-pieces.json` (the serial, the switches last taken, the ETag) and a short log in
//! `<dir>/ios-pieces.log.jsonl`. Every decision is that crate's: nothing here reads a field of
//! the file before its signature is checked there, and nothing here downloads or runs code.
//!
//! A read that fails, a file that is not published (404) and a refused file all answer from
//! the switches last taken: a blocked network or a forged file never switches a piece on or
//! off. No call here panics or returns an error to the app: a folder that cannot be written
//! costs only the memory of the last file.

use std::io::{Read as _, Write as _};
use std::path::Path;
use std::time::Duration;

use cmux_web_pieces::phone;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

/// Where the switch files are published; `ota/pieces-ios-<channel>.json` under it.
pub const BASE: &str = "https://files.cmux.com/cmux-next-web/";
/// The state file: `{"channel", "floor", "last", "etag", "checked_at"}`.
pub const STATE_FILE: &str = "ios-pieces.json";
/// The log: one `log` object of a reply per line.
pub const LOG_FILE: &str = "ios-pieces.log.jsonl";
/// The log is cut to the newest half of its lines once it passes this.
pub const LOG_MAX_BYTES: u64 = 128 * 1024;
/// A check sooner than this after the server last answered asks nothing.
pub const CHECK_EVERY: Duration = Duration::from_secs(15 * 60);
/// The whole GET, connect to last byte. Nothing in the app waits on it.
const FETCH_TIMEOUT: Duration = Duration::from_secs(10);
/// An ETag longer than this is not kept (a header the next request must carry).
const ETAG_MAX: usize = 256;

/// One answer to the GET of the switch file.
#[derive(Debug, PartialEq, Eq)]
pub enum Fetched {
    /// 200: the envelope's text and its ETag.
    Body(String, Option<String>),
    /// 304: the file whose ETag the state holds is still the one published.
    NotModified,
    /// 404: no file is published. Not "switch everything back on": the last switches stay.
    Missing,
    /// Any other status, or no answer.
    Failed(String),
}

/// What the app holds after a read.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Reading {
    /// The pieces switched off, each with the file's reason, by name.
    pub off: Vec<(String, String)>,
    /// The serial of the last file taken; 0 when none was.
    pub serial: u64,
    /// `taken`, `no_file`, a refusal's code (`unsigned`, `stale`, `too_large`, ...), or
    /// `fresh` for a check that asked nothing because the last answer is recent.
    pub verdict: String,
}

/// What is kept between checks.
#[derive(Debug, Default, PartialEq, Serialize, Deserialize)]
struct State {
    #[serde(default)]
    channel: String,
    /// The serial of the last file taken: no older file is taken after it.
    #[serde(default)]
    floor: u64,
    /// The `switches` of the reply that took it.
    #[serde(default)]
    last: Option<Value>,
    /// The ETag of the last file taken, never of a refused one.
    #[serde(default)]
    etag: Option<String>,
    /// When the server last answered (unix seconds).
    #[serde(default)]
    checked_at: u64,
}

impl State {
    fn read(dir: &Path) -> Option<State> {
        serde_json::from_slice(&read_capped(&dir.join(STATE_FILE))?).ok()
    }

    /// `channel`'s state: another channel's serial and switches say nothing about this one.
    fn of(dir: &Path, channel: &str) -> State {
        State::read(dir).filter(|state| state.channel == channel).unwrap_or_default()
    }
}

/// The channel of the build with this bundle identifier, or `None` for a build that reads no
/// switch file (`phone::channel`: today only cmux INTERNAL reads one; the App Store app does
/// not).
#[must_use]
pub fn channel(bundle_id: &str, debug: bool) -> Option<&'static str> {
    phone::channel(bundle_id, debug)
}

/// Where `channel`'s switch file is under `base` (which ends with `/`).
#[must_use]
pub fn file_url(base: &str, channel: &str) -> String {
    format!("{base}ota/{}", phone::file_name(channel))
}

/// The switches the phone last took, from the disk alone: what a launch applies before a
/// piece first shows. No network, no write.
#[must_use]
pub fn load(dir: &Path, channel: &str) -> Reading {
    let state = State::of(dir, channel);
    reading(&evaluate(&state, channel, None, 0, &cmux_web_pieces::trusted_keys()))
}

/// One check after launch: the GET, then [`take`]. Asks nothing, and answers [`load`] with the
/// verdict `fresh`, when the server answered less than [`CHECK_EVERY`] ago.
pub async fn check(dir: &Path, channel: &str, now: u64) -> Reading {
    let state = State::of(dir, channel);
    if state.checked_at <= now && now - state.checked_at < CHECK_EVERY.as_secs() {
        let mut held = load(dir, channel);
        held.verdict = "fresh".to_owned();
        return held;
    }
    let fetched = fetch(&file_url(BASE, channel), state.etag.as_deref()).await;
    let (dir, channel) = (dir.to_owned(), channel.to_owned());
    let taken = tokio::task::spawn_blocking(move || {
        take(&dir, &channel, fetched, &cmux_web_pieces::trusted_keys(), now)
    });
    taken.await.unwrap_or_default()
}

/// One check with the GET already answered: `phone::evaluate_with` against `keys`, the state
/// and the log written. A folder that cannot be written changes nothing in the answer.
pub fn take(dir: &Path, channel: &str, fetched: Fetched, keys: &[(String, [u8; 32])], now: u64) -> Reading {
    let on_disk = State::read(dir);
    // A state of another channel is left alone until this channel takes a file.
    let ours = on_disk.as_ref().is_none_or(|state| state.channel == channel);
    let mut state = on_disk.filter(|state| state.channel == channel).unwrap_or_default();
    let (envelope, etag, answered) = match fetched {
        Fetched::Body(text, etag) => (Some(text), etag, true),
        Fetched::NotModified | Fetched::Missing => (None, None, true),
        Fetched::Failed(_) => (None, None, false),
    };
    let reply = evaluate(&state, channel, envelope.as_deref(), now, keys);
    let taken = reply.get("taken").and_then(Value::as_bool).unwrap_or(false);
    let _ = create_dir(dir);
    if taken {
        state = State {
            channel: channel.to_owned(),
            floor: reply.get("serial").and_then(Value::as_u64).unwrap_or(state.floor),
            last: reply.get("switches").filter(|switches| !switches.is_null()).cloned(),
            etag: etag.filter(|etag| keeps_etag(etag)),
            checked_at: now,
        };
        let _ = write_state(dir, &state);
    } else if answered && ours {
        // Not taken: the floor, the switches and the ETag of the last file taken stay.
        channel.clone_into(&mut state.channel);
        state.checked_at = now;
        let _ = write_state(dir, &state);
    }
    if let Some(line) = reply.get("log") {
        let refused = reply.get("refusal").is_some_and(|refusal| !refusal.is_null());
        let _ = log(&dir.join(LOG_FILE), line, refused, LOG_MAX_BYTES);
    }
    reading(&reply)
}

/// The log's last `count` lines that parse, oldest first, each as its JSON text.
#[must_use]
pub fn log_tail(dir: &Path, count: usize) -> Vec<String> {
    let bytes = read_capped(&dir.join(LOG_FILE)).unwrap_or_default();
    let text = String::from_utf8_lossy(&bytes);
    let lines: Vec<&str> = text.lines().filter(|line| serde_json::from_str::<Value>(line).is_ok()).collect();
    lines[lines.len().saturating_sub(count)..].iter().map(|line| (*line).to_owned()).collect()
}

fn evaluate(
    state: &State,
    channel: &str,
    envelope: Option<&str>,
    now: u64,
    keys: &[(String, [u8; 32])],
) -> Value {
    let mut input = json!({"envelope": envelope, "channel": channel, "floor": state.floor, "now": now});
    if let (Some(last), Some(input)) = (&state.last, input.as_object_mut()) {
        input.insert("last".to_owned(), last.clone());
    }
    phone::evaluate_with(&input, keys)
}

fn reading(reply: &Value) -> Reading {
    let off = reply.get("off").and_then(Value::as_object).map(|off| {
        off.iter()
            .map(|(piece, reason)| (piece.clone(), reason.as_str().unwrap_or_default().to_owned()))
            .collect()
    });
    Reading {
        off: off.unwrap_or_default(),
        serial: reply.get("serial").and_then(Value::as_u64).unwrap_or(0),
        verdict: reply.pointer("/log/verdict").and_then(Value::as_str).unwrap_or_default().to_owned(),
    }
}

/// An ETag the next request can carry as `If-None-Match`.
fn keeps_etag(etag: &str) -> bool {
    !etag.is_empty() && etag.len() <= ETAG_MAX && etag.bytes().all(|b| (0x21..0x7f).contains(&b))
}

/// At most a state file's or a log's worth of `path`; `None` when it cannot be read.
fn read_capped(path: &Path) -> Option<Vec<u8>> {
    let mut bytes = Vec::new();
    std::fs::File::open(path).ok()?.take(4 * LOG_MAX_BYTES).read_to_end(&mut bytes).ok()?;
    Some(bytes)
}

fn create_dir(dir: &Path) -> std::io::Result<()> {
    use std::os::unix::fs::DirBuilderExt as _;
    std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)
}

/// `bytes` as `path`, whole or not at all: a temp file beside it, renamed over it.
fn write_atomic(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::os::unix::fs::OpenOptionsExt as _;
    let temp = path.with_extension(format!("{}.tmp", uuid::Uuid::new_v4().simple()));
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temp)
        .and_then(|mut file| file.write_all(bytes))
        .and_then(|()| std::fs::rename(&temp, path));
    if written.is_err() {
        let _ = std::fs::remove_file(&temp);
    }
    written
}

fn write_state(dir: &Path, state: &State) -> std::io::Result<()> {
    let mut bytes = serde_json::to_vec(state).map_err(std::io::Error::other)?;
    bytes.push(b'\n');
    write_atomic(&dir.join(STATE_FILE), &bytes)
}

/// Appends `line` (a reply's `log`) unless it says what the last line says: the same verdict,
/// serial, switched-off pieces and unknown names. A refusal (`refused`) is always written,
/// once per check. So a quiet check adds nothing, and every change and every refused file is
/// on record. Past `max` bytes the log is cut to the newest half of its lines.
fn log(path: &Path, line: &Value, refused: bool, max: u64) -> std::io::Result<()> {
    const SAME: &[&str] = &["verdict", "serial", "off", "unknown"];
    let before = read_capped(path).unwrap_or_default();
    let before = String::from_utf8_lossy(&before);
    let last = before.lines().rev().find_map(|line| serde_json::from_str::<Value>(line).ok());
    let same = last.is_some_and(|last| SAME.iter().all(|key| last.get(key) == line.get(key)));
    if same && !refused {
        return Ok(());
    }
    let text = format!("{line}\n");
    if (before.len() + text.len()) as u64 > max {
        let lines: Vec<&str> = before.lines().collect();
        let mut kept = lines.get(lines.len() / 2 + 1..).unwrap_or_default().join("\n");
        if !kept.is_empty() {
            kept.push('\n');
        }
        kept.push_str(&text);
        return write_atomic(path, kept.as_bytes());
    }
    use std::os::unix::fs::OpenOptionsExt as _;
    std::fs::OpenOptions::new()
        .append(true)
        .create(true)
        .mode(0o600)
        .open(path)
        .and_then(|mut file| file.write_all(text.as_bytes()))
}

/// GET of the switch file at `url`, with `If-None-Match: etag` when the state holds one. One
/// request: a redirect is not followed (the file is served where it is published, and no other
/// host gets the request), the whole exchange ends within [`FETCH_TIMEOUT`], and no more than
/// `cmux_web_pieces::MAX_BYTES` of a body are read. It carries no cookie, token or device id.
pub async fn fetch(url: &str, etag: Option<&str>) -> Fetched {
    crate::install_crypto_provider();
    let client = reqwest::Client::builder()
        .timeout(FETCH_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none())
        .user_agent(concat!("cmux-ios-pieces/", env!("CARGO_PKG_VERSION")))
        .build();
    let client = match client {
        Ok(client) => client,
        Err(error) => return Fetched::Failed(format!("could not start an HTTP client: {error}")),
    };
    let answer = async {
        let mut request = client.get(url).header(reqwest::header::ACCEPT, "application/json");
        if let Some(etag) = etag.filter(|etag| keeps_etag(etag)) {
            request = request.header(reqwest::header::IF_NONE_MATCH, etag);
        }
        let mut response = request.send().await.map_err(|error| format!("{url}: {error}"))?;
        match response.status() {
            reqwest::StatusCode::OK => {}
            reqwest::StatusCode::NOT_MODIFIED => return Ok(Fetched::NotModified),
            reqwest::StatusCode::NOT_FOUND => return Ok(Fetched::Missing),
            other => return Err(format!("{url}: HTTP {}", other.as_u16())),
        }
        let etag = response
            .headers()
            .get(reqwest::header::ETAG)
            .and_then(|etag| etag.to_str().ok())
            .map(str::to_owned);
        let limit = cmux_web_pieces::MAX_BYTES;
        let mut body = Vec::new();
        while let Some(chunk) = response.chunk().await.map_err(|error| format!("{url}: {error}"))? {
            if body.len() + chunk.len() > limit {
                return Err(format!("{url}: larger than {limit} bytes"));
            }
            body.extend_from_slice(&chunk);
        }
        // Bytes that are not text are no envelope: the crate refuses them, on the log.
        Ok(Fetched::Body(String::from_utf8_lossy(&body).into_owned(), etag))
    };
    answer.await.unwrap_or_else(Fetched::Failed)
}

#[cfg(test)]
#[path = "pieces_tests.rs"]
mod tests;
