import Foundation

/// Owns every active mobile workspace observer and their shared host-ordering sequencer.
@MainActor
final class MobileWorkspaceObserverRegistry {
    private var observers: [ObjectIdentifier: MobileWorkspaceListObserver] = [:]
    private let focusEventSequenceService = MobileWorkspaceFocusEventSequenceService()
    private let notificationCenter: NotificationCenter
    private let focusWorkspaceSampler: MobileWorkspaceListObserver.FocusWorkspaceSampler

    init(
        notificationCenter: NotificationCenter = .default,
        focusWorkspaceSampler: @escaping MobileWorkspaceListObserver.FocusWorkspaceSampler = {
            tabManager,
            workspaceID in
            tabManager.tabs.first(where: { $0.id == workspaceID })
        }
    ) {
        self.notificationCenter = notificationCenter
        self.focusWorkspaceSampler = focusWorkspaceSampler
    }

    func ensureObserver(
        for tabManager: TabManager,
        notificationStore: TerminalNotificationStore?
    ) {
        let id = ObjectIdentifier(tabManager)
        guard observers[id] == nil else { return }
        observers[id] = MobileWorkspaceListObserver(
            tabManager: tabManager,
            focusEventSequenceService: focusEventSequenceService,
            notificationStore: notificationStore,
            notificationCenter: notificationCenter,
            focusWorkspaceSampler: focusWorkspaceSampler
        )
    }

    func removeObserver(for tabManager: TabManager) {
        observers.removeValue(forKey: ObjectIdentifier(tabManager))
    }
}
