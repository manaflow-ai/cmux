//! Part of `transfer.rs`. Live migration, the client's half (`hub/transfer_live.rs` is the
//! daemons'): the chat's history is copied to the target in rounds while it keeps taking turns,
//! each round only what the target does not hold yet, compressed, and the freeze moves only
//! what the last round left.
//!
//! 2026-11-22: a move of a 7.26 GB coordinator chat over a ~96 KB/s relay froze it for the
//! whole copy (708 MB in 47 min, about 6 h to go). Now:
//!
//! 1. Round one stages the whole prefix with no freeze (`transfer_prepare`, `transfer_stage
//!    {resume: true}`, pages). A target that holds an unfinished stage of the chat (a move begun
//!    before whose client went away) says what it holds, and the pages go on from there once the
//!    source's digest of the same bytes agrees (`transfer_digest`).
//! 2. Each later round prepares again and sends only what came since, until a round sends at most
//!    [`SMALL_ROUND`] or [`MAX_ROUNDS`] are done. Then the stage is finished (indexed) and the
//!    freeze (`transfer_begin {prepareId, afterSeq}`) moves only what followed.
//! 3. Pages to a target that lists `transfer-live-v1` go zstd-compressed (an event log is about
//!    10x smaller), at [`PAGE`] bytes a request.
//! 4. Every few seconds the client tells the source where the move is (`transfer_progress`,
//!    `session info`'s `move:` line) and prints it.
//! 5. A copy whose estimate is past the move's bound (`Live::max_copy`, from `session move`'s
//!    placement) stops with [`SLOW`]: the stage stays, so the move begun again goes on from it.

use super::*;
use base64::Engine;
use base64::engine::general_purpose::STANDARD as BASE64;
use std::collections::HashMap;
use std::time::{Duration, Instant};

/// A round that sent at most this many bytes is the last before the freeze.
pub(super) const SMALL_ROUND: u64 = 8 << 20;
/// The most rounds before the freeze, however much each sends.
pub(super) const MAX_ROUNDS: u32 = 6;
/// The bytes a page asks the source for (its `MAX_PAGE`).
pub(super) const PAGE: u64 = 4 << 20;
/// zstd's level for pages: fast, and about 10x on an event log.
const LEVEL: i32 = 3;
/// How often the source hears where the move is, and the console with it.
const REPORT_EVERY: Duration = Duration::from_secs(3);
/// The error code of a copy that would take longer than the move's bound.
pub(super) const SLOW: &str = "transfer.slow";
/// A chat whose log is past this is never copied whole inside a freeze: with no pre-copy the
/// move is refused instead (the incident's freeze was the whole copy).
pub(super) const WHOLE_FREEZE_LIMIT: u64 = 256 << 20;

/// What a move's copy may do and where its progress goes.
#[derive(Clone, Default)]
pub(crate) struct Live {
    /// Stop a copy whose estimate is past this (`SLOW`); `None`: no bound.
    pub max_copy: Option<Duration>,
    /// Where the target is, for the progress line (`lane-vm-7`).
    pub target: String,
    /// Print progress to stderr.
    pub verbose: bool,
}

/// Whether a daemon's `initialize` or `_acpmux/status` reply lists capability `id`.
pub(super) fn lists(reply: &Value, pointer: &str, id: &str) -> bool {
    let ids = reply.pointer(pointer).and_then(Value::as_array);
    ids.is_some_and(|ids| ids.iter().any(|x| x == id))
}

/// A move's copy, as it goes: how it pages and how far it is.
pub(super) struct Pager<'a> {
    src: &'a Daemon<'a>,
    session: String,
    live: Live,
    /// The target takes zstd pages.
    zstd: bool,
    /// `pre-copy` or `freeze`.
    pub phase: &'static str,
    pub round: u32,
    /// Bytes of the files this round pages (their size), and how many it sent or found held.
    pub total: u64,
    pub done: u64,
    /// Bytes this round sent, as the files hold them and as they went.
    pub sent: u64,
    pub wire: u64,
    started: Instant,
    round_started: Instant,
    last_report: Option<Instant>,
}

impl<'a> Pager<'a> {
    pub(super) fn new(src: &'a Daemon<'a>, session: &str, live: Live, zstd: bool) -> Self {
        Self {
            src,
            session: session.to_owned(),
            live,
            zstd,
            phase: "pre-copy",
            round: 0,
            total: 0,
            done: 0,
            sent: 0,
            wire: 0,
            started: Instant::now(),
            round_started: Instant::now(),
            last_report: None,
        }
    }

    /// A new round over `manifest`'s files.
    pub(super) fn begin_round(&mut self, phase: &'static str, manifest: &Value) {
        self.phase = phase;
        self.round += 1;
        self.total = files_bytes(manifest);
        (self.done, self.sent, self.wire) = (0, 0, 0);
        self.round_started = Instant::now();
    }

    /// Bytes a second this round has sent, as the files hold them.
    fn rate(&self) -> Option<f64> {
        let secs = self.round_started.elapsed().as_secs_f64();
        (secs >= 1.0 && self.sent > 0).then(|| self.sent as f64 / secs)
    }

    /// Seconds this round has left at its rate so far.
    fn eta(&self) -> Option<f64> {
        self.rate().map(|r| self.total.saturating_sub(self.done) as f64 / r)
    }

    /// The report the source shows in `session info`.
    pub(super) fn report(&self) -> Value {
        let mut r = json!({"sessionId": self.session, "phase": self.phase, "round": self.round,
                           "totalBytes": self.total, "doneBytes": self.done,
                           "sentBytes": self.sent, "wireBytes": self.wire,
                           "elapsedMs": self.started.elapsed().as_millis() as u64,
                           "target": self.live.target});
        if let Some(rate) = self.rate() {
            r.set("bytesPerSec", json!(rate.round() as u64));
        }
        if let Some(eta) = self.eta() {
            r.set("etaSecs", json!(eta.round() as u64));
        }
        r
    }

    /// Tells the source (and the console) where the move is, at most every [`REPORT_EVERY`]
    /// unless `now`; refuses with [`SLOW`] once the estimate is past the move's bound.
    pub(super) async fn tick(&mut self, now: bool) -> Result<()> {
        if !now && self.last_report.is_some_and(|t| t.elapsed() < REPORT_EVERY) {
            return Ok(());
        }
        self.last_report = Some(Instant::now());
        let report = self.report();
        // An older source has no progress to show: the move goes on all the same.
        let _ = self.src.request("_acpmux/transfer_progress", report.clone()).await;
        if self.live.verbose {
            eprintln!("move: {}", progress_text(&report));
        }
        // Judged once the rate has had a little time to settle.
        if let (Some(bound), Some(eta)) = (self.live.max_copy, self.eta())
            && self.round_started.elapsed() >= Duration::from_secs(20)
            && eta > bound.as_secs_f64()
        {
            anyhow::bail!(
                "{SLOW}: copying {} to {} would take about {} more at {}/s, over this move's \
                 {} bound; the chat kept running, and what was copied stays there for the move \
                 begun again (pass --slow-ok to wait it out, or pick a better-connected machine)",
                mb(self.total.saturating_sub(self.done)),
                self.live.target,
                duration_text(eta),
                mb(self.rate().unwrap_or(0.0) as u64),
                duration_text(bound.as_secs_f64())
            );
        }
        Ok(())
    }

    /// The move is over: its report goes.
    pub(super) async fn done(&self) {
        let _ = self
            .src
            .request(
                "_acpmux/transfer_progress",
                json!({"sessionId": self.session, "phase": "done"}),
            )
            .await;
    }
}

/// The bytes of the files a manifest lists.
fn files_bytes(manifest: &Value) -> u64 {
    manifest
        .get("files")
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|f| f.get("size").and_then(Value::as_u64))
        .sum()
}

/// Pages every file `manifest` lists from `src`'s `transfer_id` into `receive_id` on `dst`,
/// each from its offset in `from` (what a resumed stage holds), compressed for a target that
/// takes it.
#[allow(clippy::too_many_arguments)]
pub(super) async fn page_files(
    src: &Daemon<'_>,
    dst: &Daemon<'_>,
    manifest: &Value,
    transfer_id: &Value,
    receive_id: &Value,
    epoch: Option<u64>,
    from: &HashMap<String, u64>,
    pager: &mut Pager<'_>,
) -> Result<()> {
    let files = manifest.get("files").and_then(Value::as_array).cloned().unwrap_or_default();
    for file in &files {
        let path = file.get("path").and_then(Value::as_str).unwrap_or_default();
        let size = file.get("size").and_then(Value::as_u64).unwrap_or(0);
        let mut offset = from.get(path).copied().unwrap_or(0).min(size);
        pager.done += offset;
        if offset == size && size > 0 {
            continue;
        }
        loop {
            let mut read = json!({"transferId": transfer_id, "path": path, "offset": offset,
                                  "limit": PAGE});
            let page = src.request("_acpmux/transfer_read", stamped(&mut read, epoch)).await?;
            let next = page
                .get("next")
                .and_then(Value::as_u64)
                .ok_or_else(|| anyhow!("transfer_read: no next"))?;
            let data = page.get("data").and_then(Value::as_str).unwrap_or_default();
            let mut write = json!({"receiveId": receive_id, "path": path, "offset": offset});
            let wire = if pager.zstd && !data.is_empty() {
                let raw = BASE64.decode(data).map_err(|e| anyhow!("transfer_read: data: {e}"))?;
                let packed = zstd::bulk::compress(&raw, LEVEL)?;
                write.set("encoding", json!("zstd"));
                let packed = BASE64.encode(packed);
                let len = packed.len() as u64;
                write.set("data", json!(packed));
                len
            } else {
                write.set("data", json!(data));
                data.len() as u64
            };
            if let Err(e) = dst.request("_acpmux/transfer_write", stamped(&mut write, epoch)).await
            {
                // A page the target took whose answer was lost (its daemon was swapped), or one
                // it holds more of: go on from what it holds (`transfer_reconnect.rs`).
                match held_after(&e).filter(|held| *held <= size && *held != offset) {
                    Some(held) => {
                        pager.done = pager.done.saturating_sub(offset) + held;
                        offset = held;
                        continue;
                    }
                    None => return Err(e),
                }
            }
            let moved = next.saturating_sub(offset);
            (pager.done, pager.sent, pager.wire) =
                (pager.done + moved, pager.sent + moved, pager.wire + wire);
            pager.tick(false).await?;
            offset = next;
            if page.get("eof") == Some(&Value::Bool(true)) {
                break;
            }
        }
    }
    Ok(())
}

/// The size a target's `transfer.offset` refusal says it holds of the file.
fn held_after(e: &anyhow::Error) -> Option<u64> {
    let rpc = e.chain().find_map(|c| c.downcast_ref::<crate::client::DaemonError>())?;
    if !rpc.0.message.starts_with("transfer.offset") {
        return None;
    }
    rpc.0.data.as_ref()?.get("size")?.as_u64()
}

/// `params` with the move's `epoch`, when it has one (a prepare's pages carry none).
pub(super) fn stamped(params: &mut Value, epoch: Option<u64>) -> Value {
    if let Some(epoch) = epoch {
        params.set("epoch", json!(epoch));
    }
    params.take()
}

/// Where pages start when the target already holds part of the files (`have` in a resumed
/// stage's answer, or in a receive seeded from a stage's native files): each file it holds, at
/// what it holds, once the source's digest of the same bytes of its `transfer_id` (a prepare or
/// a move) agrees; from zero (the target writes it again) when it does not or the source cannot
/// say.
pub(super) async fn resume_offsets(
    src: &Daemon<'_>,
    prepare_id: &str,
    stage: &Value,
) -> HashMap<String, u64> {
    let mut from = HashMap::new();
    for held in stage.get("have").and_then(Value::as_array).into_iter().flatten() {
        let (Some(path), Some(bytes), Some(sha)) = (
            held.get("path").and_then(Value::as_str),
            held.get("bytes").and_then(Value::as_u64),
            held.get("sha256").and_then(Value::as_str),
        ) else {
            continue;
        };
        let asked = json!({"transferId": prepare_id, "path": path, "length": bytes});
        let theirs = src.request("_acpmux/transfer_digest", asked).await.ok();
        let same = theirs.and_then(|t| t.get("sha256").and_then(Value::as_str).map(str::to_owned));
        from.insert(path.to_owned(), if same.as_deref() == Some(sha) { bytes } else { 0 });
    }
    from
}

fn mb(bytes: u64) -> String {
    let b = bytes as f64;
    if b >= 1e9 {
        format!("{:.2} GB", b / 1e9)
    } else if b >= 1e6 {
        format!("{:.1} MB", b / 1e6)
    } else {
        format!("{:.0} KB", b / 1e3)
    }
}

/// `2h 05m`, `14m 03s`, `9s`.
pub(crate) fn duration_text(secs: f64) -> String {
    let s = secs.max(0.0).round() as u64;
    match (s / 3600, (s % 3600) / 60, s % 60) {
        (0, 0, s) => format!("{s}s"),
        (0, m, s) => format!("{m}m {s:02}s"),
        (h, m, _) => format!("{h}h {m:02}m"),
    }
}

/// One line for a progress report: `pre-copy round 1 to HOST: 120.3 MB of 6.80 GB (wire 12.1 MB,
/// 1.0 MB/s), about 1h 52m left`.
pub(crate) fn progress_text(r: &Value) -> String {
    let n = |k: &str| r.get(k).and_then(Value::as_u64).unwrap_or(0);
    let phase = r.get("phase").and_then(Value::as_str).unwrap_or("?");
    let target = r.get("target").and_then(Value::as_str).filter(|t| !t.is_empty());
    let to = target.map(|t| format!(" to {t}")).unwrap_or_default();
    let mut line = format!(
        "{phase} round {}{to}: {} of {} (wire {}",
        n("round"),
        mb(n("doneBytes")),
        mb(n("totalBytes")),
        mb(n("wireBytes"))
    );
    if let Some(rate) = r.get("bytesPerSec").and_then(Value::as_u64) {
        line.push_str(&format!(", {}/s", mb(rate)));
    }
    line.push(')');
    if let Some(eta) = r.get("etaSecs").and_then(Value::as_u64) {
        line.push_str(&format!(", about {} left", duration_text(eta as f64)));
    }
    line
}

/// `session info`'s `move:` line, while a move of the chat reports.
pub(crate) fn move_progress_line(info: &Value) -> Option<String> {
    let r = info.get("moveProgress").filter(|r| r.is_object())?;
    Some(format!("move:      {}", progress_text(r)))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn progress_reads_as_a_line() {
        let r = json!({"phase": "pre-copy", "round": 1, "totalBytes": 6_800_000_000u64,
                       "doneBytes": 120_300_000u64, "wireBytes": 12_100_000u64,
                       "bytesPerSec": 1_000_000u64, "etaSecs": 6720u64,
                       "target": "lane-vm-7"});
        assert_eq!(
            progress_text(&r),
            "pre-copy round 1 to lane-vm-7: 120.3 MB of 6.80 GB (wire 12.1 MB, 1.0 MB/s), \
             about 1h 52m left"
        );
        assert_eq!(move_progress_line(&json!({"moveProgress": null})), None);
        assert!(move_progress_line(&json!({"moveProgress": r})).unwrap().starts_with("move:"));
        assert_eq!(duration_text(9.0), "9s");
        assert_eq!(duration_text(843.0), "14m 03s");
    }
}
