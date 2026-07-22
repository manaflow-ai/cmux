import CmuxFoundation
import Foundation

/// Coalesces raw PTY bytes into a cheap per-surface activity observation.
final class TerminalOutputActivityForwarder {
    typealias Handler = @MainActor @Sendable (UUID, UUID, Date) -> Void

    private static let minimumForwardInterval: Duration = .seconds(5)

    private let isEnabled: AtomicBooleanGate
    private let continuation: AsyncStream<Date>.Continuation
    private let forwardingTask: Task<Void, Never>
    private var lastForwardedAt: ContinuousClock.Instant?

    init(
        workspaceID: UUID,
        surfaceID: UUID,
        isEnabled: AtomicBooleanGate,
        handler: @escaping Handler = TerminalOutputActivityForwarder.forward
    ) {
        let (stream, continuation) = AsyncStream.makeStream(
            of: Date.self,
            bufferingPolicy: .bufferingNewest(1)
        )
        self.isEnabled = isEnabled
        self.continuation = continuation
        self.forwardingTask = Task { @MainActor in
            for await observedAt in stream {
                guard !Task.isCancelled else { return }
                handler(workspaceID, surfaceID, observedAt)
            }
        }
    }

    deinit {
        continuation.finish()
        forwardingTask.cancel()
    }

    func noteOutput(at now: ContinuousClock.Instant) {
        guard isEnabled.loadAcquire() else { return }
        if let lastForwardedAt,
           lastForwardedAt.duration(to: now) < Self.minimumForwardInterval {
            return
        }
        lastForwardedAt = now
        _ = continuation.yield(Date.now)
    }

    @MainActor
    static func forward(workspaceID: UUID, surfaceID: UUID, observedAt: Date) {
        guard let owner = AppDelegate.shared?.workspaceContainingPanel(
            panelId: surfaceID,
            preferredWorkspaceId: workspaceID
        ) else { return }
        owner.workspace.noteAgentStatusOutputActivity(panelId: surfaceID, observedAt: observedAt)
    }
}
