#if DEBUG
public import Foundation
public import CmuxMobileShell
public import CmuxMobileShellModel

/// Owns one mounted terminal consumer throughout a soak. A command must not
/// remount its terminal and download the entire scrollback again. Switching
/// surfaces and the soak's explicit reconnect still create a fresh consumer.
@MainActor
public final class MobileIrohReleaseGateTerminalSession {
    private static let verificationTimeout: Duration = .seconds(15)
    private enum State: Sendable {
        case idle
        case reading(surface: String, owner: UUID, task: Task<Void, Never>)
        case ended(surface: String)
    }
    private struct Pending {
        let id: UUID
        var probe: MobileIrohReleaseGateTerminalProbe
        let completion: AsyncStream<Void>.Continuation
    }
    private struct ClientBox: @unchecked Sendable {
        let value: any MobileIrohReleaseGateTerminalClient
    }
    private let client: any MobileIrohReleaseGateTerminalClient
    private var state = State.idle
    private var pending: Pending?

    /// Creates a session backed by the mounted terminal client.
    public init(client: any MobileIrohReleaseGateTerminalClient) { self.client = client }

    deinit {
        if case let .reading(_, _, task) = state { task.cancel() }
    }

    /// Cancels the current reader and releases its output ownership.
    public func reset() {
        let previous = state
        state = .idle
        pending?.completion.finish()
        pending = nil
        if case let .reading(surface, owner, task) = previous {
            client.clearTerminalOutputConsumerOwner(surfaceID: surface, ownerID: owner)
            task.cancel()
        }
    }

    /// Writes a marker and waits for it through the one owned output reader.
    public func verify(surfaceID: String, marker: String) async throws {
        try Task.checkCancellation()
        guard pending == nil else { throw MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed }
        try ensureReader(surfaceID: surfaceID)
        let id = UUID()
        let probe = MobileIrohReleaseGateTerminalProbe(marker: marker)
        let (proof, completion) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingOldest(1))
        pending = Pending(id: id, probe: probe, completion: completion)
        defer {
            if Task.isCancelled { reset() }
            else if pending?.id == id { pending = nil }
            completion.finish()
        }
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                let client = ClientBox(value: self.client)
                let command = probe.command
                let submitTask = Task { @MainActor in
                    await client.value.submitTerminalRawInput(command, surfaceID: surfaceID)
                }
                defer { submitTask.cancel() }
                group.addTask {
                    try await withTaskCancellationHandler {
                        await submitTask.value
                        try Task.checkCancellation()
                        for try await _ in proof {
                            try Task.checkCancellation()
                            return
                        }
                        // A cancelled iteration ends the stream with nil, so
                        // cancellation must win over a round-trip failure.
                        try Task.checkCancellation()
                        throw MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed
                    } onCancel: {
                        submitTask.cancel()
                    }
                }
                group.addTask {
                    try await ContinuousClock().sleep(for: Self.verificationTimeout)
                    throw MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed
                }
                try await group.next()
                group.cancelAll()
            }
        } catch {
            reset()
            throw error
        }
    }

    private func ensureReader(surfaceID: String) throws {
        switch state {
        case let .reading(surface, owner, _) where surface == surfaceID:
            guard client.isTerminalOutputConsumerOwner(surfaceID: surface, ownerID: owner) else {
                throw MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed
            }
            return
        case let .ended(surface) where surface == surfaceID:
            throw MobileIrohReleaseGateProbeFailure.terminalRoundTripFailed
        case .reading, .ended:
            reset()
        case .idle:
            break
        }
        let owner = UUID()
        let stream = client.terminalOutputStream(surfaceID: surfaceID, ownerID: owner)
        let client = self.client
        let reader = Task { @MainActor [weak self, client] in
            defer { client.clearTerminalOutputConsumerOwner(surfaceID: surfaceID, ownerID: owner) }
            for await chunk in stream {
                guard !Task.isCancelled,
                      self?.receive(chunk, surfaceID: surfaceID, owner: owner) == true else { break }
            }
            self?.readerEnded(surfaceID: surfaceID, owner: owner)
        }
        state = .reading(surface: surfaceID, owner: owner, task: reader)
    }

    private func receive(_ chunk: MobileTerminalOutputChunk, surfaceID: String, owner: UUID) -> Bool {
        guard case let .reading(surface, currentOwner, _) = state,
              surface == surfaceID, currentOwner == owner,
              client.isTerminalOutputConsumerOwner(surfaceID: surfaceID, ownerID: owner) else { return false }
        // Drain and acknowledge idle output too, as a mounted renderer does.
        client.terminalOutputDidProcess(surfaceID: surfaceID, streamToken: chunk.streamToken)
        guard var waiting = pending else { return true }
        if waiting.probe.consume(chunk) {
            pending = nil
            waiting.completion.yield(())
            waiting.completion.finish()
        } else {
            pending = waiting
        }
        return true
    }

    private func readerEnded(surfaceID: String, owner: UUID) {
        guard case let .reading(surface, currentOwner, _) = state,
              surface == surfaceID, currentOwner == owner else { return }
        state = .ended(surface: surfaceID)
        client.clearTerminalOutputConsumerOwner(surfaceID: surfaceID, ownerID: owner)
        pending?.completion.finish()
        pending = nil
    }
}
#endif
