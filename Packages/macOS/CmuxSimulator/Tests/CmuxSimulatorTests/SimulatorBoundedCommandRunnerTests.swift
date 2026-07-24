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

    @Test("Concurrent captures retain their pipe readers until every child exits")
    func concurrentCaptureReaderLifetime() async {
        let results = await withTaskGroup(
            of: SimulatorBoundedCommandResult.self,
            returning: [SimulatorBoundedCommandResult].self
        ) { group in
            for _ in 0..<32 {
                group.addTask {
                    await SimulatorBoundedCommandRunner().runBounded(
                        directory: FileManager.default.currentDirectoryPath,
                        executable: "/bin/sh",
                        arguments: [
                            "-c",
                            "dd if=/dev/zero bs=65536 count=4 2>/dev/null; dd if=/dev/zero bs=65536 count=4 1>&2 2>/dev/null",
                        ],
                        timeout: 5,
                        standardOutputLimit: 1_024,
                        standardErrorLimit: 512
                    )
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }

        #expect(results.count == 32)
        #expect(results.allSatisfy { $0.exitStatus == 0 })
        #expect(results.allSatisfy { $0.standardOutput.count == 1_024 })
        #expect(results.allSatisfy { $0.standardError.count == 512 })
        #expect(results.allSatisfy { $0.outputWasTruncated })
        #expect(results.allSatisfy { $0.errorWasTruncated })
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

    @Test("Timeout returns only after its command process has exited")
    func timeoutWaitsForProcessExit() async throws {
        let processIdentifier = ProcessIdentifierRecorder()
        let runner = SimulatorBoundedCommandRunner(
            terminationGrace: .seconds(30),
            sleeper: ImmediateBoundedCommandSleeper(),
            didRunProcess: { processIdentifier.record($0) }
        )

        let result = await runner.runBounded(
            directory: FileManager.default.currentDirectoryPath,
            executable: "/bin/sh",
            arguments: ["-c", "trap '' TERM; while :; do :; done"],
            timeout: 5,
            standardOutputLimit: 1_024,
            standardErrorLimit: 1_024
        )

        #expect(result.timedOut)
        let pid = try #require(processIdentifier.value)
        #expect(Darwin.kill(pid, 0) != 0)
        #expect(errno == ESRCH)
    }

    @Test("The public runner bounds timeout and kills descendants")
    func publicRunnerOwnsTimedOutDescendants() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-owned-command-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let result = await SimulatorOwnedCommandRunner().run(
            executable: "/bin/sh",
            arguments: [
                "-c",
                "(trap '' TERM; while :; do :; done) & echo $! > '\(marker.path)'; wait",
            ],
            currentDirectory: FileManager.default.currentDirectoryPath,
            timeout: 0.05
        )

        #expect(result.timedOut)
        #expect(result.status == 124)
        let descendant = try await requireMarkerPID(marker)
        await expectProcessExited(descendant)
        #expect(Darwin.kill(descendant, 0) != 0)
        #expect(errno == ESRCH)
    }

    @Test("The owned command runner delegates asynchronously to its injected process runner")
    func ownedCommandRunnerIsInjectable() async throws {
        let boundedResult = SimulatorBoundedCommandResult(
            standardOutput: Data(),
            standardError: Data("injected diagnostic".utf8),
            outputWasTruncated: false,
            errorWasTruncated: false,
            exitStatus: 17,
            timedOut: false,
            executionError: nil
        )
        let boundedRunner = RecordingSimulatorBoundedCommandRunner(
            result: boundedResult
        )
        let runner = SimulatorOwnedCommandRunner(
            boundedCommands: boundedRunner
        )

        let result = await runner.run(
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list"],
            currentDirectory: "/tmp/injected",
            timeout: 7,
            outputLimit: 321
        )
        let request = try #require(await boundedRunner.request)

        #expect(result == SimulatorOwnedCommandResult(
            status: 17,
            standardError: "injected diagnostic",
            timedOut: false
        ))
        #expect(request == SimulatorBoundedCommandRequest(
            directory: "/tmp/injected",
            executable: "/usr/bin/xcrun",
            arguments: ["simctl", "list"],
            environment: [:],
            timeout: 7,
            standardOutputLimit: 321,
            standardErrorLimit: 321
        ))
    }
}

private struct SimulatorBoundedCommandRequest: Sendable, Equatable {
    let directory: String
    let executable: String
    let arguments: [String]
    let environment: [String: String]
    let timeout: TimeInterval?
    let standardOutputLimit: Int
    let standardErrorLimit: Int
}

private actor RecordingSimulatorBoundedCommandRunner:
    SimulatorBoundedCommandRunning
{
    let result: SimulatorBoundedCommandResult
    private(set) var request: SimulatorBoundedCommandRequest?

    init(result: SimulatorBoundedCommandResult) {
        self.result = result
    }

    func runBounded(
        directory: String,
        executable: String,
        arguments: [String],
        environment: [String: String],
        timeout: TimeInterval?,
        standardOutputLimit: Int,
        standardErrorLimit: Int
    ) async -> SimulatorBoundedCommandResult {
        request = SimulatorBoundedCommandRequest(
            directory: directory,
            executable: executable,
            arguments: arguments,
            environment: environment,
            timeout: timeout,
            standardOutputLimit: standardOutputLimit,
            standardErrorLimit: standardErrorLimit
        )
        return result
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
