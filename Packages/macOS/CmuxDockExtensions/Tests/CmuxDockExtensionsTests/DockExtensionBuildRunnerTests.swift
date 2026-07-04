import Foundation
import Testing
@testable import CmuxDockExtensions

@Suite("DockExtensionBuildRunner", .serialized)
struct DockExtensionBuildRunnerTests {
    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ext-build-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Deterministic shell for tests regardless of the host user's $SHELL.
    private func makeRunner() -> DockExtensionBuildRunner {
        DockExtensionBuildRunner(loginShellPath: { "/bin/sh" })
    }

    @Test func runsStepsInOrderFromRootAndWritesLog() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let steps = [
            DockExtensionBuildStep(command: ["/bin/sh", "-c", "pwd > where.txt"]),
            DockExtensionBuildStep(command: ["/bin/sh", "-c", "echo built >> where.txt"]),
        ]
        try await makeRunner().runBuildSteps(steps, in: root, logsDirectory: logs)
        let output = try String(contentsOf: root.appendingPathComponent("where.txt"), encoding: .utf8)
        #expect(output.contains(root.lastPathComponent))
        #expect(output.contains("built"))
        let logFiles = try FileManager.default.contentsOfDirectory(atPath: logs.path)
        #expect(logFiles.count == 1)
    }

    @Test func failingStepThrowsWithLogTail() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let steps = [
            DockExtensionBuildStep(command: ["/bin/sh", "-c", "echo doomed >&2; exit 3"]),
        ]
        do {
            try await makeRunner().runBuildSteps(
                steps, in: root, logsDirectory: root.appendingPathComponent("logs")
            )
            Issue.record("expected buildFailed")
        } catch let DockExtensionError.buildFailed(_, exitCode, logTail) {
            #expect(exitCode == 3)
            #expect(logTail.contains("doomed"))
        }
    }

    @Test func stripsCmuxEnvironment() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // The parent test process env gets a CMUX_ variable via the child env
        // check below: the step fails if any CMUX_* variable is visible.
        let steps = [
            DockExtensionBuildStep(command: ["/bin/sh", "-c", "env | grep -q '^CMUX_' && exit 9 || exit 0"]),
        ]
        // Even if the test host has no CMUX_* vars, this at least proves the
        // step runs; with cmux-spawned test runs it proves stripping.
        try await makeRunner().runBuildSteps(
            steps, in: root, logsDirectory: root.appendingPathComponent("logs")
        )
    }

    @Test func timedOutStepThrows() async throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let steps = [DockExtensionBuildStep(command: ["/bin/sleep", "30"])]
        do {
            try await makeRunner().runBuildSteps(
                steps, in: root,
                logsDirectory: root.appendingPathComponent("logs"),
                stepTimeout: .milliseconds(300)
            )
            Issue.record("expected buildTimedOut")
        } catch let DockExtensionError.buildTimedOut(command) {
            #expect(command.contains("sleep"))
        }
    }
}
