//! The table, the exhaustive phase x event properties and a seeded random walk.

use std::path::PathBuf;
use std::time::Duration;

use super::*;

fn table_path() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../../schemas/mobile-link-reconnect/table.json")
}

fn rendered() -> String {
    let mut text = serde_json::to_string_pretty(&table()).expect("table renders");
    text.push('\n');
    text
}

/// The committed table is the one `step` answers. `CMUX_UPDATE_MOBILE_LINK_TABLE=1` rewrites it.
#[test]
fn committed_table_is_current() {
    let path = table_path();
    let now = rendered();
    if std::env::var("CMUX_UPDATE_MOBILE_LINK_TABLE").as_deref() == Ok("1") {
        std::fs::create_dir_all(path.parent().expect("parent")).expect("schemas dir");
        std::fs::write(&path, &now).expect("write table");
        return;
    }
    let committed = std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("{}: {e}; run with CMUX_UPDATE_MOBILE_LINK_TABLE=1", path.display()));
    assert!(
        committed == now,
        "{} is stale: rerun `CMUX_UPDATE_MOBILE_LINK_TABLE=1 cargo test -p cmux-mobile-link reconnect` and commit it",
        path.display()
    );
}

#[test]
fn the_table_holds_every_phase_against_every_event() {
    let table = table();
    let rows = table["transitions"].as_array().expect("transitions");
    assert_eq!(rows.len(), Phase::KINDS.len() * Event::KINDS.len());
    for (machine, kind) in sample_machines().iter().zip(Phase::KINDS) {
        assert_eq!(machine.phase().kind(), kind);
    }
    for (event, kind) in sample_events(Generation(1), Generation(1)).iter().zip(Event::KINDS) {
        assert_eq!(event.kind(), kind);
    }
    for row in rows {
        let refusal = row["refusal"].as_str();
        let to = row["to"].as_str();
        assert!(refusal.is_some() != to.is_some(), "{row}");
        if let Some(refusal) = refusal {
            assert!(Refusal::ALL.iter().any(|r| r.as_str() == refusal), "{row}");
        }
        for effect in row["effects"].as_array().map(Vec::as_slice).unwrap_or_default() {
            assert!(Effect::KINDS.contains(&effect.as_str().unwrap_or_default()), "{row}");
        }
        if row["from"] == "signed_out" {
            assert!(to.is_none() || to == Some("signed_out"), "signed_out left: {row}");
        }
    }
}

/// Every variation of the sample machines the step reads: background, standby kept or not,
/// target online, offline, another Mac or none; parking on or off, a link parked or not, a parked
/// session being resumed or not.
fn variants() -> Vec<Machine> {
    let mut out = Vec::new();
    let targets = [
        None,
        Some(Target { mac_id: "m1".to_owned(), name: "Studio".to_owned(), is_online: true }),
        Some(Target { mac_id: "m1".to_owned(), name: "Studio".to_owned(), is_online: false }),
    ];
    for base in sample_machines() {
        for target in &targets {
            for background in [false, true] {
                for standby in [None, Some(Generation(6))] {
                    for keeps in [true, false] {
                        for (parks, parked, resuming) in [
                            (false, None, None),
                            (true, None, None),
                            (true, Some(Generation(7)), None),
                            (true, None, Some(Generation(6))),
                        ] {
                            let mut m = base.clone();
                            m.target = target.clone();
                            m.is_backgrounded = background;
                            m.standby = standby;
                            m.keeps_standby = keeps;
                            m.parks = parks;
                            m.parked = parked;
                            m.resuming = resuming;
                            out.push(m);
                        }
                    }
                }
            }
        }
    }
    out
}

fn all_events(generation: Generation, standby: Generation) -> Vec<Event> {
    let mut events = sample_events(generation, standby).to_vec();
    let other = Target { mac_id: "m2".to_owned(), name: "Mini".to_owned(), is_online: true };
    events.push(Event::Target(None));
    events.push(Event::Target(Some(Target { is_online: false, ..other.clone() })));
    events.push(Event::Target(Some(other)));
    events.push(Event::Transport(TransportKind::WireGuard));
    events.push(Event::RelayOnly(false));
    events.push(Event::BlockUdp(false));
    events.push(Event::ResumeAfter { away: timings::PARK_LEASE - Duration::from_millis(1) });
    events.push(Event::ResumeAfter { away: timings::PARK_LEASE });
    events
}

/// Which slot an answer is for: the link, the standby beside a redial, or the parked session.
#[derive(Clone, Copy, PartialEq, Eq)]
enum Slot {
    Link,
    Standby,
    Parked,
}

/// Whether the event answers a dial, link or timer of a generation (or a standby's, or a parked
/// session's).
fn answer_generation(event: &Event) -> Option<(Generation, Slot)> {
    match event {
        Event::DialSucceeded { generation, .. }
        | Event::DialFailed { generation, .. }
        | Event::LinkUpdated { generation, .. }
        | Event::MediaUpdated { generation, .. }
        | Event::LinkDropped { generation, .. }
        | Event::RetryDue { generation }
        | Event::ProbeFailed { generation, .. }
        | Event::SignedOut { generation } => Some((*generation, Slot::Link)),
        Event::StandbyAlive { generation, .. } | Event::StandbyLost { generation } => {
            Some((*generation, Slot::Standby))
        }
        Event::ParkedResumed { generation, .. } | Event::ParkedLost { generation } => {
            Some((*generation, Slot::Parked))
        }
        Event::Target(_)
        | Event::Transport(_)
        | Event::RelayOnly(_)
        | Event::BlockUdp(_)
        | Event::Foreground
        | Event::Open
        | Event::Background
        | Event::Resume
        | Event::ResumeAfter { .. }
        | Event::MacSignaled
        | Event::NetworkChanged => None,
    }
}

/// Every phase variant against every event, at the current generation and at stale ones: no
/// panic, a refusal leaves the machine as it was, nothing leaves `signed_out`, a stale answer
/// never changes the phase or dials, and parked resume holds its own rules (below).
#[test]
fn every_phase_against_every_event_holds_the_invariants() {
    let mut steps = 0;
    for machine in variants() {
        for (generation, standby) in
            [(Generation(7), Generation(6)), (Generation(6), Generation(5)), (Generation(8), Generation(7))]
        {
            for event in all_events(generation, standby) {
                steps += 1;
                let result = step(&machine, &event);
                let mut in_place = machine.clone();
                let effects = in_place.handle(&event);
                match &result {
                    Ok((after, stepped)) => {
                        assert_eq!(after, &in_place);
                        assert_eq!(stepped, &effects);
                    }
                    Err(_) => {
                        assert_eq!(in_place, machine, "a refusal changed the machine: {event:?}");
                        assert!(effects.is_empty());
                    }
                }
                if machine.phase() == &Phase::SignedOut {
                    assert_eq!(in_place.phase(), &Phase::SignedOut, "{event:?} left signed_out");
                    assert!(effects.is_empty());
                }
                let stale = match answer_generation(&event) {
                    Some((g, Slot::Link)) => g != machine.generation(),
                    Some((g, Slot::Standby)) => Some(g) != machine.standby(),
                    Some((g, Slot::Parked)) => Some(g) != machine.resuming(),
                    None => false,
                };
                if stale {
                    assert!(result.is_err(), "stale {event:?} was taken by {machine:?}");
                    assert_eq!(in_place.phase(), machine.phase());
                    assert!(!effects.iter().any(|e| matches!(e, Effect::Dial { .. })));
                }
                for effect in &effects {
                    if let Effect::Dial { generation, .. } = effect {
                        assert_eq!(*generation, in_place.generation());
                    }
                }
                check_parked_rules(&machine, &event, &in_place, &effects);
            }
        }
    }
    assert!(steps > 10_000);
}

/// Parked resume's rules for one step from `before`: off, nothing parks and a timed resume is
/// exactly a plain one; a resume from the background that dials either closes first or resumes
/// a parked link, never neither and never both; only a parked link inside the lease resumes; a
/// parked answer never dials.
fn check_parked_rules(before: &Machine, event: &Event, after: &Machine, effects: &[Effect]) {
    let resumes = effects.iter().filter(|e| matches!(e, Effect::ResumeParked { .. })).count();
    let dials = effects.iter().filter(|e| matches!(e, Effect::Dial { .. })).count();
    let closes = effects.contains(&Effect::Close);
    assert!(dials <= 1 && resumes <= 1, "{event:?}: {effects:?}");
    if !before.parks {
        assert_eq!(resumes, 0, "parking is off: {event:?}");
        if before.parked.is_none() && before.resuming.is_none() {
            assert_eq!((after.parked, after.resuming), (None, None), "parking is off: {event:?}");
        }
        if let Event::ResumeAfter { .. } = event {
            assert_eq!(step(before, event), step(before, &Event::Resume), "off, a timed resume is a resume");
        }
    }
    if matches!(event, Event::Resume | Event::ResumeAfter { .. }) && before.is_backgrounded && dials == 1 {
        assert!(closes != (resumes == 1), "a resume dial must close or resume a parked link: {effects:?}");
    }
    if resumes == 1 {
        let Event::ResumeAfter { away } = event else { panic!("{event:?} resumed a parked link") };
        assert!(*away < timings::PARK_LEASE, "resumed past the lease: {away:?}");
        assert!(before.parks && before.parked == Some(before.generation()) && before.phase().is_connected());
        assert_eq!(dials, 1, "a parked resume races exactly one dial: {effects:?}");
        assert_eq!(after.resuming(), Some(before.generation()));
    }
    if matches!(event, Event::ParkedResumed { .. } | Event::ParkedLost { .. }) {
        assert_eq!(dials, 0, "a parked answer dialed: {effects:?}");
        assert!(!closes, "a parked answer closed the link: {effects:?}");
    }
}

/// xorshift64*: seeded, no dependency.
struct Rng(u64);

impl Rng {
    fn next(&mut self) -> u64 {
        self.0 ^= self.0 >> 12;
        self.0 ^= self.0 << 25;
        self.0 ^= self.0 >> 27;
        self.0.wrapping_mul(0x2545_f491_4f6c_dd1d)
    }
    fn below(&mut self, n: u64) -> u64 {
        self.next() % n
    }
}

fn random_event(rng: &mut Rng, m: &Machine) -> Event {
    let now = m.generation();
    let generation = match rng.below(10) {
        0 => Generation(now.0.saturating_sub(1)),
        1 => Generation(rng.below(now.0 + 1)),
        _ => now,
    };
    let standby = match (m.standby(), rng.below(4)) {
        (Some(kept), 0..=2) => kept,
        _ => Generation(rng.below(now.0 + 1)),
    };
    let parked = match (m.resuming(), rng.below(4)) {
        (Some(kept), 0..=2) => kept,
        _ => Generation(rng.below(now.0 + 1)),
    };
    let paths = [LinkPath::Direct, LinkPath::Turn, LinkPath::TurnTls, LinkPath::NoPath];
    let path = paths[rng.below(4) as usize];
    let reason = "x".to_owned();
    match rng.below(27) {
        0 => Event::Target(None),
        1 => Event::Target(Some(Target { mac_id: "m1".into(), name: "A".into(), is_online: false })),
        2 => Event::Target(Some(Target { mac_id: "m2".into(), name: "B".into(), is_online: true })),
        3 | 4 => Event::Target(Some(Target { mac_id: "m1".into(), name: "A".into(), is_online: true })),
        5 => {
            Event::Transport(if rng.below(2) == 0 { TransportKind::WebRtc } else { TransportKind::WireGuard })
        }
        6 => Event::RelayOnly(rng.below(2) == 0),
        7 => Event::BlockUdp(rng.below(2) == 0),
        8 | 9 => Event::DialSucceeded { generation, path },
        10..=12 => Event::DialFailed { generation, reason },
        13 => Event::LinkUpdated { generation, path, rtt_millis: Some(5) },
        14 => Event::MediaUpdated { generation, media: VideoMedia::Connecting },
        15 => Event::LinkDropped { generation, reason },
        16 => Event::RetryDue { generation },
        17 => Event::Foreground,
        18 => Event::Open,
        19 => {
            if rng.below(2) == 0 {
                Event::Background
            } else {
                Event::Resume
            }
        }
        20 => Event::ProbeFailed { generation, reason },
        21 => {
            if rng.below(2) == 0 {
                Event::MacSignaled
            } else {
                Event::NetworkChanged
            }
        }
        22 => {
            if rng.below(200) == 0 {
                Event::SignedOut { generation }
            } else {
                Event::StandbyLost { generation: standby }
            }
        }
        23 => Event::StandbyAlive { generation: standby, path, rtt_millis: None },
        24 => {
            // Around the lease's end, inside it most of the time.
            let away = timings::PARK_LEASE + Duration::from_secs(rng.below(120)) - Duration::from_secs(100);
            if rng.below(2) == 0 { Event::Background } else { Event::ResumeAfter { away } }
        }
        25 => Event::ParkedResumed { generation: parked, path, rtt_millis: None },
        _ => Event::ParkedLost { generation: parked },
    }
}

/// A long seeded walk (parking on for odd seeds): one dial at most per step and per generation,
/// dial generations strictly increasing, retry delays that follow the backoff table, grow within
/// a chain and start over after a success; a parked resume races one dial and its answers never
/// dial.
#[test]
fn a_seeded_random_walk_keeps_dials_and_backoff_in_order() {
    let mut total_parked_resumes = 0;
    for seed in 1..=64u64 {
        let mut rng = Rng(seed.wrapping_mul(0x9e37_79b9_7f4a_7c15) | 1);
        let mut m = Machine::new(TransportKind::WireGuard, false, false);
        m.parks = seed % 2 == 1;
        let mut parked_resumes = 0;
        let mut last_dial = Generation(0);
        let mut issued = Generation(0);
        let mut last_delay: Option<Duration> = None;
        let mut retries = 0;
        for _ in 0..5_000 {
            let event = random_event(&mut rng, &m);
            let before = m.clone();
            let effects = m.handle(&event);
            check_parked_rules(&before, &event, &m, &effects);
            let dials: Vec<_> = effects.iter().filter(|e| matches!(e, Effect::Dial { .. })).collect();
            assert!(dials.len() <= 1, "seed {seed}: {effects:?}");
            for effect in &effects {
                match effect {
                    Effect::Dial { generation, .. } => {
                        assert!(*generation > last_dial && *generation > issued, "seed {seed}: {effect:?}");
                        assert_eq!(*generation, m.generation());
                        last_dial = *generation;
                    }
                    Effect::ScheduleRetry { generation, after } => {
                        assert!(*generation > issued);
                        let Phase::Waiting { attempt, retry_in, .. } = m.phase() else {
                            panic!("seed {seed}: a retry outside waiting");
                        };
                        assert_eq!(after, retry_in);
                        let index = (*attempt as usize).saturating_sub(2).min(BACKOFF.len() - 1);
                        assert_eq!(*after, BACKOFF[index], "seed {seed}: attempt {attempt}");
                        match last_delay {
                            None => assert_eq!(*after, BACKOFF[0], "seed {seed}: a chain started past 1 s"),
                            Some(last) => assert!(*after >= last, "seed {seed}: backoff shrank"),
                        }
                        last_delay = Some(*after);
                        retries += 1;
                    }
                    Effect::PromoteStandby { generation } | Effect::PromoteParked { generation } => {
                        assert_eq!(*generation, m.generation());
                    }
                    Effect::ResumeParked { generation } => {
                        assert!(*generation < m.generation() && m.resuming() == Some(*generation));
                        parked_resumes += 1;
                    }
                    Effect::Close
                    | Effect::Probe { .. }
                    | Effect::QuickProbe { .. }
                    | Effect::KeepStandby
                    | Effect::CloseStandby
                    | Effect::CloseParked => {}
                }
            }
            issued = issued.max(m.generation());
            // A success, or a chain started over (a first dial), resets the backoff.
            if m.phase().is_connected() || matches!(m.phase(), Phase::Connecting { attempt: 1, .. }) {
                last_delay = None;
            }
            if m.phase() == &Phase::SignedOut {
                break;
            }
        }
        assert!(retries > 0 || m.phase() == &Phase::SignedOut, "seed {seed} never backed off");
        if !m.parks {
            assert_eq!(parked_resumes, 0, "seed {seed}: parked with parking off");
        }
        total_parked_resumes += parked_resumes;
    }
    assert!(total_parked_resumes > 0, "no walk resumed a parked link");
}
