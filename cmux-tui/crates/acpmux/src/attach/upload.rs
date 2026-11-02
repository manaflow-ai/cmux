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
/// timed out, a peer that is down, a chunk the daemon did not take at that offset. Not a refusal
/// the daemon gave for the upload itself, a local file error, or a closed daemon connection.
pub(super) fn transient(daemon: &Client, e: &anyhow::Error) -> bool {
    if e.downcast_ref::<LinkStopped>().is_some() {
        return true;
    }
    if daemon.is_closed() {
        return false;
    }
    e.downcast_ref::<DaemonError>().is_some_and(|DaemonError(rpc)| link_failure(rpc))
}

/// Whether a status refused for `reason` says the record's upload cannot be resumed: the daemon
/// has no such upload, or the chat's peer runs a build without `uploadResume` (which took the
/// upload, but cannot say where it stands).
fn no_resume(reason: Option<&str>) -> bool {
    matches!(reason, Some("upload.unknown" | "filePut.unsupported"))
}

/// The `reason` of the daemon's error `e`, if it gave one.
fn reason_of(e: &anyhow::Error) -> Option<&str> {
    let DaemonError(rpc) = e.downcast_ref::<DaemonError>()?;
    rpc.data.as_ref()?.get("reason")?.as_str()
}

/// Whether the daemon's error `rpc` says the link lost the request, not that it refused it.
fn link_failure(rpc: &crate::rpc::RpcError) -> bool {
    let data = rpc.data.as_ref();
    match data.and_then(|d| d.get("reason")).and_then(Value::as_str) {
        Some("upload.offset" | "peer_unreachable") => true,
        Some(_) => false,
        // The peer link's own failures (`peer.rs` `link_request_on`), which carry no reason.
        None => {
            data.and_then(|d| d.get("retryable")) == Some(&Value::Bool(true))
                || (rpc.code == -32603
                    && rpc.message.starts_with("peer ")
                    && ["timed out", "dropped the request", "connection closed", "disconnected"]
                        .iter()
                        .any(|end| rpc.message.ends_with(end)))
        }
    }
}

/// `e` as the failure of `label`'s upload: [`LinkStopped`] when the link it went on stopped, so
/// the caller keeps the uploads for a later send to resume.
pub(super) fn failure(daemon: &Client, label: &str, e: anyhow::Error) -> anyhow::Error {
    let message = format!("cannot attach {label}: {e:#}");
    if transient(daemon, &e) { LinkStopped(message).into() } else { anyhow::anyhow!(message) }
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

/// The resume record of one file's upload to one chat, held by one sender at a time: its lock
/// is the OS's, so a sender that dies lets go of it at once.
pub(super) struct Record {
    path: PathBuf,
    lock: std::fs::File,
}

/// Dropping it unlocks explicitly: a child forked but not yet exec'd (an agent the daemon
/// starts, a test's forked child) shares the lock's open file description, so closing this
/// descriptor alone would leave the record held until that child execs or exits, and the next
/// send of the file would upload without one. The daemon's own lock does the same.
impl Drop for Record {
    fn drop(&mut self) {
        let _ = self.lock.unlock();
    }
}

impl Record {
    /// The record of the upload of the file at `path` (`meta`) to chat `chat`, claimed for this
    /// sender. None when another sender holds it (a concurrent send of the same file): this one
    /// then uploads on its own, with no record.
    fn claim(chat: &str, path: &Path, meta: &std::fs::Metadata) -> Option<Self> {
        Self::claim_in(&crate::config::home().join("run").join("upload-resume"), chat, path, meta)
    }

    /// [`Record::claim`] in folder `dir`.
    fn claim_in(dir: &Path, chat: &str, path: &Path, meta: &std::fs::Metadata) -> Option<Self> {
        use sha2::Digest;
        let canonical = std::fs::canonicalize(path).ok()?;
        let mtime = meta.modified().ok()?.duration_since(std::time::UNIX_EPOCH).ok()?.as_nanos();
        let key = format!("{chat}\0{}\0{}\0{mtime}", canonical.display(), meta.len());
        let hash: String = sha2::Sha256::digest(key.as_bytes())
            .iter()
            .take(16)
            .map(|b| format!("{b:02x}"))
            .collect();
        // Its lock file stays when the record goes: a sender that opened it just before would
        // otherwise lock a file nobody else sees.
        crate::config::private_state_dir(dir).ok()?;
        let mut open = std::fs::OpenOptions::new();
        open.create(true).truncate(false).write(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut open, 0o600);
        let lock = open.open(dir.join(format!("{hash}.lock"))).ok()?;
        lock.try_lock().ok()?;
        Some(Self { path: dir.join(format!("{hash}.json")), lock })
    }

    /// The upload it names: `(uploadId, ownerToken)`.
    fn read(&self) -> Option<(String, Option<String>)> {
        let saved: Value = serde_json::from_slice(&std::fs::read(&self.path).ok()?).ok()?;
        let id = saved.get("uploadId").and_then(Value::as_str)?.to_owned();
        Some((id, saved.get("ownerToken").and_then(Value::as_str).map(str::to_owned)))
    }

    /// Saves it; false when it could not be written, so a later send cannot resume the upload.
    fn write(&self, id: &str, owner: Option<&str>) -> bool {
        let saved = json!({"uploadId": id, "ownerToken": owner}).to_string();
        crate::agent_tools::write_private(&self.path, saved.as_bytes()).is_ok()
    }

    /// Removes it: its upload finished, was cancelled, or is gone. The lock file stays, empty.
    /// False when it is still there, naming an upload another send could take as its own.
    pub(super) fn forget(&self) -> bool {
        match std::fs::remove_file(&self.path) {
            Ok(()) => true,
            Err(e) => e.kind() == std::io::ErrorKind::NotFound,
        }
    }

    /// Where it is, for an error that names it.
    pub(super) fn path(&self) -> &Path {
        &self.path
    }
}

/// The upload an earlier send of this file to this chat began, and where it stands: `(id,
/// owner, offset)`. None when there is none, or the daemon answers it is not that upload (the
/// record goes). Err when the daemon cannot be asked: the record stays for a later send.
async fn resumable(
    daemon: &Client,
    say: Say<'_>,
    chat: &str,
    record: &Record,
    name: &str,
    size: u64,
) -> anyhow::Result<Option<(String, Option<String>, u64)>> {
    let Some((id, owner)) = record.read() else { return Ok(None) };
    let ask = json!({"sessionId": chat, "uploadId": id});
    let what = format!("asking where {name} stands");
    let status = retrying(daemon, say, &what, Instant::now(), || {
        daemon.request(method::MUX_FILE_PUT_STATUS, ask.clone())
    });
    let status = match status.await {
        Ok(status) => status,
        // The daemon answered that it cannot resume it: the record is no use, begin again.
        Err(e) if no_resume(reason_of(&e)) => {
            record.forget();
            return Ok(None);
        }
        // Anything else says nothing about the upload: the record stays for a later send.
        Err(e) => return Err(e),
    };
    let same = status.get("size").and_then(Value::as_u64) == Some(size)
        && status.get("fileName").and_then(Value::as_str) == Some(name);
    if !same {
        record.forget();
        return Ok(None);
    }
    let offset = status.get("offset").and_then(Value::as_u64).unwrap_or(0).min(size);
    say(&format!("resuming {name} at {} of {}", human(offset), human(size)));
    Ok(Some((id, owner, offset)))
}

/// Begins (or resumes, [`resumable`]) an upload of the file at `path`, `size` bytes, to chat
/// `chat` and sends its bytes in chunks read as they go, retrying what the link loses. A failure
/// answers the upload when it was begun, for the caller to cancel or keep ([`LinkStopped`]).
pub(super) async fn upload(
    daemon: &Client,
    chat: &str,
    path: &Path,
    size: u64,
    progress: &mut Progress<'_>,
) -> Result<Sent, (anyhow::Error, Option<Sent>)> {
    let label = path.display().to_string();
    let name = super::safe_name(&path.file_name().map(|n| n.to_string_lossy()).unwrap_or_default());
    // With its reason: the CLI prints the outer message only.
    let fail = |e: anyhow::Error| failure(daemon, &label, e);
    let mut file = tokio::fs::File::open(path).await.map_err(|e| (fail(e.into()), None))?;
    let meta = file.metadata().await.map_err(|e| (fail(e.into()), None))?;
    let mut head = vec![0u8; HEAD_BYTES.min(usize::try_from(size).unwrap_or(HEAD_BYTES))];
    file.read_exact(&mut head).await.map_err(|e| (fail(e.into()), None))?;
    let say = progress.say;
    let resume = daemon.daemon_lists(crate::hub::file_uploads::RESUME_FEATURE);
    let mut record = resume.then(|| Record::claim(chat, path, &meta)).flatten();
    let earlier = match &record {
        Some(record) => resumable(daemon, say, chat, record, &name, size).await,
        None => Ok(None),
    };
    let earlier = earlier.map_err(|e| (fail(e), None))?;
    let (id, owner, mut offset) = match earlier {
        Some(found) => found,
        None => {
            let begin =
                json!({"sessionId": chat, "fileName": name, "size": size, "forPrompt": true});
            let what = format!("starting the upload of {name}");
            let begun = retrying(daemon, say, &what, Instant::now(), || {
                daemon.request(method::MUX_FILE_PUT_BEGIN, begin.clone())
            });
            let begun = begun.await.map_err(|e| (fail(e), None))?;
            let Some(id) = begun.get("uploadId").and_then(Value::as_str) else {
                return Err((anyhow::anyhow!("the daemon gave no uploadId for {label}"), None));
            };
            let owner = begun.get("ownerToken").and_then(Value::as_str).map(str::to_owned);
            // Without its record the upload still goes; only a later send cannot resume it.
            if record.as_ref().is_some_and(|r| !r.write(id, owner.as_deref())) {
                record = None;
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
            let part = buf.get_mut(..want).context("an upload chunk past its buffer")?;
            file.read_exact(part)
                .await
                .with_context(|| format!("{label} changed while it was sent"))?;
            let data = base64::engine::general_purpose::STANDARD.encode(&*part);
            let chunk =
                json!({"sessionId": chat, "uploadId": one.id, "offset": offset, "data": data});
            match daemon.request(method::MUX_FILE_PUT_CHUNK, chunk).await {
                Ok(_) => {
                    offset += want as u64;
                    progress.took(want as u64, true, &one.name);
                    (gained, wait) = (Instant::now(), Duration::from_secs(1));
                    #[cfg(debug_assertions)]
                    stall_for_test(offset).await;
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
            if at > offset {
                // Bytes whose answers the link lost: progress all the same.
                progress.took(at - offset, true, &one.name);
                (gained, wait) = (Instant::now(), Duration::from_secs(1));
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
        Err(e) => Err((fail(e), Some(one))),
    }
}

/// An upload that stopped because the link it went on stopped (for [`STALL`], or for a request
/// that is not retried): kept for a later send of the same file to resume.
#[derive(Debug)]
pub(super) struct LinkStopped(String);

impl std::fmt::Display for LinkStopped {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.0)
    }
}

impl std::error::Error for LinkStopped {}

/// Debug builds only: `ACPMUX_TEST_UPLOAD_STALL_AFTER=N` stops the sender for good once the
/// daemon holds N bytes of a file, for a test to kill it part way through an upload.
#[cfg(debug_assertions)]
async fn stall_for_test(offset: u64) {
    let at = std::env::var("ACPMUX_TEST_UPLOAD_STALL_AFTER").ok().and_then(|v| v.parse().ok());
    if at.is_some_and(|at: u64| offset >= at) {
        std::future::pending::<()>().await;
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

    /// Two sends of one file to one chat never share an upload: the second gets no record while
    /// the first holds it, and gets it once the first lets go (a sender that ended).
    #[test]
    fn one_sender_at_a_time_holds_a_files_resume_record() {
        let dir = std::env::temp_dir().join(format!("amx-rec-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("big.bin");
        std::fs::write(&file, b"bytes").unwrap();
        let meta = std::fs::metadata(&file).unwrap();
        let records = dir.join("records");
        let first = Record::claim_in(&records, "chat", &file, &meta).expect("the first claim");
        assert!(first.write("01a17d93-859c-75a2-82f8-350749c86551", Some("tok")));
        assert!(Record::claim_in(&records, "chat", &file, &meta).is_none(), "held by the first");
        let other = Record::claim_in(&records, "other-chat", &file, &meta);
        assert!(other.is_some(), "another chat's record is its own");
        drop(first);
        let again = Record::claim_in(&records, "chat", &file, &meta).expect("let go");
        let saved = again.read().expect("the record");
        assert_eq!(saved, ("01a17d93-859c-75a2-82f8-350749c86551".into(), Some("tok".into())));
        assert!(again.forget());
        assert!(again.read().is_none());
        assert!(again.forget(), "a record already gone is forgotten");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// A sender that ends lets go of its record even while another process shares the lock's
    /// open file description, as a child forked but not yet exec'd does (in the test binary,
    /// other tests fork such children at any moment, which made the test above fail on CI).
    /// The child here is `sleep`, handed the lock's descriptor and nothing else: every other
    /// descriptor the test binary opens is close-on-exec, so it holds no other test's lock.
    #[cfg(unix)]
    #[test]
    fn a_shared_lock_descriptor_does_not_keep_an_ended_senders_record() {
        use std::os::unix::io::AsRawFd;
        use std::os::unix::process::CommandExt;
        let dir = std::env::temp_dir().join(format!("amx-rec-shared-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("big.bin");
        std::fs::write(&file, b"bytes").unwrap();
        let meta = std::fs::metadata(&file).unwrap();
        let records = dir.join("records");
        let first = Record::claim_in(&records, "chat", &file, &meta).expect("the first claim");
        let fd = first.lock.as_raw_fd();
        const SHARED: libc::c_int = 3;
        let mut sleep = std::process::Command::new("sleep");
        sleep.arg("30").stdin(std::process::Stdio::null());
        // SAFETY: between fork and exec the child calls only dup2 and fcntl, both
        // async-signal-safe. dup2 leaves the lock open across exec as descriptor 3; when the
        // lock already is 3, fcntl clears its close-on-exec flag instead.
        unsafe {
            sleep.pre_exec(move || {
                let ok = if fd == SHARED {
                    libc::fcntl(fd, libc::F_SETFD, 0) == 0
                } else {
                    libc::dup2(fd, SHARED) == SHARED
                };
                if ok { Ok(()) } else { Err(std::io::Error::last_os_error()) }
            });
        }
        let mut child = sleep.spawn().expect("sleep");
        drop(first);
        let again = Record::claim_in(&records, "chat", &file, &meta);
        let _ = child.kill();
        let _ = child.wait();
        assert!(again.is_some(), "the child's copy kept the ended sender's record");
        let _ = std::fs::remove_dir_all(&dir);
    }

    /// Only the link losing a request is retried, never a refusal of the upload itself.
    #[test]
    fn only_a_lost_request_is_retried() {
        use crate::rpc::RpcError;
        let lost = |m: &str| link_failure(&RpcError::internal(m));
        assert!(lost("peer cosmic-gray timed out"));
        assert!(lost("peer cosmic-gray dropped the request"));
        assert!(lost("peer cosmic-gray connection closed"));
        let reason = |r: &str| RpcError::internal("x").with_data(json!({"reason": r}));
        assert!(link_failure(&reason("peer_unreachable")));
        assert!(link_failure(&reason("upload.offset")));
        assert!(!link_failure(&reason("upload.diskFull")));
        assert!(!link_failure(&reason("upload.unknown")));
        assert!(!link_failure(&reason("filePut.unsupported")));
        assert!(!lost("cannot append upload: Input/output error"));
        assert!(!link_failure(&RpcError::invalid_params("peer x timed out")));
    }

    /// A record whose upload is gone, or went to a peer that cannot say where it stands, starts
    /// a fresh upload; any other refusal keeps the record for a later send.
    #[test]
    fn a_record_is_dropped_only_when_its_upload_cannot_be_resumed() {
        assert!(no_resume(Some("upload.unknown")));
        assert!(no_resume(Some("filePut.unsupported")));
        assert!(!no_resume(Some("upload.unreadable")));
        assert!(!no_resume(Some("upload.diskFull")));
        assert!(!no_resume(Some("peer_unreachable")));
        assert!(!no_resume(None));
    }
}
