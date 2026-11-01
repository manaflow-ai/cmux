//! A host's own end once no daemon controls it (`OrphanExit`, `SpawnSpec::orphan_exit`): hosts
//! outlive their daemon on purpose, but one whose daemon never comes back ran forever. Part of
//! the host's event loop (`host.rs`): after every event `orphan_follow` starts or ends the wait;
//! its end and the census's answer come back as `Event::Orphan` through `orphan_look`.

use super::*;
use std::collections::HashSet;

/// The harness group's time between SIGTERM and SIGKILL when a host ends on its own
/// ([`OrphanExit`]), as at the daemon's shutdown (`hub/shutdown.rs` `SHUTDOWN_GRACE`).
const ORPHAN_END_GRACE: std::time::Duration = std::time::Duration::from_secs(2);

/// How long an ended host waits for a connection that has not said hello yet: a controller's
/// own wait for the answer (`link::connect`).
const HELLO_LINGER: std::time::Duration = std::time::Duration::from_secs(5);

/// What a host with no controller still holds for a next daemon ([`OrphanExit`]).
#[derive(Debug, Default, Clone, Copy, PartialEq, Eq)]
struct Pending {
    /// Requests the controller sent the harness with no answer yet: a turn in flight among them.
    requests: usize,
    /// Fenced lines queued for the harness whose receipt is not logged yet.
    unwritten: usize,
    /// Entries no controller logged that a next daemon needs (`needs_a_daemon`).
    unlogged: usize,
    /// Claude Code runs a subagent or a background shell, or a carry holds its output.
    translator: bool,
    /// Connections that have not said hello yet: a next daemon's, perhaps.
    connections: usize,
}

impl Pending {
    fn none(&self) -> bool {
        *self == Self::default()
    }
}

/// What a host with no controller does next ([`OrphanExit`]).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum OrphanStep {
    /// Look again after this long.
    Wait(std::time::Duration),
    /// The wait is over and nothing is pending: list what runs under the harness, then end.
    Census,
}

/// The policy ([`OrphanExit`]): `alone` is how long no controller has been connected, `wait`
/// the host's wait. A busy agent is looked at again a whole wait later.
fn orphan_step(
    wait: std::time::Duration,
    alone: std::time::Duration,
    pending: Pending,
) -> OrphanStep {
    if alone < wait {
        OrphanStep::Wait(wait.saturating_sub(alone))
    } else if !pending.none() {
        OrphanStep::Wait(wait)
    } else {
        OrphanStep::Census
    }
}

/// Whether a next daemon needs `entry` in its log: all but stderr lines, the harness's raw lines
/// kept beside their translation (`Tap` `in`), and its exit, which a daemon that finds no host
/// learns anyway (it loads the chat idle).
pub(super) fn needs_a_daemon(entry: &Entry) -> bool {
    !matches!(entry, Entry::Err { .. } | Entry::Exit { .. } | Entry::Tap { dir: TapDir::In, .. })
}

/// Whether a hello that came while the host ends its harness still waits (one rule, for
/// holding a new hello and for answering the held ones):
/// - until the exit entry is in the log (`exit_in`): the waiter task marks the leader reaped
///   before the main loop logs the exit (which also waits for the harness's output to close), so
///   a reaped leader is not yet an exit a daemon can read;
/// - not once the end stopped waiting for the exit (`given_up`, `end_by`): no daemon is left
///   unanswered;
/// - not once the leader is reaped while its output is held back by the buffer cap
///   (`reaped_and_held_back`): only a daemon draining that output lets the exit entry come.
pub(super) fn hello_waits(exit_in: bool, given_up: bool, reaped_and_held_back: bool) -> bool {
    !exit_in && !given_up && !reaped_and_held_back
}

/// A host's own end ([`OrphanExit`]), and what it tracks for it.
#[derive(Default)]
pub(super) struct Orphan {
    /// Since when no controller is connected.
    since: Option<std::time::Instant>,
    /// The generation of the wait or census running: a controller's hello moves it on.
    generation: u64,
    /// The end began.
    ending: bool,
    /// The entry count when the census started: a line that came while it ran keeps the host.
    census_at: u64,
    /// The census said clear, and its answer went round the event queue once more, so every
    /// event any task sent before it (a line, a connection) is handled before the end.
    confirming: bool,
    /// Hellos that came while the harness ends, answered once its exit entry is in: no daemon
    /// starts a turn on a harness that is ending, and each reads the exit.
    held: Vec<(u64, ControllerFrame)>,
    /// When the end gives up waiting for the harness's exit entry (output held back by the
    /// buffer cap with no daemon to drain it can keep it out for good).
    end_by: Option<std::time::Instant>,
    /// Once the exit is in: until when the host waits for a daemon to log what is left.
    linger_until: Option<std::time::Instant>,
    /// Requests the controller sent the harness with no answer yet, by id (its JSON text).
    open: HashSet<String>,
    /// Fenced lines queued for the harness whose receipt is not logged yet.
    pub(super) unwritten: usize,
    /// The ACP `mcpServers` the controller last opened a session with: the census counts them as
    /// the harness's own.
    given_servers: Option<Value>,
}

impl Orphan {
    /// Holds connection `id`'s hello `frame` while the harness ends and its exit entry is not in
    /// the log yet ([`hello_waits`]): true when it is held, to be answered once it no longer waits.
    pub(super) fn hold_hello(&mut self, id: u64, frame: &ControllerFrame, waits: bool) -> bool {
        let held = self.ending && waits;
        if held {
            self.held.push((id, frame.clone()));
        }
        held
    }

    /// A line from the controller: a request waits for its answer, and a session opened with
    /// MCP servers names them.
    pub(super) fn note_request(&mut self, message: &Message) {
        let Message::Request { id, method, params } = message else { return };
        self.open.insert(id.to_string());
        if matches!(
            method.as_str(),
            "session/new" | "session/load" | "session/resume" | "session/fork"
        ) && let Some(servers) = params.as_ref().and_then(|p| p.get("mcpServers"))
        {
            self.given_servers = Some(servers.clone());
        }
    }

    /// What the host's hello tells the next daemon of its harness's MCP servers
    /// (`HostServers`): `exit`'s, read before the harness started, and the ACP ones its
    /// sessions opened with. None when the daemon that started it read none (`exit` is None).
    pub(super) fn census_servers(&self, exit: Option<&OrphanExit>) -> Option<HostServers> {
        let exit = exit?;
        Some(HostServers {
            servers: exit.servers.clone(),
            path: exit.path.clone(),
            cwd: exit.cwd.clone(),
            given: self.given_servers.as_ref().map(crate::hub::census_servers),
        })
    }

    /// An entry for the controller: an answer from the harness settles its request.
    pub(super) fn note_entry(&mut self, entry: &Entry) {
        if let Entry::In { msg } = entry
            && msg.get("method").is_none()
            && let Some(id) = msg.get("id")
        {
            self.open.remove(&id.to_string());
        }
    }
}

impl State {
    /// End the harness group: SIGTERM, then SIGKILL after `grace` (`ControllerFrame::Terminate`).
    /// The exit entry is the sign that it ended.
    pub(super) async fn terminate_group(&mut self, grace: std::time::Duration) {
        if let Some(pg) =
            self.pgid.filter(|_| self.leader_alive.load(std::sync::atomic::Ordering::SeqCst))
        {
            self.under = tokio::task::spawn_blocking(|| {
                super::super::tree::descendants(&[std::process::id()])
            })
            .await
            .unwrap_or_default();
            // SAFETY: the harness leads this process group.
            unsafe { libc::killpg(pg, libc::SIGTERM) };
            let alive = self.leader_alive.clone();
            // A bounded kill deadline, not synchronization: the exit
            // entry is the signal that the harness ended.
            tokio::spawn(async move {
                tokio::time::sleep(grace).await;
                if alive.load(std::sync::atomic::Ordering::SeqCst) {
                    // SAFETY: the leader is unreaped, so the group is ours.
                    unsafe { libc::killpg(pg, libc::SIGKILL) };
                }
            });
        }
    }

    /// Whether a hello during the end still waits ([`hello_waits`]), from this host's state.
    pub(super) fn hello_waits(&self) -> bool {
        let reaped = !self.leader_alive.load(std::sync::atomic::Ordering::SeqCst);
        let given_up = self.orphan.end_by.is_some_and(|by| std::time::Instant::now() >= by);
        hello_waits(self.exit_h.is_some(), given_up, reaped && self.output_held_back())
    }

    /// What this host still holds for a next daemon ([`Pending`]).
    async fn pending(&self) -> Pending {
        let translator = !self.held.is_empty()
            || match &self.translator {
                Some(tr) => tr.holding().is_some() || tr.runs_background_work().await,
                None => false,
            };
        Pending {
            requests: self.orphan.open.len(),
            unwritten: self.orphan.unwritten,
            unlogged: self.entries.iter().filter(|e| e.needed).count(),
            translator,
            connections: 0,
        }
    }

    /// As the host starts serving and after every event: a controller's hello ends the wait (its
    /// generation moves on); its absence starts one ([`OrphanExit`]). True once the host's own
    /// end is done: the harness exited and no controller is there to log it. A daemon that
    /// connected while the harness ended is answered once its exit entry is in (`hold_hello`): it logs
    /// the rest and the exit, as of a harness that crashed, and the host then ends as every host
    /// does (`finished`). A connection that has not said hello yet gets [`HELLO_LINGER`]; what
    /// the harness wrote as it ended that a next daemon needs gets the whole wait again, for a
    /// daemon to come and log it, and is then let go. An exit entry that never comes (output
    /// the buffer cap holds back) is waited for as long (`end_by`): the host never runs on for
    /// good.
    pub(super) async fn orphan_follow(&mut self, events: &mpsc::Sender<Event>) -> bool {
        if self.orphan.ending {
            if !self.hello_waits() {
                for (id, hello) in std::mem::take(&mut self.orphan.held) {
                    self.on_frame(id, Some(hello)).await;
                }
            }
            if self.controller.is_some() {
                return false;
            }
            let now = std::time::Instant::now();
            if self.exit_h.is_none() {
                return self.orphan.end_by.is_some_and(|by| now >= by);
            }
            let unlogged = self.entries.iter().any(|e| e.needed);
            if self.pending_conns.is_empty() && !unlogged {
                return true;
            }
            let until = match self.orphan.linger_until {
                Some(until) => until,
                None => {
                    let after =
                        if unlogged { self.orphan_idle().max(HELLO_LINGER) } else { HELLO_LINGER };
                    self.orphan_wait(events, after);
                    *self.orphan.linger_until.insert(now + after)
                }
            };
            return now >= until;
        }
        let Some(exit) = &self.spec.orphan_exit else { return false };
        if self.controller.is_some() {
            if self.orphan.since.take().is_some() {
                self.orphan.generation = self.orphan.generation.wrapping_add(1);
            }
        } else if self.orphan.since.is_none() && !self.orphan.ending {
            let wait = std::time::Duration::from_millis(exit.idle_ms);
            self.orphan.since = Some(std::time::Instant::now());
            self.orphan_wait(events, wait);
        }
        false
    }

    /// Look again after `after`, unless a controller says hello first.
    fn orphan_wait(&self, events: &mpsc::Sender<Event>, after: std::time::Duration) {
        let (events, generation) = (events.clone(), self.orphan.generation);
        // task-owner: one bounded wait; a hello makes its generation stale, the runtime ends it
        // with the host.
        tokio::spawn(async move {
            tokio::time::sleep(after).await;
            let _ = events.send(Event::Orphan(generation, None)).await;
        });
    }

    /// A wait with no controller ended (`census`: the census's answer once it ran): wait again,
    /// run the census, or end the harness and the host ([`OrphanExit`]). One of an older
    /// `generation` is stale: a controller said hello since.
    pub(super) async fn orphan_look(
        &mut self,
        events: &mpsc::Sender<Event>,
        generation: u64,
        census: Option<bool>,
    ) {
        let (Some(exit), Some(since)) = (self.spec.orphan_exit.clone(), self.orphan.since) else {
            return;
        };
        // While the end runs a wait only wakes the loop: `orphan_follow` reads its deadlines.
        if self.orphan.ending {
            return;
        }
        if generation != self.orphan.generation || self.controller.is_some() {
            return;
        }
        let wait = std::time::Duration::from_millis(exit.idle_ms);
        // Checked again on the census's answer, and on its round of the event queue: an entry or
        // a connection that came meanwhile keeps the host (a connection that has not said hello
        // yet may be a next daemon's). From here to the group's SIGTERM no other event is handled.
        let mut pending = self.pending().await;
        pending.connections = self.pending_conns.len();
        pending.unlogged = pending
            .unlogged
            .saturating_add(usize::from(census.is_some() && self.next_h != self.orphan.census_at));
        if let OrphanStep::Wait(after) = orphan_step(wait, since.elapsed(), pending) {
            self.orphan_wait(events, after);
            return;
        }
        let leader = self.leader_alive.load(std::sync::atomic::Ordering::SeqCst);
        match (census, self.record.harness_pid) {
            // Nothing runs that a census could find: the harness already ended.
            _ if !leader => self.orphan_end(events).await,
            (Some(true), _) if self.orphan.confirming => self.orphan_end(events).await,
            // Other tasks' events sent before the census's answer may wait behind it (tokio's
            // queue orders each sender, not all of them): one more round lets them in first.
            (Some(true), _) => {
                self.orphan.confirming = true;
                let (events, generation) = (events.clone(), self.orphan.generation);
                // task-owner: one send; the runtime ends it with the host.
                tokio::spawn(async move {
                    let _ = events.send(Event::Orphan(generation, Some(true))).await;
                });
            }
            // Something else runs under it (a dev server it left), or it can not tell.
            (Some(false), _) | (None, None) => self.orphan_wait(events, wait),
            (None, Some(pid)) => {
                (self.orphan.census_at, self.orphan.confirming) = (self.next_h, false);
                let given = self.orphan.given_servers.clone();
                let (events, generation) = (events.clone(), self.orphan.generation);
                // task-owner: one census, bounded by its own budget (`hub/idle_census.rs`).
                tokio::spawn(async move {
                    let clear = crate::hub::host_census(pid, exit, given).await;
                    let _ = events.send(Event::Orphan(generation, Some(clear))).await;
                });
            }
        }
    }

    /// No daemon controlled this host for its wait and its agent is idle: end the harness
    /// group as `Terminate` does; the host ends once its exit is in (`serve`).
    async fn orphan_end(&mut self, events: &mpsc::Sender<Event>) {
        tracing::info!("no daemon came back for this host's wait and its agent is idle; ending it");
        self.orphan.ending = true;
        let by = ORPHAN_END_GRACE.saturating_add(self.orphan_idle().max(HELLO_LINGER));
        self.orphan.end_by = Some(std::time::Instant::now() + by);
        self.orphan_wait(events, by);
        self.terminate_group(ORPHAN_END_GRACE).await;
    }

    /// The host's wait with no controller ([`OrphanExit`]).
    fn orphan_idle(&self) -> std::time::Duration {
        std::time::Duration::from_millis(self.spec.orphan_exit.as_ref().map_or(0, |e| e.idle_ms))
    }
}

#[cfg(test)]
mod tests {
    use super::{Entry, OrphanStep, Pending, TapDir, hello_waits, needs_a_daemon, orphan_step};
    use std::time::Duration;

    /// A host with no controller looks at its agent only once its whole wait passed, ends it
    /// (after the census) only when nothing is pending, and otherwise looks again a wait later.
    #[test]
    fn an_orphaned_host_ends_only_an_idle_agent_after_its_wait() {
        let wait = Duration::from_secs(600);
        let idle = Pending::default();
        assert_eq!(orphan_step(wait, Duration::ZERO, idle), OrphanStep::Wait(wait));
        assert_eq!(
            orphan_step(wait, Duration::from_secs(590), idle),
            OrphanStep::Wait(Duration::from_secs(10))
        );
        assert_eq!(orphan_step(wait, wait, idle), OrphanStep::Census);
        assert_eq!(orphan_step(wait, wait * 5, idle), OrphanStep::Census);
        for busy in [
            Pending { requests: 1, ..idle },
            Pending { unwritten: 1, ..idle },
            Pending { unlogged: 1, ..idle },
            Pending { translator: true, ..idle },
            Pending { connections: 1, ..idle },
        ] {
            assert_eq!(orphan_step(wait, wait * 5, busy), OrphanStep::Wait(wait), "{busy:?}");
        }
    }

    /// Output no daemon logged keeps the host; stderr, raw taps and the exit do not.
    #[test]
    fn only_what_a_next_daemon_needs_keeps_an_orphaned_host() {
        let msg = serde_json::json!({"jsonrpc": "2.0", "method": "session/update"});
        assert!(needs_a_daemon(&Entry::In { msg: msg.clone() }));
        assert!(needs_a_daemon(&Entry::Tap { dir: TapDir::Out, msg: msg.clone() }));
        assert!(!needs_a_daemon(&Entry::Tap { dir: TapDir::In, msg }));
        assert!(!needs_a_daemon(&Entry::Err { line: "warn".into() }));
        assert!(!needs_a_daemon(&Entry::Exit { code: Some(0) }));
    }

    /// A daemon that connects while the host ends its harness waits until the exit entry is in
    /// the log, so its log has the exit and it never starts a turn on a dying harness. The waiter
    /// task marks the leader reaped before the main loop logs the exit, so "reaped" is not
    /// "exit in" (orphan_exit `a_daemon_connecting_while_the_harness_ends_is_told_it_exited`,
    /// `last_h` 0, red on base). It never waits past the end's deadline, nor while only a daemon
    /// can drain the output the buffer cap holds back after the reap (review of #30897).
    #[test]
    fn a_hello_during_the_end_waits_for_the_exit_entry() {
        // (exit_in, given_up, reaped_and_held_back) -> waits
        assert!(hello_waits(false, false, false), "reaped or not, the exit is not logged yet");
        assert!(!hello_waits(true, false, false), "the exit is in");
        assert!(!hello_waits(false, true, false), "the end stopped waiting for the exit");
        assert!(!hello_waits(false, false, true), "only a daemon can drain the capped output");
    }
}
