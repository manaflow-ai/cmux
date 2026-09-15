import Foundation

/// Delivers a ``MachineCreateNotice`` through the app's notification store:
/// a banner (unless the person is already looking at the target) plus an
/// entry in the notifications list, anchored to the workspace the machine
/// opened in so clicking it goes there. Failures anchor to the workspace the
/// person is in right now, so an error from a create they walked away from
/// still reaches them.
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
