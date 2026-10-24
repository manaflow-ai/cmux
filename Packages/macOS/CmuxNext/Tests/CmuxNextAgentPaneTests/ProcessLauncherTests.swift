@testable import CmuxNextAgentPane
import Foundation
import Testing

/// The real launcher waits for the child's exit and bounds it: the exit status comes back, and a
/// child that does not end by the deadline is killed and reported as not finished.
@Suite(.timeLimit(.minutes(1))) struct ProcessLauncherTests {
    @Test func theExitStatusComesBack() async {
        let status = await ProcessLauncher().run(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "exit 3"], environment: [:])
        #expect(status == 3)
    }

    @Test func aChildPastItsDeadlineIsKilled() async {
        let started = ContinuousClock.now
        // The deadline is the behavior under test: 200 ms against a child that would run 60 s.
        let status = await ProcessLauncher(timeout: .milliseconds(200))
            .run(URL(fileURLWithPath: "/bin/sleep"), arguments: ["60"], environment: [:])
        #expect(status == nil)
        #expect(ContinuousClock.now - started < .seconds(30), "the launcher waited for the child instead of its deadline")
    }

    @Test func aMissingExecutableIsNotStarted() async {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("no-such-\(UUID().uuidString)")
        let status = await ProcessLauncher().run(missing, arguments: [], environment: [:])
        #expect(status == nil)
    }
}
