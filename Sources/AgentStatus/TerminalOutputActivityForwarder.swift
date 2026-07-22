import Foundation

/// Coalesces raw PTY bytes into a cheap per-surface activity observation.
final class TerminalOutputActivityForwarder {
    private static let minimumForwardInterval: Duration = .seconds(5)

    private let workspaceID: UUID
    private let surfaceID: UUID
    private var lastForwardedAt: ContinuousClock.Instant?

    init(workspaceID: UUID, surfaceID: UUID) {
        self.workspaceID = workspaceID
        self.surfaceID = surfaceID
    }

    func noteOutput(at now: ContinuousClock.Instant) {
        if let lastForwardedAt,
           lastForwardedAt.duration(to: now) < Self.minimumForwardInterval {
            return
        }
        lastForwardedAt = now
        let workspaceID = workspaceID
        let surfaceID = surfaceID
        let observedAt = Date.now
        Task { @MainActor in
            guard let owner = AppDelegate.shared?.workspaceContainingPanel(
                panelId: surfaceID,
                preferredWorkspaceId: workspaceID
            ) else { return }
            owner.workspace.noteAgentStatusOutputActivity(
                panelId: surfaceID,
                observedAt: observedAt
            )
        }
    }
}
