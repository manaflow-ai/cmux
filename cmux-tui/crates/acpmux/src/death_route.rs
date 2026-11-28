//! Death routing: what happens next to a session that died while it owned work.
//!
//! One pure decision over what a watcher knows about the dead session (its host, how it died,
//! what was tried already, which hosts admit one more session): restart it in place, move it
//! with its transcript, start its host again, start it again from nothing on a healthy host,
//! fail it over to a successor, wait, or hand its work to a person or coordinator.
//! `acpmux session route --facts FILE` prints the decision; the caller runs the step
//! (`session restart`, `session move`, ...) and records what came of it, and asks again on its
//! next pass. Nothing here reads the fleet or runs a step: same facts, same answer.
//!
//! The order is the fleet's (leo-workspace `tools/lane_deaths.py` steps a-f, 2026-11-22), which
//! moves here so the product owns the decision (cmuxterm-hq `docs/design/fleet-dogfoods-remote.md`
//! move 2, failure classes 2 and 3):
//! - a live session holds the dead one's work: nothing starts;
//! - it came back: one resume prompt;
//! - it was moved: finish the move once it reads alive there;
//! - its host is down past the grace, or its row is gone, and this machine keeps a copy of its
//!   chat (`hub/peer_snapshot.rs`): move it from the copy (`session move --from-snapshot`) to the
//!   first admitted host, its transcript and name with it, before anything starts it from briefs
//!   (class 4: "let a move start from the copy");
//! - no row to restart (gone, and its host is not down within the grace), or a network death:
//!   start it again on a healthy host, else hand off (a network death goes on to failover);
//! - its host is down within the grace: ask its host to start (a GCP VM), else wait;
//! - a Codex usage limit resets within the hour: wait, then restart in place;
//! - not a capacity, paused-Codex or network death: an on-demand host moves it to a persistent
//!   one; a full host moves it to one with room (else hands off); else restart in place while
//!   restarts are left;
//! - then a successor (failover) while failovers are left, never onto a full fleet, past this
//!   pass's placement cap or too late in the pass;
//! - else hand off.
//!
//! Restart intensity (RFD 0181 B8, RFD 0177 item 4, OTP's `MaxR` in `MaxT`): the counts above
//! are per death, so a session that dies, comes back and dies again starts at restart 1 every
//! time. A caller that counts deaths across deaths sets `max_deaths`; once `deaths_in_window`
//! reaches it, the session is handed over (`Ending::Intensity`) instead of restarted, moved or
//! failed over again, unless a move is in flight or a live session holds its work.

use serde::{Deserialize, Serialize};

pub mod observe;

/// What a watcher knows about one dead session. Every field defaults, so a caller sends only
/// what it read; a missing count reads 0 and a missing flag false.
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct Facts {
    /// `HOST/NAME`, for the lines this prints.
    pub key: String,
    /// The host it ran on.
    pub host: String,
    /// It reads alive again this pass.
    pub alive: bool,
    /// Its row was read (a session exists to restart or move).
    pub has_row: bool,
    /// Its host is down (stopped VM, or unreachable past the bound).
    pub host_down: bool,
    /// Seconds since it was first seen dead.
    pub dead_seconds: f64,
    /// How long a down host gets to come back before its sessions are routed elsewhere.
    pub host_grace_seconds: f64,
    /// Its host is a GCP VM the watcher can ask to start.
    pub host_startable: bool,
    /// Its host is on-demand (an idle guard powers it off): a restart there dies again.
    pub host_on_demand: bool,
    /// It died of its own network failure, or on a host where another session did within the hour.
    pub network: bool,
    /// A provider capacity failure (Claude 503/529/429, a Codex usage limit): no in-place retry.
    pub capacity: bool,
    /// A Codex session while Codex is out: never restarted, moved or prompted in place.
    pub paused: bool,
    /// Seconds until a Codex usage limit resets, when it resets within the hour.
    pub reset_in_seconds: Option<f64>,
    /// When that limit resets (an ISO time), for the wait line; empty prints the minutes left.
    pub reset_at: String,
    /// A live session that holds its work (`HOST/NAME (PRs ...)`), or empty.
    pub holder: String,
    /// Why this pass may place no more sessions, or empty.
    pub placement_cap: String,
    /// Seconds left in the caller's pass, when it has a deadline.
    pub pass_seconds_left: Option<f64>,
    /// The least a failover needs of the pass to finish.
    pub failover_min_seconds: f64,
    /// Records of its chat this machine's copy holds (`_acpmux/peer_snapshot`, as
    /// `session move --from-snapshot --dry-run --json` counts them); 0 for none or unread.
    pub snapshot_records: u64,
    /// Its deaths within the restart-intensity window, this one included (the caller counts
    /// across deaths); 0 unread.
    pub deaths_in_window: u32,
    /// Restart intensity: at this many deaths in the window it is handed over, not restarted
    /// again; 0 is no limit.
    pub max_deaths: u32,
    /// The window's length in seconds, for the hand-off line.
    pub window_seconds: f64,
    pub max_restarts: u32,
    pub max_failovers: u32,
    pub hosts: Hosts,
    /// What earlier passes did (the caller's record of this death).
    pub tried: Tried,
}

/// Where it could go. Host lists are in preference order.
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct Hosts {
    /// The persistent hosts it may move or start on, in order.
    pub move_to: Vec<String>,
    /// Hosts whose sessions answered this pass.
    pub answering: Vec<String>,
    /// People's machines: never a fresh start's target.
    pub personal: Vec<String>,
    /// Hosts picked last.
    pub last_resort: Vec<String>,
    /// Hosts whose network failed a session within the hour.
    pub avoid: Vec<String>,
    /// Whether the admission read is known (every candidate's sessions were read).
    pub room_known: bool,
    /// Hosts admission would put one more session on, best first (away from `host`).
    pub admitted: Vec<String>,
    /// Hosts admission refuses.
    pub refused: Vec<String>,
    /// Why its own host refuses one more session (full, or a person's machine while a fleet host
    /// has room), or empty.
    pub own_full: String,
    /// The sentence that says no host admits one, for a hand-off or a wait.
    pub none_text: String,
}

/// What earlier passes did for this death.
#[derive(Debug, Clone, Default, Deserialize, Serialize, PartialEq)]
#[serde(default)]
pub struct Tried {
    /// Its work was handed off, or a successor was named: routing is over.
    pub done: bool,
    /// A resume prompt went out after it came back.
    pub resumed: bool,
    /// It was moved to this host (and the move is not finished).
    pub moved_to: String,
    /// A move failed (why).
    pub move_failed: String,
    /// A fresh start was tried.
    pub respawn_tried: bool,
    /// Why the fresh start failed.
    pub respawn_failed: String,
    /// Its host was asked to start.
    pub start_asked: bool,
    /// A move from this machine's copy failed (why).
    pub snapshot_failed: String,
    pub restarts: u32,
    pub failovers: u32,
}

/// The one step to run now.
#[derive(Debug, Clone, Deserialize, Serialize, PartialEq)]
#[serde(tag = "step", rename_all = "snake_case")]
pub enum Route {
    /// Nothing to do this pass (routing is over, or it waits silently).
    None,
    /// Wait; `why` is the line to record (once).
    Wait { why: String },
    /// It came back: send one resume prompt.
    Resume,
    /// It was moved: carry its work once it reads alive on `to`.
    FinishMove { to: String },
    /// Start a fresh session of its name on `to` (empty: the caller's pick) from its briefs.
    Respawn { to: String, network: bool },
    /// Ask its host to start; it resumes in place when the host is back.
    StartHost,
    /// `acpmux session move` to `to`; on failure, `otherwise` says what the next pass does.
    Move { to: String, otherwise: String },
    /// `acpmux session move --from-snapshot` to `to`: its host answers nothing, so it starts
    /// there from this machine's copy of its chat (a new chat of its name).
    MoveFromCopy { to: String },
    /// `acpmux session restart` in place (restart number `number`).
    Restart { number: u32 },
    /// Start a successor (failover number `number`), on `to` when set.
    Successor { to: String, number: u32 },
    /// Hand its work to whoever started it, else the coordinator. `after` says which step
    /// ran out: `fresh_start` (no host admits one, or the start failed), `full` (its host is full
    /// and nothing took it), `used_up` (restarts and failovers) or `intensity` (it died
    /// `max_deaths` times in the window).
    Handoff { why: String, after: Ending },
}

/// Which step ran out before a hand-off.
#[derive(Debug, Clone, Copy, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum Ending {
    FreshStart,
    Full,
    UsedUp,
    Intensity,
}

fn listed(list: &[String], host: &str) -> bool {
    list.iter().any(|h| h == host)
}

/// The admitted hosts past every host whose network failed a session within the hour.
fn healthy(f: &Facts) -> Vec<String> {
    f.hosts.admitted.iter().filter(|h| !listed(&f.hosts.avoid, h)).cloned().collect()
}

/// Decide the next step for the dead session `f`.
pub fn route(f: &Facts) -> Route {
    let h = &f.hosts;
    let t = &f.tried;
    if t.done {
        return Route::None;
    }
    if !f.holder.is_empty() && !f.alive {
        return Route::Wait { why: format!("a live lane holds its work: {}", f.holder) };
    }
    if f.alive {
        return if t.resumed || f.paused { Route::None } else { Route::Resume };
    }
    if !t.moved_to.is_empty() {
        return Route::FinishMove { to: t.moved_to.clone() };
    }
    if f.max_deaths > 0 && f.deaths_in_window >= f.max_deaths {
        let why = format!(
            "it died {} times in {} min (restart intensity: {} in {} min), so it is not started \
again",
            f.deaths_in_window,
            (f.window_seconds / 60.0).round() as u64,
            f.max_deaths,
            (f.window_seconds / 60.0).round() as u64,
        );
        return Route::Handoff { why, after: Ending::Intensity };
    }
    let in_grace = f.host_down && f.dead_seconds < f.host_grace_seconds;
    let network = f.network && !f.host_down && f.has_row && !f.capacity;
    if (f.host_down || !f.has_row)
        && !in_grace
        && f.snapshot_records > 0
        && t.snapshot_failed.is_empty()
        && !t.respawn_tried
    {
        let to = if h.room_known {
            healthy(f).into_iter().find(|c| *c != f.host)
        } else {
            h.move_to
                .iter()
                .find(|c| {
                    **c != f.host
                        && listed(&h.answering, c)
                        && !listed(&h.personal, c)
                        && !listed(&h.last_resort, c)
                        && !listed(&h.avoid, c)
                })
                .cloned()
        };
        if let Some(to) = to {
            if !f.placement_cap.is_empty() {
                return Route::Wait { why: f.placement_cap.clone() };
            }
            return Route::MoveFromCopy { to };
        }
    }
    if (!f.has_row && !in_grace) || (network && !t.respawn_tried) {
        let mut target = h
            .move_to
            .iter()
            .find(|c| {
                **c != f.host
                    && listed(&h.answering, c)
                    && !listed(&h.personal, c)
                    && !listed(&h.last_resort, c)
                    && !listed(&h.avoid, c)
            })
            .cloned()
            .unwrap_or_default();
        let mut no_room = String::new();
        if h.room_known {
            let admitted = healthy(f);
            target = admitted.first().cloned().unwrap_or_default();
            if admitted.is_empty() {
                no_room = h.none_text.clone();
                if !h.avoid.is_empty() {
                    let mut avoid = h.avoid.clone();
                    avoid.sort();
                    no_room.push_str(&format!(
                        "; hosts whose network failed a lane within the hour: {}",
                        avoid.join(", ")
                    ));
                }
            }
        }
        if !f.placement_cap.is_empty() && !t.respawn_tried && no_room.is_empty() {
            return Route::Wait { why: f.placement_cap.clone() };
        }
        if !t.respawn_tried && no_room.is_empty() && (!target.is_empty() || !network) {
            return Route::Respawn { to: target, network };
        }
        if !network {
            let why = if !no_room.is_empty() {
                format!("no host would admit a fresh session: {no_room}")
            } else {
                let failed =
                    if t.respawn_failed.is_empty() { "unknown" } else { &t.respawn_failed };
                format!("a fresh session could not start: {failed}")
            };
            return Route::Handoff { why, after: Ending::FreshStart };
        }
        // a network death whose fresh start could not happen: a successor on a healthy host below
    }
    if in_grace {
        return if f.host_startable && !t.start_asked { Route::StartHost } else { Route::None };
    }
    if let Some(reset) = f.reset_in_seconds
        && !f.host_down
        && reset > 0.0
    {
        let when = if f.reset_at.is_empty() {
            format!("in {} min", (reset / 60.0).ceil() as u64)
        } else {
            format!("at {}", f.reset_at)
        };
        return Route::Wait {
            why: format!("waits for its Codex usage limit to reset {when}, then restarts in place"),
        };
    }
    let capacity = f.capacity && !f.host_down;
    if !capacity && !f.paused && !network {
        let persistent = h
            .move_to
            .iter()
            .find(|c| **c != f.host && listed(&h.answering, c) && !listed(&h.refused, c))
            .cloned();
        if let Some(to) = persistent
            && !f.host_down
            && f.host_on_demand
            && t.move_failed.is_empty()
            && f.has_row
        {
            return Route::Move { to, otherwise: "restarting in place instead".into() };
        }
        let full = if f.host_down { "" } else { h.own_full.as_str() };
        if !full.is_empty() && t.restarts < f.max_restarts {
            if let Some(to) = h.admitted.first()
                && t.move_failed.is_empty()
                && f.has_row
            {
                return Route::Move {
                    to: to.clone(),
                    otherwise: "its work goes to a live owner instead".into(),
                };
            }
            let why = if !t.move_failed.is_empty() {
                format!(
                    "{full}, so it is not restarted there, and the move failed: {}",
                    t.move_failed
                )
            } else {
                format!("{full}, so it is not restarted there; {}", h.none_text)
            };
            return Route::Handoff { why, after: Ending::Full };
        }
        if !f.host_down && t.restarts < f.max_restarts {
            return Route::Restart { number: t.restarts + 1 };
        }
    }
    if t.failovers < f.max_failovers {
        let healthy = if h.room_known { healthy(f) } else { Vec::new() };
        if !capacity && h.room_known && healthy.is_empty() {
            return Route::Wait {
                why: format!("failover waits: {}; the next pass tries again", h.none_text),
            };
        }
        if !f.placement_cap.is_empty() {
            return Route::Wait { why: format!("failover waits: {}", f.placement_cap) };
        }
        if let Some(left) = f.pass_seconds_left
            && left < f.failover_min_seconds
        {
            return Route::Wait {
                why: format!(
                    "failover waits: under {} s of this pass left; the next pass starts it",
                    f.failover_min_seconds
                ),
            };
        }
        let to = if network { healthy.first().cloned().unwrap_or_default() } else { String::new() };
        return Route::Successor { to, number: t.failovers + 1 };
    }
    Route::Handoff { why: "restarts and failovers used up".into(), after: Ending::UsedUp }
}

#[cfg(test)]
#[path = "death_route_tests.rs"]
mod tests;
