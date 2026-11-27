import CMUXMobileCore
import CmuxWorkspacePresence
import Foundation

actor PresenceTestConnection: WorkspacePresenceConnection {
    nonisolated let views: AsyncStream<Bool>
    nonisolated let endEvents: AsyncStream<Void>
    private let viewContinuation: AsyncStream<Bool>.Continuation
    private let endContinuation: AsyncStream<Void>.Continuation
    private var frames: [WorkspacePresenceSnapshot] = []
    private var receiver: CheckedContinuation<WorkspacePresenceSnapshot, any Error>?
    private var ended = false

    init() {
        (views, viewContinuation) = AsyncStream.makeStream()
        (endEvents, endContinuation) = AsyncStream.makeStream()
    }

    func receive() async throws -> WorkspacePresenceSnapshot {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            if ended { throw URLError(.networkConnectionLost) }
            if !frames.isEmpty { return frames.removeFirst() }
            return try await withCheckedThrowingContinuation { receiver = $0 }
        } onCancel: {
            self.close()
        }
    }

    func sendViewing(_ active: Bool, revision: UInt64) async throws {
        if ended { throw URLError(.networkConnectionLost) }
        viewContinuation.yield(active)
    }

    func deliver(_ snapshot: WorkspacePresenceSnapshot) {
        if let receiver {
            self.receiver = nil
            receiver.resume(returning: snapshot)
        } else {
            frames.append(snapshot)
        }
    }

    func disconnect() {
        guard !ended else { return }
        ended = true
        receiver?.resume(throwing: URLError(.networkConnectionLost))
        receiver = nil
        viewContinuation.finish()
        endContinuation.yield(())
        endContinuation.finish()
    }

    var isEnded: Bool { ended }

    func waitUntilEnded() async {
        guard !ended else { return }
        for await _ in endEvents { return }
    }

    nonisolated func close() {
        Task { await disconnect() }
    }
}
