//! Parked resume (RFD 0049, the warm link): off by default, the lease boundary, the race between
//! the parked session and the dial beside it, and a background in the middle of it. No Swift
//! test to mirror yet: Swift still closes and redials on every resume.

use std::time::Duration;

use super::timings::PARK_LEASE;
use super::*;

const WG: TransportKind = TransportKind::WireGuard;

fn mac() -> Target {
    Target { mac_id: "m1".to_owned(), name: "Studio".to_owned(), is_online: true }
}

fn g(n: u64) -> Generation {
    Generation(n)
}

fn dial(generation: u64) -> Effect {
    Effect::Dial { generation: g(generation), mac_id: "m1".to_owned(), transport: WG }
}

fn after(away: Duration) -> Event {
    Event::ResumeAfter { away }
}

fn resumed(generation: u64) -> Event {
    Event::ParkedResumed { generation: g(generation), path: LinkPath::Direct, rtt_millis: Some(12) }
}

fn lost(generation: u64) -> Event {
    Event::ParkedLost { generation: g(generation) }
}

/// A machine connected under generation 1, parking as `parks` says.
fn connected(parks: bool) -> Machine {
    let mut m = Machine::new(WG, false, false);
    m.parks = parks;
    m.handle(&Event::Target(Some(mac())));
    m.handle(&Event::DialSucceeded { generation: g(1), path: LinkPath::Direct });
    m
}

/// Connected, backgrounded and resumed a minute later with parking on: the race is running.
fn racing() -> Machine {
    let mut m = connected(true);
    m.handle(&Event::Background);
    assert_eq!(
        m.handle(&after(Duration::from_secs(60))),
        [Effect::ResumeParked { generation: g(1) }, dial(2)]
    );
    m
}

#[test]
fn parking_off_resumes_exactly_as_today() {
    for away in [Duration::ZERO, Duration::from_secs(60), PARK_LEASE, PARK_LEASE * 2] {
        let mut timed = connected(false);
        let mut plain = connected(false);
        timed.handle(&Event::Background);
        plain.handle(&Event::Background);
        assert_eq!(timed.parked(), None, "nothing parks with parking off");
        assert_eq!(timed.handle(&after(away)), [Effect::Close, dial(2)]);
        assert_eq!(plain.handle(&Event::Resume), [Effect::Close, dial(2)]);
        assert_eq!(timed, plain);
    }
}

#[test]
fn the_lease_boundary() {
    let inside = PARK_LEASE - Duration::from_millis(1);
    for (away, resumes) in
        [(inside, true), (PARK_LEASE, false), (PARK_LEASE + Duration::from_millis(1), false)]
    {
        let mut m = connected(true);
        m.handle(&Event::Background);
        assert_eq!(m.parked(), Some(g(1)));
        let effects = m.handle(&after(away));
        if resumes {
            assert_eq!(effects, [Effect::ResumeParked { generation: g(1) }, dial(2)], "{away:?}");
            assert_eq!(m.resuming(), Some(g(1)));
        } else {
            assert_eq!(effects, [Effect::Close, dial(2)], "{away:?}");
            assert_eq!(m.resuming(), None);
        }
        assert_eq!(m.parked(), None, "a resume spends the parked link");
        assert_eq!(m.phase(), &Phase::Connecting { transport: WG, attempt: 1 });
    }
}

#[test]
fn a_plain_resume_or_no_live_link_closes_and_dials() {
    // The runner does not know how long the app was away: today's close and dial.
    let mut m = connected(true);
    m.handle(&Event::Background);
    assert_eq!(m.handle(&Event::Resume), [Effect::Close, dial(2)]);
    // A dial in flight at the background is not parked.
    let mut m = Machine::new(WG, false, false);
    m.parks = true;
    m.handle(&Event::Target(Some(mac())));
    m.handle(&Event::Background);
    assert_eq!(m.parked(), None);
    assert_eq!(m.handle(&after(Duration::from_secs(5))), [Effect::Close, dial(2)]);
    // The parked link dropped and was redialed in the background: what is live is not parked.
    let mut m = connected(true);
    m.handle(&Event::Background);
    m.handle(&Event::LinkDropped { generation: g(1), reason: "gone".to_owned() });
    m.handle(&Event::DialSucceeded { generation: g(2), path: LinkPath::Turn });
    assert_eq!(m.handle(&after(Duration::from_secs(5))), [Effect::Close, dial(3)]);
}

#[test]
fn the_parked_session_wins_the_race() {
    let mut m = racing();
    assert_eq!(m.handle(&resumed(1)), [Effect::PromoteParked { generation: g(3) }]);
    assert_eq!(m.phase(), &Phase::Connected { transport: WG, path: LinkPath::Direct, rtt_millis: Some(12) });
    assert_eq!(m.resuming(), None);
    // The abandoned dial's late answers are stale.
    assert_eq!(
        step(&m, &Event::DialSucceeded { generation: g(2), path: LinkPath::Turn }),
        Err(Refusal::StaleGeneration)
    );
    assert_eq!(step(&m, &resumed(1)), Err(Refusal::NotResuming));
}

#[test]
fn the_dial_wins_the_race() {
    let mut m = racing();
    assert_eq!(
        m.handle(&Event::DialSucceeded { generation: g(2), path: LinkPath::Turn }),
        [Effect::CloseParked]
    );
    assert_eq!(m.phase(), &Phase::Connected { transport: WG, path: LinkPath::Turn, rtt_millis: None });
    assert_eq!(step(&m, &resumed(1)), Err(Refusal::NotResuming));
}

#[test]
fn a_failed_resume_falls_through_to_the_one_dial_racing_it() {
    let mut m = racing();
    assert_eq!(m.handle(&lost(1)), [Effect::CloseParked], "no second dial, no close");
    assert_eq!(m.phase(), &Phase::Connecting { transport: WG, attempt: 1 });
    // The racing dial goes on along the usual ladder: one silent retry, then the backoff.
    assert_eq!(m.handle(&Event::DialFailed { generation: g(2), reason: "x".to_owned() }), [dial(3)]);
    assert_eq!(
        m.handle(&Event::DialFailed { generation: g(3), reason: "x".to_owned() }),
        [Effect::ScheduleRetry { generation: g(4), after: Duration::from_secs(1) }]
    );
    assert_eq!(step(&m, &lost(1)), Err(Refusal::NotResuming));
}

#[test]
fn the_parked_session_outlives_the_dials_retries() {
    let mut m = racing();
    m.handle(&Event::DialFailed { generation: g(2), reason: "x".to_owned() });
    m.handle(&Event::DialFailed { generation: g(3), reason: "x".to_owned() });
    assert!(matches!(m.phase(), Phase::Waiting { .. }));
    assert_eq!(m.resuming(), Some(g(1)));
    assert_eq!(m.handle(&resumed(1)), [Effect::PromoteParked { generation: g(5) }]);
    assert!(m.phase().is_connected());
}

#[test]
fn a_second_background_during_a_parked_resume() {
    // Back before either side answers: the race is closed and dialed afresh, as today.
    let mut m = racing();
    assert_eq!(m.handle(&Event::Background), []);
    assert_eq!(m.parked(), None, "a dial in flight is not parked");
    assert_eq!(m.handle(&after(Duration::from_secs(1))), [Effect::Close, dial(3)]);
    assert_eq!(m.resuming(), None);
    assert_eq!(step(&m, &resumed(1)), Err(Refusal::NotResuming));
    // The parked session answers while the app is away again: it is the link, not parked, so
    // the next resume closes and dials.
    let mut m = racing();
    m.handle(&Event::Background);
    assert_eq!(m.handle(&resumed(1)), [Effect::PromoteParked { generation: g(3) }]);
    assert_eq!(m.handle(&after(Duration::from_secs(1))), [Effect::Close, dial(4)]);
}

#[test]
fn a_retarget_during_a_parked_resume_closes_it() {
    let mut m = racing();
    assert_eq!(m.handle(&Event::Target(None)), [Effect::Close]);
    assert_eq!(m.resuming(), None);
    assert_eq!(step(&m, &lost(1)), Err(Refusal::NotResuming));
}
