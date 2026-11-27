//! A machine joined before the hub recorded capabilities states them itself, at daemon start.
//! A sign-in that finds such a join asks the same way (`enroll.rs`), never by a rotate. It sends
//! this acpmux's list ([`machine_capabilities`]) with its own credential to
//! `PUT /v1/machines/credentials/self/capabilities`, and its record keeps the hub's answer, so it
//! never asks again.
//!
//! - Only a record with no list asks: one a redeem or a rotate wrote never does.
//! - 409 `machine.capabilities_widen`: the hub holds a narrower list a person set. It is left as
//!   it is and recorded so (an empty list), never sent again.
//! - 401 `machine.revoked`: the record is marked revoked, as a sign-in's check marks it.
//! - No answer, or a retryable refusal (503 `machine.join.unavailable`): tried again in the
//!   background, at most [`BACKOFF`]`.len() + 1` times over about an hour, then not until the
//!   next start or the next time the mesh relay's hub answers again after failing. The daemon's
//!   start and its relay never wait for it.
//! - Any other refusal: nothing is recorded; the next start asks once more.
//! - The daemon start and a relay reconnect share one [`Trigger`]: one statement runs at a time,
//!   and none starts again once one settled (saved, or nothing to state). A start that finds no
//!   join settles nothing: a later join or sign-in asks.
//!
//! The recorded list is informational. Nothing reads it to decide whether this acpmux runs the
//! vault's egress proxy, or what a redeem or a rotate sends: those come from the build
//! ([`machine_capabilities`]). An empty list saved after a 409 says only what the hub holds.
use super::*;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

/// The waits between tries: five tries over about an hour (0, 2, 7, 22 and 62 minutes).
pub(crate) const BACKOFF: [Duration; 4] = [
    Duration::from_secs(2 * 60),
    Duration::from_secs(5 * 60),
    Duration::from_secs(15 * 60),
    Duration::from_secs(40 * 60),
];

/// What a start's statement did.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Stated {
    /// No call: a copy of another box's join, revoked, or a list already recorded.
    NotNeeded,
    /// No call: not joined. Not settled: a later join or sign-in may find a record with no list
    /// (one an older build wrote), and asks then.
    NotJoined,
    /// No call yet: a sign-out's leave is pending. Not settled: once the leave keeps the join
    /// (a pair-code or join-line machine), the start asks again ([`state_after_leave`]), and a
    /// reconnect or sign-in may.
    Deferred,
    /// The hub recorded this list, and the record keeps it.
    Recorded(Vec<String>),
    /// 409: the hub keeps the narrower list a person set; recorded as an empty list.
    LeftAlone,
    /// 401 `machine.revoked`: the record is marked revoked.
    Revoked,
    /// Refused for good (an unknown credential, an unknown capability): nothing recorded.
    Refused,
    /// The record changed while the hub answered (a sign-in rotated it, a leave removed it), or
    /// the join lock stayed held: nothing recorded here.
    Unsaved,
    /// Every try went unanswered: nothing recorded; the next start tries again.
    GaveUp,
}

/// The hub's answer to one try.
enum Answer {
    Set(Vec<String>),
    Widen,
    Revoked,
    Refused(String),
    Unavailable(String),
}

/// One statement at a time for this daemon, from its start or a relay reconnect, and none once
/// one settled.
pub(crate) struct Trigger {
    in_flight: AtomicBool,
    settled: AtomicBool,
}

/// This daemon's [`Trigger`].
static TRIGGER: Trigger = Trigger::new();

/// The owner of this daemon's statements: a child of the hub's scope, set at the start
/// ([`state_at_start`]), so the daemon's shutdown ends them. A process with none (the CLI)
/// starts none: the daemon's next start asks.
static SCOPE: std::sync::OnceLock<cmux_scope::Scope> = std::sync::OnceLock::new();

/// Clears the in-flight mark when its statement ends, however it ends.
struct InFlight<'a>(&'a AtomicBool);

impl Drop for InFlight<'_> {
    fn drop(&mut self) {
        self.0.store(false, Ordering::SeqCst);
    }
}

impl Trigger {
    pub(crate) const fn new() -> Self {
        Self { in_flight: AtomicBool::new(false), settled: AtomicBool::new(false) }
    }

    /// Starts a statement for the record in `home` in the background, unless one is running or
    /// one settled. None when it started none.
    pub(crate) fn fire(
        &'static self,
        scope: &cmux_scope::Scope,
        why: &'static str,
        home: PathBuf,
        current: Option<String>,
        backoff: &'static [Duration],
    ) -> Option<tokio::task::JoinHandle<Stated>> {
        if self.settled.load(Ordering::SeqCst)
            || self
                .in_flight
                .compare_exchange(false, true, Ordering::SeqCst, Ordering::SeqCst)
                .is_err()
        {
            return None;
        }
        // At most `backoff.len() + 1` hub requests (each with the join client's 10 s deadline) and
        // `backoff`'s waits, about an hour in all; ends with them, or with the daemon's scope.
        Some(scope.spawn_named("machine-capabilities", async move {
            let _in_flight = InFlight(&self.in_flight);
            let stated = state_at(&home, current.as_deref(), backoff).await;
            match &stated {
                Stated::NotNeeded | Stated::NotJoined | Stated::Deferred => {}
                stated => tracing::info!(?stated, why, "machine capabilities"),
            }
            // Saved, or nothing to state: no start or reconnect of this daemon asks again. Unsaved
            // or unanswered: the next reconnect may.
            if matches!(
                stated,
                Stated::NotNeeded
                    | Stated::Recorded(_)
                    | Stated::LeftAlone
                    | Stated::Revoked
                    | Stated::Refused
            ) {
                self.settled.store(true, Ordering::SeqCst);
            }
            stated
        }))
    }
}

/// Fires this daemon's [`Trigger`] for its own state, on its scope; none before the start set it.
fn fire(why: &'static str) {
    let Some(scope) = SCOPE.get() else { return };
    let _ = TRIGGER.fire(scope, why, state_dir(), host_fingerprint::current(), &BACKOFF);
}

/// At daemon start, after its relay: states this machine's capabilities in the background when
/// its record has none, as a task of `scope` (the hub's).
pub(crate) fn state_at_start(scope: &cmux_scope::Scope) {
    SCOPE.get_or_init(|| scope.child("machine capabilities"));
    fire("start");
}

/// The start's pending leave kept the join (`server/machine_enroll.rs`): the statement it put
/// off ([`Stated::Deferred`]) goes now.
pub(crate) fn state_after_leave() {
    fire("leave kept the join");
}

/// A sign-in found this machine joined with no list (`enroll.rs`): states it, as a start does.
pub(crate) fn state_on_sign_in() {
    fire("sign-in");
}

/// The joined mesh relay's hub answers again after failing (`server/mesh_relay.rs`): states this
/// machine's capabilities when its record still has none and no statement is running.
pub(crate) fn state_on_reconnect() {
    fire("reconnect");
}

/// The record in `home` that has no list yet and may ask with its own credential.
fn legacy_record(home: &Path, current: Option<&str>) -> Option<MachineCredential> {
    load_at(home).ok().flatten().filter(|record| {
        record.capabilities.is_none()
            && !record.revoked
            && record.credential.starts_with("cmm_")
            && !copied_here(home, record, current)
    })
}

/// States this acpmux's list for the record in `home` (the box whose fingerprint is `current`),
/// trying again after each of `backoff`'s waits while the hub does not answer.
pub(crate) async fn state_at(home: &Path, current: Option<&str>, backoff: &[Duration]) -> Stated {
    let sent = machine_capabilities();
    let mut waits = backoff.iter();
    loop {
        // A sign-out's leave pending: put off, not done (the leave may keep the join).
        if std::fs::symlink_metadata(home.join(enroll::LEAVE_FILE)).is_ok() {
            return Stated::Deferred;
        }
        // Read again before each try: a sign-in may have rotated it meanwhile.
        if load_at(home).ok().flatten().is_none() {
            return Stated::NotJoined;
        }
        let Some(record) = legacy_record(home, current) else { return Stated::NotNeeded };
        match ask(&record, &sent).await {
            Answer::Set(list) => {
                return save_if_unchanged(home, &record, |r| r.capabilities = Some(list.clone()))
                    .await
                    .map_or(Stated::Unsaved, |()| Stated::Recorded(list));
            }
            Answer::Widen => {
                return save_if_unchanged(home, &record, |r| r.capabilities = Some(Vec::new()))
                    .await
                    .map_or(Stated::Unsaved, |()| Stated::LeftAlone);
            }
            Answer::Revoked => {
                return save_if_unchanged(home, &record, |r| r.revoked = true)
                    .await
                    .map_or(Stated::Unsaved, |()| Stated::Revoked);
            }
            Answer::Refused(why) => {
                tracing::warn!("machine capabilities: the hub refused: {why}");
                return Stated::Refused;
            }
            Answer::Unavailable(why) => {
                let Some(wait) = waits.next() else {
                    tracing::warn!("machine capabilities: no answer, until the next start: {why}");
                    return Stated::GaveUp;
                };
                tracing::debug!("machine capabilities: no answer, trying again: {why}");
                tokio::time::sleep(*wait).await;
            }
        }
    }
}

/// One `PUT /v1/machines/credentials/self/capabilities` with the record's own credential.
async fn ask(record: &MachineCredential, sent: &[String]) -> Answer {
    let client = match origin(Some(record.hub_origin.clone()))
        .and_then(|hub| hub_client(&hub, Some(&record.credential)))
    {
        Ok(client) => client,
        Err(e) => return Answer::Refused(format!("{e:#}")),
    };
    let body: cmux_cloud_client::types::MachineSelfCapabilities =
        match serde_json::from_value(json!({"capabilities": sent})) {
            Ok(body) => body,
            Err(e) => return Answer::Refused(e.to_string()),
        };
    let answer = match client.machine_redeem_self_capabilities(&body).await {
        Ok(answer) => serde_json::to_value(answer.into_inner()).unwrap_or_default(),
        Err(error) => {
            let error = cmux_cloud_client::ApiError::from_api(error).await;
            // Status and code only: a message may repeat what was sent.
            let why = format!("{:?} {}", error.status, error.code.as_deref().unwrap_or_default());
            return match (error.status, error.code.as_deref()) {
                (Some(409), Some("machine.capabilities_widen")) => Answer::Widen,
                (Some(401), Some("machine.revoked")) => Answer::Revoked,
                _ if error.retryable => Answer::Unavailable(why),
                _ => Answer::Refused(why),
            };
        }
    };
    if answer.get("machineId").and_then(Value::as_str) != Some(record.machine_id.as_str()) {
        return Answer::Refused("the hub answered for another machine".to_owned());
    }
    let Some(list) = answer.get("capabilities").and_then(Value::as_array) else {
        return Answer::Refused("the hub answered with no list".to_owned());
    };
    Answer::Set(list.iter().filter_map(Value::as_str).filter_map(safe_id).collect())
}

/// Saves `edit` of the record in `home` only when it is still the one that asked: the same
/// credential, still with no list and not revoked.
async fn save_if_unchanged(
    home: &Path,
    asked: &MachineCredential,
    edit: impl FnOnce(&mut MachineCredential),
) -> Result<()> {
    let _lock = enroll::wait_for_lock(home)
        .await
        .ok_or_else(|| anyhow!("another machine join is in progress"))?;
    let mut record = load_at(home)?.ok_or_else(|| anyhow!("the join was removed"))?;
    anyhow::ensure!(
        record.credential == asked.credential && record.capabilities.is_none() && !record.revoked,
        "the record changed"
    );
    edit(&mut record);
    save_at(home, &record).inspect_err(|e| tracing::warn!("machine capabilities: not saved: {e:#}"))
}

#[cfg(all(test, unix))]
#[path = "self_capabilities_tests.rs"]
mod tests;
