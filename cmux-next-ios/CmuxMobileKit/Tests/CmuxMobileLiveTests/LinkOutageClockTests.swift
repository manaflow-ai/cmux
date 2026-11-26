import CmuxMobileTerminal
import Testing
@testable import CmuxMobileLive

/// Back in front after minutes away, the cached terminal stays live: no "Mac offline", no Send
/// refused, no first key held. Leo, 2026-11-24: "The like multi-second long reattach where like
/// the entire thing is somehow grayed out and I can't interact with anything at all."
///
/// The clock is injected (instants built from one `now`), nothing sleeps.
@Suite struct LinkOutageClockTests {
    let start = ContinuousClock.now
    let lost = LinkMachine.Phase.waiting(.webRTC, attempt: 2, reason: "The link dropped", retryIn: .seconds(1))
    let redial = LinkMachine.Phase.connecting(.webRTC, attempt: 1)

    /// What a reattaching terminal of the Mac shows, as `DaemonTerminalSession.connectionState`
    /// decides it from the coordinator's word (`setMacOffline`).
    func terminal(offline: Bool) -> TerminalConnectionState {
        offline ? .offline(mac: "Studio") : .reattaching(mac: "Studio")
    }

    /// The person's first tap or key at `at` after the return: taken (queued in the session's
    /// hold, sent on attach) unless the screen refuses it.
    func firstInputTaken(_ outage: inout LinkOutageClock, phase: LinkMachine.Phase, at: ContinuousClock.Instant) -> Bool {
        let down = outage.follow(phase, at: at)
        let state = terminal(offline: LinkOutageClock.terminalsOffline(phase, down: down, teamStarted: true))
        return state.composerNotSentNotice == nil && state.pillSubtitle == nil && state.keepsWarmFrame
    }

    @Test func fiveMinutesAwayWithTheLinkLostIsNotOfflineOnReturn() {
        var outage = LinkOutageClock()
        _ = outage.follow(.connected(.webRTC, .direct, rttMillis: 20), at: start)
        // Backgrounded; the link drops 5 s later, while iOS still runs the app.
        _ = outage.follow(lost, at: start + .seconds(5))
        // 5 minutes away, then in front: the links redial.
        let back = start + .seconds(5 * 60)
        outage.foregrounded(at: back)
        // The first tap or key, at once and 100 ms on: taken, nothing dimmed or offline.
        #expect(firstInputTaken(&outage, phase: redial, at: back))
        #expect(firstInputTaken(&outage, phase: redial, at: back + .milliseconds(100)))
        #expect(outage.since == back)
        // The outage still has its bound, counted from the return: a first redial says
        // offline only after twice `offlineAfter`, as at launch.
        #expect(firstInputTaken(&outage, phase: redial, at: back + LinkMachine.Phase.offlineAfter * 2 - .milliseconds(1)))
        let late = outage.follow(redial, at: back + LinkMachine.Phase.offlineAfter * 2)
        #expect(LinkOutageClock.terminalsOffline(redial, down: late, teamStarted: true))
    }

    /// Base: the outage counted the time away, so the return read 5 minutes down and put the
    /// terminal offline (Send refused, "Mac offline") before the redial had a chance.
    @Test func countingTheTimeAwayIsWhatWentOffline() {
        var outage = LinkOutageClock()
        _ = outage.follow(lost, at: start + .seconds(5))
        let back = start + .seconds(5 * 60)
        // No `foregrounded(at:)`: the old count.
        #expect(!firstInputTaken(&outage, phase: redial, at: back))
    }

    @Test func aLinkTheMacKeptHasNoOutage() {
        var outage = LinkOutageClock()
        _ = outage.follow(.connected(.webRTC, .direct, rttMillis: 20), at: start)
        let back = start + .seconds(5 * 60)
        outage.foregrounded(at: back)
        #expect(outage.since == nil)
        #expect(outage.follow(.connected(.webRTC, .direct, rttMillis: 20), at: back) == .zero)
    }

    /// Presence says the Mac is offline: that is its word, not a bound, and the return keeps it.
    @Test func aMacPresenceCallsOfflineStaysOffline() {
        var outage = LinkOutageClock()
        _ = outage.follow(.macOffline, at: start)
        let back = start + .seconds(5 * 60)
        outage.foregrounded(at: back)
        let down = outage.follow(.macOffline, at: back)
        #expect(LinkOutageClock.terminalsOffline(.macOffline, down: down, teamStarted: true))
    }
}
