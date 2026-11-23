//! The whole step table as data (`schemas/mobile-link-reconnect/table.json`).

use std::time::Duration;

use serde_json::{Value, json};

use super::{Effect, Event, Generation, Machine, Phase, Refusal, Target, VideoMedia, step};
use crate::dial::{LinkPath, TransportKind};

/// The generation the sample machines are at and their sample answers carry.
const SAMPLE: Generation = Generation(7);
/// The standby the sample `connecting` and `waiting` machines keep.
const SAMPLE_STANDBY: Generation = Generation(6);

fn sample_target() -> Target {
    Target { mac_id: "m1".to_owned(), name: "Studio".to_owned(), is_online: true }
}

/// One machine per phase, in [`Phase::KINDS`] order: WireGuard, at [`SAMPLE`], foreground,
/// targeting an online Mac (none when idle). The `connecting` and `waiting` ones keep a standby
/// ([`SAMPLE_STANDBY`]), the only phases a standby outlives a step in besides `mac_offline`.
pub fn sample_machines() -> [Machine; 6] {
    let transport = TransportKind::WireGuard;
    [
        (Phase::Idle, None),
        (Phase::MacOffline, None),
        (Phase::Connecting { transport, attempt: 1 }, Some(SAMPLE_STANDBY)),
        (Phase::Connected { transport, path: LinkPath::Direct, rtt_millis: Some(20) }, None),
        (
            Phase::Waiting {
                transport,
                attempt: 2,
                reason: "timeout".to_owned(),
                retry_in: Duration::from_secs(1),
            },
            Some(SAMPLE_STANDBY),
        ),
        (Phase::SignedOut, None),
    ]
    .map(|(phase, standby)| {
        let target = if phase == Phase::Idle { None } else { Some(sample_target()) };
        Machine { phase, target, generation: SAMPLE, standby, ..Machine::new(transport, false, false) }
    })
}

/// One event per kind, in [`Event::KINDS`] order. Answers carry `generation`, standby answers
/// `standby`; settings flip away from [`sample_machines`]'; the target is the same online Mac.
pub fn sample_events(generation: Generation, standby: Generation) -> [Event; 20] {
    let reason = || "timeout".to_owned();
    [
        Event::Target(Some(sample_target())),
        Event::Transport(TransportKind::WebRtc),
        Event::RelayOnly(true),
        Event::BlockUdp(true),
        Event::DialSucceeded { generation, path: LinkPath::Direct },
        Event::DialFailed { generation, reason: reason() },
        Event::LinkUpdated { generation, path: LinkPath::Turn, rtt_millis: Some(30) },
        Event::MediaUpdated { generation, media: VideoMedia::Up { path: LinkPath::Turn, rtt_millis: None } },
        Event::LinkDropped { generation, reason: reason() },
        Event::RetryDue { generation },
        Event::Foreground,
        Event::Open,
        Event::Background,
        Event::Resume,
        Event::ProbeFailed { generation, reason: reason() },
        Event::MacSignaled,
        Event::NetworkChanged,
        Event::SignedOut { generation },
        Event::StandbyAlive { generation: standby, path: LinkPath::Direct, rtt_millis: Some(40) },
        Event::StandbyLost { generation: standby },
    ]
}

/// Every phase against every event: the phase it moves to and its effects' kinds, or a named
/// refusal. Rows use [`sample_machines`] and [`sample_events`]`(SAMPLE, SAMPLE_STANDBY)`.
pub fn table() -> Value {
    let mut rows = Vec::new();
    for machine in sample_machines() {
        for event in sample_events(SAMPLE, SAMPLE_STANDBY) {
            let from = machine.phase.kind();
            rows.push(match step(&machine, &event) {
                Ok((after, effects)) => json!({
                    "from": from,
                    "event": event.kind(),
                    "to": after.phase.kind(),
                    "effects": effects.iter().map(Effect::kind).collect::<Vec<_>>(),
                }),
                Err(refusal) => json!({ "from": from, "event": event.kind(), "refusal": refusal.as_str() }),
            });
        }
    }
    json!({
        "version": 1,
        "source": "cmux-next-ios/rust/crates/cmux-mobile-link/src/reconnect/mod.rs",
        "port_of": "cmux-next-ios/CmuxMobileKit/Sources/CmuxMobileLive/LinkMachine.swift",
        "samples": "Each phase's machine is WireGuard, foreground, at generation 7, targeting an online Mac (none when idle); connecting and waiting keep a standby at generation 6. Answers carry 7, standby answers 6; the target event names the same online Mac; transport, relay_only and block_udp flip their setting.",
        "stale": "An answer (dial_*, link_*, media_updated, retry_due, probe_failed, signed_out) whose generation is not the current one is refused stale_generation; a standby answer whose generation is not the kept standby's is refused stale_generation, or no_standby when none is kept; signed_out refuses every event but target, which it records. A refusal leaves the machine unchanged.",
        "generations": "Every dial, wait, reset and standby promotion bumps the generation (current + 1); every dial and timer is issued under the new one.",
        "backoff_seconds": super::BACKOFF.map(|d| d.as_secs()),
        "silent_retries": super::SILENT_RETRIES,
        "phases": Phase::KINDS,
        "events": Event::KINDS,
        "effects": Effect::KINDS,
        "refusals": Refusal::ALL.map(Refusal::as_str),
        "transitions": rows,
    })
}
