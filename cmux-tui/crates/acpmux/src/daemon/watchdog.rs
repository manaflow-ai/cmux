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
//!   sends first. The hello's deadline is systemd's own: the watchdog limit from the last ping,
//!   less [`PING_RESERVE`] ([`Plan::hello_wait`], at least [`HELLO_BOUND`]). An answer pings
//!   `WATCHDOG=1`, however slow: a starved host or a hub busy replaying answers late but is not
//!   hung, and a fixed 20 s hello made systemd end a live daemon after three slow answers. No
//!   answer for the whole window, past [`STARTUP_GRACE`] (hello waits for the hub during a long
//!   replay), pings nothing: systemd ends the daemon within its limit and starts a new one,
//!   agents kept (`KillMode=process`).
//! - Its resident memory over [`rss_bound`] for [`RSS_STRIKES`] checks in a row sends the daemon
//!   SIGTERM, the restart handoff a supervisor uses (`daemon.rs`), so it stops as an update does.
//!
//! - A pause holds it ([`hold`], `acpmux daemon watchdog-hold`, which the platform runs just
//!   before it pauses the VM): `WATCHDOG_USEC=0` stops systemd's timer, so a pause of any length
//!   cannot trip it. On 2026-11-27 a 60 s pause came back to `Watchdog timeout (limit 3min)!` and
//!   a SIGTERM to the daemon before this thread could ping: systemd's timer ran across the pause.
//!   The hello goes on while held; a daemon that stops answering during a hold restarts itself
//!   through the SIGTERM handoff. The hold ends, and [`LIMIT`] is armed again with a ping, once
//!   this thread sees the machine resumed (a clock gap well past its interval, [`resumed`]), or
//!   after [`HOLD_BOUND`] with no gap.
//!
//! It runs on its own OS thread, off the daemon's runtime: a runtime that stops scheduling stops
//! the pings too. Every decision is one log line; the stop is a counted self-stop
//! (`supervision.rs`). Linux only; without systemd's watchdog (a daemon a client started) it
//! does nothing.

use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::{UnixDatagram, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime};

use cmux_deadline::Deadline;
use cmux_supervise_core::StopCause;

/// The least one hello waits, and the answer time past which it says the daemon is slow: a
/// client's slow notice says so at 10 s (`slow_notice.rs`); twice that is a daemon no client can
/// use. Slow is not hung: the hello waits on until [`Plan::hello_wait`] (systemd's own limit).
pub(crate) const HELLO_BOUND: Duration = Duration::from_secs(20);
/// Kept before systemd's limit when a hello waits: the ping after a late answer must land in time.
pub(crate) const PING_RESERVE: Duration = Duration::from_secs(10);
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

/// How long a hold lasts when no resume shows: a pause the platform asked for but never made (or
/// one this thread could not see) leaves systemd's watchdog off no longer than this.
pub(crate) const HOLD_BOUND: Duration = Duration::from_secs(15 * 60);

/// This daemon's watchdog, once [`start`] armed it: what [`hold`] stops.
static ARMED: OnceLock<Arc<Hold>> = OnceLock::new();

/// Holds this daemon's systemd watchdog until the machine resumes: false when systemd armed none
/// (a daemon a client started, or not under the unit).
pub(crate) fn hold() -> bool {
    ARMED.get().is_some_and(|held| {
        held.take();
        true
    })
}

/// A hold of one watchdog: its notify socket, the limit it re-arms, and since when it is held.
pub(crate) struct Hold {
    notify: String,
    limit: Duration,
    since: Mutex<Option<Instant>>,
}

impl Hold {
    pub(crate) fn new(notify: &str, limit: Duration) -> Self {
        Self { notify: notify.to_owned(), limit, since: Mutex::new(None) }
    }

    /// Stops systemd's timer (`WATCHDOG_USEC=0`; systemd 255 stops the watchdog for a zero
    /// override). A hold while held starts its bound again.
    pub(crate) fn take(&self) {
        let mut since = self.since.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        notify_line(&self.notify, "WATCHDOG_USEC=0");
        *since = Some(Instant::now());
        tracing::info!(
            bound_s = HOLD_BOUND.as_secs(),
            "self-check: holding the systemd watchdog for a pause, until the machine resumes"
        );
    }

    /// Since when it is held, if it is.
    pub(crate) fn since(&self) -> Option<Instant> {
        *self.since.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    /// Ends the hold: arms the limit again and pings, so systemd counts from now. How long it was
    /// held, or None when it was not.
    pub(crate) fn release(&self) -> Option<Duration> {
        let mut since = self.since.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
        let held = since.take()?.elapsed();
        notify_line(&self.notify, &format!("WATCHDOG_USEC={}", self.limit.as_micros()));
        ping(&self.notify);
        Some(held)
    }
}

/// The time this thread did not run across a wait it planned as `planned`: how far the monotonic
/// clock ran past the plan, or the wall clock past the monotonic one (a pause the monotonic clock
/// does not count), when that is at least `slack`. On the 2026-11-27 provider both clocks moved
/// across a 5 min pause, so the monotonic lateness alone shows it there.
pub(crate) fn resumed(
    planned: Duration,
    mono: Duration,
    wall: Duration,
    slack: Duration,
) -> Option<Duration> {
    let gap = mono.saturating_sub(planned).max(wall.saturating_sub(mono));
    (gap >= slack).then_some(gap)
}

/// Both clocks now, to measure one wait with [`resumed`].
#[derive(Clone, Copy)]
struct Clocks {
    mono: Instant,
    wall: SystemTime,
}

impl Clocks {
    fn now() -> Self {
        Self { mono: Instant::now(), wall: SystemTime::now() }
    }

    /// The gap across a wait planned as `planned` since these clocks.
    fn gap(&self, planned: Duration, slack: Duration) -> Option<Duration> {
        let mono = self.mono.elapsed();
        // A wall clock set back reads 0: no pause.
        let wall = SystemTime::now().duration_since(self.wall).unwrap_or_default();
        resumed(planned, mono, wall, slack)
    }
}

/// What the hold does after one check.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum HoldStep {
    /// Not held, or held and nothing ended it: as before.
    Keep,
    /// The machine resumed, or the hold ran its bound: arm the limit again.
    Release,
    /// Held, and the daemon stopped answering: arm it again and restart through the handoff.
    Restart,
}

/// The hold's decision: held since `since` (None: not held), at `now`, whether this check saw a
/// resume, and the check's verdict.
pub(crate) fn hold_step(
    since: Option<Instant>,
    now: Instant,
    resumed: bool,
    verdict: &Verdict,
    bound: Duration,
) -> HoldStep {
    let Some(since) = since else { return HoldStep::Keep };
    if *verdict == Verdict::Hung {
        HoldStep::Restart
    } else if resumed || now.saturating_duration_since(since) >= bound {
        HoldStep::Release
    } else {
        HoldStep::Keep
    }
}

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

/// How one watchdog runs: systemd's limit, how often it checks, the startup grace, what it keeps
/// before the limit and the least a hello waits. [`Plan::for_limit`] is the daemon's; tests scale it.
#[derive(Clone, Copy, Debug)]
pub(crate) struct Plan {
    pub(crate) limit: Duration,
    pub(crate) every: Duration,
    pub(crate) grace: Duration,
    pub(crate) reserve: Duration,
    pub(crate) floor: Duration,
    /// How long a hold lasts with no resume seen ([`HOLD_BOUND`]).
    pub(crate) hold: Duration,
}

impl Plan {
    pub(crate) fn for_limit(limit: Duration) -> Self {
        Self {
            limit,
            every: interval(limit),
            grace: STARTUP_GRACE,
            reserve: PING_RESERVE.min(limit / 6),
            floor: HELLO_BOUND.min(limit / 3),
            hold: HOLD_BOUND,
        }
    }

    /// The lateness past a planned wait that reads as a resume: half a check interval, so a
    /// total wait half again past its plan. Scheduling noise is far under it.
    pub(crate) fn resumed(&self) -> Duration {
        self.every / 2
    }

    /// How long a hello asked at `now` waits: until systemd's limit counted from `last_ping`, less
    /// the reserve, and at least the floor. One deadline (systemd's), never a fresh one per check:
    /// a daemon that answers anywhere inside it pings in time.
    pub(crate) fn hello_wait(&self, last_ping: Instant, now: Instant) -> Duration {
        Deadline::starting(last_ping, self.limit).timeout_at(now, None, self.floor, self.reserve)
    }
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
    let held = ARMED.get_or_init(|| Arc::new(Hold::new(&notify, limit))).clone();
    let _ = std::thread::Builder::new().name("acpmux-watchdog".into()).spawn(move || {
        watch(&socket, &notify, Plan::for_limit(limit), bound, &held, &AtomicBool::new(false))
    });
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
pub(crate) struct Check {
    over: u32,
    unanswered: u32,
    grace: Duration,
}

impl Default for Check {
    fn default() -> Self {
        Self::new(STARTUP_GRACE)
    }
}

impl Check {
    pub(crate) fn new(grace: Duration) -> Self {
        Self { over: 0, unanswered: 0, grace }
    }

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
        } else if answered || uptime < self.grace {
            Verdict::Ping
        } else {
            Verdict::Hung
        }
    }
}

/// The check loop, until `stop` (the daemon's never is; a test's is).
pub(crate) fn watch(
    socket: &Path,
    notify: &str,
    plan: Plan,
    bound: Option<u64>,
    held: &Hold,
    stop: &AtomicBool,
) {
    let born = Instant::now();
    let limit = plan.limit;
    let mut last_ping = born;
    let mut check = Check::new(plan.grace);
    let mut restarting = false;
    // The wait before this check (the sleep), to see a pause across it.
    let mut slept: Option<(Clocks, Duration)> = None;
    while !stop.load(Ordering::Relaxed) {
        let mut gap = slept.and_then(|(at, planned)| at.gap(planned, plan.resumed()));
        let asked = Instant::now();
        let before = Clocks::now();
        let wait = plan.hello_wait(last_ping, asked);
        let answered = hello(socket, wait);
        let took = asked.elapsed();
        // A hello that spanned the pause timed out on a deadline the pause used up: not hung.
        let across = before.gap(wait, plan.resumed());
        if answered.is_err() && across.is_some() {
            gap = gap.max(across);
            if let Some(gap) = gap {
                tracing::warn!(
                    gap_ms = u64::try_from(gap.as_millis()).unwrap_or(u64::MAX),
                    "self-check: the machine resumed during the hello; asking again, not judging it"
                );
            }
            if held.release().is_some() {
                tracing::info!(
                    "self-check: the machine resumed; the systemd watchdog is armed again"
                );
            } else {
                ping(notify);
            }
            last_ping = Instant::now();
            slept = None;
            continue;
        }
        if answered.is_ok() && took > plan.floor {
            tracing::warn!(
                took_ms = u64::try_from(took.as_millis()).unwrap_or(u64::MAX),
                "self-check: the daemon answered its own hello slowly; slow is not hung, it pings"
            );
        }
        let rss = rss_bytes();
        let mut pinged = true;
        let verdict = check.judge(answered.is_ok(), born.elapsed(), rss, bound);
        match hold_step(held.since(), Instant::now(), gap.is_some(), &verdict, plan.hold) {
            HoldStep::Keep => {}
            HoldStep::Release => {
                let was = held.release();
                tracing::info!(
                    held_s = was.map(|d| d.as_secs()),
                    gap_ms = gap.map(|g| u64::try_from(g.as_millis()).unwrap_or(u64::MAX)),
                    "self-check: {}; the systemd watchdog is armed again at {}s",
                    if gap.is_some() {
                        "the machine resumed"
                    } else {
                        "the hold ran its bound with no resume seen"
                    },
                    limit.as_secs()
                );
            }
            HoldStep::Restart => {
                let why = answered.as_ref().err().cloned().unwrap_or_default();
                held.release();
                tracing::error!(
                    error = %why,
                    "self-check: the daemon stopped answering its own hello while its watchdog was held; restarting it through its SIGTERM handoff, agents kept"
                );
                if !restarting {
                    restarting = true;
                    super::supervision::stopping(StopCause::SelfStop(format!(
                        "watchdog: no answer to its own hello while held ({why})"
                    )));
                    // SAFETY: kill(2) on this process's own pid with a signal the daemon handles.
                    unsafe { libc::kill(libc::getpid(), libc::SIGTERM) };
                }
                // The watchdog is armed again and not pinged: a handoff that hangs is ended by
                // systemd within its limit.
                slept = Some((Clocks::now(), plan.every.saturating_sub(asked.elapsed())));
                std::thread::sleep(plan.every.saturating_sub(asked.elapsed()));
                continue;
            }
        }
        match verdict {
            // Held: systemd's timer is stopped, nothing to ping.
            Verdict::Ping if held.since().is_some() => {}
            Verdict::Ping => ping(notify),
            Verdict::Hung => {
                let why = answered.err().unwrap_or_default();
                tracing::error!(
                    unanswered = check.unanswered,
                    waited_ms = u64::try_from(asked.elapsed().as_millis()).unwrap_or(u64::MAX),
                    rss,
                    error = %why,
                    "self-check: the daemon did not answer its own hello within systemd's limit; the systemd watchdog restarts it within {}s",
                    limit.as_secs()
                );
                pinged = false;
                super::supervision::stopping(StopCause::NoProgress(format!(
                    "watchdog: no answer to its own hello ({why})"
                )));
            }
            Verdict::Restart if !restarting => {
                restarting = true;
                held.release();
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
        if pinged {
            last_ping = Instant::now();
        }
        let nap = plan.every.saturating_sub(asked.elapsed());
        slept = Some((Clocks::now(), nap));
        std::thread::sleep(nap);
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
