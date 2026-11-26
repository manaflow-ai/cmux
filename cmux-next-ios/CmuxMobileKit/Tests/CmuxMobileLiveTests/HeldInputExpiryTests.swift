import Foundation
import Testing
@testable import CmuxMobileLive

/// Keys typed before the attach wait for it while the terminal reconnects, and go only when the
/// reconnect gives up (Leo, 2026-11-24, back from another app: "I can't interact with anything
/// at all"): `DaemonTerminalSession.heldInputExpiry`.
struct HeldInputExpiryTests {
    typealias Session = DaemonTerminalSession

    @Test func keysWaitForAReconnectPastTheOldTenSeconds() {
        let at: TimeInterval = 1000
        #expect(Session.heldInputExpiry(typedAt: [at], now: at + Session.inputHoldLimit * 3,
                                        gaveUp: false, offlineSince: nil) == nil)
    }

    @Test func nothingHeldNeverExpires() {
        #expect(Session.heldInputExpiry(typedAt: [], now: 1_000_000, gaveUp: true, offlineSince: 0) == nil)
    }

    @Test func aReattachThatGaveUpDropsThemAtOnce() {
        #expect(Session.heldInputExpiry(typedAt: [1000], now: 1000, gaveUp: true, offlineSince: nil) != nil)
    }

    @Test func theMacOfflineForTheHoldDropsThem() {
        let typed: TimeInterval = 1000
        // Offline from 5 s after the key: the hold counts from going offline.
        let offline = typed + 5
        #expect(Session.heldInputExpiry(typedAt: [typed], now: offline + Session.inputHoldLimit - 1,
                                        gaveUp: false, offlineSince: offline) == nil)
        #expect(Session.heldInputExpiry(typedAt: [typed], now: offline + Session.inputHoldLimit,
                                        gaveUp: false, offlineSince: offline) != nil)
        // A key typed while offline gets the whole hold from its own tap.
        let late = offline + 8
        #expect(Session.heldInputExpiry(typedAt: [late], now: late + Session.inputHoldLimit - 1,
                                        gaveUp: false, offlineSince: offline) == nil)
    }

    /// termfix-r13 D5: an app suspended with keys queued never types them minutes later.
    @Test func theCeilingDropsKeysASuspendedAppKept() {
        let typed: TimeInterval = 1000
        #expect(Session.heldInputExpiry(typedAt: [typed], now: typed + Session.inputHoldCeiling - 1,
                                        gaveUp: false, offlineSince: nil) == nil)
        #expect(Session.heldInputExpiry(typedAt: [typed], now: typed + 15 * 60,
                                        gaveUp: false, offlineSince: nil) != nil)
        #expect(Session.inputHoldCeiling > 16 + 8 + Session.inputHoldLimit,
                "past the reattach backoff (about 16 s) and the offline call (8 s) plus its hold")
    }
}
