//! The daemon on the supervisor contract (`cmux-supervise-core`, hq
//! `docs/design/remote-cloud-durability.md` 4.1), the same one `cmux host run` keeps on a Cloud
//! machine.
//!
//! - Once it holds `daemon.lock`, before it serves, the daemon settles how the one before it
//!   ended and writes its own owner record (`daemon.owner.json`: pid, start time, pgid, boot id,
//!   epoch, argv). A client tells "the daemon still runs" from that record, never from a pid
//!   alone: after a reboot or a crash a recorded pid may be anyone's (F7, `client::closed_error`).
//! - Every stop is counted with its cause in `daemon.stops.json`, per day. A stop it makes itself
//!   writes its end first (`daemon.end.json`); a previous owner that wrote none and is gone died
//!   (a crash, a kill, a power loss), and its death goes to `daemon.deaths.jsonl` naming what it
//!   owned. Deaths and self-stops count against [`BUDGET_PER_DAY`]; meant stops and update
//!   handovers do not. Above it, `_acpmux/status` reads `restart-budget-exceeded` with the causes.
//!   The service manager (launchd `KeepAlive`, systemd `Restart=always`) still starts it: a held
//!   daemon would turn a loop into an outage of every chat on the machine, so here the budget is
//!   the alarm, and the loop is visible instead of looking like normal life.

use std::path::Path;
use std::sync::Mutex;

use cmux_supervise_core::{Files, OwnerRecord, StopCause, ends, record};
use serde_json::{Value, json};

/// Faults (deaths, self-stops) a day before the daemon reads `restart-budget-exceeded`. A daemon
/// that never crashes and never stops itself spends none (leo-workspace `daemon_stops.py` keeps
/// 0 outside installs); a few are a bad day, more is a loop.
pub(crate) const BUDGET_PER_DAY: u32 = 3;

/// This daemon's files in `home`.
pub(crate) fn files(home: &Path) -> Files {
    Files::new(home, "daemon", BUDGET_PER_DAY)
}

/// The record this daemon wrote at its start, while it runs.
static OWNER: Mutex<Option<OwnerRecord>> = Mutex::new(None);
/// Why this daemon is stopping, as the stop that won named it; the first one stays.
static STOPPING: Mutex<Option<StopCause>> = Mutex::new(None);

/// Writes under the held home only (`config::write_atomic`).
fn write(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    crate::config::write_atomic(path, bytes).map_err(std::io::Error::other)
}

/// After the lock, before serving: settle the previous owner's end, then write this one's
/// record. Best effort: a daemon that cannot write it (a full disk) serves without it; a client
/// then reads its liveness as unknown and keeps it.
pub(super) fn start(home: &Path) {
    let files = files(home);
    let owned = ["daemon.log", "logs", "sessions"].map(|n| home.join(n).display().to_string());
    match ends::settle_previous(&files, &owned, &write) {
        ends::Previous::Died(death) => {
            tracing::warn!(
                pid = death.owner.pid,
                epoch = death.owner.epoch,
                "the daemon before this one died without a stop; counted ({:?})",
                files.budget.state()
            );
        }
        ends::Previous::Ended(prev, end) => {
            tracing::info!(pid = prev.pid, epoch = prev.epoch, cause = ?end.cause, "the daemon before this one stopped");
        }
        ends::Previous::None | ends::Previous::Running(_) => {}
    }
    match record::claim_current_with(&files.owner, &write) {
        Ok(owner) => *OWNER.lock().unwrap_or_else(std::sync::PoisonError::into_inner) = Some(owner),
        Err(e) => tracing::warn!("the daemon's owner record: {e}"),
    }
}

/// Name why this daemon stops; the first cause stays.
pub(crate) fn stopping(cause: StopCause) {
    let mut slot = STOPPING.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    slot.get_or_insert(cause);
}

/// Whether this daemon is stopping to hand its home over to an update's successor.
pub(crate) fn handing_over() -> bool {
    matches!(
        *STOPPING.lock().unwrap_or_else(std::sync::PoisonError::into_inner),
        Some(StopCause::Update(_))
    )
}

/// The cause of a client's `_acpmux/shutdown`: an update's or a take-over's handover, else a
/// meant stop.
pub(crate) fn shutdown_cause(reason: &str, restart: bool) -> StopCause {
    if restart || reason.starts_with("handover") || reason.contains("update") {
        StopCause::Update(reason.to_owned())
    } else {
        StopCause::Intentional(reason.to_owned())
    }
}

/// At the end of `run`, before the process exits: write this daemon's end and count it.
pub(super) fn finish(home: &Path, exit_status: i32) {
    let Some(owner) = OWNER.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take() else {
        return;
    };
    let named = STOPPING.lock().unwrap_or_else(std::sync::PoisonError::into_inner).take();
    let cause = match exit_status {
        super::EXIT_REPAIR => {
            StopCause::SelfStop("the store asked for a repair restart (74)".into())
        }
        super::stop_causes::EXIT_TASK_PANIC => {
            StopCause::SelfStop("a supervised task could not go on (70)".into())
        }
        _ => named.unwrap_or_else(|| StopCause::Intentional("stopped".into())),
    };
    if let Err(e) = ends::mark(&files(home), owner.epoch, cause, &write) {
        tracing::warn!("the daemon's end: {e}");
    }
}

/// The `supervisor` block of `_acpmux/status`: this daemon's owner record and today's stops.
pub(crate) fn status(home: &Path) -> Value {
    let files = files(home);
    let ledger = files.budget.today();
    let state = files.budget.state_of(&ledger);
    let owner = OWNER.lock().unwrap_or_else(std::sync::PoisonError::into_inner).clone();
    let recent: Vec<_> = ledger.recent.iter().rev().take(10).collect();
    json!({
        "state": if state.exceeded() { "restart-budget-exceeded" } else { "running" },
        "owner": owner,
        "budget": state,
        "stopsToday": ledger.stops,
        "faultsToday": ledger.faults,
        "recent": recent,
    })
}

/// The owner record in `home`, if any.
pub(crate) fn owner(home: &Path) -> Option<OwnerRecord> {
    record::load(&files(home).owner).record().cloned()
}
