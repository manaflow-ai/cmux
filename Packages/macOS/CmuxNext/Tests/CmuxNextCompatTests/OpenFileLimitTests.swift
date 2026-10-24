import Darwin
import Foundation
import Testing
import CmuxNextCompat

/// The app's open-file limit (`OpenFileLimit`): launchd's soft 256 stopped the app at 80-100
/// Chromium tabs (activation-perf, 2026-10-23), so the app raises it at launch, as Chrome and the
/// cmux daemons raise theirs.
struct OpenFileLimitTests {
    /// RLIM_INFINITY (<sys/resource.h>, a macro Swift does not import). `nonisolated`: an
    /// immutable `rlim_t` that the `@Sendable` read closures capture, off the package's default MainActor.
    nonisolated static let unlimited: rlim_t = (1 << 63) - 1

    /// A kernel that reports `soft` and `hard`, caps a soft limit at `cap`, and refuses one above
    /// `refuseAbove` with EINVAL, as an older kernel refuses more than OPEN_MAX.
    static func kernel(soft: rlim_t, hard: rlim_t, cap: rlim_t = 24_576, refuseAbove: rlim_t = .max) -> OpenFileLimit {
        OpenFileLimit(read: { .success((soft: soft, hard: hard)) },
                      write: { new, _ in new <= refuseAbove ? .success(()) : .failure(.init(errno: EINVAL)) },
                      perProcessCap: { cap })
    }

    @Test func launchdsSoftLimitRisesToThePerProcessCap() {
        #expect(Self.kernel(soft: 256, hard: Self.unlimited).raise()
            == .init(change: .init(before: 256, after: 24_576), line: "cmux: open-file limit 256 -> 24576"))
    }

    @Test func neverAboveTheHardLimitOrTheCeiling() {
        #expect(Self.kernel(soft: 256, hard: 4_096).raise().change?.after == 4_096)
        #expect(Self.kernel(soft: 256, hard: Self.unlimited, cap: 1_000_000).raise().change?.after == 65_536)
    }

    /// A launch from a shell with a higher limit keeps it, writes nothing, and still logs its line.
    @Test func aHigherLimitIsKept() {
        let limit = OpenFileLimit(read: { .success((soft: 50_000, hard: Self.unlimited)) },
                                  write: { soft, _ in
                                      Issue.record("the raise wrote \(soft) over a higher limit")
                                      return .failure(.init(errno: EINVAL))
                                  },
                                  perProcessCap: { 24_576 })
        #expect(limit.raise() == .init(change: .init(before: 50_000, after: 50_000), line: "cmux: open-file limit 50000 (kept)"))
    }

    /// An older kernel refuses a soft limit above OPEN_MAX: the raise falls back to it and says why.
    @Test func aRefusedRaiseFallsBackToOpenMax() {
        #expect(Self.kernel(soft: 256, hard: Self.unlimited, refuseAbove: 10_240).raise()
            == .init(change: .init(before: 256, after: 10_240),
                     line: "cmux: open-file limit 256 -> 10240 (setrlimit 24576: errno \(EINVAL))"))
    }

    /// A launch that stays at 256 says so, with the errno (review 1: it logged nothing).
    @Test func aRefusedRaiseKeepsTheLimitAndSaysWhy() {
        #expect(Self.kernel(soft: 256, hard: Self.unlimited, refuseAbove: 200).raise()
            == .init(change: .init(before: 256, after: 256),
                     line: "cmux: open-file limit stays 256 (setrlimit 24576: errno \(EINVAL))"))
    }

    @Test func anUnreadableLimitSaysSo() {
        let limit = OpenFileLimit(read: { .failure(.init(errno: EFAULT)) }, write: { _, _ in .success(()) },
                                  perProcessCap: { 24_576 })
        #expect(limit.raise() == .init(change: nil, line: "cmux: open-file limit unknown (getrlimit: errno \(EFAULT))"))
    }

    /// The daemons get the launch limit back for their shells (cmux-pty LAUNCH_SOFT_LIMIT_ENV,
    /// cmux-holder NOFILE_SOFT_ENV); nothing when nothing was raised.
    @Test func theDaemonsGetTheLaunchLimitBack() {
        let raised = OpenFileLimit.Change(before: 256, after: 24_576)
        #expect(raised.launchLimit == 256)
        #expect(OpenFileLimit.daemonEnvironment(launchLimit: raised.launchLimit) == ["CMUX_TUI_HOST_NOFILE_SOFT": "256"])
        let kept = OpenFileLimit.Change(before: 50_000, after: 50_000)
        #expect(kept.launchLimit == nil)
        #expect(OpenFileLimit.daemonEnvironment(launchLimit: kept.launchLimit).isEmpty)
    }

    /// The real getrlimit/setrlimit, in a child process at launchd's soft limit (an exit test, so
    /// this test process's own limit never changes): after the raise it holds 600 descriptors
    /// open at once, as a 100-tab Chromium browser process needs.
    @Test func aProcessAtLaunchdsLimitHolds600FilesAfterTheRaise() async {
        await #expect(processExitsWith: .success) {
            var limit = rlimit()
            guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { exit(2) }
            limit.rlim_cur = 256
            guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { exit(3) }
            guard let change = OpenFileLimit().raise().change, change.before == 256, change.after >= 1_024 else { exit(4) }
            for _ in 0..<600 {
                guard open("/dev/null", O_RDONLY) >= 0 else { exit(5) }
            }
            exit(0)
        }
    }

    /// The control for the test above: at launchd's limit and without the raise, the same 600
    /// opens run out (EMFILE), so the test above fails when the raise does nothing.
    @Test func withoutTheRaiseAProcessAtLaunchdsLimitRunsOutBefore600Files() async {
        await #expect(processExitsWith: .success) {
            var limit = rlimit()
            guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { exit(2) }
            limit.rlim_cur = 256
            guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { exit(3) }
            for _ in 0..<600 {
                guard open("/dev/null", O_RDONLY) >= 0 else { exit(errno == EMFILE ? 0 : 5) }
            }
            exit(6)
        }
    }
}
