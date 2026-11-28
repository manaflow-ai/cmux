//! cmux#52200: Cosmic Gray read "Offline" on Leo's iPhone for 50 minutes while the Mac was up
//! but overloaded, with no way to retry or see why. Mirrors MacReachabilityTests.swift.

use super::*;
use MacLinkFailureKind as F;
use MacLinkState as L;
use MacReachabilityKind as K;
use MacRecoveryObservation as O;
use MacRecoveryStep as S;

fn resolve(online: bool, quiet: Option<i64>, connection: Option<L>, failure: Option<F>) -> K {
    mac_reachability_resolve(MacReachabilityInput {
        is_online: online,
        quiet_ms: if online { mac_reachability_late_quiet(quiet) } else { None },
        connection,
        failure,
        live: true,
        phone_offline: false,
    })
}

fn attempt(step: S) -> MacRecoveryAttemptState {
    MacRecoveryAttemptState { step, result: None }
}

fn ended(step: S, result: MacRecoveryResult) -> MacRecoveryAttemptState {
    MacRecoveryAttemptState { step, result: Some(result) }
}

fn failed(step: S) -> MacRecoveryResult {
    MacRecoveryResult::Failed { step }
}

#[test]
fn offline_offers_retry() {
    let reach = resolve(false, None, None, None);
    assert_eq!(reach, K::Offline);
    assert_eq!(mac_reachability_action(reach), Some(MacRecoveryActionKind::Retry));
}

/// The incident: listed online, but its heartbeat stopped reaching the service.
#[test]
fn late_heartbeat_is_slow_not_offline() {
    let reach = resolve(true, Some(185_000), None, None);
    assert_eq!(reach, K::Slow { quiet_seconds: 180 });
    assert_eq!(mac_reachability_action(reach), Some(MacRecoveryActionKind::Retry));
    assert_eq!(mac_reachability_span(180), "3 min");
}

#[test]
fn fresh_heartbeat_is_dropped_so_polls_change_nothing() {
    assert_eq!(mac_reachability_late_quiet(Some(4_000)), None);
    assert_eq!(mac_reachability_late_quiet(Some(18_000)), None);
    assert_eq!(mac_reachability_late_quiet(Some(18_001)), Some(10_000));
    assert_eq!(mac_reachability_late_quiet(Some(25_000)), mac_reachability_late_quiet(Some(29_999)));
    assert_eq!(mac_reachability_late_quiet(None), None);
}

#[test]
fn a_live_link_wins_over_a_late_heartbeat() {
    assert_eq!(resolve(true, Some(60_000), Some(L::Connected), None), K::Connected);
    assert_eq!(resolve(true, Some(60_000), Some(L::Connecting), None), K::Connecting);
}

#[test]
fn a_dial_that_got_no_answer_says_so_with_what_the_service_said() {
    assert_eq!(resolve(false, None, None, Some(F::HostUnreachable)), K::Offline);
    assert_eq!(
        resolve(true, None, Some(L::Failed), Some(F::HostUnreachable)),
        K::NoAnswer { listed_online: true }
    );
    // A failed link with no failure recorded yet still says it didn't answer.
    assert_eq!(resolve(true, None, Some(L::Failed), None), K::NoAnswer { listed_online: true });
    // A new dial under way is connecting, whatever the last one did.
    assert_eq!(resolve(true, None, Some(L::Connecting), Some(F::HostUnreachable)), K::Connecting);
}

#[test]
fn reached_the_mac_but_cmux_did_not_answer_is_service_down() {
    let reach = resolve(true, None, Some(L::Connected), Some(F::ServiceDown));
    assert_eq!(reach, K::ServiceDown);
    assert_eq!(mac_reachability_action(reach), Some(MacRecoveryActionKind::Retry));
}

#[test]
fn auth_and_pairing_and_phone_network() {
    assert_eq!(resolve(true, None, Some(L::Failed), Some(F::AuthRequired)), K::AuthRequired);
    assert_eq!(mac_reachability_action(K::AuthRequired), Some(MacRecoveryActionKind::SignIn));
    assert_eq!(resolve(true, None, Some(L::Failed), Some(F::NotAllowed)), K::NotAllowed);
    let phone = |connection| {
        mac_reachability_resolve(MacReachabilityInput {
            is_online: true,
            quiet_ms: None,
            connection,
            failure: None,
            live: true,
            phone_offline: true,
        })
    };
    assert_eq!(phone(None), K::PhoneOffline);
    assert_eq!(phone(Some(L::Connected)), K::Connected);
}

#[test]
fn not_linked_online_mac_is_not_connected() {
    assert_eq!(resolve(true, None, None, None), K::NotConnected);
    assert_eq!(mac_reachability_action(K::NotConnected), None);
}

#[test]
fn mock_mode_follows_presence() {
    let mock = |online, failure| {
        mac_reachability_resolve(MacReachabilityInput {
            is_online: online,
            quiet_ms: Some(90_000),
            connection: None,
            failure,
            live: false,
            phone_offline: false,
        })
    };
    assert_eq!(mock(true, None), K::Connected);
    assert_eq!(mock(false, Some(F::ServiceDown)), K::Offline);
}

#[test]
fn spans_read_seconds_minutes_hours() {
    assert_eq!(mac_reachability_span(45), "45 s");
    assert_eq!(mac_reachability_span(3599), "59 min");
    assert_eq!(mac_reachability_span(7200), "2 h");
}

#[test]
fn steps_advance_to_connected() {
    let mut a = mac_recovery_advanced(attempt(S::Mac), O::Dialing);
    assert_eq!(a, attempt(S::Mac));
    a = mac_recovery_advanced(a, O::Linked);
    assert_eq!(a, attempt(S::Session));
    a = mac_recovery_advanced(a, O::Live);
    assert_eq!(a.result, Some(MacRecoveryResult::Connected));
}

#[test]
fn no_answer_from_the_mac_fails_at_the_mac() {
    assert_eq!(mac_recovery_advanced(attempt(S::Mac), O::Offline).result, Some(failed(S::Mac)));
    assert_eq!(
        mac_recovery_advanced(attempt(S::Mac), O::Failed { failure: F::HostUnreachable }).result,
        Some(failed(S::Mac))
    );
}

#[test]
fn daemon_silence_fails_at_the_session_step() {
    let a = mac_recovery_advanced(attempt(S::Mac), O::Linked);
    let a = mac_recovery_advanced(a, O::Failed { failure: F::ServiceDown });
    assert_eq!(a.result, Some(failed(S::Session)));
    let refused = mac_recovery_advanced(attempt(S::Mac), O::Failed { failure: F::NotAllowed });
    assert_eq!(refused.result, Some(failed(S::Mac)));
}

#[test]
fn the_service_step_ignores_the_link_and_an_ended_attempt_stays() {
    assert_eq!(mac_recovery_advanced(attempt(S::Service), O::Live), attempt(S::Service));
    let done = ended(S::Mac, failed(S::Mac));
    assert_eq!(mac_recovery_advanced(done, O::Live), done);
    assert_eq!(mac_recovery_timed_out(done), done);
}

/// All Macs: one Retry over every offline Mac reads as one attempt.
#[test]
fn combined_attempt_runs_while_any_runs_and_connects_when_one_does() {
    assert_eq!(mac_recovery_combined(vec![]), None);
    let f = ended(S::Mac, failed(S::Mac));
    assert_eq!(mac_recovery_combined(vec![f, attempt(S::Session)]), Some(attempt(S::Session)));
    assert_eq!(
        mac_recovery_combined(vec![f, ended(S::Session, MacRecoveryResult::Connected)])
            .and_then(|a| a.result),
        Some(MacRecoveryResult::Connected)
    );
    assert_eq!(
        mac_recovery_combined(vec![f, ended(S::Service, failed(S::Service))]),
        Some(ended(S::Mac, failed(S::Mac)))
    );
}

#[test]
fn a_deadline_fails_where_the_attempt_stood() {
    assert_eq!(mac_recovery_timed_out(attempt(S::Session)).result, Some(failed(S::Session)));
    assert_eq!(mac_recovery_timed_out(attempt(S::Service)).result, Some(failed(S::Service)));
}
