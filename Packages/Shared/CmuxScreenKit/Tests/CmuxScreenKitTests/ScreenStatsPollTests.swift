import Foundation
import Testing
@testable import CmuxScreenKit

/// WebRTC's stats are asked for only while the stats line can show, and the reconnect wait
/// gives the system leeway to share its wake (p14-energy-067f).
@MainActor struct ScreenStatsPollTests {
    static let connected = ScreenSession.Phase.connected(VNCServerInfo(width: 0, height: 0, name: "Mac", nativeFormat: .bgrx,
                                                                       protocolMinor: 8, securityType: 0))

    @Test func statsArePolledOnlyWhileTheLineCanShow() {
        #expect(ScreenSession.pollsStreamStats(showStats: true, phase: Self.connected))
        #expect(!ScreenSession.pollsStreamStats(showStats: false, phase: Self.connected), "the stats line is turned off")
        #expect(!ScreenSession.pollsStreamStats(showStats: true, phase: .connecting), "a reconnect shows no stats")
        #expect(!ScreenSession.pollsStreamStats(showStats: true, phase: .ended))
        #expect(!ScreenSession.pollsStreamStats(showStats: true, phase: .failed(message: "x", needsSignIn: false)))
    }

    @Test func reconnectWaitsHaveATenthOfLeewayAtLeast8ms() {
        #expect(ScreenSession.backoffTolerance(0) == .milliseconds(8))
        #expect(ScreenSession.backoffTolerance(1) == .milliseconds(100))
        #expect(ScreenSession.backoffTolerance(8) == .milliseconds(800))
    }
}
