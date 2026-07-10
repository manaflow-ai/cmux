import Darwin
import Foundation
import Testing
@testable import CmuxSimulator

@Suite("Simulator bounded command runner")
struct SimulatorBoundedCommandRunnerTests {
    @Test("Capture drains overflow but retains only its byte ceilings")
    func boundedProcessCapture() async {
        let runner = SimulatorBoundedCommandRunner()
        let script = """
        i=0
        while [ $i -lt 4096 ]; do printf 0123456789abcdef; i=$((i + 1)); done
        i=0
        while [ $i -lt 4096 ]; do printf fedcba9876543210 >&2; i=$((i + 1)); done
        """

        let result = await runner.runBounded(
            directory: FileManager.default.currentDirectoryPath,
            executable: "/bin/sh",
            arguments: ["-c", script],
            timeout: 5,
            standardOutputLimit: 1_024,
            standardErrorLimit: 512
        )

        #expect(result.exitStatus == 0)
        #expect(result.standardOutput.count == 1_024)
        #expect(result.standardError.count == 512)
        #expect(result.outputWasTruncated)
        #expect(result.errorWasTruncated)
    }

    @Test("Cancellation terminates a child launched in the cancellation race")
    func boundedProcessCancellation() async throws {
        let gate = BoundedLaunchRaceGate()
        let processIdentifier = ProcessIdentifierRecorder()
        let runner = SimulatorBoundedCommandRunner(
            terminationGrace: .seconds(30),
            sleeper: ImmediateBoundedCommandSleeper(),
            beforeProcessRun: { gate.pause() },
            didRunProcess: { processIdentifier.record($0) }
        )
        let task = Task {
            await runner.runBounded(
                directory: FileManager.default.currentDirectoryPath,
                executable: "/bin/sh",
                arguments: ["-c", "trap '' TERM; while :; do :; done"],
                timeout: nil,
                standardOutputLimit: 1_024,
                standardErrorLimit: 1_024
            )
        }
        gate.waitUntilPaused()
        task.cancel()
        gate.resume()
        let result = await task.value
        #expect(result.executionError?.contains("cancelled") == true)
        let pid = try #require(processIdentifier.value)
        await expectProcessExited(pid)
    }

    @Test("Cancellation terminates descendants in the command process group")
    func boundedProcessCancellationTerminatesDescendants() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-bounded-descendant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let runner = SimulatorBoundedCommandRunner(
            terminationGrace: .seconds(30),
            sleeper: ImmediateBoundedCommandSleeper()
        )
        let task = Task {
            await runner.runBounded(
                directory: FileManager.default.currentDirectoryPath,
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' TERM; /bin/sh -c 'trap \"\" TERM; while :; do :; done' & echo $! > '\(marker.path)'; while :; do :; done",
                ],
                timeout: nil,
                standardOutputLimit: 1_024,
                standardErrorLimit: 1_024
            )
        }
        defer { task.cancel() }
        let descendant = try await requireMarkerPID(marker)

        task.cancel()
        let result = await task.value

        #expect(result.executionError?.contains("cancelled") == true)
        await expectProcessExited(descendant)
    }

    @Test("Negative output limits return an error without launching")
    func rejectsNegativeOutputLimits() async {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-negative-limit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let result = await SimulatorBoundedCommandRunner().runBounded(
            directory: FileManager.default.currentDirectoryPath,
            executable: "/usr/bin/touch",
            arguments: [marker.path],
            timeout: 5,
            standardOutputLimit: -1,
            standardErrorLimit: 1
        )
        #expect(result.executionError?.contains("nonnegative") == true)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }
}

private func requireMarkerPID(_ marker: URL) async throws -> Int32 {
    for _ in 0..<2_000 {
        if let value = try? String(contentsOf: marker, encoding: .utf8),
           let processIdentifier = Int32(value.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return processIdentifier
        }
        try await ContinuousClock().sleep(for: .milliseconds(1))
    }
    Issue.record("Command did not publish its descendant PID")
    throw CancellationError()
}

private func expectProcessExited(_ processIdentifier: Int32) async {
    for _ in 0..<2_000 {
        if Darwin.kill(processIdentifier, 0) != 0, errno == ESRCH { return }
        try? await ContinuousClock().sleep(for: .milliseconds(1))
    }
    _ = Darwin.kill(processIdentifier, SIGKILL)
    Issue.record("Descendant process \(processIdentifier) survived group cleanup")
}

private struct ImmediateBoundedCommandSleeper: SimulatorWorkerSleeping {
    func sleep(for duration: Duration) async throws {}
}

private final class BoundedLaunchRaceGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var paused = false
    private var released = false

    func pause() {
        condition.lock()
        paused = true
        condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
    }

    func waitUntilPaused() {
        condition.lock()
        while !paused { condition.wait() }
        condition.unlock()
    }

    func resume() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class ProcessIdentifierRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var processIdentifier: Int32?

    var value: Int32? { lock.withLock { processIdentifier } }

    func record(_ processIdentifier: Int32) {
        lock.withLock { self.processIdentifier = processIdentifier }
    }
}
