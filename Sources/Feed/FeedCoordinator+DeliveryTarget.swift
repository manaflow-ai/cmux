import CMUXAgentLaunch
import Foundation

extension FeedCoordinator {
    /// Reconciles a surface-scoped Feed event with the app's live ownership map.
    ///
    /// This runs on the main actor immediately before store insertion, making
    /// pane movement and Feed ownership one serialized decision. The CLI's
    /// earlier resolution remains a useful fail-fast check, but it cannot be
    /// authoritative after the socket round-trip.
    @MainActor
    func eventRehomedToLiveSurface(_ event: WorkstreamEvent) -> WorkstreamEvent {
        guard let rawSurfaceId = event.surfaceId?.trimmingCharacters(in: .whitespacesAndNewlines),
              let surfaceId = UUID(uuidString: rawSurfaceId),
              let owner = AppDelegate.shared?.workspaceContainingPanel(
                  panelId: surfaceId,
                  preferredWorkspaceId: event.workspaceId.flatMap(UUID.init(uuidString:))
              )
        else {
            return event
        }

        return WorkstreamEvent(
            sessionId: event.sessionId,
            hookEventName: event.hookEventName,
            source: event.source,
            workspaceId: owner.workspace.id.uuidString,
            surfaceId: surfaceId.uuidString,
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
}
