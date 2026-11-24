#if os(iOS)
import Foundation
import Testing
@testable import CmuxMobileLive

/// Every connection chip for a Mac counts its quiet 10 s from that Mac's link drop
/// (`AppStore.macLinkDownSince`, written in `phaseChanged` for every Mac, focused or not):
/// set at the first phase that is not connected, kept while it stays down, cleared when back.
@Suite struct LinkDownSinceTests {
    @Test func theDropIsSetOnceKeptWhileDownAndClearedWhenBack() {
        let drop = Date(timeIntervalSince1970: 1_000)
        let first = LiveCoordinator.nextLinkDownSince(nil, down: true, now: drop)
        #expect(first == drop)
        // Connecting, then Reconnecting, then Mac offline: still the first drop.
        #expect(LiveCoordinator.nextLinkDownSince(first, down: true, now: drop.addingTimeInterval(9)) == drop)
        #expect(LiveCoordinator.nextLinkDownSince(first, down: false, now: drop.addingTimeInterval(12)) == nil)
        #expect(LiveCoordinator.nextLinkDownSince(nil, down: false, now: drop) == nil)
    }
}
#endif
