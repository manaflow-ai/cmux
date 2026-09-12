import CmuxTerminal
import Foundation

/// Adapts synchronous Ghostty callbacks to complete main-actor pointer snapshots.
final class GhosttyPointerStyleIngress: Sendable {
    let mailbox: TerminalPointerStyleMailbox
    private let consumerTask: Task<Void, Never>

    init(surfaceView: GhosttyNSView) {
        let mailbox = TerminalPointerStyleMailbox()
        self.mailbox = mailbox
        consumerTask = Task { @MainActor [weak surfaceView] in
            for await _ in mailbox.updates {
                guard let surfaceView else { return }
                let snapshot = mailbox.snapshot
                guard surfaceView.terminalSurface?.id == snapshot.surfaceId else { continue }
                surfaceView.applyTerminalPointerStyleSnapshot(snapshot)
            }
        }
    }

    deinit {
        mailbox.finish()
        consumerTask.cancel()
    }

    @discardableResult
    func activate(runtimeLifetimeId: UUID, surfaceId: UUID) -> UInt64 {
        mailbox.activate(lifetimeId: runtimeLifetimeId, surfaceId: surfaceId)
    }

    @discardableResult
    func submit(_ request: GhosttyPointerStyleIngressRequest) -> Bool {
        mailbox.submit(
            request.event.terminalEvent(runtimeLifetimeId: request.runtimeLifetimeId),
            surfaceId: request.surfaceId,
            lifetimeId: request.runtimeLifetimeId,
            generation: request.runtimeGeneration
        )
    }
}
