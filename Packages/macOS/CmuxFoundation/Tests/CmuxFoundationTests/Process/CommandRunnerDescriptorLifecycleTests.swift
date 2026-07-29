import Darwin
import Foundation
import Testing

@testable import CmuxFoundation

@Suite("CommandRunner descriptor lifecycle", .serialized)
struct CommandRunnerDescriptorLifecycleTests {
    private let runner = CommandRunner()
    private let tempDirectory = FileManager.default.temporaryDirectory

    @Test("Capture pipes are close-on-exec and close before success returns")
    func capturePipesAreCloseOnExecAndCloseAfterSuccess() async throws {
        let baseline = openPipeDescriptors()
        let marker = uniqueTemporaryFile(named: "started")
        defer { try? FileManager.default.removeItem(at: marker) }

        let command = Task {
            await runner.run(
                directory: tempDirectory.path,
                executable: "sh",
                arguments: ["-c", "printf started > \"$1\"; sleep 1", "cmux-test", marker.path],
                timeout: 5
            )
        }

        try await waitForFile(at: marker)
        let captureDescriptors = openPipeDescriptors().subtracting(baseline)
        #expect(
            captureDescriptors.count >= 2,
            "Expected CommandRunner's live stdout and stderr capture pipes"
        )
        for descriptor in captureDescriptors {
            let flags = fcntl(descriptor, F_GETFD)
            #expect(flags != -1)
            #expect(
                flags & FD_CLOEXEC != 0,
                "CommandRunner pipe descriptor \(descriptor) can leak into unrelated child processes"
            )
        }

        let result = await command.value
        #expect(result.exitStatus == 0)
        let retained = openPipeDescriptors().subtracting(baseline)
        #expect(
            retained.isEmpty,
            "CommandRunner retained pipe descriptors after success: \(retained.sorted())"
        )
    }

    @Test("Task cancellation terminates the child and closes capture pipes")
    func cancellationTerminatesAndClosesPipes() async throws {
        let baseline = openPipeDescriptors()
        let pidFile = uniqueTemporaryFile(named: "pid")
        defer { try? FileManager.default.removeItem(at: pidFile) }

        let command = Task {
            await runner.run(
                directory: tempDirectory.path,
                executable: "sh",
                arguments: ["-c", "printf %s $$ > \"$1\"; exec sleep 30", "cmux-test", pidFile.path],
                timeout: 2
            )
        }

        try await waitForFile(at: pidFile)
        let pidText = try String(contentsOf: pidFile, encoding: .utf8)
        let pid = try #require(pid_t(pidText))
        command.cancel()

        let result = await command.value
        #expect(result.timedOut == false)
        #expect(result.executionError != nil)
        #expect(kill(pid, 0) == -1 && errno == ESRCH)

        let retained = openPipeDescriptors().subtracting(baseline)
        #expect(
            retained.isEmpty,
            "CommandRunner retained pipe descriptors after cancellation: \(retained.sorted())"
        )
    }

    private func uniqueTemporaryFile(named suffix: String) -> URL {
        tempDirectory.appendingPathComponent(
            "cmux-command-runner-\(UUID().uuidString)-\(suffix)",
            isDirectory: false
        )
    }

    private func waitForFile(at url: URL) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !FileManager.default.fileExists(atPath: url.path) {
            guard clock.now < deadline else {
                throw DescriptorLifecycleTestError.markerTimedOut
            }
            try await clock.sleep(for: .milliseconds(10))
        }
    }

    private func openPipeDescriptors() -> Set<Int32> {
        var descriptors: Set<Int32> = []
        for descriptor in 0..<getdtablesize() {
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0,
                  metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFIFO) else {
                continue
            }
            descriptors.insert(descriptor)
        }
        return descriptors
    }

    private enum DescriptorLifecycleTestError: Error {
        case markerTimedOut
    }
}
