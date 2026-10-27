import Foundation
import Testing
@testable import CmuxScreenKit

/// WebRTC's stats are read only while the stats line is on screen, each sample on a one-shot deadline that the
/// next sample arms again, and every start takes a new receive-rate baseline; the reconnect wait gives the system
/// leeway to share its wake (p14-energy-067f).
@MainActor struct ScreenStatsPollTests {
    static let connected = ScreenSession.Phase.connected(VNCServerInfo(width: 0, height: 0, name: "Mac", nativeFormat: .bgrx,
                                                                       protocolMinor: 8, securityType: 0))
    static let megabyte = 1024.0 * 1024

    /// A deadline the test fires by hand.
    @MainActor final class HandDeadline: ScreenDeadline {
        private(set) var delay: Double?
        private var action: (@MainActor @Sendable () -> Void)?

        func schedule(after seconds: Double, _ action: @escaping @MainActor @Sendable () -> Void) {
            delay = seconds
            self.action = action
        }

        func cancel() {
            delay = nil
            action = nil
        }

        var isPending: Bool { action != nil }

        func fire() {
            let action = self.action
            cancel()
            action?()
        }
    }

    /// A stream's WebRTC receiver: `bytesReceived` counts from the connect.
    @MainActor final class FakeStats: ScreenVideoStatsSource {
        var bytes: Double
        private(set) var reads = 0

        init(bytes: Double) { self.bytes = bytes }

        func videoStats() async -> ScreenStreamViewer.VideoStats {
            reads += 1
            var stats = ScreenStreamViewer.VideoStats()
            stats.fps = 60
            stats.rttMs = 12
            stats.codec = "H264"
            stats.decoder = "VideoToolbox"
            stats.bytesReceived = bytes
            return stats
        }
    }

    /// The stats clock the test steps.
    @MainActor final class StatsClock {
        var now: CFTimeInterval = 1000
    }

    /// A stream session with the stats line on screen, on a hand deadline and a stepped clock.
    @MainActor struct Rig {
        let session: ScreenSession
        let deadline: HandDeadline
        let clock: StatsClock

        init() {
            let deadline = HandDeadline()
            let clock = StatsClock()
            let session = ScreenSession(title: "Mac", preferences: ScreenPreferences(showStats: true), signaling: { nil })
            session.useStatsDeadline(deadline)
            session.statsNow = { clock.now }
            session.statsVisible = true
            self.session = session
            self.deadline = deadline
            self.clock = clock
        }

        /// One second of the stream at 1 MB/s, then the deadline's sample.
        func nextSecond(_ source: FakeStats) async {
            source.bytes += ScreenStatsPollTests.megabyte
            clock.now += 1
            #expect(deadline.isPending)
            deadline.fire()
            await session.pendingStatsRead?.value
        }
    }

    @Test func statsAreReadOnlyWhileTheLineIsOnScreen() {
        #expect(ScreenSession.pollsStreamStats(showStats: true, statsVisible: true, phase: Self.connected))
        #expect(!ScreenSession.pollsStreamStats(showStats: false, statsVisible: true, phase: Self.connected), "the stats line is turned off")
        #expect(!ScreenSession.pollsStreamStats(showStats: true, statsVisible: false, phase: Self.connected), "the line is not on screen")
        #expect(!ScreenSession.pollsStreamStats(showStats: true, statsVisible: true, phase: .connecting), "a reconnect shows no stats")
        #expect(!ScreenSession.pollsStreamStats(showStats: true, statsVisible: true, phase: .ended))
        #expect(!ScreenSession.pollsStreamStats(showStats: true, statsVisible: true, phase: .failed(message: "x", needsSignIn: false)))
    }

    @Test func eachSampleArmsTheNextOnADeadline() async {
        let rig = Rig()
        let source = FakeStats(bytes: 0)
        rig.session.streamOpened(source, name: "Mac")
        #expect(rig.session.pollsStats, "a connected stream with the line on screen is sampled")
        await rig.session.pendingStatsRead?.value
        #expect(source.reads == 1)
        #expect(rig.deadline.delay == ScreenSession.statsInterval, "one read, then a one-shot deadline for the next")

        await rig.nextSecond(source)
        #expect(source.reads == 2)
        #expect(abs(rig.session.stats.kilobytesPerSecond - 1024) < 1e-9)
        #expect(rig.session.stats.fps == 60)
        #expect(rig.session.stats.encoding == "H264 HW")
        #expect(rig.deadline.isPending, "each sample arms the next")
    }

    @Test func turningStatsOffStopsTheReadsAndClearsTheNumbers() async {
        let rig = Rig()
        let source = FakeStats(bytes: 0)
        rig.session.streamOpened(source, name: "Mac")
        await rig.session.pendingStatsRead?.value
        await rig.nextSecond(source)
        #expect(rig.session.stats.fps == 60)

        rig.session.preferences.showStats = false
        #expect(!rig.session.pollsStats)
        #expect(!rig.deadline.isPending, "no wake while the line is off")
        #expect(rig.session.stats == ScreenSession.LiveStats(), "stale numbers never read as live")

        rig.session.statsVisible = false
        rig.session.preferences.showStats = true
        #expect(!rig.session.pollsStats, "the line is on but not on screen (a hidden tab)")
        rig.session.statsVisible = true
        #expect(rig.session.pollsStats)
    }

    /// 10 minutes into a 1 MB/s stream, a person turns Stream stats off and on: the first rate is the stream's,
    /// not every byte since the connect over one second.
    @Test func aMidStreamToggleTakesANewBaseline() async {
        let rig = Rig()
        let source = FakeStats(bytes: 0)
        rig.session.streamOpened(source, name: "Mac")
        await rig.session.pendingStatsRead?.value
        rig.session.preferences.showStats = false

        source.bytes += 600 * Self.megabyte
        rig.clock.now += 600
        rig.session.preferences.showStats = true
        await rig.session.pendingStatsRead?.value
        #expect(rig.session.stats.kilobytesPerSecond == 0, "the first read of a run is only the baseline")

        await rig.nextSecond(source)
        #expect(abs(rig.session.stats.kilobytesPerSecond - 1024) < 1e-9, "\(rig.session.stats.kilobytesPerSecond) KB/s")
    }

    @Test func aReconnectSamplesTheNewStream() async {
        let rig = Rig()
        let old = FakeStats(bytes: 0)
        rig.session.streamOpened(old, name: "Mac")
        await rig.session.pendingStatsRead?.value
        #expect(old.reads == 1)

        // connect() drops the old stream (.connecting); this session has no signaling, so it fails.
        rig.session.connect()
        #expect(!rig.session.pollsStats, "a dropped stream is not sampled")
        #expect(!rig.deadline.isPending)

        let new = FakeStats(bytes: 5 * Self.megabyte)
        rig.session.streamOpened(new, name: "Mac")
        #expect(rig.session.pollsStats)
        await rig.session.pendingStatsRead?.value
        await rig.nextSecond(new)
        #expect(new.reads == 2)
        #expect(old.reads == 1, "the old stream is never read again")
        #expect(abs(rig.session.stats.kilobytesPerSecond - 1024) < 1e-9)

        rig.session.disconnect()
        #expect(!rig.session.pollsStats)
        #expect(!rig.deadline.isPending)
    }

    @Test func theStandaloneDeadlineHasATenthOfLeeway() {
        #expect(RunLoopScreenDeadline.tolerance(1) == 0.1)
        #expect(RunLoopScreenDeadline.tolerance(0.01) == 0.008)
        #expect(RunLoopScreenDeadline.tolerance(0) == 0)
    }

    @Test func reconnectWaitsHaveATenthOfLeewayAtLeast8ms() {
        #expect(ScreenSession.backoffTolerance(0) == .milliseconds(8))
        #expect(ScreenSession.backoffTolerance(1) == .milliseconds(100))
        #expect(ScreenSession.backoffTolerance(8) == .milliseconds(800))
    }
}
