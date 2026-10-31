import Darwin
import Foundation
import Testing
import CmuxNextCompat

/// The app's open-file limit (`OpenFileLimit`): launchd's soft 256 stopped the app at 80-100
/// Chromium tabs (activation-perf, 2026-10-23), so the app raises it at launch, as Chrome and the
/// cmux daemons raise theirs.
@Suite(.serialized)
struct OpenFileLimitTests {
    /// RLIM_INFINITY (<sys/resource.h>, a macro Swift does not import).
    static let unlimited: rlim_t = (1 << 63) - 1
    /// A limit the test owns: `read` reports it, `write` changes it unless the kernel refuses `refuseAbove`.
    final class FakeLimit {
        var soft: rlim_t
        let hard: rlim_t
        var refuseAbove: rlim_t = .max
        init(soft: rlim_t, hard: rlim_t) { self.soft = soft; self.hard = hard }

        func limit(cap: rlim_t = 24_576) -> OpenFileLimit {
            var limit = OpenFileLimit()
            limit.read = { (self.soft, self.hard) }
            limit.write = { soft, _ in
                guard soft <= self.refuseAbove else { return false }
                self.soft = soft
                return true
            }
            limit.perProcessCap = { cap }
            return limit
        }
    }

    @Test func launchdsSoftLimitRisesToThePerProcessCap() {
        let fake = FakeLimit(soft: 256, hard: Self.unlimited)
        #expect(fake.limit().raise() == .init(before: 256, after: 24_576))
        #expect(fake.soft == 24_576)
    }

    @Test func neverAboveTheHardLimitOrTheCeiling() {
        let low = FakeLimit(soft: 256, hard: 4_096)
        #expect(low.limit().raise()?.after == 4_096)
        let high = FakeLimit(soft: 256, hard: Self.unlimited)
        #expect(high.limit(cap: 1_000_000).raise()?.after == 65_536)
    }

    @Test func aHigherLimitIsKept() {
        let fake = FakeLimit(soft: 50_000, hard: Self.unlimited)
        #expect(fake.limit().raise() == .init(before: 50_000, after: 50_000))
        #expect(fake.soft == 50_000)
    }

    /// An older kernel refuses a soft limit above OPEN_MAX: the raise falls back to it.
    @Test func aRefusedRaiseFallsBackToOpenMax() {
        let fake = FakeLimit(soft: 256, hard: Self.unlimited)
        fake.refuseAbove = 10_240
        #expect(fake.limit().raise() == .init(before: 256, after: 10_240))
    }

    /// Shells keep the launch limit: the daemon and its terminal hosts read the old soft limit from
    /// CMUX_TUI_HOST_NOFILE_SOFT (cmux-holder NOFILE_SOFT_ENV); nothing when nothing was raised.
    @Test func theChildrenGetTheLaunchLimitBack() {
        #expect(OpenFileLimit.Change(before: 256, after: 24_576).childEnvironment == ["CMUX_TUI_HOST_NOFILE_SOFT": "256"])
        #expect(OpenFileLimit.Change(before: 50_000, after: 50_000).childEnvironment.isEmpty)
    }

    /// A launch under a hard limit of 256 (`ulimit -n 256` in a shell sets both) cannot raise it, and
    /// Chromium aborted the app within 6 s there (`SeatbeltExecClient: pipe failed`, chaos fuzz row h,
    /// cmux21, 2026-10-31): Chromium must not start.
    @Test func aHardLimitOf256KeepsChromiumFromStarting() {
        let fake = FakeLimit(soft: 256, hard: 256)
        let limit = fake.limit()
        #expect(limit.raise() == .init(before: 256, after: 256))
        #expect(limit.chromiumShortfall() == 256)
    }

    /// launchd's soft 256 with an unlimited hard limit (Finder, the Dock, `open`) rises past the floor.
    @Test func launchdsDefaultLetsChromiumStartAfterTheRaise() {
        let fake = FakeLimit(soft: 256, hard: Self.unlimited)
        let limit = fake.limit()
        #expect(limit.chromiumShortfall() == 256)
        _ = limit.raise()
        #expect(limit.chromiumShortfall() == nil)
    }

    @Test func theFloorItselfIsEnough() {
        #expect(FakeLimit(soft: OpenFileLimit.chromiumFloor, hard: OpenFileLimit.chromiumFloor).limit().chromiumShortfall() == nil)
        #expect(FakeLimit(soft: OpenFileLimit.chromiumFloor - 1, hard: OpenFileLimit.chromiumFloor - 1).limit().chromiumShortfall()
            == OpenFileLimit.chromiumFloor - 1)
    }

    /// A limit that cannot be read does not keep Chromium from starting.
    @Test func anUnreadableLimitLetsChromiumStart() {
        var limit = OpenFileLimit()
        limit.read = { nil }
        #expect(limit.chromiumShortfall() == nil)
    }

    /// This process, through the real getrlimit/setrlimit: after the raise it can hold far more
    /// than 256 descriptors open at once (a 100-tab Chromium browser process needs that).
    @Test func thisProcessHoldsMoreThanLaunchdsLimitAfterTheRaise() throws {
        let change = try #require(OpenFileLimit().raise())
        #expect(change.after > 256)
        var descriptors: [Int32] = []
        defer { descriptors.forEach { close($0) } }
        for _ in 0..<600 {
            let fd = open("/dev/null", O_RDONLY)
            let openErrno = errno
            try #require(fd >= 0, "open failed after \(descriptors.count) descriptors: errno \(openErrno)")
            descriptors.append(fd)
        }
    }
}
