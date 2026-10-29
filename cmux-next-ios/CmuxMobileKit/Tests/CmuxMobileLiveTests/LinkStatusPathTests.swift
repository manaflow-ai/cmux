import CmuxMobileDesign
import CmuxMobileTransport
import Foundation
import Testing
@testable import CmuxMobileLive

/// VERIFY-round8 Claim 10 (transport switch): the phone said `WireGuard TURN`
/// while the rig's hostd logged `kind=WireGuard path=Direct` with Relay only on.
/// The label is the path the link reports, never the Relay only setting: a
/// relay-only WireGuard link that reports a direct path reads "direct". (The
/// disagreement was hostd's label: the Mac sends plain UDP to a relay-only
/// phone's TURN relayed address and called that Direct; cmux-mobile-link `0b6e4f61`
/// and `e8d42d40` label it TURN on the Mac too. The rig's hostd, from
/// `604fc689`, predates them.)
@Suite struct LinkStatusPathTests {
    @Test func theLabelShowsThePathInUseNotTheRelayOnlySetting() {
        var machine = LinkMachine(transport: .wireGuard, relayOnly: true)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m", name: "Studio", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected")
        _ = machine.handle(.linkUpdated(generation: machine.generation, path: .turn, rttMillis: 40))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected")
        // UDP blocked: TURN reached over TLS. (There is no WebSocket relay any more.)
        _ = machine.handle(.linkUpdated(generation: machine.generation, path: .turnTLS, rttMillis: nil))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected")
        _ = machine.handle(.linkUpdated(generation: machine.generation, path: .noPath, rttMillis: nil))
        #expect(machine.phase.statusLine(macName: "Studio") == "Connected")
    }
}

/// verify/hybrid-link.md: the status line shows the WireGuard link's path and
/// the WebRTC media session beside it ("WireGuard direct · video WebRTC (TURN)").
@Suite struct LinkStatusMediaTests {
    @Test func theLineShowsTheMediaSessionBesideTheLink() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m", name: "Studio", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .direct))
        _ = machine.handle(.linkUpdated(generation: machine.generation, path: .direct, rttMillis: 14))
        #expect(machine.phase.statusLine(macName: "Studio", media: machine.media) == "Connected")
        _ = machine.handle(.mediaUpdated(generation: machine.generation, .up(.turn, rttMillis: 16)))
        #expect(machine.phase.statusLine(macName: "Studio", media: machine.media)
            == "Connected")
        _ = machine.handle(.mediaUpdated(generation: machine.generation, .up(.direct, rttMillis: 9)))
        #expect(machine.phase.statusLine(macName: "Studio", media: machine.media)
            == "Connected")
        // The session failed: video rides the tunnel.
        _ = machine.handle(.mediaUpdated(generation: machine.generation, .failed(reason: "ICE failed")))
        #expect(machine.phase.statusLine(macName: "Studio", media: machine.media)
            == "Connected")
    }

    @Test func aStaleLinksMediaIsIgnoredAndARedialForgetsIt() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m", name: "Studio", isOnline: true)))
        let first = machine.generation
        _ = machine.handle(.dialSucceeded(generation: first, path: .direct))
        _ = machine.handle(.mediaUpdated(generation: first, .up(.direct, rttMillis: nil)))
        #expect(machine.media == .up(.direct, rttMillis: nil))
        _ = machine.handle(.linkDropped(generation: first, reason: "gone"))
        #expect(machine.media == .off)
        _ = machine.handle(.mediaUpdated(generation: first, .up(.turn, rttMillis: nil)))
        #expect(machine.media == .off)
    }
}

// LiveCoordinator and ConnectionBannerState are iOS only; the job's iOS simulator
// test step runs these.
#if os(iOS)
/// A WireGuard link that was up dropped (its tunnel stopped passing
/// handshakes), the first redial failed, and the machine waits out its
/// backoff before the next one. The phone showed "Can't reach … over
/// WireGuard" for every such wait, which reads as giving up while it was
/// still retrying. A Mac the link was connected to says "Reconnecting".
@Suite struct WaitingBannerTests {
    let offline = LinkController.reason(LinkError(code: "offline", message: ""))
    let timedOut = LinkController.reason(LinkError(code: "timeout", message: ""))

    @Test func aMacTheLinkWasConnectedToIsReconnecting() {
        let banner = LiveCoordinator.waitingBanner(
            macName: "Studio", transport: .wireGuard, reason: timedOut, attempt: 2, wasConnected: true,
            relayAvailable: true)
        #expect(banner == .reconnecting(to: "Studio"))
    }

    /// Still unreachable after the first redials (about half a minute): say
    /// why, with the relay hint, instead of spinning forever.
    @Test func aMacStillUnreachableAfterTheFirstRedialsIsAFailure() {
        let late = LiveCoordinator.reconnectingAttempts + 1
        let banner = LiveCoordinator.waitingBanner(
            macName: "Studio", transport: .wireGuard, reason: timedOut, attempt: late, wasConnected: true,
            relayAvailable: false)
        #expect(banner == .failed("Offline · Retry"))
    }

    @Test func aMacNeverReachedIsAFailure() {
        let banner = LiveCoordinator.waitingBanner(
            macName: "Studio", transport: .wireGuard, reason: timedOut, attempt: 2, wasConnected: false,
            relayAvailable: true)
        #expect(banner == .failed("Offline · Retry"))
        let noRelay = LiveCoordinator.waitingBanner(
            macName: "Studio", transport: .webRTC, reason: timedOut, attempt: 2, wasConnected: false,
            relayAvailable: false)
        #expect(noRelay == .failed("Offline · Retry"))
    }

    @Test func anOfflineMacIsOfflineEitherWay() {
        for wasConnected in [false, true] {
            let banner = LiveCoordinator.waitingBanner(
                macName: "Studio", transport: .wireGuard, reason: offline, attempt: 2,
                wasConnected: wasConnected, relayAvailable: nil)
            #expect(banner == .macOffline("Studio"))
        }
    }
}
#endif

@Suite struct DroppedLinkRedialTests {
    /// Context for the banner: after a drop, the immediate redial and its
    /// silent retry fail and the machine waits (`.waiting`, attempt 2). This
    /// held before the change; the coordinator maps that phase to the banner.
    @Test func aDroppedLinkWhoseRedialsFailWaits() {
        var machine = LinkMachine(transport: .wireGuard)
        _ = machine.handle(.target(LinkMachine.Target(macID: "m", name: "Studio", isOnline: true)))
        _ = machine.handle(.dialSucceeded(generation: machine.generation, path: .turn))
        _ = machine.handle(.linkDropped(generation: machine.generation, reason: "keepalive timed out"))
        _ = machine.handle(.dialFailed(generation: machine.generation, reason: "timed out"))
        _ = machine.handle(.dialFailed(generation: machine.generation, reason: "timed out"))
        guard case .waiting(.wireGuard, let attempt, _, _) = machine.phase, attempt == 2 else {
            Issue.record("expected waiting, got \(machine.phase)")
            return
        }
    }
}
