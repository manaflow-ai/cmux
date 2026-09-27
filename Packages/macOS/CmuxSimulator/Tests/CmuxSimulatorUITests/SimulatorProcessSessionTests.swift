import CmuxSimulator
import Darwin
import Foundation
import Testing
@testable import CmuxSimulatorUI

@Suite("Simulator process session")
@MainActor
struct SimulatorProcessSessionTests {
    @Test("Closing the parent pipe writer delivers output through EOF")
    func closesParentPipeWriter() async throws {
        let output = ProcessOutputRecorder()
        var didTerminate = false
        let session = SimulatorProcessSession()

        try session.start(
            SimulatorCommandDescriptor(
                executable: "/bin/sh",
                arguments: ["-c", "printf 'first\\nsecond\\n'"]
            ),
            capturesOutput: true,
            onOutput: { await output.append($0) },
            onTermination: { didTerminate = true }
        )

        await eventually { didTerminate }

        #expect(await output.snapshot() == "first\nsecond\n")
        #expect(session.isRunning == false)
    }

    @Test("A process that ignores interrupt is terminated after the injected deadline")
    func escalatesAfterInterruptDeadline() async throws {
        let sleeper = ImmediateProcessSleeper()
        let output = ProcessOutputRecorder()
        var didTerminate = false
        let session = SimulatorProcessSession(
            sleeper: sleeper,
            interruptGracePeriod: .seconds(30),
            terminationGracePeriod: .seconds(30)
        )

        try session.start(
            SimulatorCommandDescriptor(
                executable: "/bin/sh",
                arguments: ["-c", "trap '' INT; printf 'ready\\n'; while :; do :; done"]
            ),
            capturesOutput: true,
            onOutput: { await output.append($0) },
            onTermination: { didTerminate = true }
        )
        await eventuallyAsync { await output.snapshot() == "ready\n" }

        await session.stopAndWait()
        #expect(didTerminate)

        #expect(await sleeper.callCount > 0)
        #expect(session.isRunning == false)
    }

    @Test("Stopping a session terminates its descendant process group")
    func stopTerminatesDescendants() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-simulator-session-descendant-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        var didTerminate = false
        let session = SimulatorProcessSession(
            sleeper: ImmediateProcessSleeper(),
            interruptGracePeriod: .seconds(30),
            terminationGracePeriod: .seconds(30)
        )
        try session.start(
            SimulatorCommandDescriptor(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' INT TERM; /bin/sh -c 'trap \"\" INT TERM; while :; do :; done' & echo $! > '\(marker.path)'; while :; do :; done",
                ]
            ),
            capturesOutput: false,
            onOutput: { _ in },
            onTermination: { didTerminate = true }
        )
        let descendant = try await requireMarkerPID(marker)

        await session.stopAndWait()
        #expect(didTerminate)

        await expectProcessExited(descendant)
        #expect(session.isRunning == false)
    }

    @Test("Canceling a stop waiter does not cancel process escalation")
    func cancelledStopWaiterStillEscalates() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-simulator-session-waiter-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let sleeper = ManuallyAdvancingProcessSleeper()
        var didTerminate = false
        let session = SimulatorProcessSession(
            sleeper: sleeper,
            interruptGracePeriod: .seconds(30),
            terminationGracePeriod: .seconds(30)
        )
        try session.start(
            SimulatorCommandDescriptor(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' INT TERM; echo $$ > '\(marker.path)'; while :; do :; done",
                ]
            ),
            capturesOutput: false,
            onOutput: { _ in },
            onTermination: { didTerminate = true }
        )
        _ = try await requireMarkerPID(marker)

        let stopTask = Task { await session.stopAndWait() }
        await sleeper.waitForCallCount(1)
        stopTask.cancel()
        await sleeper.advance()
        await sleeper.waitForCallCount(2)
        await sleeper.advance()
        await stopTask.value
        #expect(didTerminate)

        #expect(session.isRunning == false)
    }

    @Test("A finished wait stream without an event is cancellation")
    func finishedWaitStreamIsCancellation() async {
        let (stream, continuation) = AsyncStream.makeStream(of: Void.self)
        continuation.finish()

        let result = await waitForSimulatorProcessTermination(
            events: stream,
            sleeper: CancellableProcessSleeper(),
            for: .seconds(30)
        )

        #expect(result == .cancelled)
    }

    @Test("Dropping a session force-kills a child that ignores interrupt and terminate")
    func deinitEscalatesToKill() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-simulator-session-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        var session: SimulatorProcessSession? = SimulatorProcessSession(
            sleeper: ImmediateProcessSleeper(),
            interruptGracePeriod: .seconds(30),
            terminationGracePeriod: .seconds(30)
        )
        try session?.start(
            SimulatorCommandDescriptor(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' INT TERM; printf '%s' $$ > '\(marker.path)'; while :; do :; done",
                ]
            ),
            capturesOutput: false,
            onOutput: { _ in },
            onTermination: {}
        )
        var rawPID = ""
        await eventually {
            rawPID = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            return Int32(rawPID) != nil
        }
        let processIdentifier = try #require(Int32(rawPID))

        session = nil
        await eventually { Darwin.kill(processIdentifier, 0) != 0 && errno == ESRCH }

        #expect(Darwin.kill(processIdentifier, 0) != 0)
        _ = session
    }

    @Test("Process termination cancels a stored escalation deadline")
    func terminationCancelsEscalationDeadline() async throws {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-simulator-session-cancel-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        let sleeper = CancellableProcessSleeper()
        var didTerminate = false
        let session = SimulatorProcessSession(
            sleeper: sleeper,
            interruptGracePeriod: .seconds(30),
            terminationGracePeriod: .seconds(30)
        )
        try session.start(
            SimulatorCommandDescriptor(
                executable: "/bin/sh",
                arguments: [
                    "-c",
                    "trap '' INT TERM; printf '%s' $$ > '\(marker.path)'; while :; do :; done",
                ]
            ),
            capturesOutput: false,
            onOutput: { _ in },
            onTermination: { didTerminate = true }
        )
        var rawPID = ""
        await eventually {
            rawPID = (try? String(contentsOf: marker, encoding: .utf8)) ?? ""
            return Int32(rawPID) != nil
        }
        let processIdentifier = try #require(Int32(rawPID))

        session.stop()
        for _ in 0..<100 {
            if await sleeper.hasStarted { break }
            await Task.yield()
        }
        _ = Darwin.kill(processIdentifier, SIGKILL)
        await eventually { didTerminate }
        for _ in 0..<100 {
            if await sleeper.wasCancelled { break }
            await Task.yield()
        }

        #expect(await sleeper.wasCancelled)
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
    Issue.record("Process did not publish its PID")
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

private func eventuallyAsync(
    attempts: Int = 2_000,
    _ condition: @escaping @Sendable () async -> Bool
) async {
    for _ in 0..<attempts {
        if await condition() { return }
        try? await ContinuousClock().sleep(for: .milliseconds(1))
    }
    Issue.record("Condition did not become true")
}

@MainActor
private func eventually(
    attempts: Int = 20_000,
    _ condition: @escaping @MainActor () -> Bool
) async {
    for _ in 0..<attempts {
        if condition() { return }
        await Task.yield()
    }
    Issue.record("Condition did not become true")
}
