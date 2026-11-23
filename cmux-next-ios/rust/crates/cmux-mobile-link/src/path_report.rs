//! One log line for a link's path and round trip: on every path change and
//! every [`PATH_REPORT_INTERVAL`] between them, so a log shows which route a
//! phone used and how slow it was at any moment (relay or direct, and the
//! resets a network change causes).
//!
//! [`PathReport`] is the pure part (tested below); [`run`] drives it from a
//! link's path and RTT watches until the link closes.

use std::time::Duration;

use tokio::sync::watch;
use tokio::time::Instant;

use crate::dial::LinkPath;

/// The longest gap between two lines while the path holds.
pub const PATH_REPORT_INTERVAL: Duration = Duration::from_secs(10);

/// Why a line was written.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PathReportReason {
    /// The first line, at link up.
    Up,
    /// The path changed since the last line.
    Changed,
    /// [`PATH_REPORT_INTERVAL`] passed with the same path.
    Periodic,
}

/// One line's contents.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PathLine {
    pub path: LinkPath,
    /// Smoothed RTT (RFC 6298: 7/8 old, 1/8 new); `None` before the first pong.
    pub srtt: Option<Duration>,
    /// The latest RTT sample.
    pub rtt: Option<Duration>,
    /// Path changes since link up, this one included.
    pub changes: u32,
    pub reason: PathReportReason,
}

impl PathLine {
    pub fn srtt_ms(&self) -> Option<u64> {
        self.srtt.map(|d| d.as_millis() as u64)
    }

    pub fn rtt_ms(&self) -> Option<u64> {
        self.rtt.map(|d| d.as_millis() as u64)
    }
}

/// The state between lines.
#[derive(Debug, Default)]
pub struct PathReport {
    path: Option<LinkPath>,
    srtt: Option<Duration>,
    rtt: Option<Duration>,
    changes: u32,
    last_line: Option<Instant>,
}

impl PathReport {
    /// A new RTT sample.
    pub fn sample(&mut self, rtt: Duration) {
        self.rtt = Some(rtt);
        self.srtt = Some(match self.srtt {
            None => rtt,
            Some(srtt) => (srtt * 7 + rtt) / 8,
        });
    }

    /// The line due at `now` with the link on `path`, if any.
    pub fn observe(&mut self, now: Instant, path: LinkPath) -> Option<PathLine> {
        let reason = match self.path {
            None => PathReportReason::Up,
            Some(old) if old != path => PathReportReason::Changed,
            Some(_) if self.last_line.is_none_or(|last| now >= last + PATH_REPORT_INTERVAL) => {
                PathReportReason::Periodic
            }
            Some(_) => return None,
        };
        if reason == PathReportReason::Changed {
            self.changes += 1;
        }
        self.path = Some(path);
        self.last_line = Some(now);
        Some(PathLine { path, srtt: self.srtt, rtt: self.rtt, changes: self.changes, reason })
    }
}

/// Write `emit` lines for a link until its path or RTT watch closes.
pub async fn run(
    mut path: watch::Receiver<LinkPath>,
    mut rtt: watch::Receiver<Option<Duration>>,
    mut emit: impl FnMut(PathLine) + Send,
) {
    let mut report = PathReport::default();
    if let Some(sample) = *rtt.borrow_and_update() {
        report.sample(sample);
    }
    let current = *path.borrow_and_update();
    if let Some(line) = report.observe(Instant::now(), current) {
        emit(line);
    }
    let mut ticker = tokio::time::interval_at(Instant::now() + PATH_REPORT_INTERVAL, PATH_REPORT_INTERVAL);
    ticker.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
    loop {
        tokio::select! {
            changed = path.changed() => {
                if changed.is_err() { return; }
            }
            changed = rtt.changed() => {
                if changed.is_err() { return; }
                if let Some(sample) = *rtt.borrow_and_update() {
                    report.sample(sample);
                }
                continue;
            }
            _ = ticker.tick() => {}
        }
        let current = *path.borrow_and_update();
        if let Some(line) = report.observe(Instant::now(), current) {
            emit(line);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn first_line_then_every_interval_and_every_change() {
        let start = Instant::now();
        let mut report = PathReport::default();
        assert_eq!(report.observe(start, LinkPath::Turn).map(|l| l.reason), Some(PathReportReason::Up));
        assert_eq!(report.observe(start + Duration::from_secs(3), LinkPath::Turn), None);
        let periodic = report.observe(start + PATH_REPORT_INTERVAL, LinkPath::Turn).unwrap();
        assert_eq!(periodic.reason, PathReportReason::Periodic);
        let changed =
            report.observe(start + PATH_REPORT_INTERVAL + Duration::from_secs(1), LinkPath::NoPath).unwrap();
        assert_eq!((changed.reason, changed.changes), (PathReportReason::Changed, 1));
        let back =
            report.observe(start + PATH_REPORT_INTERVAL + Duration::from_secs(2), LinkPath::Turn).unwrap();
        assert_eq!((back.reason, back.changes, back.path), (PathReportReason::Changed, 2, LinkPath::Turn));
    }

    #[test]
    fn srtt_smooths_one_eighth() {
        let mut report = PathReport::default();
        report.sample(Duration::from_millis(80));
        report.sample(Duration::from_millis(160));
        let line = report.observe(Instant::now(), LinkPath::Direct).unwrap();
        assert_eq!((line.srtt_ms(), line.rtt_ms()), (Some(90), Some(160)));
    }

    #[tokio::test(start_paused = true)]
    async fn run_writes_on_change_and_each_interval() {
        let (path_tx, path_rx) = watch::channel(LinkPath::Turn);
        let (rtt_tx, rtt_rx) = watch::channel(None);
        let lines = std::sync::Arc::new(std::sync::Mutex::new(Vec::new()));
        let sink = std::sync::Arc::clone(&lines);
        let task = tokio::spawn(run(path_rx, rtt_rx, move |line| sink.lock().unwrap().push(line)));
        tokio::task::yield_now().await;
        rtt_tx.send_replace(Some(Duration::from_millis(40)));
        tokio::time::sleep(PATH_REPORT_INTERVAL + Duration::from_millis(1)).await;
        path_tx.send_replace(LinkPath::Direct);
        tokio::time::sleep(Duration::from_millis(1)).await;
        drop(path_tx);
        task.await.unwrap();
        let lines = lines.lock().unwrap();
        let reasons: Vec<_> = lines.iter().map(|l| l.reason).collect();
        assert_eq!(reasons, [PathReportReason::Up, PathReportReason::Periodic, PathReportReason::Changed]);
        assert_eq!(lines[1].srtt_ms(), Some(40));
        assert_eq!(lines[2].path, LinkPath::Direct);
    }
}
