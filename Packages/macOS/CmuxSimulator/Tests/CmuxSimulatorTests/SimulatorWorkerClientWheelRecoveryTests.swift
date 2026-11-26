import Foundation
import Testing
@testable import CmuxSimulator

extension SimulatorWorkerClientTests {
    @Test("A failed correlated hardware button still sends a raw up")
    func interactiveButtonFailureRecovery() async throws {
        let launcher = TestWorkerLauncher()
        launcher.setResponder { message in
            switch message {
            case .attach: .status(.streaming)
            case let .ping(sequence): .ack(sequence)
            case let .interactiveAction(requestID, _):
                .interactiveAction(requestID: requestID, succeeded: false)
            default: nil
            }
        }
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let worker = try #require(launcher.endpoint(at: 0))

        await #expect(throws: SimulatorControlError.self) {
            try await client.perform(.interactive(.hardwareButton(.volumeUp)))
        }

        let release = SimulatorWorkerInbound.hidButton(.init(
            button: .init(page: 0x0C, usage: 0xE9),
            phase: .up
        ))
        for _ in 0..<1_000 {
            if worker.inboundMessages().contains(release) { break }
            await Task.yield()
        }
        #expect(worker.inboundMessages().contains(release))
        await client.stop()
    }

    @Test("Crash during correlated hardware button replays a raw up")
    func interactiveButtonCrashRecovery() async throws {
        let launcher = TestWorkerLauncher()
        launcher.setResponder { message in
            switch message {
            case .attach: .status(.streaming)
            case let .ping(sequence): .ack(sequence)
            default: nil
            }
        }
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let first = try #require(launcher.endpoint(at: 0))
        let task = Task {
            try await client.perform(.interactive(.hardwareButton(.volumeUp)))
        }
        try await awaitWheelInboundInteractive(first)
        first.finish()
        _ = await task.result

        let second = try await wheelReplacementEndpoint(launcher)
        let release = SimulatorWorkerInbound.hidButton(.init(
            button: .init(page: 0x0C, usage: 0xE9),
            phase: .up
        ))
        second.emit(.status(.streaming))
        for _ in 0..<1_000 {
            if second.inboundMessages().contains(release) { break }
            await Task.yield()
        }
        #expect(second.inboundMessages().contains(release))
        await client.stop()
    }

    @Test("Wheel completion clears only its burst and a crash replays an unfinished cancellation")
    func scrollWheelCrashRecovery() async throws {
        let launcher = TestWorkerLauncher()
        launcher.setResponder { message in
            switch message {
            case .attach: .status(.streaming)
            case let .ping(sequence): .ack(sequence)
            default: nil
            }
        }
        let client = makeClient(launcher: launcher)
        await client.send(.attach(udid: "DEVICE", geometry: nil))
        let firstWorker = try #require(launcher.endpoint(at: 0))
        let first = SimulatorScrollWheelEvent(
            anchor: SimulatorPoint(x: 0.5, y: 0.5),
            deltaX: 0,
            deltaY: 0.1
        )
        await client.send(.scrollWheel(first))
        for _ in 0..<1_000 {
            if await client.activeScrollIdentifier == first.id { break }
            await Task.yield()
        }
        firstWorker.emit(.scrollWheelEnded(eventID: first.id))
        for _ in 0..<1_000 {
            if await client.activeScrollIdentifier == nil { break }
            await Task.yield()
        }
        #expect(await client.activeScrollIdentifier == nil)

        let second = SimulatorScrollWheelEvent(
            anchor: SimulatorPoint(x: 0.4, y: 0.4),
            deltaX: 0.05,
            deltaY: 0.1
        )
        await client.send(.scrollWheel(second))
        for _ in 0..<1_000 {
            if await client.activeScrollIdentifier == second.id { break }
            await Task.yield()
        }
        let events = await client.subscribe()
        var iterator = events.makeAsyncIterator()
        #expect(await iterator.next() == .message(.status(.streaming)))
        firstWorker.finish()
        while await iterator.next() != .workerStopped {}
        let replacement = try await wheelReplacementEndpoint(launcher)
        let expectedCancellation = SimulatorWorkerInbound.pointer(.init(
            phase: .cancelled,
            primary: SimulatorPoint(x: 0.45, y: 0.5)
        ))
        for _ in 0..<1_000 {
            if replacement.inboundMessages().contains(expectedCancellation) { break }
            await Task.yield()
        }
        #expect(replacement.inboundMessages().contains(expectedCancellation))
        await client.stop()
    }

    private func wheelReplacementEndpoint(
        _ launcher: TestWorkerLauncher
    ) async throws -> TestWorkerEndpoint {
        for _ in 0..<1_000 {
            if let endpoint = launcher.endpoint(at: 1) { return endpoint }
            await Task.yield()
        }
        throw SimulatorControlError(
            code: "missing_replacement",
            arguments: [],
            message: "The replacement test worker did not launch."
        )
    }

    private func awaitWheelInboundInteractive(_ endpoint: TestWorkerEndpoint) async throws {
        for _ in 0..<1_000 {
            if endpoint.inboundMessages().contains(where: {
                if case .interactiveAction = $0 { true } else { false }
            }) { return }
            await Task.yield()
        }
        throw SimulatorControlError(
            code: "missing_interactive",
            arguments: [],
            message: "The interactive test action was not sent."
        )
    }
}
