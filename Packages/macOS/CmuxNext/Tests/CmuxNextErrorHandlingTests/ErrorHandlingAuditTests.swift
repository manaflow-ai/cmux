@testable import CmuxNextAgentPane
import CmuxNextCloud
@testable import CmuxNextRemote
import Foundation
import Testing

@Suite(.timeLimit(.minutes(1)))
struct ErrorHandlingAuditTests {
    @Test func anSSHDeadlineTerminatesAProcessThatDoesNotExit() async throws {
        let clock = ContinuousClock()
        let started = clock.now
        var deadlineError: (any Error)?
        do {
            _ = try await SSHProcessRunner.run(
                ["/bin/sh", "-c", "sleep 5"],
                environment: [:],
                deadline: .milliseconds(50),
                label: "hung ssh test"
            )
        } catch {
            deadlineError = error
        }

        #expect(deadlineError is DeadlineExceeded)
        #expect(started.duration(to: clock.now) < .seconds(2))
    }

    @Test func aGitTimeoutSignalsTheChildProcessGroup() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-error-handling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let script = root.appendingPathComponent("git-stub.sh")
        let marker = root.appendingPathComponent("term.txt")
        try """
        #!/bin/sh
        marker="$1"
        trap '' TERM
        (
          trap 'printf term > "$marker"; exit 0' TERM
          while :; do sleep 1; done
        ) &
        wait
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let outcome = await AgentPaneGitProcess.output(
            [marker.path],
            executable: script.path,
            timeout: .milliseconds(50)
        )

        #expect(outcome.status == nil)
        #expect(outcome.message == AgentPaneGitProcess.timedOutMessage)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func aFailedScreenCaptureIsNotReportedAsCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-error-handling-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let tool = root.appendingPathComponent("capture-stub.sh")
        try "#!/bin/sh\nexit 23\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)

        let captured = await AgentPaneCapture.capture(
            window: false,
            to: root.appendingPathComponent("capture.png"),
            executable: tool.path
        )

        #expect(captured == .failed)
    }
}
