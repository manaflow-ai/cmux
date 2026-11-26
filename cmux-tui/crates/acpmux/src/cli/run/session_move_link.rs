//! Part of `session_move.rs`. How long a move's copy takes over the link to a target, before
//! anything is copied: the history's bytes as they go (compressed), over the bytes a second a
//! fresh ssh to the target carries (`probe_rate`).
//!
//! 2026-11-22: a 7.26 GB chat was sent to a host reached only through a ~96 KB/s relay (about
//! 6 h), when another host took about 1 MB/s. Placement now passes over a host whose copy is
//! estimated past [`SLOW_COPY`] (`walk`), and a named one is refused unless `--slow-ok`.

use std::time::{Duration, Instant};

/// A copy estimated past this is slow: passed over by `auto`, refused for a named host without
/// `--slow-ok`. The chat runs all through the copy, so this bounds the wait, not a freeze.
pub(crate) const SLOW_COPY: Duration = Duration::from_secs(2 * 3600);
/// A copy estimated past this is named in a warning.
pub(crate) const WARN_COPY: Duration = Duration::from_secs(10 * 60);
/// What an event log's pages weigh once compressed, of their size (zstd level 3 on a coordinator
/// chat's log: 8.46 MB to 0.88 MB, plus base64): an estimate, on the heavy side.
pub(crate) const WIRE_RATIO: f64 = 0.15;
/// A copy under this many bytes on the wire is not worth probing the link for.
pub(crate) const PROBE_OVER: u64 = 32 << 20;
/// The probe's bytes, and the longest it waits.
const PROBE_BYTES: usize = 1 << 20;
const PROBE_BOUND: Duration = Duration::from_secs(8);

/// The bytes a copy of `history` bytes of log sends.
pub(crate) fn wire_bytes(history: u64) -> u64 {
    (history as f64 * WIRE_RATIO) as u64
}

/// Seconds a copy of `wire` bytes takes at `rate` bytes a second.
pub(crate) fn copy_secs(wire: u64, rate: f64) -> f64 {
    wire as f64 / rate.max(1.0)
}

/// Bytes a second a fresh ssh to `ssh` carries, the way the move's forward goes: one ssh that
/// takes 1 MiB of bytes that do not compress, less one that takes none (the handshake and the
/// round trip). A link that does not finish in [`PROBE_BOUND`] is at most that fast. `None`
/// when the probe could not run at all.
pub(crate) fn probe_rate(ssh: &str) -> Option<f64> {
    let timed = |bytes: usize| -> Option<(f64, bool)> {
        let argv = crate::cli::hosts::ssh_argv(ssh, "cat >/dev/null").ok()?;
        let mut cmd = cmux_process::Command::new("ssh");
        cmd.args(argv);
        let started = Instant::now();
        let ran =
            crate::cli::owned_child::owned(&mut cmd, Some(noise(bytes)), PROBE_BOUND, "link probe");
        let secs = started.elapsed().as_secs_f64();
        match ran {
            Ok(out) if out.status.success() => Some((secs, true)),
            Err(e) if e.kind() == std::io::ErrorKind::TimedOut => Some((secs, false)),
            _ => None,
        }
    };
    let (empty, done) = timed(0)?;
    if !done {
        return None;
    }
    let (full, _) = timed(PROBE_BYTES)?;
    // Unfinished in time: at most this fast.
    Some(PROBE_BYTES as f64 / (full - empty).max(0.001))
}

/// `n` bytes that do not compress (xorshift).
fn noise(n: usize) -> Vec<u8> {
    let mut x: u64 = 0x9e37_79b9_7f4a_7c15;
    (0..n)
        .map(|_| {
            x ^= x << 13;
            x ^= x >> 7;
            x ^= x << 17;
            (x >> 24) as u8
        })
        .collect()
}

/// `1.0 MB/s`, `96 KB/s`.
pub(crate) fn rate_text(rate: f64) -> String {
    if rate >= 1e6 { format!("{:.1} MB/s", rate / 1e6) } else { format!("{:.0} KB/s", rate / 1e3) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_incident_estimates_hours_over_the_relay_and_minutes_over_a_direct_link() {
        // The 2026-11-22 coordinator chat: 6.8 GB of event log.
        let wire = wire_bytes(6_800_000_000);
        assert!(copy_secs(wire, 96_000.0) > SLOW_COPY.as_secs_f64());
        assert!(copy_secs(wire, 1_000_000.0) < SLOW_COPY.as_secs_f64() / 4.0);
        assert_eq!(rate_text(96_000.0), "96 KB/s");
        assert_eq!(rate_text(1_000_000.0), "1.0 MB/s");
    }

    #[test]
    fn noise_does_not_compress() {
        let bytes = noise(1 << 16);
        let packed = zstd::bulk::compress(&bytes, 3).unwrap();
        assert!(packed.len() > bytes.len() * 9 / 10);
    }
}
