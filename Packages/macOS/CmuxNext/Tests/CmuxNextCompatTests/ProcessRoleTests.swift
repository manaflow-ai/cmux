import CmuxNextCompat
import Darwin
import Testing

/// `ProcessRole`, the Swift twin of `cmux_threads::process_role`: the default role reads
/// foreground, suppression sets `PRIO_DARWIN_BG` and foreground clears it, and a parent suppresses a child by pid.
/// The role and `PRIO_DARWIN_BG` are process-wide and the other suites of this test process run beside this one,
/// so every change to this process's role runs in an exit-test child (``ProcessRoleChild``). This process only
/// reads its own role and changes a spawned child's flag.
@Suite(.timeLimit(.minutes(1)))
struct ProcessRoleTests {
    @Test func theDefaultRoleReadsForeground() async {
        await #expect(processExitsWith: .success) { ProcessRoleChild.applyTheDefaultRole() }
    }

    @Test func suppressedThenForegroundClearsDarwinBackground() async {
        await #expect(processExitsWith: .success) { ProcessRoleChild.suppressThenReturnToForeground() }
    }

    @Test func thisProcessReadsItsRoleAndFlags() {
        #expect(ProcessRole.currentTaskRole() != nil, "task_policy_get(TASK_CATEGORY_POLICY) answers")
        #expect(ProcessRole.darwinBackground() != nil, "proc_pidinfo(PROC_PIDTBSDINFO) answers")
    }

    /// A real child (`/bin/sleep`), suppressed by pid from this process, read, cleared and read again: the flag a
    /// parent sets is the child's external one, and this process keeps its own flags.
    @Test func aParentSuppressesAndClearsAChildByPid() throws {
        let before = ProcessRole.darwinBackground()
        let pid = try Self.spawnSleep()
        defer {
            kill(pid, SIGKILL)
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
        }
        let externallySuppressed = ProcessRole.DarwinBackground(internalFlag: false, externalFlag: true)
        let clear = ProcessRole.DarwinBackground(internalFlag: false, externalFlag: false)
        try ProcessRole.backgroundSuppressed.applySuppression(toChild: pid)
        let suppressed = ProcessRole.darwinBackground(pid: pid)
        #expect(suppressed == externallySuppressed, "the parent sets the child's external flag")
        #expect(suppressed?.isSuppressed == true)

        try ProcessRole.foreground.applySuppression(toChild: pid)
        #expect(ProcessRole.darwinBackground(pid: pid) == clear, "and clears it")
        #expect(ProcessRole.darwinBackground() == before, "this process's flags do not change")
    }

    private struct SpawnFailed: Error { let code: Int32 }

    private static func spawnSleep() throws -> pid_t {
        let words: [String] = ["/bin/sleep", "30"]
        let arguments: [UnsafeMutablePointer<CChar>?] = words.map { strdup($0) } + [nil]
        let environment: [UnsafeMutablePointer<CChar>?] = [strdup("PATH=/usr/bin:/bin"), nil]
        defer { for pointer in arguments + environment { free(pointer) } }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, "/bin/sleep", nil, nil, arguments, environment)
        guard result == 0 else { throw SpawnFailed(code: result) }
        return pid
    }
}

/// The exit-test children: each changes its own process's role, checks it, and exits with the number of the first
/// check that fails (0 when all pass). The external flag is whatever the child inherited, so only the internal one,
/// which the child sets itself, is checked. Nonisolated: an exit-test body is a nonisolated `@Sendable` closure, and
/// the children touch no main-actor state.
nonisolated enum ProcessRoleChild {
    /// TASK_FOREGROUND_APPLICATION and TASK_BACKGROUND_APPLICATION (mach/task_policy.h).
    private static let foreground: Int32 = 1
    private static let background: Int32 = 2

    static func applyTheDefaultRole() {
        do { try ProcessRole.applyDefault() } catch { exit(1) }
        if ProcessRole.currentTaskRole() != foreground { exit(2) }
    }

    static func suppressThenReturnToForeground() {
        do { try ProcessRole.backgroundSuppressed.apply() } catch { exit(1) }
        if ProcessRole.currentTaskRole() != background { exit(2) }
        if ProcessRole.darwinBackground()?.internalFlag != true { exit(3) }

        do { try ProcessRole.background.apply() } catch { exit(4) }
        if ProcessRole.darwinBackground()?.internalFlag != false { exit(5) } // plain background is not suppressed

        do { try ProcessRole.backgroundSuppressed.apply() } catch { exit(6) }
        do { try ProcessRole.foreground.apply() } catch { exit(7) }
        if ProcessRole.currentTaskRole() != foreground { exit(8) }
        if ProcessRole.darwinBackground()?.internalFlag != false { exit(9) }
    }
}
