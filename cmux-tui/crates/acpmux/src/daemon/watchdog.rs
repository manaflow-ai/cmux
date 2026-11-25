//! The daemon's self-check under systemd: it pings the unit's watchdog only while the daemon
//! answers its own hello, and restarts itself through its restart handoff when its memory stays
//! over a bound.
//!
//! On 2026-11-20 huge-blue's daemon grew to 16.5 GB at 186% CPU and stopped answering hello;
//! `Restart=always` only reacts to an exit, so it stayed hung and every peer read it as
//! "reconnecting" until someone restarted it by hand. `acpmux.service` now takes the daemon's
//! notifications (`NotifyAccess=main`, `cli/hosts.rs` `SYSTEMD_UNIT`); this thread arms systemd's
//! watchdog at [`LIMIT`] and is the only thing that pings it:
//! - Every [`interval`] it connects to the daemon's own socket and sends the hello every client
//!   sends first, with a [`HELLO_BOUND`] deadline. An answer pings `WATCHDOG=1`. No answer, past
//!   [`STARTUP_GRACE`] (hello waits for the hub during a long replay), pings nothing: systemd
//!   ends the daemon after `WatchdogSec` and starts a new one, agents kept (`KillMode=process`).
//! - Its resident memory over [`rss_bound`] for [`RSS_STRIKES`] checks in a row sends the daemon
//!   SIGTERM, the restart handoff a supervisor uses (`daemon.rs`), so it stops as an update does.
//!
//! It runs on its own OS thread, off the daemon's runtime: a runtime that stops scheduling stops
//! the pings too. Every decision is one log line; the stop is a counted self-stop
//! (`supervision.rs`). Linux only; without systemd's watchdog (a daemon a client started) it
//! does nothing.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixDatagram, UnixStream};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

use cmux_supervise_core::StopCause;

/// How long the daemon has to answer its own hello: a client's slow notice says so at 10 s
/// (`slow_notice.rs`); twice that is a daemon no client can use.
pub(crate) const HELLO_BOUND: Duration = Duration::from_secs(20);
/// Pings before this much uptime need no hello: a start that replays a large journal answered
/// its first hello 93 s after binding (2026-11-12, `gauges.rs`).
pub(crate) const STARTUP_GRACE: Duration = Duration::from_secs(10 * 60);
/// The default memory bound: `ACPMUX_DAEMON_RSS_MAX` (bytes; 0 turns it off) overrides it. A
/// healthy daemon with ~100 sessions holds about 0.3 to 2 GB (machines/huge-blue/README.md).
pub(crate) const RSS_BOUND: u64 = 6 << 30;
pub(crate) const RSS_ENV: &str = "ACPMUX_DAEMON_RSS_MAX";
/// Checks in a row over the bound before it restarts: a burst that frees itself is left alone.
pub(crate) const RSS_STRIKES: u32 = 3;

/// The watchdog limit this daemon arms when its unit set none: a hung daemon is restarted within
/// three minutes.
pub(crate) const LIMIT: Duration = Duration::from_secs(180);

/// The watchdog for this process: systemd's notify socket (the unit's `NotifyAccess=main`), with
/// the unit's `WATCHDOG_USEC` when it set one, else [`LIMIT`], which [`start`] arms itself
/// (`WATCHDOG_USEC=` on the socket). The daemon arms it, not the unit's `WatchdogSec`, so an
/// older binary under the same unit (an update's rollback) is never ended for not pinging.
fn armed() -> Option<(Option<Duration>, String)> {
    let pid = std::env::var("WATCHDOG_PID").ok();
    if pid.is_some_and(|pid| pid.trim() != std::process::id().to_string()) {
        return None;
    }
    let socket = std::env::var("NOTIFY_SOCKET").ok().filter(|s| !s.is_empty())?;
    let usec = std::env::var("WATCHDOG_USEC").ok().and_then(|v| v.trim().parse::<u64>().ok());
    Some((usec.filter(|&u| u > 0).map(Duration::from_micros), socket))
}

/// A third of the watchdog's limit (systemd's advice is half; a third leaves a missed check
/// room), at least 5 s.
pub(crate) fn interval(limit: Duration) -> Duration {
    (limit / 3).max(Duration::from_secs(5))
}

/// [`RSS_BOUND`], or `ACPMUX_DAEMON_RSS_MAX`; None when that is 0 (off).
pub(crate) fn rss_bound(env: Option<&str>) -> Option<u64> {
    match env.map(str::trim).filter(|v| !v.is_empty()) {
        None => Some(RSS_BOUND),
        Some(v) => v.parse::<u64>().ok().map_or(Some(RSS_BOUND), |n| (n > 0).then_some(n)),
    }
}

/// Starts the self-check for the daemon serving `socket`, when systemd armed a watchdog.
pub(crate) fn start(socket: PathBuf) {
    let Some((set, notify)) = armed() else { return };
    let limit = set.unwrap_or(LIMIT);
    if set.is_none() {
        notify_line(&notify, &format!("WATCHDOG_USEC={}", limit.as_micros()));
    }
    let bound = rss_bound(std::env::var(RSS_ENV).ok().as_deref());
    tracing::info!(
        limit_s = limit.as_secs(),
        rss_bound = bound,
        "self-check: pinging the systemd watchdog while the daemon answers its own hello"
    );
    let _ = std::thread::Builder::new()
        .name("acpmux-watchdog".into())
        .spawn(move || run(&socket, &notify, limit, bound));
}

/// What one check decided.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum Verdict {
    /// Ping the watchdog.
    Ping,
    /// Ping nothing: systemd restarts it.
    Hung,
    /// Restart now, through the SIGTERM handoff.
    Restart,
}

/// The check's state between runs.
#[derive(Default)]
pub(crate) struct Check {
    over: u32,
    unanswered: u32,
}

impl Check {
    /// One check: whether the hello was answered, how long the daemon has run, its RSS.
    pub(crate) fn judge(
        &mut self,
        answered: bool,
        uptime: Duration,
        rss: Option<u64>,
        bound: Option<u64>,
    ) -> Verdict {
        self.over = match (rss, bound) {
            (Some(rss), Some(bound)) if rss > bound => self.over + 1,
            _ => 0,
        };
        self.unanswered = if answered { 0 } else { self.unanswered + 1 };
        if self.over >= RSS_STRIKES {
            Verdict::Restart
        } else if answered || uptime < STARTUP_GRACE {
            Verdict::Ping
        } else {
            Verdict::Hung
        }
    }
}

fn run(socket: &Path, notify: &str, limit: Duration, bound: Option<u64>) {
    let born = Instant::now();
    let every = interval(limit);
    let mut check = Check::default();
    let mut restarting = false;
    loop {
        let asked = Instant::now();
        let answered = hello(socket, HELLO_BOUND);
        let rss = rss_bytes();
        match check.judge(answered.is_ok(), born.elapsed(), rss, bound) {
            Verdict::Ping => ping(notify),
            Verdict::Hung => {
                let why = answered.err().unwrap_or_default();
                tracing::error!(
                    unanswered = check.unanswered,
                    waited_ms = u64::try_from(asked.elapsed().as_millis()).unwrap_or(u64::MAX),
                    rss,
                    error = %why,
                    "self-check: the daemon did not answer its own hello; the systemd watchdog restarts it within {}s",
                    limit.as_secs()
                );
                super::supervision::stopping(StopCause::NoProgress(format!(
                    "watchdog: no answer to its own hello ({why})"
                )));
            }
            Verdict::Restart if !restarting => {
                restarting = true;
                tracing::error!(
                    rss,
                    bound,
                    strikes = RSS_STRIKES,
                    "self-check: the daemon's memory stayed over its bound; restarting it through its SIGTERM handoff, agents kept"
                );
                super::supervision::stopping(StopCause::SelfStop(format!(
                    "watchdog: RSS {} over {} bytes",
                    rss.unwrap_or(0),
                    bound.unwrap_or(0)
                )));
                // SAFETY: kill(2) on this process's own pid with a signal the daemon handles.
                unsafe { libc::kill(libc::getpid(), libc::SIGTERM) };
                // Pings go on while the handoff runs; a handoff that hangs stops answering hello,
                // and the watchdog ends it.
                ping(notify);
            }
            Verdict::Restart => ping(notify),
        }
        std::thread::sleep(every.saturating_sub(asked.elapsed()));
    }
}

/// The hello a client sends first (`client.rs`), on a fresh connection, answered within `bound`.
pub(crate) fn hello(socket: &Path, bound: Duration) -> Result<(), String> {
    let deadline = Instant::now() + bound;
    let stream = UnixStream::connect(socket).map_err(|e| format!("connect: {e}"))?;
    let left = || deadline.saturating_duration_since(Instant::now()).max(Duration::from_millis(1));
    stream.set_write_timeout(Some(left())).map_err(|e| e.to_string())?;
    let hello = serde_json::json!({
        "jsonrpc": "2.0",
        "id": 1,
        "method": crate::rpc::method::INITIALIZE,
        "params": {"protocolVersion": 1, "clientCapabilities": {},
                   "clientInfo": {"name": "acpmux-watchdog", "version": crate::hub::VERSION}},
    });
    (&stream).write_all(format!("{hello}\n").as_bytes()).map_err(|e| format!("write: {e}"))?;
    let mut reader = BufReader::new(&stream);
    let mut line = String::new();
    // Notifications may come first; the answer is the line with id 1.
    loop {
        stream.set_read_timeout(Some(left())).map_err(|e| e.to_string())?;
        line.clear();
        match reader.read_line(&mut line) {
            Ok(0) => return Err("the daemon closed the connection".into()),
            Ok(_) => {}
            Err(e) => return Err(format!("no answer in {}s: {e}", bound.as_secs())),
        }
        if let Ok(v) = serde_json::from_str::<serde_json::Value>(&line)
            && v.get("id").and_then(serde_json::Value::as_i64) == Some(1)
        {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err(format!("no answer in {}s", bound.as_secs()));
        }
    }
}

fn rss_bytes() -> Option<u64> {
    let status = std::fs::read_to_string("/proc/self/status").ok()?;
    let line = status.lines().find(|l| l.starts_with("VmRSS:"))?;
    line.split_whitespace().nth(1)?.parse::<u64>().ok().map(|kb| kb * 1024)
}

fn ping(notify: &str) {
    notify_line(notify, "WATCHDOG=1");
}

/// One line on systemd's notify socket (a path, or `@name` in the abstract namespace).
fn notify_line(notify: &str, line: &str) {
    let sent = (|| -> std::io::Result<()> {
        let sock = UnixDatagram::unbound()?;
        match notify.strip_prefix('@') {
            Some(name) => {
                use std::os::linux::net::SocketAddrExt;
                let addr = std::os::unix::net::SocketAddr::from_abstract_name(name.as_bytes())?;
                sock.send_to_addr(line.as_bytes(), &addr)?;
            }
            None => {
                sock.send_to(line.as_bytes(), notify)?;
            }
        }
        Ok(())
    })();
    if let Err(error) = sent {
        tracing::warn!(%error, line, "self-check: could not write to systemd's notify socket");
    }
}

#[cfg(test)]
#[path = "watchdog_tests.rs"]
mod tests;
