//! Wake on intent on the phone: the phone unlocked (the app became active) with a Cloud
//! machine's chat in front, so a paused machine starts its restore before the first key.
//!
//! Every decision is the Mac's own rules (`cmux-cloud-handlers` `wake_hint`, the same
//! [`WakeHints`] ledger the Mac app asks over `cloud_handler_wake_*`): which signal counts, the
//! debounce, the per-machine cap, and the re-pause of a machine a hint woke that nobody used.
//! This module holds the process's one ledger on a monotonic clock and says each answer in
//! uniffi types. Swift only forwards the raw signal with the facts it holds, runs the resume or
//! pause these answer, and reports input from the chat's submit path.

use std::sync::{LazyLock, Mutex, MutexGuard, PoisonError};
use std::time::Instant;

use cmux_cloud_handlers::wake_hint::{self, Hint, HintDecision, IdleDecision, Outcome, Signal, WakeHints};

static WAKE_HINTS: LazyLock<Mutex<WakeHints>> = LazyLock::new(Mutex::default);
static EPOCH: LazyLock<Instant> = LazyLock::new(Instant::now);

fn ledger() -> MutexGuard<'static, WakeHints> {
    WAKE_HINTS.lock().unwrap_or_else(PoisonError::into_inner)
}

fn now_ms() -> u64 {
    u64::try_from(EPOCH.elapsed().as_millis()).unwrap_or(u64::MAX)
}

/// The wake hint's protocol version the phone sends (`WAKE_HINT_VERSION`).
#[uniffi::export]
pub fn cloud_wake_version() -> u32 {
    wake_hint::WAKE_HINT_VERSION
}

/// A hint as the phone forwards it: the raw signal (`focus`, `terminal`, `unlock`) and the
/// facts its models hold.
#[derive(Debug, Clone, uniffi::Record)]
pub struct CloudWakeHint {
    pub v: u32,
    pub machine: String,
    pub signal: String,
    /// The hidden setting (default off).
    pub enabled: bool,
    /// The phone may call Cloud (signed in).
    pub allowed: bool,
    /// The machine's status was read.
    pub loaded: bool,
    pub status: Option<String>,
}

/// What a hint does: resume the machine now, or skip it for `reason`.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CloudWakeAnswer {
    pub resume: bool,
    pub reason: Option<String>,
}

/// How a hint wake ended, for the wake log.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct CloudWakeOutcome {
    /// `used` (input followed; `ms` from the resume's answer to it) or `false` (no input within
    /// the bound; `ms` awake).
    pub tag: String,
    pub signal: String,
    pub ms: u64,
}

/// What to do about a machine a hint woke when its idle check comes due.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum CloudWakeIdle {
    /// Ask again this much later.
    Wait { check_after_ms: u64 },
    /// Pause it (script-originated); the wake was false.
    Pause { outcome: CloudWakeOutcome },
    /// Nothing more to do.
    Done,
}

/// Decides one hint. On `resume`, run the resume and tell [`cloud_wake_resumed`].
#[uniffi::export]
pub fn cloud_wake_hint(hint: CloudWakeHint) -> CloudWakeAnswer {
    answer(ledger().hint(&to_hint(hint), now_ms()))
}

/// The hint's resume answered; accepted: the idle check is due in the returned ms.
#[uniffi::export]
pub fn cloud_wake_resumed(machine: String, ok: bool) -> Option<u64> {
    ledger().resumed(&machine, ok, now_ms())
}

/// The person used `machine` (sent a prompt in its chat): a hint wake it had is `used`, once.
#[uniffi::export]
pub fn cloud_wake_input(machine: String) -> Option<CloudWakeOutcome> {
    ledger().input(&machine, now_ms()).map(outcome)
}

/// The idle check of a machine a hint woke, with its status now.
#[uniffi::export]
pub fn cloud_wake_idle(machine: String, status: Option<String>) -> CloudWakeIdle {
    idle(ledger().idle(&machine, status.as_deref(), now_ms()))
}

fn to_hint(hint: CloudWakeHint) -> Hint {
    // The raw name as the Mac's page sends it; an unknown one is the rules' `unknownSignal`.
    let signal = serde_json::from_value::<Signal>(serde_json::Value::String(hint.signal)).ok();
    Hint {
        v: hint.v,
        machine: hint.machine,
        signal,
        enabled: hint.enabled,
        allowed: hint.allowed,
        loaded: hint.loaded,
        status: hint.status,
    }
}

fn answer(decision: HintDecision) -> CloudWakeAnswer {
    match decision {
        HintDecision::Resume => CloudWakeAnswer { resume: true, reason: None },
        HintDecision::Skip(reason) => CloudWakeAnswer { resume: false, reason: Some(reason.to_owned()) },
    }
}

fn signal_name(signal: Signal) -> String {
    serde_json::to_value(signal).ok().and_then(|value| value.as_str().map(str::to_owned)).unwrap_or_default()
}

fn outcome(outcome: Outcome) -> CloudWakeOutcome {
    match outcome {
        Outcome::Used { signal, lead_ms } => {
            CloudWakeOutcome { tag: "used".into(), signal: signal_name(signal), ms: lead_ms }
        }
        Outcome::False { signal, awake_ms } => {
            CloudWakeOutcome { tag: "false".into(), signal: signal_name(signal), ms: awake_ms }
        }
    }
}

fn idle(decision: IdleDecision) -> CloudWakeIdle {
    match decision {
        IdleDecision::Wait { check_after_ms } => CloudWakeIdle::Wait { check_after_ms },
        IdleDecision::Pause { outcome: ended } => CloudWakeIdle::Pause { outcome: outcome(ended) },
        IdleDecision::Done => CloudWakeIdle::Done,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn unlock(machine: &str, status: &str) -> CloudWakeHint {
        CloudWakeHint {
            v: cloud_wake_version(),
            machine: machine.into(),
            signal: "unlock".into(),
            enabled: true,
            allowed: true,
            loaded: true,
            status: Some(status.into()),
        }
    }

    /// The phone's whole flow over the Mac's rules: an unlock wakes a paused machine once, input
    /// ends it `used`; a second wake with no input re-pauses after the bound, counted `false`.
    #[test]
    fn an_unlock_wakes_a_paused_machine_then_input_or_the_idle_bound_ends_it() {
        let mut hints = WakeHints::default();
        assert_eq!(
            answer(hints.hint(&to_hint(unlock("m", "paused")), 0)),
            CloudWakeAnswer { resume: true, reason: None }
        );
        // A second unlock while its resume is in flight starts nothing.
        assert_eq!(
            answer(hints.hint(&to_hint(unlock("m", "paused")), 10)).reason.as_deref(),
            Some("inFlight")
        );
        assert_eq!(hints.resumed("m", true, 100), Some(wake_hint::IDLE_BOUND_MS));
        let used = hints.input("m", 1_100).map(outcome);
        assert_eq!(used, Some(CloudWakeOutcome { tag: "used".into(), signal: "unlock".into(), ms: 1_000 }));
        assert_eq!(hints.input("m", 1_200), None, "input ends a hint wake once");

        let later = 10_000;
        assert!(answer(hints.hint(&to_hint(unlock("m", "paused")), later)).resume);
        hints.resumed("m", true, later);
        assert_eq!(
            idle(hints.idle("m", Some("starting"), later + 5)),
            CloudWakeIdle::Wait { check_after_ms: wake_hint::IDLE_BOUND_MS }
        );
        let due = later + wake_hint::IDLE_BOUND_MS;
        assert_eq!(
            idle(hints.idle("m", Some("running"), due)),
            CloudWakeIdle::Pause {
                outcome: CloudWakeOutcome {
                    tag: "false".into(),
                    signal: "unlock".into(),
                    ms: wake_hint::IDLE_BOUND_MS
                }
            }
        );
        assert_eq!(idle(hints.idle("m", Some("running"), due + 1)), CloudWakeIdle::Done);
    }

    /// Off by default, awake machines untouched, unknown signals skipped: the same rules as the Mac.
    #[test]
    fn an_unlock_skips_when_off_awake_or_unknown() {
        let mut hints = WakeHints::default();
        let mut off = unlock("a", "paused");
        off.enabled = false;
        assert_eq!(answer(hints.hint(&to_hint(off), 0)).reason.as_deref(), Some("disabled"));
        assert_eq!(
            answer(hints.hint(&to_hint(unlock("b", "running")), 0)).reason.as_deref(),
            Some("notPaused")
        );
        let mut odd = unlock("c", "paused");
        odd.signal = "shake".into();
        assert_eq!(answer(hints.hint(&to_hint(odd), 0)).reason.as_deref(), Some("unknownSignal"));
        // A failed resume frees the machine and starts no idle check.
        assert!(answer(hints.hint(&to_hint(unlock("d", "paused")), 0)).resume);
        assert_eq!(hints.resumed("d", false, 5), None);
        assert_eq!(idle(hints.idle("d", Some("paused"), 50_000)), CloudWakeIdle::Done);
    }

    /// The process ledger behind the exported calls answers the same way.
    #[test]
    fn the_exported_calls_share_one_ledger() {
        let machine = "vm_cloud_wake_exported";
        assert!(cloud_wake_hint(unlock(machine, "paused")).resume);
        assert_eq!(cloud_wake_resumed(machine.into(), true), Some(wake_hint::IDLE_BOUND_MS));
        assert!(matches!(
            cloud_wake_idle(machine.into(), Some("running".into())),
            CloudWakeIdle::Wait { .. }
        ));
        assert_eq!(cloud_wake_input(machine.into()).map(|ended| ended.tag), Some("used".into()));
        assert_eq!(cloud_wake_idle(machine.into(), Some("running".into())), CloudWakeIdle::Done);
    }
}
