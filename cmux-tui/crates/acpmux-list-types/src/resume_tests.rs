use super::*;
use std::io::ErrorKind;

/// Spends `class`'s whole budget and returns every decision, including the
/// first refusal.
fn run_out(class: ResumeErrorClass) -> Vec<Decision> {
    let mut budget = ResumeBudget::new();
    let mut decisions = Vec::new();
    loop {
        let decision = budget.on_failure(class);
        decisions.push(decision);
        if matches!(decision, Decision::Surface { .. }) {
            return decisions;
        }
        assert!(decisions.len() <= 64, "{class} never surfaced");
    }
}

fn steps(decisions: &[Decision]) -> Vec<(NextStep, Duration)> {
    decisions
        .iter()
        .filter_map(|d| match d {
            Decision::Act { step, after, .. } => Some((*step, *after)),
            Decision::Surface { .. } => None,
        })
        .collect()
}

#[test]
fn gap_too_old_resyncs_at_once_and_surfaces_on_the_second_gap() {
    let decisions = run_out(ResumeErrorClass::GapTooOld);
    assert_eq!(
        steps(&decisions),
        vec![(NextStep::FullResync, Duration::ZERO), (NextStep::FullResync, Duration::ZERO)]
    );
    assert_eq!(
        decisions.last(),
        Some(&Decision::Surface { class: ResumeErrorClass::GapTooOld, attempts: 2 })
    );
    // Never a retry of the cursor that fell off the log.
    assert!(steps(&decisions).iter().all(|(step, _)| *step != NextStep::RetrySameCursor));
}

#[test]
fn deadline_exceeded_retries_three_times_with_bounded_waits_then_surfaces() {
    assert_eq!(
        ResumeErrorClass::from_io_kind(ErrorKind::TimedOut),
        ResumeErrorClass::DeadlineExceeded
    );
    let decisions = run_out(ResumeErrorClass::DeadlineExceeded);
    assert_eq!(
        steps(&decisions),
        vec![
            (NextStep::RetrySameCursor, Duration::from_secs(1)),
            (NextStep::RetrySameCursor, Duration::from_secs(2)),
            (NextStep::RetrySameCursor, Duration::from_secs(4)),
        ]
    );
    assert!(matches!(decisions.last(), Some(Decision::Surface { attempts: 3, .. })));
}

#[test]
fn clean_close_reattaches_fresh_never_retries_the_old_stream() {
    let decisions = run_out(ResumeErrorClass::CleanClose);
    assert_eq!(steps(&decisions), vec![(NextStep::ReattachFresh, Duration::ZERO); 3]);
    assert!(matches!(
        decisions.last(),
        Some(Decision::Surface { class: ResumeErrorClass::CleanClose, attempts: 3 })
    ));
}

#[test]
fn auth_refreshes_the_credential_once_then_stops() {
    assert_eq!(ResumeErrorClass::from_io_kind(ErrorKind::PermissionDenied), ResumeErrorClass::Auth);
    let decisions = run_out(ResumeErrorClass::Auth);
    assert_eq!(steps(&decisions), vec![(NextStep::RefreshCredential, Duration::ZERO)]);
    assert_eq!(
        decisions.last(),
        Some(&Decision::Surface { class: ResumeErrorClass::Auth, attempts: 1 })
    );
}

#[test]
fn transient_retries_eight_times_with_backoff_capped_at_ten_seconds() {
    for kind in [
        ErrorKind::ConnectionRefused,
        ErrorKind::ConnectionReset,
        ErrorKind::BrokenPipe,
        ErrorKind::NotFound,
        ErrorKind::UnexpectedEof,
        ErrorKind::NetworkUnreachable,
    ] {
        assert_eq!(ResumeErrorClass::from_io_kind(kind), ResumeErrorClass::Transient, "{kind:?}");
    }
    let decisions = run_out(ResumeErrorClass::Transient);
    let waits: Vec<_> = steps(&decisions).into_iter().map(|(_, after)| after).collect();
    let ms = Duration::from_millis;
    assert_eq!(
        waits,
        vec![ms(250), ms(500), ms(1000), ms(2000), ms(4000), ms(8000), ms(10_000), ms(10_000)]
    );
    assert!(matches!(decisions.last(), Some(Decision::Surface { attempts: 8, .. })));
    assert_eq!(ResumeErrorClass::Transient.policy().total_wait(), ms(35_750));
}

#[test]
fn unknown_retries_once_then_surfaces() {
    assert_eq!(ResumeErrorClass::from_io_kind(ErrorKind::InvalidData), ResumeErrorClass::Unknown);
    let decisions = run_out(ResumeErrorClass::Unknown);
    assert_eq!(steps(&decisions), vec![(NextStep::RetrySameCursor, Duration::from_secs(1))]);
    assert!(matches!(decisions.last(), Some(Decision::Surface { attempts: 1, .. })));
}

#[test]
fn alternating_classes_are_bounded_by_the_sum_of_every_budget() {
    let mut budget = ResumeBudget::new();
    let total: u32 = ResumeErrorClass::ALL.iter().map(|c| c.policy().attempts).sum();
    let mut acted = 0;
    for _ in 0..1000 {
        let mut any = false;
        for class in ResumeErrorClass::ALL {
            if let Decision::Act { .. } = budget.on_failure(class) {
                acted += 1;
                any = true;
            }
        }
        if !any {
            break;
        }
    }
    assert_eq!(acted, total);
}

#[test]
fn a_success_gives_every_class_its_budget_back() {
    let mut budget = ResumeBudget::new();
    let _ = budget.on_failure(ResumeErrorClass::Auth);
    assert!(matches!(budget.on_failure(ResumeErrorClass::Auth), Decision::Surface { .. }));
    budget.on_success();
    assert_eq!(budget.used(ResumeErrorClass::Auth), 0);
    assert!(matches!(
        budget.on_failure(ResumeErrorClass::Auth),
        Decision::Act { step: NextStep::RefreshCredential, attempt: 1, .. }
    ));
}

#[test]
fn every_class_has_a_bounded_budget_and_a_stable_name() {
    let mut names = std::collections::HashSet::new();
    for class in ResumeErrorClass::ALL {
        let policy = class.policy();
        assert!(policy.attempts >= 1 && policy.attempts <= 8, "{class}");
        assert!(policy.most_wait <= Duration::from_secs(10), "{class}");
        assert!(names.insert(class.as_str()));
    }
}
