//! Part of `session_move.rs`. How long a move's copy takes over the link to a target, before
//! anything is copied: the history's bytes as they go (compressed), over the bytes a second a
//! fresh ssh to the target carries (`probe_rate`).
//!
//! 2026-11-22: a 7.26 GB chat was sent to a host reached only through a ~96 KB/s relay (about
//! 6 h), when another host took about 1 MB/s. Placement now passes over a host whose copy is
//! estimated past [`SLOW_COPY`] (`walk`), and a named one is refused unless `--slow-ok`.

use std::io::{BufRead as _, Write as _};
use std::process::{Command, Stdio};
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

/// Bytes a second a fresh ssh to `ssh` carries, the way the move's forward goes: 1 MiB of
/// bytes that do not compress, timed from the far end's first line to its last, so the ssh
/// handshake is not counted. A link that does not finish in [`PROBE_BOUND`] is at most that
/// fast. `None` when the probe could not run at all.
pub(crate) fn probe_rate(ssh: &str) -> Option<f64> {
    let script = "read -r _; echo ready; head -c 1048576 >/dev/null; echo done";
    let argv = crate::cli::hosts::ssh_argv(ssh, script).ok()?;
    let mut child = Command::new("ssh")
        .args(argv)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let mut stdin = child.stdin.take()?;
    let stdout = child.stdout.take()?;
    let (tx, rx) = std::sync::mpsc::channel::<String>();
    std::thread::spawn(move || {
        for line in std::io::BufReader::new(stdout).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
    let started = Instant::now();
    let rate = (|| {
        stdin.write_all(b"go\n").ok()?;
        stdin.flush().ok()?;
        let ready = rx.recv_timeout(PROBE_BOUND).ok()?;
        if ready.trim() != "ready" {
            return None;
        }
        let t0 = Instant::now();
        let payload = noise(PROBE_BYTES);
        let writer = std::thread::spawn(move || {
            let _ = stdin.write_all(&payload);
        });
        let left = PROBE_BOUND.saturating_sub(started.elapsed()).max(Duration::from_secs(2));
        // Unfinished in time: at most this fast.
        let _ = rx.recv_timeout(left);
        let secs = t0.elapsed().as_secs_f64().max(0.001);
        drop(writer);
        Some(PROBE_BYTES as f64 / secs)
    })();
    let _ = child.kill();
    let _ = child.wait();
    rate
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
        // Mango: 6.8 GB of event log.
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
