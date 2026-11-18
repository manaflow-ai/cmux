#if os(iOS)
@testable import CmuxMobileDesign
import Foundation
import Testing

/// A dismissed connection banner stays hidden through the link's flaps (audit 20, ceremony: a
/// dismissed "Reconnecting" came back on every flap); a real new drop shows again.
@Suite struct BannerDismissalTests {
    static let start = Date(timeIntervalSince1970: 1_000_000)
    static let reconnecting = ConnectionBannerState.reconnecting(to: "Mac", identity: "m1")

    /// Runs `states` (each with its seconds from `start`) through a dismissal of `dismissed`.
    static func run(_ dismissed: ConnectionBannerState, _ states: [(TimeInterval, ConnectionBannerState?)]) -> BannerDismissal? {
        var dismissal: BannerDismissal? = BannerDismissal(state: dismissed)
        for (at, state) in states {
            dismissal = BannerDismissal.remembered(dismissal, after: state, at: start.addingTimeInterval(at))
        }
        return dismissal
    }

    @Test func theSameStateKeepsItsDismissal() {
        #expect(Self.run(.offline, [(1, .offline)])?.state == .offline)
    }

    /// Detector: down, dismissed, back for a moment, down again, several times inside the window:
    /// the banner never comes back. On the old code the first "back" ended the dismissal.
    @Test func flapsInsideTheWindowAfterADismissalShowNoBanner() {
        var dismissal: BannerDismissal? = BannerDismissal(state: Self.reconnecting)
        var shown = 0
        var at: TimeInterval = 0
        for _ in 0..<10 {
            at += 5
            dismissal = BannerDismissal.remembered(dismissal, after: nil, at: Self.start.addingTimeInterval(at))
            at += 15
            dismissal = BannerDismissal.remembered(dismissal, after: Self.reconnecting, at: Self.start.addingTimeInterval(at))
            if dismissal?.state != Self.reconnecting { shown += 1 }
        }
        #expect(shown == 0, "a flap within \(BannerDismissal.flapWindow) s of the link coming back shows nothing")
    }

    @Test func theSameStateAfterTheConnectionHeldIsANewDrop() {
        let dismissal = Self.run(Self.reconnecting, [(5, nil), (5 + BannerDismissal.flapWindow, Self.reconnecting)])
        #expect(dismissal == nil, "held for the whole window: a real new drop shows")
    }

    @Test func anotherStateEndsTheDismissal() {
        #expect(Self.run(Self.reconnecting, [(1, .offline)]) == nil)
        #expect(Self.run(Self.reconnecting, [(1, nil), (2, .signedOut)]) == nil)
    }

    @Test func nothingDismissedStaysThatWay() {
        #expect(BannerDismissal.remembered(nil, after: .offline, at: Self.start) == nil)
        #expect(BannerDismissal.remembered(nil, after: nil, at: Self.start) == nil)
    }
}
#endif
