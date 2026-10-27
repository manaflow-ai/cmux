//! A leftover daemon exits (p07-memory-063, behind the default-off
//! `leftoverDaemonIdleExit` feature in `schemas/features/features.d`).
//!
//! Every cmux app, tagged dev build and CLI start leaves an acpmux daemon
//! running for good. With the feature on, the daemon exits once it has had,
//! for [`IDLE_EXIT_GRACE`], no client connection, no live agent (a harness or
//! agent host, a turn, a queued prompt, a pending permission, a start), no
//! running background process and no owning app. An app that restarts for an
//! update reconnects within the grace and keeps the daemon; any client that
//! connects and leaves starts the grace again.
//!
//! Chromium ends a renderer the same way once nothing refers to it
//! (`content/browser/renderer_host/render_process_host_impl.cc`,
//! `RenderProcessHostImpl::Cleanup` once its listener count and keep-alive
//! ref count reach zero) and its utility processes once their last client
//! disconnects; the delay matches the spare-renderer and Chromium host idle
//! exits in cmux.
//!
//! One task waits on the client presence channel and on the injected clock
//! for the grace deadline: it never polls. Agents, processes and the owning
//! app are read only at the deadline; when one still runs, a full grace
//! starts again (one wake per grace while a client-less daemon keeps agents).
//! The exit is fenced like the cmux-tui owner's (`stop_orphaned_owner`): the
//! presence closes only while no client connected since the deadline's read,
//! a closed presence refuses every new connection, and the live work is read
//! again under the fence; work found then opens the presence again.
//!
//! The owning app's exit (a quit or a crash; cmux-ad 2026-10-27: a Cmd-Q
//! left the app's acpmux running) shortens the next wait to
//! [`OWNER_EXIT_GRACE`]: Chromium's child processes end when the browser
//! process goes (`ChildProcessHost` channel error), and an idle daemon whose
//! app exited serves nobody. A thread blocks in the kernel for that exit
//! ([`OwnerApp::exited`]). Live work still keeps the daemon (Keep Sessions
//! Running keeps agents working); once a deadline finds it, the full grace
//! applies again. The next app starts its own daemon when it needs one.
//! This part is not behind the feature: with the feature off, a daemon an
//! app started (`ACPMUX_OWNER_APP_PID`) waits for that app's exit and then
//! follows the same rules ([`wait_for_daemon_exit`]); a daemon with no
//! owning app (the CLI's) still runs until it is stopped.

use std::sync::Arc;
use std::time::Duration;

use tokio::sync::watch;

use crate::clock::Clock;

/// The registry name of the feature (`schemas/features/features.d`).
pub const FEATURE: &str = "leftoverDaemonIdleExit";

/// How long the daemon stays with nothing that needs it.
pub const IDLE_EXIT_GRACE: Duration = Duration::from_secs(10 * 60);

/// How long the daemon stays with nothing that needs it once its owning app
/// has exited (a quit or a crash): the first wait after that exit, instead
/// of [`IDLE_EXIT_GRACE`].
pub const OWNER_EXIT_GRACE: Duration = Duration::from_secs(2);

/// The process id of the app that owns this daemon; while that process runs
/// the daemon stays, connected or not.
pub const OWNER_APP_PID_ENV: &str = "ACPMUX_OWNER_APP_PID";

/// Connected clients, how many ever connected, and whether the daemon is
/// closing (no connection is taken any more).
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
struct Presence {
    clients: usize,
    arrivals: u64,
    closing: bool,
}

/// The daemon's client connections, counted by [`ClientGuard`]s.
#[derive(Debug)]
pub struct ClientPresence(Arc<watch::Sender<Presence>>);

impl Default for ClientPresence {
    fn default() -> Self {
        Self(Arc::new(watch::channel(Presence::default()).0))
    }
}

impl ClientPresence {
    /// A client connected; it counts until the guard drops. None once the
    /// daemon is closing: the connection is refused.
    pub fn connect(&self) -> Option<ClientGuard> {
        let mut taken = false;
        self.0.send_if_modified(|presence| {
            taken = !presence.closing;
            if taken {
                presence.clients += 1;
                presence.arrivals += 1;
            }
            taken
        });
        taken.then(|| ClientGuard(self.0.clone()))
    }

    /// Closes the presence when no client is connected and none arrived
    /// since `arrivals` was read; true when it closed.
    fn close_if_unchanged(&self, arrivals: u64) -> bool {
        let mut closed = false;
        self.0.send_if_modified(|presence| {
            closed = presence.clients == 0 && presence.arrivals == arrivals;
            presence.closing |= closed;
            closed
        });
        closed
    }

    /// Takes connections again after a close that found live work.
    fn reopen(&self) {
        self.0.send_if_modified(|presence| std::mem::replace(&mut presence.closing, false));
    }

    /// Connected clients now.
    pub fn clients(&self) -> usize {
        self.0.borrow().clients
    }

    fn subscribe(&self) -> watch::Receiver<Presence> {
        self.0.subscribe()
    }
}

/// One connected client; dropping it ends the connection's count.
#[derive(Debug)]
pub struct ClientGuard(Arc<watch::Sender<Presence>>);

impl Drop for ClientGuard {
    fn drop(&mut self) {
        self.0.send_modify(|presence| presence.clients = presence.clients.saturating_sub(1));
    }
}

/// What keeps a client-less daemon running, read only at a deadline.
pub trait Liveness: Send + Sync {
    /// Agents that run or are about to (see the module comment).
    fn live_agents(&self) -> usize;
    /// Background processes an agent started that still run.
    fn live_processes(&self) -> usize;
    /// The owning app's process runs.
    fn owner_app_alive(&self) -> bool;
}

fn keeps_daemon(liveness: &dyn Liveness) -> bool {
    liveness.live_agents() > 0 || liveness.live_processes() > 0 || liveness.owner_app_alive()
}

/// The next thing the waiter does.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Step {
    /// A client is connected: wait for a presence change.
    Serve,
    /// Wait this long on the clock, or for a presence change.
    Wait(Duration),
    /// Exit the daemon.
    Exit,
}

/// The policy on the clock's time; the waiter feeds it.
#[derive(Debug)]
pub struct IdlePolicy {
    grace: Duration,
    /// When the daemon last became client-less; `None` while one is connected.
    idle_since: Option<Duration>,
    /// The owning app exited and no deadline has found live work since: the
    /// next deadline is [`OWNER_EXIT_GRACE`] after the daemon became idle.
    owner_exited: bool,
}

impl IdlePolicy {
    pub fn new(grace: Duration) -> Self {
        Self { grace, idle_since: None, owner_exited: false }
    }

    /// The owning app's process exited: an idle daemon is nobody's now. The
    /// next deadline comes [`OWNER_EXIT_GRACE`] (at most the grace) after
    /// the daemon became idle, or after its last client leaves.
    pub fn owner_exited(&mut self) {
        self.owner_exited = true;
    }

    /// The wait the next deadline is due after.
    fn current_grace(&self) -> Duration {
        if self.owner_exited { OWNER_EXIT_GRACE.min(self.grace) } else { self.grace }
    }

    /// The client count at `now`; `arrived` says a client connected since
    /// the last call (it may have left already), which starts the grace again.
    pub fn presence(&mut self, now: Duration, clients: usize, arrived: bool) {
        if clients > 0 {
            self.idle_since = None;
        } else if arrived || self.idle_since.is_none() {
            self.idle_since = Some(now);
        }
    }

    /// What to do at `now`. Past the grace, `keeps` is asked once: true
    /// starts a full grace again, false exits. Live work found after the
    /// owner's exit (an agent that keeps working through a Keep Sessions
    /// quit) also ends the short grace: one wake per full grace, as before.
    pub fn step(&mut self, now: Duration, keeps: impl FnOnce() -> bool) -> Step {
        let Some(since) = self.idle_since else { return Step::Serve };
        let idle = now.saturating_sub(since);
        let grace = self.current_grace();
        if idle < grace {
            return Step::Wait(grace - idle);
        }
        if keeps() {
            self.owner_exited = false;
            self.idle_since = Some(now);
            return Step::Wait(self.grace);
        }
        Step::Exit
    }

    /// An exit that did not happen (a client came, or work started, at the
    /// deadline): a full grace starts again at `now` while no client is connected.
    fn restart(&mut self, now: Duration) {
        if self.idle_since.is_some() {
            self.idle_since = Some(now);
        }
    }
}

/// Resolves when the daemon should exit; never while a client is connected.
/// On return the presence is closed: [`ClientPresence::connect`] refuses
/// every connection after it.
pub async fn wait_for_idle_exit(
    presence: &ClientPresence,
    clock: Arc<dyn Clock>,
    liveness: &dyn Liveness,
    grace: Duration,
    owner_exit: impl std::future::Future<Output = ()>,
) {
    let mut rx = presence.subscribe();
    let mut policy = IdlePolicy::new(grace);
    let mut last_arrivals = rx.borrow().arrivals;
    let mut owner_exit = std::pin::pin!(owner_exit);
    let mut watching_owner = true;
    loop {
        let seen = *rx.borrow_and_update();
        policy.presence(clock.now(), seen.clients, seen.arrivals != last_arrivals);
        last_arrivals = seen.arrivals;
        let step = policy.step(clock.now(), || keeps_daemon(liveness));
        let changed = match step {
            Step::Exit => {
                // The fence: no client between the read above and the close,
                // and still nothing live once no client can start any.
                if presence.close_if_unchanged(last_arrivals) {
                    if !keeps_daemon(liveness) {
                        return;
                    }
                    presence.reopen();
                }
                policy.restart(clock.now());
                continue;
            }
            Step::Serve => {
                tokio::select! {
                    changed = rx.changed() => changed,
                    () = &mut owner_exit, if watching_owner => {
                        watching_owner = false;
                        policy.owner_exited();
                        Ok(())
                    }
                }
            }
            Step::Wait(after) => {
                tokio::select! {
                    _ = clock.sleep_until(clock.now() + after) => Ok(()),
                    changed = rx.changed() => changed,
                    () = &mut owner_exit, if watching_owner => {
                        watching_owner = false;
                        policy.owner_exited();
                        Ok(())
                    }
                }
            }
        };
        // The sender lives as long as `presence`: a closed channel means the
        // hub is going away, and the daemon's own shutdown ends it.
        if changed.is_err() {
            std::future::pending::<()>().await;
        }
    }
}

/// The owning app a launcher named in an environment variable (acpmux:
/// [`OWNER_APP_PID_ENV`]), read once at start.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct OwnerApp {
    pid: Option<i32>,
}

impl OwnerApp {
    pub fn from_env(variable: &str) -> Self {
        Self::parse(std::env::var(variable).ok().as_deref())
    }

    /// A pid above 1; anything else names no owner.
    pub fn parse(value: Option<&str>) -> Self {
        let pid = value.and_then(|v| v.trim().parse::<i32>().ok()).filter(|pid| *pid > 1);
        Self { pid }
    }

    /// Whether an owner was named.
    pub fn is_named(&self) -> bool {
        self.pid.is_some()
    }

    /// Blocks the calling thread until the owner's process exits (a quit or
    /// a crash), at once when it is already gone: true then; false without
    /// an owner, or where the platform cannot watch it. One kernel wait, no
    /// polling. The cmux-tui Chief owner waits on it (its
    /// `headless/chief_owner_exit.rs`).
    pub fn wait_for_exit(self) -> bool {
        self.pid.is_some_and(wait_for_process_exit)
    }

    /// Resolves when the owner's process exits (a quit or a crash), at once
    /// when it is already gone; never without an owner, or where the
    /// platform cannot watch a process this one did not start (the grace
    /// then decides, as before). One named thread waits in the kernel for
    /// the exit for the daemon's life: no polling.
    pub async fn exited(self) {
        let Some(pid) = self.pid else { return std::future::pending().await };
        let (done, exit) = tokio::sync::oneshot::channel::<()>();
        let watch = std::thread::Builder::new().name("acpmux-owner-exit".into()).spawn(move || {
            if wait_for_process_exit(pid) {
                let _ = done.send(());
            }
        });
        if watch.is_err() || exit.await.is_err() {
            // No watch: only the grace ends this daemon.
            std::future::pending::<()>().await;
        }
    }

    /// The owner's process exists (a recycled pid keeps the daemon: it fails
    /// toward staying).
    pub fn alive(&self) -> bool {
        let Some(pid) = self.pid else { return false };
        #[cfg(unix)]
        {
            // Signal 0 checks existence and permission only; EPERM means it exists.
            // SAFETY: kill with signal 0 delivers nothing and touches no memory.
            let rc = unsafe { libc::kill(pid, 0) };
            rc == 0 || std::io::Error::last_os_error().raw_os_error() == Some(libc::EPERM)
        }
        #[cfg(not(unix))]
        {
            let _ = pid;
            true
        }
    }
}

/// Blocks until process `pid` exits; true when it exited (or was already
/// gone), false when it cannot be watched. macOS: a kqueue `EVFILT_PROC`
/// `NOTE_EXIT` event, which works for a process that is not this one's child.
#[cfg(target_os = "macos")]
fn wait_for_process_exit(pid: i32) -> bool {
    // SAFETY: kqueue takes no arguments and returns a new descriptor or -1.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return false;
    }
    // SAFETY: kevent is a plain C struct; all zero is a valid value of it.
    let mut change: libc::kevent = unsafe { std::mem::zeroed() };
    change.ident = pid as libc::uintptr_t;
    change.filter = libc::EVFILT_PROC;
    change.flags = libc::EV_ADD | libc::EV_ONESHOT;
    change.fflags = libc::NOTE_EXIT;
    let exited = loop {
        // SAFETY: as above.
        let mut event: libc::kevent = unsafe { std::mem::zeroed() };
        // SAFETY: one change and one event slot, locals that outlive the call; a null
        // timeout blocks until the event.
        let n = unsafe { libc::kevent(queue, &change, 1, &mut event, 1, std::ptr::null()) };
        if n < 0 {
            match std::io::Error::last_os_error().raw_os_error() {
                Some(libc::EINTR) => continue,
                // Already gone.
                Some(libc::ESRCH) => break true,
                _ => break false,
            }
        }
        if n == 0 {
            continue;
        }
        if event.flags & libc::EV_ERROR != 0 {
            break event.data == libc::ESRCH as libc::intptr_t;
        }
        break event.fflags & libc::NOTE_EXIT != 0;
    };
    // SAFETY: closes the descriptor kqueue returned above, once.
    unsafe { libc::close(queue) };
    exited
}

/// Linux: a pidfd turns readable when the process exits.
#[cfg(target_os = "linux")]
fn wait_for_process_exit(pid: i32) -> bool {
    // SAFETY: pidfd_open(pid, 0) returns a new descriptor or -1.
    let fd = unsafe { libc::syscall(libc::SYS_pidfd_open, pid, 0) };
    if fd < 0 {
        return std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH);
    }
    let Ok(fd) = libc::c_int::try_from(fd) else { return false };
    let mut poll = libc::pollfd { fd, events: libc::POLLIN, revents: 0 };
    let exited = loop {
        // SAFETY: one pollfd, a local that outlives the call; -1 blocks until it is ready.
        let n = unsafe { libc::poll(&mut poll, 1, -1) };
        if n < 0 && std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
            continue;
        }
        break n > 0;
    };
    // SAFETY: closes the descriptor pidfd_open returned above, once.
    unsafe { libc::close(fd) };
    exited
}

#[cfg(not(any(target_os = "macos", target_os = "linux")))]
fn wait_for_process_exit(_pid: i32) -> bool {
    false
}

/// The hub's facts for a daemon.
pub struct HubLiveness {
    pub hub: Arc<crate::hub::Hub>,
    pub owner: OwnerApp,
}

impl Liveness for HubLiveness {
    fn live_agents(&self) -> usize {
        self.hub.live_agent_count()
    }

    fn live_processes(&self) -> usize {
        self.hub.live_process_count()
    }

    fn owner_app_alive(&self) -> bool {
        self.owner.alive()
    }
}

/// Whether `features` turn the idle exit on.
fn enabled(features: &cmux_features::Snapshot) -> bool {
    features.is_enabled(cmux_features::feature::LEFTOVER_DAEMON_IDLE_EXIT)
}

/// The daemon's features, resolved as the cmux-tui owner resolves its own
/// (`cmux_features::sources`): the channel of the app bundle this daemon
/// ships in, the feature lists, then managed policy and the signed
/// document's `DisabledFeatures`, which win.
fn daemon_features() -> cmux_features::Snapshot {
    let exe = std::env::current_exe().ok();
    let kind = exe.as_deref().and_then(cmux_features::sources::bundle_kind);
    cmux_features::sources::daemon_snapshot(kind)
}

/// Resolves when the daemon should exit. With the idle exit on, as
/// [`wait_for_idle_exit`] says. With it off (every channel's default), a
/// daemon without an owning app never exits idle; one whose owning app
/// exited (a quit) does, after [`OWNER_EXIT_GRACE`] with no client and no
/// live work, as with the feature on: a helper the app started stops with
/// the app.
pub async fn wait_for_daemon_exit(
    idle_exit_on: bool,
    presence: &ClientPresence,
    clock: Arc<dyn Clock>,
    liveness: &dyn Liveness,
    owner_exit: impl std::future::Future<Output = ()>,
) {
    if idle_exit_on {
        wait_for_idle_exit(presence, clock, liveness, IDLE_EXIT_GRACE, owner_exit).await;
    } else {
        owner_exit.await;
        wait_for_idle_exit(presence, clock, liveness, IDLE_EXIT_GRACE, std::future::ready(()))
            .await;
    }
}

/// The daemon's exit when nothing needs it (see [`wait_for_daemon_exit`]).
pub async fn run_for_daemon(hub: Arc<crate::hub::Hub>) {
    // The policy and document reads are disk reads: off the runtime's workers.
    let features = cmux_blocking::spawn_blocking(daemon_features).await;
    let idle_exit_on = features.as_ref().is_ok_and(enabled);
    let clock = hub.lifecycle_clock();
    let owner = OwnerApp::from_env(OWNER_APP_PID_ENV);
    let liveness = HubLiveness { hub: hub.clone(), owner };
    wait_for_daemon_exit(idle_exit_on, &hub.clients, clock, &liveness, owner.exited()).await;
}

#[cfg(test)]
#[path = "daemon_lifecycle_tests.rs"]
mod idle_exit_tests;
