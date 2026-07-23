import CMUXAgentLaunch
import Foundation

extension FeedCoordinator {
    /// Reconciles a surface-scoped Feed event with the app's live ownership map.
    ///
    /// This runs on the main actor immediately before store insertion, making
    /// pane movement and Feed ownership one serialized decision. Exact UUID
    /// claims arrive without a redundant CLI preflight; legacy handles are
    /// resolved before the Feed request because the wire event carries UUIDs.
    @MainActor
    func eventRehomedToLiveSurface(_ event: WorkstreamEvent) -> WorkstreamEvent? {
        eventsRehomedToLiveSurface([event])?.first
    }

    /// Resolves one shared live owner for a same-surface Feed batch.
    @MainActor
    func eventsRehomedToLiveSurface(_ events: [WorkstreamEvent]) -> [WorkstreamEvent]? {
        guard let first = events.first else { return [] }
        guard let claimedSurfaceId = first.surfaceId else {
            return events.allSatisfy { $0.surfaceId == nil } ? events : nil
        }
        guard let surfaceId = normalizedUUID(claimedSurfaceId),
              events.allSatisfy({ $0.surfaceId.flatMap(normalizedUUID) == surfaceId }),
              let owner = AppDelegate.shared?.workspaceContainingPanel(
                  panelId: surfaceId,
                  preferredWorkspaceId: first.workspaceId.flatMap(normalizedUUID)
              )
        else { return nil }

        return events.map {
            event(
                $0,
                rehomedToWorkspaceId: owner.workspace.id.uuidString,
                surfaceId: surfaceId.uuidString
            )
        }
    }

    private func event(
        _ event: WorkstreamEvent,
        rehomedToWorkspaceId workspaceId: String,
        surfaceId: String
    ) -> WorkstreamEvent {
        return WorkstreamEvent(
            sessionId: event.sessionId,
            hookEventName: event.hookEventName,
            source: event.source,
            workspaceId: workspaceId,
            surfaceId: surfaceId,
            transcriptPath: event.transcriptPath,
            cwd: event.cwd,
            toolName: event.toolName,
            toolInputJSON: event.toolInputJSON,
            isError: event.isError,
            context: event.context,
            requestId: event.requestId,
            ppid: event.ppid,
            receivedAt: event.receivedAt,
            extraFieldsJSON: event.extraFieldsJSON
        )
    }

    private func normalizedUUID(_ rawValue: String) -> UUID? {
        UUID(uuidString: rawValue.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
