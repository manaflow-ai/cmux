import CmuxNextCompat
import Darwin
import Testing

/// `ProcessRole` (p02-threads-235), the Swift twin of `cmux_threads::process_role`: the default role reads
/// foreground, suppression sets `PRIO_DARWIN_BG` and foreground clears it. The role is process-wide, so the
/// suite runs serialized and leaves the test process in the foreground.
@Suite(.serialized, .timeLimit(.minutes(1)))
struct ProcessRoleTests {
    /// TASK_FOREGROUND_APPLICATION and TASK_BACKGROUND_APPLICATION (mach/task_policy.h).
    private let foreground: Int32 = 1
    private let background: Int32 = 2

    @Test func theDefaultRoleReadsForeground() throws {
        try ProcessRole.applyDefault()
        #expect(ProcessRole.currentTaskRole() == foreground)
    }

    @Test func suppressedThenForegroundClearsDarwinBackground() throws {
        defer { try? ProcessRole.foreground.apply() }
        try ProcessRole.backgroundSuppressed.apply()
        #expect(ProcessRole.currentTaskRole() == background)
        #expect(ProcessRole.isDarwinBackground() == true)

        try ProcessRole.background.apply()
        #expect(ProcessRole.isDarwinBackground() == false, "plain background is not suppressed")

        try ProcessRole.backgroundSuppressed.apply()
        try ProcessRole.foreground.apply()
        #expect(ProcessRole.currentTaskRole() == foreground)
        #expect(ProcessRole.isDarwinBackground() == false)
    }

    @Test func suppressionByPidSetsAndClearsDarwinBackground() throws {
        defer { try? ProcessRole.foreground.apply() }
        try ProcessRole.backgroundSuppressed.applySuppression(toChild: getpid())
        #expect(ProcessRole.isDarwinBackground(pid: getpid()) == true)
        try ProcessRole.foreground.applySuppression(toChild: getpid())
        #expect(ProcessRole.isDarwinBackground(pid: getpid()) == false)
    }
}
