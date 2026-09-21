import Foundation

extension AppDelegate {
    /// Composes a read-only query over owners already running in this app.
    @MainActor
    func currentWorkQueryService() -> CurrentWorkQueryService {
        CurrentWorkQueryService(
            catalog: .shared,
            workspaceOwners: { [weak self] in self?.workspacesForRead(tabIds: $0) ?? [:] },
            agentRecords: { TerminalController.shared.agentChatTranscriptService?.sessionRecords(workspaceID: nil) },
            unread: { TerminalNotificationStore.shared.sidebarUnread.snapshot },
            unreadSurfaces: { TerminalNotificationStore.shared.sidebarUnread.unreadSurfaceKeys }
        )
    }
}
