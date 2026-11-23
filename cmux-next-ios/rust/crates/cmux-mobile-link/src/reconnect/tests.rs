//! The Swift `LinkMachine` tests, one Rust test each, same name in snake_case, same events and
//! expected effects (LiveTests.swift `LinkMachineTests`, LinkRecoveryTests.swift
//! `LinkResumeMachineTests`, LinkStatusPathTests.swift, ConnectivityMatrixTests.swift
//! `cellNetworkUDPBlocked`). Swift's `statusLine`/`diagnosticLine` checks are presentation that
//! stays in Swift; where a test reads one, the Rust test checks the phase or media it is drawn from.

use std::time::Duration;

use super::*;

const WG: TransportKind = TransportKind::WireGuard;
const RTC: TransportKind = TransportKind::WebRtc;

fn mac() -> Target {
    Target { mac_id: "m1".to_owned(), name: "Studio".to_owned(), is_online: true }
}

fn offline(target: Target) -> Target {
    Target { is_online: false, ..target }
}

fn named(id: &str, name: &str) -> Target {
    Target { mac_id: id.to_owned(), name: name.to_owned(), is_online: true }
}

fn g(n: u64) -> Generation {
    Generation(n)
}

fn dial(generation: u64, mac_id: &str, transport: TransportKind) -> Effect {
    Effect::Dial { generation: g(generation), mac_id: mac_id.to_owned(), transport }
}

fn target(t: Target) -> Event {
    Event::Target(Some(t))
}

fn succeeded(generation: u64, path: LinkPath) -> Event {
    Event::DialSucceeded { generation: g(generation), path }
}

fn failed(generation: u64, reason: &str) -> Event {
    Event::DialFailed { generation: g(generation), reason: reason.to_owned() }
}

fn dropped(generation: u64, reason: &str) -> Event {
    Event::LinkDropped { generation: g(generation), reason: reason.to_owned() }
}

fn probe_failed(generation: u64, reason: &str) -> Event {
    Event::ProbeFailed { generation: g(generation), reason: reason.to_owned() }
}

fn updated(generation: u64, path: LinkPath, rtt_millis: Option<u32>) -> Event {
    Event::LinkUpdated { generation: g(generation), path, rtt_millis }
}

fn standby_alive(generation: u64, path: LinkPath, rtt_millis: Option<u32>) -> Event {
    Event::StandbyAlive { generation: g(generation), path, rtt_millis }
}

fn connecting(transport: TransportKind, attempt: u32) -> Phase {
    Phase::Connecting { transport, attempt }
}

fn connected(transport: TransportKind, path: LinkPath, rtt_millis: Option<u32>) -> Phase {
    Phase::Connected { transport, path, rtt_millis }
}

fn machine(transport: TransportKind) -> Machine {
    Machine::new(transport, false, false)
}

// MARK: LiveTests.swift, LinkMachineTests

#[test]
fn dials_online_target_and_connects() {
    let mut m = machine(WG);
    assert_eq!(m.handle(&target(mac())), [dial(1, "m1", WG)]);
    assert_eq!(m.phase(), &connecting(WG, 1));
    assert_eq!(m.handle(&succeeded(1, LinkPath::TurnTls)), []);
    assert_eq!(m.phase(), &connected(WG, LinkPath::TurnTls, None));
    m.handle(&updated(1, LinkPath::TurnTls, Some(27)));
    assert!(m.phase().is_connected()); // statusLine == "Connected"
}

#[test]
fn offline_mac_is_not_dialed() {
    let mut m = machine(RTC);
    assert_eq!(m.handle(&target(offline(mac()))), []);
    assert_eq!(m.phase(), &Phase::MacOffline);
    // Presence brings it back: dial.
    assert_eq!(m.handle(&target(mac())), [dial(2, "m1", RTC)]);
}

#[test]
fn opening_a_surface_dials_a_mac_presence_calls_offline() {
    let mut m = machine(RTC);
    assert_eq!(m.handle(&target(offline(mac()))), []);
    assert_eq!(m.phase(), &Phase::MacOffline);
    assert_eq!(m.handle(&Event::Open), [dial(2, "m1", RTC)]);
    assert_eq!(m.phase(), &connecting(RTC, 1));
    // A repeated presence "offline" does not cancel the dial the surface asked for.
    assert_eq!(m.handle(&target(offline(mac()))), []);
    assert_eq!(m.phase(), &connecting(RTC, 1));
    // The dial really failed while presence says offline: offline, no retry loop.
    assert_eq!(m.handle(&failed(2, "offline")), []);
    assert_eq!(m.phase(), &Phase::MacOffline);
}

#[test]
fn opening_a_surface_on_a_live_link_does_nothing() {
    let mut m = machine(RTC);
    m.handle(&target(mac()));
    assert_eq!(m.handle(&Event::Open), []);
    assert_eq!(m.phase(), &connecting(RTC, 1));
}

#[test]
fn failures_back_off_and_retry() {
    let mut m = machine(RTC);
    m.handle(&target(mac()));
    // The first failure retries at once and shows nothing.
    assert_eq!(m.handle(&failed(1, "signaling reset")), [dial(2, "m1", RTC)]);
    assert_eq!(m.phase(), &connecting(RTC, 2));
    assert_eq!(
        m.handle(&failed(2, "ICE timed out")),
        [Effect::ScheduleRetry { generation: g(3), after: Duration::from_secs(1) }]
    );
    assert_eq!(
        m.phase(),
        &Phase::Waiting {
            transport: RTC,
            attempt: 2,
            reason: "ICE timed out".to_owned(),
            retry_in: Duration::from_secs(1)
        }
    );
    // statusLine == "Reconnecting…": a waiting phase whose reason is not "offline".
    assert_eq!(m.handle(&Event::RetryDue { generation: g(3) }), [dial(4, "m1", RTC)]);
    assert_eq!(
        m.handle(&failed(4, "x")),
        [Effect::ScheduleRetry { generation: g(5), after: Duration::from_secs(2) }]
    );
    // A stale timer is ignored.
    assert_eq!(m.handle(&Event::RetryDue { generation: g(3) }), []);
}

#[test]
fn transport_switch_redials_and_ignores_late_result() {
    let mut m = machine(RTC);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    assert_eq!(m.handle(&Event::Transport(WG)), [Effect::Close, dial(2, "m1", WG)]);
    // The old link's drop arrives late: ignored.
    assert_eq!(m.handle(&dropped(1, "closed")), []);
    assert_eq!(m.phase(), &connecting(WG, 1));
    // Switching while waiting redials immediately with the new transport.
    m.handle(&failed(2, "x"));
    m.handle(&failed(3, "x"));
    assert_eq!(m.handle(&Event::Transport(RTC)), [Effect::Close, dial(5, "m1", RTC)]);
}

#[test]
fn relay_only_change_redials() {
    let mut m = machine(RTC);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    assert_eq!(m.handle(&Event::RelayOnly(false)), []);
    assert_eq!(m.handle(&Event::RelayOnly(true)), [Effect::Close, dial(2, "m1", RTC)]);
    assert!(m.relay_only());
    assert_eq!(m.handle(&succeeded(2, LinkPath::Turn)), []);
    assert!(m.phase().is_connected()); // statusLine == "Connected"
}

#[test]
fn block_udp_change_redials() {
    let mut m = machine(WG);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    assert_eq!(m.handle(&Event::BlockUdp(false)), []);
    assert_eq!(m.handle(&Event::BlockUdp(true)), [Effect::Close, dial(2, "m1", WG)]);
    assert!(m.block_udp());
    assert_eq!(m.handle(&succeeded(2, LinkPath::TurnTls)), []);
    assert!(m.phase().is_connected()); // statusLine == "Connected"
    // WebRTC ignores it: a change there does not redial.
    let mut web_rtc = machine(RTC);
    web_rtc.handle(&target(mac()));
    web_rtc.handle(&succeeded(1, LinkPath::Direct));
    assert_eq!(web_rtc.handle(&Event::BlockUdp(true)), []);
    assert!(web_rtc.block_udp());
}

#[test]
fn drop_reconnects_and_foreground_probes() {
    let mut m = machine(WG);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Turn));
    assert_eq!(m.handle(&Event::Foreground), [Effect::Probe { generation: g(1) }]);
    // A silent link redials at once, and is kept beside the redial.
    assert_eq!(m.handle(&probe_failed(1, "closed")), [Effect::KeepStandby, dial(2, "m1", WG)]);
    m.handle(&failed(2, "x"));
    m.handle(&failed(3, "x"));
    // Foreground while waiting dials now instead of waiting out the timer.
    assert_eq!(m.handle(&Event::Foreground), [dial(5, "m1", WG)]);
}

#[test]
fn presence_offline_keeps_a_connected_link_and_probes_it() {
    let mut m = machine(RTC);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    assert_eq!(m.handle(&target(offline(mac()))), [Effect::QuickProbe { generation: g(1) }]);
    assert_eq!(m.phase(), &connected(RTC, LinkPath::Direct, None));
    // Back online with the link still up: nothing to do (no second link).
    assert_eq!(m.handle(&target(mac())), []);
    assert!(m.phase().is_connected());
    assert_eq!(m.handle(&updated(1, LinkPath::Direct, Some(3))), []);
    assert_eq!(m.phase(), &connected(RTC, LinkPath::Direct, Some(3)));
}

#[test]
fn mac_signaling_back_probes_the_link_and_redials_when_it_is_dead() {
    let mut m = machine(RTC);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    assert_eq!(m.handle(&Event::MacSignaled), [Effect::QuickProbe { generation: g(1) }]);
    assert_eq!(m.handle(&probe_failed(1, "timeout")), [Effect::KeepStandby, dial(2, "m1", RTC)]);
    // A dial in flight when the host's socket connects again is restarted.
    assert_eq!(m.handle(&Event::MacSignaled), [dial(3, "m1", RTC)]);
}

#[test]
fn network_change_restarts_a_dial_in_flight_and_ends_the_backoff() {
    let mut m = machine(WG);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    assert_eq!(m.handle(&Event::NetworkChanged), [], "a live link roams in place");
    assert_eq!(m.handle(&dropped(1, "network lost")), [Effect::Close, dial(2, "m1", WG)]);
    // The redial is on the dead path; the network comes back.
    assert_eq!(m.handle(&Event::NetworkChanged), [dial(3, "m1", WG)]);
    assert_eq!(m.phase(), &connecting(WG, 1));
    // The old dial's late failure is ignored.
    assert_eq!(m.handle(&failed(2, "timeout")), []);
    m.handle(&failed(3, "x"));
    m.handle(&failed(4, "x"));
    let Phase::Waiting { attempt, .. } = *m.phase() else { panic!("expected waiting, got {:?}", m.phase()) };
    assert_eq!(m.handle(&Event::NetworkChanged), [dial(6, "m1", WG)]);
    assert_eq!(m.phase(), &connecting(WG, attempt + 1));
}

#[test]
fn probe_failure_keeps_the_link_beside_the_redial() {
    let mut m = machine(WG);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    assert_eq!(m.handle(&probe_failed(1, "timeout")), [Effect::KeepStandby, dial(2, "m1", WG)]);
    assert_eq!(m.standby(), Some(g(1)));
    assert_eq!(m.phase(), &connecting(WG, 1));
    // The redial on the dark path fails; the silent retry goes out.
    assert_eq!(m.handle(&failed(2, "timeout")), [dial(3, "m1", WG)]);
    // The old link answers first: it is the link again, the redial is dropped.
    assert_eq!(
        m.handle(&standby_alive(1, LinkPath::Direct, Some(40))),
        [Effect::PromoteStandby { generation: g(4) }]
    );
    assert_eq!(m.phase(), &connected(WG, LinkPath::Direct, Some(40)));
    assert_eq!(m.standby(), None);
    assert_eq!(m.handle(&succeeded(3, LinkPath::Direct)), [], "the dropped redial's late success is ignored");
    assert_eq!(m.handle(&standby_alive(1, LinkPath::Direct, Some(40))), []);
    // Silent again; this time the redial lands first and the old link closes.
    assert_eq!(m.handle(&probe_failed(4, "timeout")), [Effect::KeepStandby, dial(5, "m1", WG)]);
    assert_eq!(m.handle(&succeeded(5, LinkPath::Turn)), [Effect::CloseStandby]);
    assert_eq!(m.standby(), None);
    assert_eq!(m.handle(&standby_alive(4, LinkPath::Direct, Some(40))), []);
    // A standby that closes or stays silent is dropped; the redial goes on.
    m.handle(&probe_failed(5, "timeout"));
    assert_eq!(m.handle(&Event::StandbyLost { generation: g(5) }), [Effect::CloseStandby]);
    assert_eq!(m.phase(), &connecting(WG, 1));
    // A link that closed itself is not kept; neither is one in the background.
    m.handle(&succeeded(6, LinkPath::Direct));
    assert_eq!(m.handle(&dropped(6, "closed")), [Effect::Close, dial(7, "m1", WG)]);
    m.handle(&succeeded(7, LinkPath::Direct));
    m.handle(&Event::Background);
    assert_eq!(m.handle(&probe_failed(7, "timeout")), [Effect::Close, dial(8, "m1", WG)]);
    assert_eq!(m.standby(), None);
}

#[test]
fn a_retarget_drops_the_standby() {
    let mut m = machine(WG);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    m.handle(&probe_failed(1, "timeout"));
    assert_eq!(m.handle(&Event::Target(None)), [Effect::Close]);
    assert_eq!(m.standby(), None);
    assert_eq!(m.handle(&standby_alive(1, LinkPath::Direct, Some(1))), []);
}

#[test]
fn a_dead_link_to_an_offline_mac_waits_for_presence() {
    let mut m = machine(RTC);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    m.handle(&target(offline(mac())));
    assert_eq!(m.handle(&probe_failed(1, "timeout")), [Effect::Close]);
    assert_eq!(m.phase(), &Phase::MacOffline);
    assert_eq!(m.handle(&target(mac())), [dial(3, "m1", RTC)]);
}

#[test]
fn mac_back_online_ends_the_backoff() {
    let mut m = machine(RTC);
    m.handle(&target(mac()));
    m.handle(&failed(1, "x"));
    m.handle(&failed(2, "x"));
    assert!(matches!(m.phase(), Phase::Waiting { .. }), "expected waiting");
    assert_eq!(m.handle(&Event::MacSignaled), [dial(4, "m1", RTC)]);
}

#[test]
fn mac_signaling_back_restarts_a_dial_in_flight() {
    let mut m = machine(RTC);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    m.handle(&dropped(1, "keepalive timed out"));
    assert!(matches!(m.phase(), Phase::Connecting { attempt: 1, .. }), "expected a redial");
    assert_eq!(m.handle(&Event::MacSignaled), [dial(3, "m1", RTC)]);
    // The abandoned dial's late failure changes nothing.
    assert_eq!(m.handle(&failed(2, "answer timeout")), []);
    assert!(matches!(m.phase(), Phase::Connecting { .. }), "expected connecting");
}

#[test]
fn a_revoked_session_stops_redialing_and_says_signed_out() {
    let mut m = machine(RTC);
    m.handle(&target(mac()));
    // The dial that was refused is still connecting: it is closed.
    assert_eq!(m.handle(&Event::SignedOut { generation: g(1) }), [Effect::Close]);
    assert_eq!(m.phase(), &Phase::SignedOut); // statusLine == "Signed out"
    for event in [
        Event::RetryDue { generation: g(2) },
        Event::Foreground,
        Event::Resume,
        Event::MacSignaled,
        Event::NetworkChanged,
        target(mac()),
        Event::Transport(WG),
        failed(2, "x"),
    ] {
        assert_eq!(m.handle(&event), [], "{event:?} dialed a signed-out session");
    }
    assert_eq!(m.phase(), &Phase::SignedOut);
    // An idle link closed and opened again: still signed out, and nothing dials.
    assert_eq!(m.handle(&Event::Target(None)), []);
    assert_eq!(m.phase(), &Phase::SignedOut);
    assert_eq!(m.handle(&target(mac())), []);
    assert_eq!(m.handle(&Event::RetryDue { generation: m.generation() }), []);
    assert_eq!(m.phase(), &Phase::SignedOut);
    assert_eq!(m.target(), Some(&mac()));
    // A late result for an older dial changes nothing.
    let mut other = machine(RTC);
    other.handle(&target(mac()));
    other.handle(&Event::Transport(WG));
    assert_eq!(other.handle(&Event::SignedOut { generation: g(1) }), []);
    assert!(matches!(other.phase(), Phase::Connecting { .. }), "a stale revoke ended a live dial");
}

#[test]
fn same_target_keeps_link_and_nil_target_closes() {
    let mut m = machine(WG);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Turn));
    assert_eq!(m.handle(&target(mac())), []);
    assert_eq!(m.handle(&Event::Target(None)), [Effect::Close]);
    assert_eq!(m.phase(), &Phase::Idle);
}

// MARK: LinkRecoveryTests.swift, LinkResumeMachineTests

#[test]
fn background_dial_is_replaced_and_late_results_ignored() {
    let mut m = machine(WG);
    m.handle(&target(named("m", "Mac")));
    m.handle(&Event::Background);
    assert_eq!(m.handle(&Event::Resume), [Effect::Close, dial(2, "m", WG)]);
    assert_eq!(m.handle(&succeeded(1, LinkPath::Direct)), []);
    assert_eq!(m.phase(), &connecting(WG, 1));
}

#[test]
fn inactive_foreground_only_probes_and_idle_resume_does_not_dial() {
    let mut m = machine(WG);
    m.handle(&Event::Background);
    assert!(m.handle(&Event::Resume).is_empty());
    m.handle(&target(named("m", "Mac")));
    m.handle(&succeeded(m.generation().0, LinkPath::Direct));
    assert_eq!(m.handle(&Event::Resume), [Effect::Probe { generation: m.generation() }]);
}

// MARK: LinkStatusPathTests.swift

/// The label is drawn from the path the link reports, never the Relay only setting.
#[test]
fn the_label_shows_the_path_in_use_not_the_relay_only_setting() {
    let mut m = Machine::new(WG, true, false);
    m.handle(&target(named("m", "Studio")));
    m.handle(&succeeded(m.generation().0, LinkPath::Direct));
    assert_eq!(m.phase(), &connected(WG, LinkPath::Direct, None));
    m.handle(&updated(m.generation().0, LinkPath::Turn, Some(40)));
    assert_eq!(m.phase(), &connected(WG, LinkPath::Turn, Some(40)));
    m.handle(&updated(m.generation().0, LinkPath::TurnTls, None));
    assert_eq!(m.phase(), &connected(WG, LinkPath::TurnTls, Some(40)));
    m.handle(&updated(m.generation().0, LinkPath::NoPath, None));
    assert_eq!(m.phase(), &connected(WG, LinkPath::NoPath, Some(40)));
}

#[test]
fn the_line_shows_the_media_session_beside_the_link() {
    let mut m = machine(WG);
    m.handle(&target(named("m", "Studio")));
    m.handle(&succeeded(m.generation().0, LinkPath::Direct));
    m.handle(&updated(m.generation().0, LinkPath::Direct, Some(14)));
    assert_eq!(m.phase(), &connected(WG, LinkPath::Direct, Some(14)));
    assert_eq!(m.media(), &VideoMedia::Off);
    for media in [
        VideoMedia::Up { path: LinkPath::Turn, rtt_millis: Some(16) },
        VideoMedia::Up { path: LinkPath::Direct, rtt_millis: Some(9) },
        // The session failed: video rides the tunnel.
        VideoMedia::Failed { reason: "ICE failed".to_owned() },
    ] {
        m.handle(&Event::MediaUpdated { generation: m.generation(), media: media.clone() });
        assert_eq!(m.media(), &media);
    }
}

#[test]
fn a_stale_links_media_is_ignored_and_a_redial_forgets_it() {
    let mut m = machine(WG);
    m.handle(&target(named("m", "Studio")));
    let first = m.generation();
    m.handle(&Event::DialSucceeded { generation: first, path: LinkPath::Direct });
    let up = VideoMedia::Up { path: LinkPath::Direct, rtt_millis: None };
    m.handle(&Event::MediaUpdated { generation: first, media: up.clone() });
    assert_eq!(m.media(), &up);
    m.handle(&Event::LinkDropped { generation: first, reason: "gone".to_owned() });
    assert_eq!(m.media(), &VideoMedia::Off);
    m.handle(&Event::MediaUpdated {
        generation: first,
        media: VideoMedia::Up { path: LinkPath::Turn, rtt_millis: None },
    });
    assert_eq!(m.media(), &VideoMedia::Off);
}

#[test]
fn a_dropped_link_whose_redials_fail_waits() {
    let mut m = machine(WG);
    m.handle(&target(named("m", "Studio")));
    m.handle(&succeeded(m.generation().0, LinkPath::Turn));
    m.handle(&dropped(m.generation().0, "keepalive timed out"));
    m.handle(&failed(m.generation().0, "timed out"));
    m.handle(&failed(m.generation().0, "timed out"));
    assert!(
        matches!(m.phase(), Phase::Waiting { transport: WG, attempt: 2, .. }),
        "expected waiting, got {:?}",
        m.phase()
    );
}

// MARK: ConnectivityMatrixTests.swift

#[test]
fn cell_network_udp_blocked() {
    let mut m = machine(WG);
    m.handle(&target(mac()));
    m.handle(&succeeded(1, LinkPath::Direct));
    assert_eq!(m.handle(&Event::BlockUdp(true)), [Effect::Close, dial(2, "m1", WG)]);
    m.handle(&succeeded(2, LinkPath::TurnTls));
    assert_eq!(m.phase(), &connected(WG, LinkPath::TurnTls, None));
}
