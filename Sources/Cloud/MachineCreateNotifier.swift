import Foundation

/// Delivers actionable failure and fallback success notices through the app's
/// notification store. A success that selected its workspace never reaches it.
struct MachineCreateNotifier {
    @MainActor
    func post(_ notice: MachineCreateNotice) {
        guard let appDelegate = AppDelegate.shared else { return }
        let anchorTabID: UUID?
        if let workspaceID = notice.workspaceID, appDelegate.tabManagerFor(tabId: workspaceID) != nil {
            anchorTabID = workspaceID
        } else {
            anchorTabID = appDelegate.activeTabManagerForCommands(preferredWindow: nil)?.selectedTabId
        }
        guard let anchorTabID else { return }
        TerminalNotificationStore.shared.addNotification(
            tabId: anchorTabID,
            surfaceId: nil,
            title: notice.title,
            subtitle: notice.subtitle,
            body: notice.body,
            retargetsToLiveSurfaceOwner: false
        )
    }
}
