use super::*;

pub(crate) fn line(at_work: &[SessionAtWork], now_ms: u64) -> Value {
    let mut tracker = Tracker::new("/probe.sock".into());
    tracker.observe(at_work, now_ms);
    tracker.line(at_work.len() as u64, true, now_ms).expect("a renewal always sends")
}

/// Whether the Cloud may pause the machine on `line` (no session at work).
pub(crate) fn pausable(line: &Value) -> bool {
    flushes_before(line)
}
