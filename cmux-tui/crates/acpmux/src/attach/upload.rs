//! Sending the files of a message by reference ([`super::blocks_for`]) over a slow or flaky link.
//!
//! A 2 GiB file to a chat on a peer took an hour at the link's 1 MB/s, and the sender said nothing
//! the whole time (hb-acpmux's no-cap stop check, 2026-10-27). So:
//!
//! - The sender says what it is doing ([`Progress`]): one line when the uploads start, one every
//!   [`PROGRESS_EVERY`] with the bytes sent, the rate and the time left, and one when they are in.
//!   The CLI prints them on stderr.
//! - A request the link loses (a peer link that drops, a peer daemon that restarts) is retried:
//!   the sender asks the daemon where the upload stands (`_acpmux/file_put_status`) and goes on
//!   from there, until no byte has gone for [`STALL`].
//! - A sender that dies leaves a record of each upload it began
//!   (`<ACPMUX_HOME>/run/upload-resume/`, owner-only), keyed by the chat and the file's path, size
//!   and modification time. The next send of the same file to the same chat resumes that upload
//!   instead of starting over; the record goes once the upload is finished or cancelled.

use super::Sent;
use crate::client::{Client, DaemonError};
use crate::rpc::method;
use anyhow::Context;
use base64::Engine;
use serde_json::{Value, json};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};
use tokio::io::{AsyncReadExt, AsyncSeekExt};

/// How often a long upload says how far it is.
const PROGRESS_EVERY: Duration = Duration::from_secs(10);
/// How long a send keeps retrying with no byte gained before it fails.
const STALL: Duration = Duration::from_secs(600);
/// The longest wait between two retries.
const MAX_BACKOFF: Duration = Duration::from_secs(15);
/// The bytes of a file's start kept to tell an image ([`super::image_type`]).
const HEAD_BYTES: usize = 64;

/// Where the sender's lines go: the CLI's stderr; nowhere for an agent's `send_message`.
pub type Say<'a> = &'a (dyn Fn(&str) + Send + Sync);

/// `bytes` for a person: "2.0 GiB", "512.0 MiB", "21.4 KiB", "12 bytes".
pub(super) fn human(bytes: u64) -> String {
    const UNITS: [(&str, u64); 3] = [("GiB", 1 << 30), ("MiB", 1 << 20), ("KiB", 1 << 10)];
    for (unit, size) in UNITS {
        if bytes >= size {
            return format!("{:.1} {unit}", bytes as f64 / size as f64);
        }
    }
    format!("{bytes} bytes")
}

/// `d` for a person: "1 h 4 min", "3 min 20 s", "12 s".
fn span(d: Duration) -> String {
    let s = d.as_secs();
    match s {
        0..60 => format!("{s} s"),
        60..3600 => format!("{} min {} s", s / 60, s % 60),
        _ => format!("{} h {} min", s / 3600, s % 3600 / 60),
    }
}

/// How far the uploads of one send are, said every [`PROGRESS_EVERY`].
pub(super) struct Progress<'a> {
    say: Say<'a>,
    total: u64,
    files: usize,
    /// Bytes the daemon holds, resumed ones included.
    done: u64,
    /// Bytes this sender sent and the daemon took: the rate.
    sent: u64,
    started: Instant,
    last: Instant,
}

impl<'a> Progress<'a> {
    pub(super) fn start(say: Say<'a>, chat: &str, sizes: &[u64]) -> Self {
        let total = sizes.iter().sum();
        let files = sizes.len();
        let plural = if files == 1 { "" } else { "s" };
        say(&format!(
            "uploading {files} file{plural} ({}) to {chat} before the message is sent",
            human(total)
        ));
        let now = Instant::now();
        Self { say, total, files, done: 0, sent: 0, started: now, last: now }
    }

    fn say(&self, line: &str) {
        (self.say)(line);
    }

    /// The daemon took `bytes` more that this sender sent (`sent`) or that an earlier send
    /// left there.
    fn took(&mut self, bytes: u64, sent: bool, name: &str) {
        self.done = self.done.saturating_add(bytes);
        if sent {
            self.sent = self.sent.saturating_add(bytes);
        }
        if self.last.elapsed() < PROGRESS_EVERY {
            return;
        }
        self.last = Instant::now();
        let secs = self.started.elapsed().as_secs_f64().max(0.001);
        let rate = self.sent as f64 / secs;
        let left = (rate >= 1.0)
            .then(|| {
                span(Duration::from_secs_f64(self.total.saturating_sub(self.done) as f64 / rate))
            })
            .map_or_else(String::new, |t| format!(", about {t} left"));
        let pct = (self.done as f64 * 100.0 / self.total.max(1) as f64).min(100.0);
        self.say(&format!(
            "uploaded {} of {} ({pct:.0}%) at {}/s{left}; now {name}",
            human(self.done),
            human(self.total),
            human(rate as u64)
        ));
    }

    /// The daemon's bytes went back from `from` to `to` (a cut-back write).
    fn lost(&mut self, from: u64, to: u64) {
        self.done = self.done.saturating_sub(from.saturating_sub(to));
    }

    pub(super) fn finished(&self) {
        let plural = if self.files == 1 { "" } else { "s" };
        self.say(&format!(
            "uploaded {} file{plural} ({}) in {}; sending the message",
            self.files,
            human(self.total),
            span(self.started.elapsed())
        ));
    }
}

/// Whether failure `e` of a request to `daemon` may pass if asked again: a link that dropped or
/// timed out, a peer daemon that restarted, a chunk the daemon did not take at that offset. Not a
/// refusal the daemon gave with its reason, a local file error, or a closed daemon connection.
pub(super) fn transient(daemon: &Client, e: &anyhow::Error) -> bool {
    if daemon.is_closed() {
        return false;
    }
    let Some(DaemonError(rpc)) = e.downcast_ref::<DaemonError>() else { return false };
    match rpc.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str) {
        Some(reason) => matches!(reason, "upload.offset" | "peer_unreachable"),
        // An internal error with no reason: a link that dropped or timed out on the way.
        None => rpc.code == -32603,
    }
}

/// Asks `call` until it answers, waiting longer each time a [`transient`] failure comes, for at
/// most [`STALL`] from `since`.
pub(super) async fn retrying<F, Fut>(
    daemon: &Client,
    say: Say<'_>,
    what: &str,
    since: Instant,
    mut call: F,
) -> anyhow::Result<Value>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = anyhow::Result<Value>>,
{
    let mut wait = Duration::from_secs(1);
    loop {
        match call().await {
            Ok(answer) => return Ok(answer),
            Err(e) if !transient(daemon, &e) || since.elapsed() >= STALL => return Err(e),
            Err(e) => {
                say(&format!("{what}: {e:#}; trying again in {}", span(wait)));
                tokio::time::sleep(wait).await;
                wait = (wait * 2).min(MAX_BACKOFF);
            }
        }
    }
}

/// The record of the upload of the file at `path` (`meta`) to chat `chat`.
fn record_path(chat: &str, path: &Path, meta: &std::fs::Metadata) -> Option<PathBuf> {
    use sha2::Digest;
    let canonical = std::fs::canonicalize(path).ok()?;
    let mtime = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos();
    let key = format!("{chat}\0{}\0{}\0{mtime}", canonical.display(), meta.len());
    let hash: String =
        sha2::Sha256::digest(key.as_bytes()).iter().take(16).map(|b| format!("{b:02x}")).collect();
    Some(crate::config::home().join("run").join("upload-resume").join(format!("{hash}.json")))
}

/// Removes the record of a finished or cancelled upload.
pub(super) fn forget(one: &Sent) {
    if let Some(record) = &one.record {
        let _ = std::fs::remove_file(record);
    }
}

/// The upload an earlier send of this file to this chat began, and where it stands: `(id,
/// owner, offset)`. None when there is none, or the daemon no longer has it.
async fn resumable(
    daemon: &Client,
    say: Say<'_>,
    chat: &str,
    record: &Path,
    name: &str,
    size: u64,
) -> Option<(String, Option<String>, u64)> {
    let saved: Value = serde_json::from_slice(&std::fs::read(record).ok()?).ok()?;
    let id = saved.get("uploadId").and_then(Value::as_str)?.to_owned();
    let owner = saved.get("ownerToken").and_then(Value::as_str).map(str::to_owned);
    let ask = json!({"sessionId": chat, "uploadId": id});
    let what = format!("asking where {name} stands");
    let status = retrying(daemon, say, &what, Instant::now(), || {
        daemon.request(method::MUX_FILE_PUT_STATUS, ask.clone())
    });
    let same = |s: &Value| {
        s.get("size").and_then(Value::as_u64) == Some(size)
            && s.get("fileName").and_then(Value::as_str) == Some(name)
    };
    match status.await {
        Ok(status) if same(&status) => {
            let offset = status.get("offset").and_then(Value::as_u64).unwrap_or(0).min(size);
            say(&format!("resuming {name} at {} of {}", human(offset), human(size)));
            Some((id, owner, offset))
        }
        _ => {
            let _ = std::fs::remove_file(record);
            None
        }
    }
}

/// Begins (or resumes, [`resumable`]) an upload of the file at `path`, `size` bytes, to chat
/// `chat` and sends its bytes in chunks read as they go, retrying what the link loses. A failure
/// answers the upload when it was begun, for the caller to cancel.
pub(super) async fn upload(
    daemon: &Client,
    chat: &str,
    path: &Path,
    size: u64,
    progress: &mut Progress<'_>,
) -> Result<Sent, (anyhow::Error, Option<Sent>)> {
    let label = path.display();
    let name = super::safe_name(&path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default());
    // With its reason: the CLI prints the outer message only.
    let context = |e: anyhow::Error| anyhow::anyhow!("cannot attach {label}: {e:#}");
    let mut file = tokio::fs::File::open(path).await.map_err(|e| (context(e.into()), None))?;
    let meta = file.metadata().await.map_err(|e| (context(e.into()), None))?;
    let mut head = vec![0u8; HEAD_BYTES.min(usize::try_from(size).unwrap_or(HEAD_BYTES))];
    file.read_exact(&mut head).await.map_err(|e| (context(e.into()), None))?;
    let say = progress.say;
    let resume = daemon.daemon_lists(crate::hub::file_uploads::RESUME_FEATURE);
    let record = resume.then(|| record_path(chat, path, &meta)).flatten();
    let earlier = match &record {
        Some(record) => resumable(daemon, say, chat, record, &name, size).await,
        None => None,
    };
    let (id, owner, mut offset) = match earlier {
        Some(found) => found,
        None => {
            let begin =
                json!({"sessionId": chat, "fileName": name, "size": size, "forPrompt": true});
            let begun = daemon.request(method::MUX_FILE_PUT_BEGIN, begin).await;
            let begun = begun.map_err(|e| (context(e), None))?;
            let Some(id) = begun.get("uploadId").and_then(Value::as_str) else {
                return Err((anyhow::anyhow!("the daemon gave no uploadId for {label}"), None));
            };
            let owner = begun.get("ownerToken").and_then(Value::as_str).map(str::to_owned);
            if let Some(record) = &record {
                let saved = json!({"uploadId": id, "ownerToken": owner}).to_string();
                // Without its record the upload still goes; only a later send cannot resume it.
                let _ = crate::agent_tools::write_private(record, saved.as_bytes());
            }
            (id.to_owned(), owner, 0)
        }
    };
    progress.took(offset, false, &name);
    let one = Sent { id, owner, name, size, head, record };
    let sent = async {
        let mut buf = vec![0u8; crate::hub::file_uploads::CHUNK_BYTES];
        let mut gained = Instant::now();
        let mut wait = Duration::from_secs(1);
        file.seek(std::io::SeekFrom::Start(offset)).await?;
        while offset < size {
            let want = usize::try_from((size - offset).min(buf.len() as u64))?;
            file.read_exact(&mut buf[..want])
                .await
                .with_context(|| format!("{label} changed while it was sent"))?;
            let data = base64::engine::general_purpose::STANDARD.encode(&buf[..want]);
            let chunk =
                json!({"sessionId": chat, "uploadId": one.id, "offset": offset, "data": data});
            match daemon.request(method::MUX_FILE_PUT_CHUNK, chunk).await {
                Ok(_) => {
                    offset += want as u64;
                    progress.took(want as u64, true, &one.name);
                    (gained, wait) = (Instant::now(), Duration::from_secs(1));
                    #[cfg(debug_assertions)]
                    exit_for_test(offset);
                    continue;
                }
                Err(e) if !resume || !transient(daemon, &e) || gained.elapsed() >= STALL => {
                    return Err(e);
                }
                Err(e) => say(&format!(
                    "uploading {} stopped at {} of {}: {e:#}; resuming in {}",
                    one.name,
                    human(offset),
                    human(size),
                    span(wait)
                )),
            }
            tokio::time::sleep(wait).await;
            wait = (wait * 2).min(MAX_BACKOFF);
            // The daemon may hold more than it answered for (an answer the link lost) or less.
            let ask = json!({"sessionId": chat, "uploadId": one.id});
            let what = format!("asking where {} stands", one.name);
            let status = retrying(daemon, say, &what, gained, || {
                daemon.request(method::MUX_FILE_PUT_STATUS, ask.clone())
            })
            .await?;
            let at = status.get("offset").and_then(Value::as_u64).unwrap_or(0).min(size);
            if at >= offset {
                progress.took(at - offset, true, &one.name);
            } else {
                progress.lost(offset, at);
            }
            offset = at;
            file.seek(std::io::SeekFrom::Start(offset)).await?;
        }
        anyhow::Ok(())
    };
    match sent.await {
        Ok(()) => Ok(one),
        Err(e) if transient(daemon, &e) => {
            Err((LinkStopped(format!("{:#}", context(e))).into(), Some(one)))
        }
        Err(e) => Err((context(e), Some(one))),
    }
}

/// An upload that stopped because the link stayed down for [`STALL`]: kept for a later send of
/// the same file to resume.
#[derive(Debug)]
pub(super) struct LinkStopped(String);

impl std::fmt::Display for LinkStopped {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for LinkStopped {}

/// Debug builds only: `ACPMUX_TEST_UPLOAD_EXIT_AFTER=N` ends the sender once the daemon holds N
/// bytes of a file, as a sender that is killed part way through an upload.
#[cfg(debug_assertions)]
fn exit_for_test(offset: u64) {
    let at = std::env::var("ACPMUX_TEST_UPLOAD_EXIT_AFTER").ok().and_then(|v| v.parse().ok());
    if at.is_some_and(|at: u64| offset >= at) {
        std::process::exit(75);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sizes_and_spans_read_plainly() {
        assert_eq!(human(2 << 30), "2.0 GiB");
        assert_eq!(human(512 << 20), "512.0 MiB");
        assert_eq!(human(21906), "21.4 KiB");
        assert_eq!(human(12), "12 bytes");
        assert_eq!(span(Duration::from_secs(12)), "12 s");
        assert_eq!(span(Duration::from_secs(200)), "3 min 20 s");
        assert_eq!(span(Duration::from_secs(3840)), "1 h 4 min");
    }
}
