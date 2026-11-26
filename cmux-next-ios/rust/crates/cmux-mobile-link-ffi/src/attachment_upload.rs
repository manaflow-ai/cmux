//! The phone's attachment upload engine (design/attachment-upload.md "Phone: one Rust engine").
//!
//! One `AttachmentUploads` per app. Swift reserves an upload when a file is picked (stage
//! `Compressing` while the platform encoder runs), hands over the finished file, and the engine
//! sends it over the Mac's `upload` service: 192 KiB chunks read off the runtime threads, one
//! channel per attempt, every stage bounded, retried from the last byte the Mac acked, never
//! blocking `cancel`. Swift only feeds it links (`set_link`) and renders `UploadProgress`.
//!
//! Wire (hostd v2): replies are newline-delimited JSON: `{"have":N}` first, `{"ack":N}` per MiB,
//! `{"error":"resume_gap","have":L}`, a final `{"path","size"}`. An older hostd sends only the
//! final object (maybe without a newline) and never `have`: every retry then starts at byte 0.
//! During `Compressing`, `acked_bytes` / `total_bytes` carry the encoder's progress in
//! thousandths (`total_bytes` is 1000).
//!
//! Whole-file dedup: the engine hashes the file (SHA-256, on a blocking thread) before its first
//! attempt and sends `sha256` in the `upload` open. A Mac that already has that file answers the
//! final `{"path","size","deduped":true}` at once, so the engine waits for the Mac's first reply
//! (`have` or the final) before its first byte. A Mac that never answers first (hostd before
//! resumable uploads) costs that wait once (`Timings::first_reply`); later attempts don't wait.

use std::collections::HashMap;
use std::io::{Read, Seek, SeekFrom};
use std::path::PathBuf;
use std::sync::{Arc, Mutex, MutexGuard, PoisonError};
use std::time::{Duration, Instant};

use tokio::sync::{mpsc, watch};

use crate::{ChannelHandle, ChannelMessage, CmuxMobileError, LinkHandle, runtime};

/// Bytes per channel write.
const CHUNK: usize = 192 << 10;
/// Unacked bytes in flight before a silent Mac counts as stalled.
const STALL_WINDOW: u64 = 2 << 20;
const MAX_VIDEO_BYTES_ORIGINAL: u64 = 25 << 20;
const MAX_ORIGINAL_BITS_PER_SECOND: u64 = 12_000_000;
const MAX_LONG_SIDE: u32 = 1920;
const HEVC_PRESET: &str = "AVAssetExportPresetHEVC1920x1080";
const MAX_IMAGE_LONG_SIDE: u32 = 2048;
const MAX_IMAGE_BYTES_ORIGINAL: u64 = 2 << 20;
const IMAGE_JPEG_QUALITY: f64 = 0.85;

/// Every time bound of the engine; tests shorten them.
#[doc(hidden)]
#[derive(Debug, Clone)]
pub struct Timings {
    pub open: Duration,
    pub have: Duration,
    pub ack_stall: Duration,
    pub final_answer: Duration,
    pub backoff_start: Duration,
    pub backoff_max: Duration,
    pub give_up: Duration,
    pub progress_interval: Duration,
    /// How long a fresh attempt that sent `sha256` waits for the Mac's first reply before its
    /// first byte.
    pub first_reply: Duration,
}

impl Default for Timings {
    fn default() -> Self {
        Self {
            open: Duration::from_secs(15),
            have: Duration::from_secs(10),
            ack_stall: Duration::from_secs(30),
            final_answer: Duration::from_secs(60),
            backoff_start: Duration::from_millis(500),
            backoff_max: Duration::from_secs(10),
            give_up: Duration::from_secs(300),
            progress_interval: Duration::from_millis(100),
            first_reply: Duration::from_secs(3),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum UploadStage {
    Compressing,
    WaitingForMac,
    Uploading,
    Finishing,
    Done,
    Failed,
    Cancelled,
}

impl UploadStage {
    fn terminal(self) -> bool {
        matches!(self, Self::Done | Self::Failed | Self::Cancelled)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UploadProgress {
    pub upload_id: String,
    pub stage: UploadStage,
    /// Bytes the Mac confirmed (with an older hostd: bytes sent).
    pub acked_bytes: u64,
    /// Bytes written to channels over all attempts.
    pub sent_bytes: u64,
    pub total_bytes: u64,
    pub attempt: u32,
    pub mac_path: Option<String>,
    pub error_code: Option<String>,
    pub error_message: Option<String>,
}

/// Receives progress on a library thread.
#[uniffi::export(with_foreign)]
pub trait UploadObserver: Send + Sync {
    fn on_progress(&self, progress: UploadProgress);
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct UploadSpec {
    /// Chosen by the caller, stable across relaunches; a UUID v4 is made when none.
    pub upload_id: Option<String>,
    pub mac_id: String,
    pub name: String,
    pub cwd: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct VideoPlan {
    pub reencode: bool,
    /// The long side the encoder must not exceed (the original's when sent as is).
    pub max_long_side: u32,
    /// The platform export preset; empty when the original goes.
    pub preset: String,
    pub reason: String,
}

/// Send the original when it is small (<= 25 MiB) or already <= 1080p at <= 12 Mbit/s;
/// otherwise re-encode to HEVC with the long side at most 1920.
#[uniffi::export]
pub fn video_plan(width: u32, height: u32, duration_ms: u64, bytes: u64, codec: String) -> VideoPlan {
    let long_side = width.max(height);
    let original = |reason: String| VideoPlan {
        reencode: false,
        max_long_side: long_side,
        preset: String::new(),
        reason,
    };
    if bytes <= MAX_VIDEO_BYTES_ORIGINAL {
        return original(format!("{bytes} bytes is small enough to send as is"));
    }
    let bits_per_second = (duration_ms > 0).then(|| u128::from(bytes) * 8 * 1000 / u128::from(duration_ms));
    if long_side <= MAX_LONG_SIDE
        && bits_per_second.is_some_and(|b| b <= u128::from(MAX_ORIGINAL_BITS_PER_SECOND))
    {
        return original(format!("already {long_side}px {codec} at a modest bitrate"));
    }
    let why = match bits_per_second {
        _ if long_side > MAX_LONG_SIDE => format!("{long_side}px {codec} is larger than 1080p"),
        Some(b) => format!("{codec} at {} Mbit/s is heavier than 12 Mbit/s", b / 1_000_000),
        None => format!("{bytes} bytes of {codec} with an unknown length"),
    };
    VideoPlan { reencode: true, max_long_side: MAX_LONG_SIDE, preset: HEVC_PRESET.into(), reason: why }
}

#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct ImagePlan {
    pub reencode: bool,
    /// The long side the encoder makes (the original's when sent as is; never larger than it).
    pub max_long_side: u32,
    /// JPEG quality, 0...1, of the re-encode; 1 when the original goes.
    pub quality: f64,
    pub reason: String,
}

/// Sizes a picked image to what an agent needs (design/attachment-upload.md, Next, item 2): the
/// original when its long side is <= 2048 px and it is <= 2 MiB; otherwise a JPEG (q 0.85) with
/// the long side at most 2048 px. HEIC in, JPEG out: agents read JPEG. A width or height of 0
/// means unknown.
#[uniffi::export]
pub fn image_plan(width: u32, height: u32, bytes: u64, format: String) -> ImagePlan {
    let long_side = width.max(height);
    let fits = long_side <= MAX_IMAGE_LONG_SIDE;
    if fits && bytes <= MAX_IMAGE_BYTES_ORIGINAL {
        return ImagePlan {
            reencode: false,
            max_long_side: long_side,
            quality: 1.0,
            reason: format!("{long_side}px {format} of {bytes} bytes is small enough to send as is"),
        };
    }
    let reason = if fits {
        format!("{bytes} bytes of {format} is heavier than 2 MiB")
    } else {
        format!("{long_side}px {format} is larger than 2048px")
    };
    let target = if long_side == 0 { MAX_IMAGE_LONG_SIDE } else { long_side.min(MAX_IMAGE_LONG_SIDE) };
    ImagePlan { reencode: true, max_long_side: target, quality: IMAGE_JPEG_QUALITY, reason }
}

type UploadResult = Result<String, CmuxMobileError>;

fn lock<T>(mutex: &Mutex<T>) -> MutexGuard<'_, T> {
    mutex.lock().unwrap_or_else(PoisonError::into_inner)
}

struct State {
    progress: UploadProgress,
    /// Bytes the Mac confirmed (needs `have_seen`); where the next attempt starts.
    acked: u64,
    /// This Mac answered `have` for this upload: it resumes.
    have_seen: bool,
    /// The cwd was refused: send without it.
    no_cwd: bool,
    last_emit: Option<Instant>,
    /// The last time the progress bytes moved (reset while waiting for the Mac).
    last_advance: Instant,
    /// Counts every advance, so the run loop can tell an attempt made progress.
    epoch: u64,
    file_ready: bool,
    /// The file's SHA-256 (lowercase hex), sent so the Mac can answer with a copy it has.
    sha256: Option<String>,
    /// This Mac sent no first reply in time: an older hostd, so attempts no longer wait for one.
    silent_mac: bool,
}

struct Upload {
    mac_id: String,
    /// The name on the Mac; `file_ready_as` may change it before the first attempt.
    name: Mutex<String>,
    cwd: Option<String>,
    state: Mutex<State>,
    result: watch::Sender<Option<UploadResult>>,
    task: Mutex<Option<tokio::task::AbortHandle>>,
    channel: Mutex<Option<Arc<ChannelHandle>>>,
    observer: Arc<dyn UploadObserver>,
    timings: Timings,
}

impl Upload {
    fn name(&self) -> String {
        lock(&self.name).clone()
    }

    /// Edits the state; tells the observer when the stage changed, `force`, or the interval passed.
    /// Nothing changes once the upload ended.
    fn edit(&self, force: bool, edit: impl FnOnce(&mut State)) {
        let snapshot = {
            let mut st = lock(&self.state);
            if st.progress.stage.terminal() {
                return;
            }
            let before = st.progress.stage;
            edit(&mut st);
            let due = st.last_emit.is_none_or(|at| at.elapsed() >= self.timings.progress_interval);
            if before == st.progress.stage && !force && !due {
                return;
            }
            st.last_emit = Some(Instant::now());
            st.progress.clone()
        };
        self.observer.on_progress(snapshot);
    }

    fn stage(&self, stage: UploadStage) {
        self.edit(true, |st| st.progress.stage = stage);
    }

    /// Ends the upload (once); false when it had already ended.
    fn finish(&self, outcome: Result<String, (String, String)>, stage: UploadStage) -> bool {
        let snapshot = {
            let mut st = lock(&self.state);
            if st.progress.stage.terminal() {
                return false;
            }
            st.progress.stage = stage;
            match &outcome {
                Ok(path) => {
                    st.progress.mac_path = Some(path.clone());
                    st.progress.acked_bytes = st.progress.total_bytes;
                }
                Err((code, message)) => {
                    st.progress.error_code = Some(code.clone());
                    st.progress.error_message = Some(message.clone());
                }
            }
            st.progress.clone()
        };
        // send_replace, not send: `send` drops the value when no waiter is subscribed yet (the
        // channel keeps no receiver), and a `wait` that came after would then hang forever.
        self.result.send_replace(Some(
            outcome.map_err(|(code, message)| CmuxMobileError::Refused { code, message }),
        ));
        self.observer.on_progress(snapshot);
        true
    }

    fn fail(&self, code: &str, message: &str) {
        self.finish(Err((code.into(), message.into())), UploadStage::Failed);
        self.close_channel("failed");
    }

    /// Closes the attempt's channel without waiting for it.
    fn close_channel(&self, reason: &'static str) {
        if let Some(channel) = lock(&self.channel).take() {
            runtime().spawn(async move { channel.close("cancelled".into(), reason.into()).await });
        }
    }

    /// The Mac confirmed `bytes` (or, from an older hostd, `bytes` were sent).
    fn advance(&self, bytes: u64, confirmed: bool) {
        self.edit(false, |st| {
            if confirmed {
                st.acked = st.acked.max(bytes);
            }
            if bytes > st.progress.acked_bytes {
                st.progress.acked_bytes = bytes.min(st.progress.total_bytes);
                st.last_advance = Instant::now();
                st.epoch += 1;
            }
        });
    }
}

struct Core {
    observer: Arc<dyn UploadObserver>,
    timings: Timings,
    links: Mutex<HashMap<String, watch::Sender<Option<Arc<LinkHandle>>>>>,
    uploads: Mutex<HashMap<String, Arc<Upload>>>,
}

impl Core {
    fn link_channel(&self, mac_id: &str) -> watch::Sender<Option<Arc<LinkHandle>>> {
        lock(&self.links).entry(mac_id.to_string()).or_insert_with(|| watch::channel(None).0).clone()
    }
}

/// Every attachment upload of the app.
#[derive(uniffi::Object)]
pub struct AttachmentUploads {
    core: Arc<Core>,
}

impl AttachmentUploads {
    /// `new` with other time bounds (tests).
    #[doc(hidden)]
    pub fn with_timings(observer: Arc<dyn UploadObserver>, timings: Timings) -> Arc<Self> {
        Arc::new(Self {
            core: Arc::new(Core { observer, timings, links: Mutex::default(), uploads: Mutex::default() }),
        })
    }

    fn get(&self, upload_id: &str) -> Option<Arc<Upload>> {
        lock(&self.core.uploads).get(upload_id).cloned()
    }
}

#[uniffi::export]
impl AttachmentUploads {
    #[uniffi::constructor]
    pub fn new(observer: Arc<dyn UploadObserver>) -> Arc<Self> {
        Self::with_timings(observer, Timings::default())
    }

    /// The Mac's current link (or none). Call on every link change; uploads waiting for the
    /// Mac resume, and one running on a replaced link restarts on the new one.
    pub fn set_link(&self, mac_id: String, link: Option<Arc<LinkHandle>>) {
        if link.is_some() {
            self.core.link_channel(&mac_id).send_replace(link);
            return;
        }
        // No link: an entry nothing waits on goes (one-shot keys never pile up).
        let mut links = lock(&self.core.links);
        if let Some(sender) = links.get(&mac_id) {
            sender.send_replace(None);
            if sender.receiver_count() == 0 {
                links.remove(&mac_id);
            }
        }
    }

    /// Registers an upload in stage `Compressing` and returns its id.
    pub fn reserve(&self, spec: UploadSpec) -> String {
        let id =
            spec.upload_id.filter(|id| !id.is_empty()).unwrap_or_else(|| uuid::Uuid::new_v4().to_string());
        let progress = UploadProgress {
            upload_id: id.clone(),
            stage: UploadStage::Compressing,
            acked_bytes: 0,
            sent_bytes: 0,
            total_bytes: 1000,
            attempt: 0,
            mac_path: None,
            error_code: None,
            error_message: None,
        };
        let upload = Arc::new(Upload {
            mac_id: spec.mac_id,
            name: Mutex::new(spec.name),
            cwd: spec.cwd,
            state: Mutex::new(State {
                progress: progress.clone(),
                acked: 0,
                have_seen: false,
                no_cwd: false,
                last_emit: Some(Instant::now()),
                last_advance: Instant::now(),
                epoch: 0,
                file_ready: false,
                sha256: None,
                silent_mac: false,
            }),
            result: watch::channel(None).0,
            task: Mutex::new(None),
            channel: Mutex::new(None),
            observer: Arc::clone(&self.core.observer),
            timings: self.core.timings.clone(),
        });
        lock(&self.core.uploads).insert(id.clone(), upload);
        self.core.observer.on_progress(progress);
        id
    }

    /// The encoder's progress, 0...1.
    pub fn compress_progress(&self, upload_id: String, fraction: f64) {
        if let Some(upload) = self.get(&upload_id) {
            let permille = (fraction.clamp(0.0, 1.0) * 1000.0).round() as u64;
            upload.edit(false, |st| {
                if st.progress.stage == UploadStage::Compressing {
                    st.progress.acked_bytes = permille;
                }
            });
        }
    }

    /// The file to send is ready at `path`: starts the upload.
    pub fn file_ready(&self, upload_id: String, path: String) {
        let Some(upload) = self.get(&upload_id) else { return };
        {
            let mut st = lock(&upload.state);
            if st.progress.stage != UploadStage::Compressing || st.file_ready {
                return;
            }
            st.file_ready = true;
        }
        let core = Arc::clone(&self.core);
        let task_upload = Arc::clone(&upload);
        let handle = runtime().spawn(run(core, task_upload, PathBuf::from(path)));
        *lock(&upload.task) = Some(handle.abort_handle());
        // Cancelled between the checks above and the handle being stored.
        if lock(&upload.state).progress.stage.terminal() {
            handle.abort();
        }
    }

    /// `file_ready` under another name on the Mac: the platform encoder made a different file
    /// (a HEIC photo re-encoded as `IMG_1.jpg`, `image_plan`).
    pub fn file_ready_as(&self, upload_id: String, path: String, name: String) {
        if let Some(upload) = self.get(&upload_id)
            && !name.is_empty()
            && !lock(&upload.state).file_ready
        {
            *lock(&upload.name) = name;
        }
        self.file_ready(upload_id, path);
    }

    /// `reserve` and `file_ready`.
    pub fn start(&self, spec: UploadSpec, path: String) -> String {
        let id = self.reserve(spec);
        self.file_ready(id.clone(), path);
        id
    }

    /// The compression (or reading the pick) failed: ends the upload with `message`.
    pub fn fail(&self, upload_id: String, code: String, message: String) {
        if let Some(upload) = self.get(&upload_id) {
            upload.fail(&code, &message);
        }
    }

    /// Returns at once. The attempt stops, its channel closes `cancelled` in the background,
    /// waiters get `Refused { code: "cancelled" }`.
    pub fn cancel(&self, upload_id: String) {
        let Some(upload) = self.get(&upload_id) else { return };
        let ended = upload
            .finish(Err(("cancelled".into(), "The upload was cancelled.".into())), UploadStage::Cancelled);
        if let Some(task) = lock(&upload.task).take() {
            task.abort();
        }
        if ended {
            upload.close_channel("cancelled");
        }
    }

    pub fn progress(&self, upload_id: String) -> Option<UploadProgress> {
        self.get(&upload_id).map(|upload| lock(&upload.state).progress.clone())
    }

    /// Drops a finished upload's record.
    pub fn forget(&self, upload_id: String) {
        let mut uploads = lock(&self.core.uploads);
        if uploads.get(&upload_id).is_some_and(|u| lock(&u.state).progress.stage.terminal()) {
            uploads.remove(&upload_id);
        }
    }

    /// The file's path on the Mac, once uploaded.
    pub async fn wait(&self, upload_id: String) -> Result<String, CmuxMobileError> {
        let upload = self
            .get(&upload_id)
            .ok_or_else(|| CmuxMobileError::InvalidArgument { message: format!("no upload {upload_id}") })?;
        let mut rx = upload.result.subscribe();
        loop {
            if let Some(result) = rx.borrow_and_update().clone() {
                return result;
            }
            if rx.changed().await.is_err() {
                return Err(CmuxMobileError::Closed { message: "the upload was dropped".into() });
            }
        }
    }
}

enum Outcome {
    Done(String),
    /// The attempt ended; the upload goes on.
    Retry,
    /// Retry at once (the cwd fallback, a resume gap).
    RetryNow,
    Fatal(String, String),
}

fn unreadable(name: &str) -> Outcome {
    Outcome::Fatal("unreadable".into(), format!("Couldn't read {name} on this iPhone."))
}

async fn run(core: Arc<Core>, upload: Arc<Upload>, path: PathBuf) {
    let size = match tokio::fs::metadata(&path).await {
        Ok(meta) => meta.len(),
        Err(_) => {
            return upload.fail("unreadable", &format!("Couldn't read {} on this iPhone.", upload.name()));
        }
    };
    upload.edit(true, |st| {
        st.progress.total_bytes = size;
        st.progress.acked_bytes = 0;
        st.progress.stage = UploadStage::WaitingForMac;
        st.last_advance = Instant::now();
    });
    let (hashing, hash_path) = (Arc::clone(&upload), path.clone());
    let hashed = tokio::task::spawn_blocking(move || {
        file_sha256(&hash_path, || lock(&hashing.state).progress.stage.terminal())
    });
    match hashed.await {
        Ok(Ok(Some(hash))) => lock(&upload.state).sha256 = Some(hash),
        // Cancelled while hashing.
        Ok(Ok(None)) => return,
        _ => return upload.fail("unreadable", &format!("Couldn't read {} on this iPhone.", upload.name())),
    }
    let timings = upload.timings.clone();
    let mut links = core.link_channel(&upload.mac_id).subscribe();
    let mut backoff = timings.backoff_start;
    loop {
        // A link the keepalive declared dead is no link: wait for the app's next one with the
        // give-up clock held, as for a phone offline, instead of burning attempts on it.
        let current = links.borrow_and_update().clone().filter(|link| !link.is_closed());
        let link = match current {
            Some(link) => link,
            None => {
                upload.stage(UploadStage::WaitingForMac);
                let live =
                    |link: &Option<Arc<LinkHandle>>| link.as_ref().is_some_and(|link| !link.is_closed());
                let Ok(link) = links.wait_for(live).await.map(|l| l.clone()) else { return };
                let Some(link) = link else { continue };
                lock(&upload.state).last_advance = Instant::now();
                link
            }
        };
        let epoch = lock(&upload.state).epoch;
        let outcome = {
            let attempting = attempt(&upload, &link, &path, size);
            tokio::pin!(attempting);
            loop {
                tokio::select! {
                    outcome = &mut attempting => break outcome,
                    changed = links.changed() => {
                        if changed.is_err() { return }
                        let now = links.borrow().clone();
                        if !now.as_ref().is_some_and(|now| Arc::ptr_eq(now, &link)) {
                            break Outcome::RetryNow;
                        }
                    }
                }
            }
        };
        drop(link);
        match outcome {
            Outcome::Done(path) => {
                upload.finish(Ok(path), UploadStage::Done);
                return;
            }
            Outcome::Fatal(code, message) => return upload.fail(&code, &message),
            Outcome::RetryNow => {
                upload.close_channel("retry");
                continue;
            }
            Outcome::Retry => upload.close_channel("retry"),
        }
        let (progressed, idle) = {
            let st = lock(&upload.state);
            (st.epoch != epoch, st.last_advance.elapsed())
        };
        let offline = links.borrow().as_ref().is_none_or(|link| link.is_closed());
        if idle >= timings.give_up && !offline {
            return upload
                .fail("stalled", "The upload stopped making progress, so it gave up. Try sending it again.");
        }
        if progressed {
            backoff = timings.backoff_start;
        }
        upload.stage(UploadStage::WaitingForMac);
        tokio::select! {
            () = tokio::time::sleep(backoff) => {}
            _ = links.changed() => {}
        }
        backoff = (backoff * 2).min(timings.backoff_max);
    }
}

/// The SHA-256 of the file at `path`, lowercase hex, read 1 MiB at a time; `None` once `stop`
/// says the upload ended.
fn file_sha256(path: &std::path::Path, stop: impl Fn() -> bool) -> std::io::Result<Option<String>> {
    use std::fmt::Write as _;
    let mut file = std::fs::File::open(path)?;
    let mut context = ring::digest::Context::new(&ring::digest::SHA256);
    let mut buffer = vec![0_u8; 1 << 20];
    loop {
        if stop() {
            return Ok(None);
        }
        match file.read(&mut buffer)? {
            0 => break,
            n => context.update(&buffer[..n]),
        }
    }
    let mut hex = String::with_capacity(64);
    for byte in context.finish().as_ref() {
        let _ = write!(hex, "{byte:02x}");
    }
    Ok(Some(hex))
}

/// A reply of the Mac.
#[derive(Debug)]
enum Event {
    Have(u64),
    Ack(u64),
    Gap(u64),
    Final(String),
    Refused { code: String, message: String },
    Closed,
}

fn parse_reply(text: &str) -> Option<Event> {
    let value: serde_json::Value = serde_json::from_str(text.trim()).ok()?;
    let number = |key: &str| value.get(key).and_then(serde_json::Value::as_u64);
    if let Some(code) = value.get("error").and_then(|e| e.as_str()) {
        if code == "resume_gap" {
            return number("have").map(Event::Gap);
        }
        let message = value.get("message").and_then(|m| m.as_str()).unwrap_or("The upload failed.");
        return Some(Event::Refused { code: code.into(), message: message.into() });
    }
    if let Some(path) = value.get("path").and_then(|p| p.as_str()) {
        return path.starts_with('/').then(|| Event::Final(path.into()));
    }
    number("ack").map(Event::Ack).or_else(|| number("have").map(Event::Have))
}

/// Reads the channel's replies into events: whole lines, and at the close whatever is left.
async fn reader(channel: Arc<ChannelHandle>, events: mpsc::UnboundedSender<Event>) {
    let mut buffer: Vec<u8> = Vec::new();
    loop {
        match channel.recv().await {
            ChannelMessage::Data { bytes } => {
                buffer.extend(bytes);
                while let Some(end) = buffer.iter().position(|b| *b == b'\n') {
                    let line: Vec<u8> = buffer.drain(..=end).collect();
                    if let Some(event) = parse_reply(&String::from_utf8_lossy(&line)) {
                        let _ = events.send(event);
                    }
                }
            }
            ChannelMessage::Closed { .. } => {
                if let Some(event) = parse_reply(&String::from_utf8_lossy(&buffer)) {
                    let _ = events.send(event);
                }
                let _ = events.send(Event::Closed);
                return;
            }
        }
    }
}

struct AbortOnDrop(tokio::task::JoinHandle<()>);
impl Drop for AbortOnDrop {
    fn drop(&mut self) {
        self.0.abort();
    }
}

/// What `handle` needs besides the upload.
struct Attempt {
    sent_cwd: bool,
    got_have: bool,
    last_ack: Instant,
}

fn handle(upload: &Upload, event: Event, attempt: &mut Attempt) -> Option<Outcome> {
    match event {
        Event::Have(bytes) => {
            attempt.got_have = true;
            attempt.last_ack = Instant::now();
            lock(&upload.state).have_seen = true;
            upload.advance(bytes, true);
            None
        }
        Event::Ack(bytes) => {
            attempt.last_ack = Instant::now();
            lock(&upload.state).have_seen = true;
            upload.advance(bytes, true);
            None
        }
        Event::Gap(have) => {
            let mut st = lock(&upload.state);
            st.have_seen = true;
            st.acked = have;
            Some(Outcome::RetryNow)
        }
        Event::Final(path) => Some(Outcome::Done(path)),
        Event::Refused { code, message } => match code.as_str() {
            // `unavailable` with a cwd is the Mac's daemon not answering for the tab folder
            // (hostd bounds it at 5 s); the uploads folder needs no daemon.
            "forbidden" | "not_found" | "unavailable" if attempt.sent_cwd => {
                lock(&upload.state).no_cwd = true;
                Some(Outcome::RetryNow)
            }
            "bad_request" | "io" | "forbidden" | "not_found" => Some(Outcome::Fatal(code, message)),
            _ => Some(Outcome::Retry),
        },
        Event::Closed => Some(Outcome::Retry),
    }
}

fn read_chunk(mut file: std::fs::File, want: usize) -> (std::fs::File, std::io::Result<Vec<u8>>) {
    let mut buffer = vec![0_u8; want];
    let read = file.read(&mut buffer).map(|n| {
        buffer.truncate(n);
        buffer
    });
    (file, read)
}

async fn attempt(
    upload: &Arc<Upload>,
    link: &Arc<LinkHandle>,
    path: &std::path::Path,
    total: u64,
) -> Outcome {
    let timings = &upload.timings;
    let (offset, use_cwd, sha256, silent_mac) = {
        let st = lock(&upload.state);
        (if st.have_seen { st.acked.min(total) } else { 0 }, !st.no_cwd, st.sha256.clone(), st.silent_mac)
    };
    upload.edit(true, |st| {
        st.progress.attempt += 1;
        st.progress.stage = UploadStage::Uploading;
    });
    let mut args = serde_json::json!({
        "name": upload.name(),
        "size": total.to_string(),
        "upload_id": lock(&upload.state).progress.upload_id,
        "offset": offset.to_string(),
    });
    let wait_first = sha256.is_some() && offset == 0 && !silent_mac;
    if let Some(hash) = sha256 {
        args["sha256"] = hash.into();
    }
    let sent_cwd = match upload.cwd.as_deref().filter(|c| use_cwd && c.starts_with('/')) {
        Some(cwd) => {
            args["cwd"] = cwd.into();
            true
        }
        None => false,
    };
    let channel = match tokio::time::timeout(
        timings.open,
        link.open_channel("upload".into(), args.to_string()),
    )
    .await
    {
        Ok(Ok(channel)) => channel,
        _ => return Outcome::Retry,
    };
    *lock(&upload.channel) = Some(Arc::clone(&channel));
    let (tx, mut events) = mpsc::unbounded_channel();
    let _reader = AbortOnDrop(runtime().spawn(reader(Arc::clone(&channel), tx)));
    let mut state = Attempt { sent_cwd, got_have: false, last_ack: Instant::now() };

    let file_path = path.to_path_buf();
    let opened = tokio::task::spawn_blocking(move || {
        let mut file = std::fs::File::open(file_path)?;
        file.seek(SeekFrom::Start(offset))?;
        Ok::<_, std::io::Error>(file)
    })
    .await;
    let Ok(Ok(mut file)) = opened else { return unreadable(&upload.name()) };

    if wait_first {
        // The Mac may already have this file: hear it before sending any byte.
        match tokio::time::timeout(timings.first_reply, events.recv()).await {
            Ok(Some(event)) => {
                if let Some(outcome) = handle(upload, event, &mut state) {
                    return outcome;
                }
            }
            Ok(None) => return Outcome::Retry,
            Err(_) => lock(&upload.state).silent_mac = true,
        }
    }

    if offset > 0 {
        let deadline = tokio::time::Instant::now() + timings.have;
        while !state.got_have {
            match tokio::time::timeout_at(deadline, events.recv()).await {
                Ok(Some(event)) => {
                    if let Some(outcome) = handle(upload, event, &mut state) {
                        return outcome;
                    }
                }
                _ => return Outcome::Retry,
            }
        }
    }

    let mut position = offset;
    let mut send_failed = false;
    loop {
        while let Ok(event) = events.try_recv() {
            if let Some(outcome) = handle(upload, event, &mut state) {
                return outcome;
            }
        }
        if position < total && !send_failed {
            let (have_seen, acked) = {
                let st = lock(&upload.state);
                (st.have_seen, st.acked)
            };
            if have_seen
                && position.saturating_sub(acked) >= STALL_WINDOW
                && state.last_ack.elapsed() > timings.ack_stall
            {
                return Outcome::Retry;
            }
            let want = CHUNK.min(usize::try_from(total - position).unwrap_or(CHUNK));
            let (back, chunk) = match tokio::task::spawn_blocking(move || read_chunk(file, want)).await {
                Ok((file, Ok(chunk))) if !chunk.is_empty() => (file, chunk),
                _ => return unreadable(&upload.name()),
            };
            file = back;
            let count = chunk.len() as u64;
            match tokio::time::timeout(timings.ack_stall, channel.send(chunk)).await {
                Err(_) => return Outcome::Retry,
                // The Mac closed or answered early: read what it says.
                Ok(Err(_)) => send_failed = true,
                Ok(Ok(())) => {
                    position += count;
                    upload.edit(false, |st| st.progress.sent_bytes += count);
                    if !lock(&upload.state).have_seen {
                        upload.advance(position, false);
                    }
                }
            }
        } else {
            if !send_failed {
                upload.edit(true, |st| st.progress.stage = UploadStage::Finishing);
            }
            return match tokio::time::timeout(timings.final_answer, events.recv()).await {
                Ok(Some(event)) => match handle(upload, event, &mut state) {
                    Some(outcome) => outcome,
                    None => continue_waiting(upload, &mut events, &mut state, timings.final_answer).await,
                },
                _ => Outcome::Retry,
            };
        }
    }
}

/// After the last byte: replies until the final answer or a close, within `bound` in all.
async fn continue_waiting(
    upload: &Upload,
    events: &mut mpsc::UnboundedReceiver<Event>,
    state: &mut Attempt,
    bound: Duration,
) -> Outcome {
    let deadline = tokio::time::Instant::now() + bound;
    loop {
        match tokio::time::timeout_at(deadline, events.recv()).await {
            Ok(Some(event)) => {
                if let Some(outcome) = handle(upload, event, state) {
                    return outcome;
                }
            }
            _ => return Outcome::Retry,
        }
    }
}
