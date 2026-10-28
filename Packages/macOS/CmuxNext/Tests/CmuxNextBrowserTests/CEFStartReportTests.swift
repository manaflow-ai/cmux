@testable import CmuxNextBrowser
import CmuxNextTrace
import Testing

/// `debug.cef`'s `ready_after_launch_s`: wall-clock seconds since the kernel's process start.
@Suite struct CEFStartReportTests {
    private static let second: UInt64 = 1_000_000_000

    private static func clock(startWall: UInt64?, wall: UInt64, uptime: UInt64) -> LaunchClock {
        LaunchClock(reader: .init(processStartWallNanos: { startWall }, wallNanos: { wall }, uptimeNanos: { uptime },
                                  pageins: { nil }))
    }

    @Test func countsWallTimeSinceTheKernelStart() throws {
        let clock = Self.clock(startWall: 1_000 * Self.second, wall: 1_012 * Self.second, uptime: 500 * Self.second)
        let seconds = try #require(CEFStartReport.secondsSinceLaunch(clock))
        #expect(abs(seconds - 12) < 1e-9)
    }

    @Test func aWallClockSetBackPastTheStartIsZeroNotNegative() throws {
        let clock = Self.clock(startWall: 2_000 * Self.second, wall: 1_000 * Self.second, uptime: 500 * Self.second)
        #expect(try #require(CEFStartReport.secondsSinceLaunch(clock)) == 0)
    }

    @Test func anUnreadableStartIsNil() {
        let clock = Self.clock(startWall: nil, wall: 1_000 * Self.second, uptime: 500 * Self.second)
        #expect(CEFStartReport.secondsSinceLaunch(clock) == nil)
    }
}
