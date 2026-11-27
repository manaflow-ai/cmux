use super::*;
use crate::attach::Reattach;
use crate::client::{DaemonConfig, Reconnect, reconnect_after};
use acpmux_list_types::resume::ResumeBudget;
use cmux::ResourceKind;
use std::io::{self, ErrorKind};
use std::time::Duration;

/// Every reconnect the worker makes for `class` until it gives up, and the
/// one after (the budget starts over).
fn reconnects(class: ResumeErrorClass) -> (Vec<Reconnect>, Reconnect) {
    let config = DaemonConfig::new("resume-class-test");
    let mut budget = ResumeBudget::new();
    let mut seen = Vec::new();
    loop {
        let next = reconnect_after(&mut budget, class, &config);
        seen.push(next);
        if next.gave_up {
            break;
        }
        assert!(seen.len() <= 64, "{class} never gave up");
    }
    let after = reconnect_after(&mut budget, class, &config);
    (seen, after)
}

fn waits(seen: &[Reconnect]) -> Vec<Duration> {
    seen.iter().filter(|r| !r.gave_up).map(|r| r.retry_in).collect()
}

fn io(kind: ErrorKind) -> cmux::Error {
    cmux::Error::ConnectionIo { message: format!("{kind:?}"), kind }
}

#[test]
fn a_mirror_gap_is_gap_too_old_and_reconnects_for_a_snapshot_at_once() {
    for e in [
        MirrorError::NoBaseline,
        MirrorError::GenerationChanged { mirror: "g1".into(), event: "g2".into() },
        MirrorError::RevisionGap { mirror: 4, previous: 9 },
        MirrorError::Mismatch(ResourceKind::Workspace),
        MirrorError::InvalidState { resource: "w".into(), reason: "r".into() },
    ] {
        let end = SessionEnd::mirror(&e);
        assert_eq!(end.class, ResumeErrorClass::GapTooOld, "{e}");
        assert!(end.error.starts_with("resync: "));
    }
    let gone = AttachEnd::TerminalGone("no such terminal".into());
    assert_eq!(attach_end_class(&gone), ResumeErrorClass::GapTooOld);

    let (seen, after) = reconnects(ResumeErrorClass::GapTooOld);
    // Before: the first resync waited min_backoff (250 ms), the next 500 ms.
    assert_eq!(waits(&seen), vec![Duration::ZERO, Duration::ZERO]);
    assert_eq!(seen.last().map(|r| r.retry_in), Some(Duration::from_secs(10)));
    assert!(seen.iter().all(|r| !r.refresh_key));
    assert!(!after.gave_up, "the budget starts over after the park");
}

#[test]
fn a_timeout_is_deadline_exceeded_and_stops_after_three_retries() {
    assert_eq!(
        sdk_class(&cmux::Error::Timeout("session.snapshot".into())),
        ResumeErrorClass::DeadlineExceeded
    );
    assert_eq!(sdk_class(&io(ErrorKind::TimedOut)), ResumeErrorClass::DeadlineExceeded);
    assert_eq!(
        launch_class(&LaunchError::Timeout(Duration::from_secs(20))),
        ResumeErrorClass::DeadlineExceeded
    );
    let (seen, _) = reconnects(ResumeErrorClass::DeadlineExceeded);
    let s = Duration::from_secs;
    assert_eq!(waits(&seen), vec![s(1), s(2), s(4)]);
    assert!(seen.last().is_some_and(|r| r.gave_up));
}

#[test]
fn a_clean_close_reattaches_fresh_at_once_three_times_then_parks() {
    assert_eq!(SessionEnd::stream_ended().class, ResumeErrorClass::CleanClose);
    assert_eq!(sdk_class(&cmux::Error::Closed), ResumeErrorClass::CleanClose);
    assert_eq!(
        sdk_class(&cmux::Error::StreamEnded {
            reason: "shutdown".into(),
            recovery: None,
            error: None
        }),
        ResumeErrorClass::CleanClose
    );
    assert_eq!(attach_end_class(&AttachEnd::Released), ResumeErrorClass::CleanClose);
    let shutdown = AttachEnd::Interrupted {
        reason: EndReason::Detached {
            reason: Some(cmux::raw::DetachReason::HostShutdown),
            actor: None,
        },
        reattach: Reattach::AfterGenerationResolves,
    };
    assert_eq!(attach_end_class(&shutdown), ResumeErrorClass::CleanClose);

    let (seen, _) = reconnects(ResumeErrorClass::CleanClose);
    assert_eq!(waits(&seen), vec![Duration::ZERO; 3]);
    assert!(seen.last().is_some_and(|r| r.gave_up && r.retry_in == Duration::from_secs(10)));
}

#[test]
fn a_refused_credential_is_auth_reloads_the_key_once_then_gives_up() {
    assert_eq!(
        sdk_class(&cmux::Error::AuthorityDenied { command: "client-hello", authority: "app" }),
        ResumeErrorClass::Auth
    );
    assert_eq!(sdk_class(&io(ErrorKind::PermissionDenied)), ResumeErrorClass::Auth);
    let (seen, _) = reconnects(ResumeErrorClass::Auth);
    assert_eq!(seen.len(), 2);
    assert_eq!(seen[0], Reconnect { retry_in: Duration::ZERO, refresh_key: true, gave_up: false });
    assert!(seen[1].gave_up && !seen[1].refresh_key);
}

#[test]
fn a_refused_socket_is_transient_and_keeps_the_configured_backoff_for_eight_tries() {
    for e in [io(ErrorKind::ConnectionRefused), io(ErrorKind::NotFound), io(ErrorKind::BrokenPipe)]
    {
        assert_eq!(sdk_class(&e), ResumeErrorClass::Transient, "{e}");
    }
    assert_eq!(sdk_class(&cmux::Error::Connection("reset".into())), ResumeErrorClass::Transient);
    let wrapped = cmux::Error::StreamEnded {
        reason: "lost".into(),
        recovery: None,
        error: Some(Box::new(io(ErrorKind::ConnectionReset))),
    };
    assert_eq!(sdk_class(&wrapped), ResumeErrorClass::Transient);
    assert_eq!(
        launch_class(&LaunchError::Spawn(io::Error::from(ErrorKind::ConnectionRefused))),
        ResumeErrorClass::Transient
    );
    let (seen, _) = reconnects(ResumeErrorClass::Transient);
    let ms = Duration::from_millis;
    // The same 250 ms..10 s doubling as before, now with an end.
    assert_eq!(
        waits(&seen),
        vec![ms(250), ms(500), ms(1000), ms(2000), ms(4000), ms(8000), ms(10_000), ms(10_000)]
    );
    assert!(seen.last().is_some_and(|r| r.gave_up));
}

#[test]
fn an_unnamed_failure_is_unknown_and_retries_once() {
    assert_eq!(sdk_class(&cmux::Error::Decode("bad json".into())), ResumeErrorClass::Unknown);
    assert_eq!(launch_class(&LaunchError::BinaryNotFound(Vec::new())), ResumeErrorClass::Unknown);
    assert_eq!(attach_end_class(&AttachEnd::Failed("x".into())), ResumeErrorClass::Unknown);
    let (seen, _) = reconnects(ResumeErrorClass::Unknown);
    assert_eq!(waits(&seen), vec![Duration::from_secs(1)]);
    assert!(seen.last().is_some_and(|r| r.gave_up));
}

#[test]
fn a_configured_max_backoff_caps_every_class_and_the_park() {
    let mut config = DaemonConfig::new("resume-class-test");
    config.max_backoff = Duration::from_millis(300);
    let mut budget = ResumeBudget::new();
    for class in ResumeErrorClass::ALL {
        for _ in 0..20 {
            let next = reconnect_after(&mut budget, class, &config);
            assert!(next.retry_in <= config.max_backoff, "{class}: {next:?}");
        }
    }
}
