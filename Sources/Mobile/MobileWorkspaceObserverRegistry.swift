import Foundation

/// Owns every active mobile workspace observer and their shared host-ordering sequencer.
@MainActor
final class MobileWorkspaceObserverRegistry {
    private var observers: [ObjectIdentifier: MobileWorkspaceListObserver] = [:]
    private let focusEventSequenceService = MobileWorkspaceFocusEventSequenceService()

    func ensureObserver(
        for tabManager: TabManager,
        notificationStore: TerminalNotificationStore?
    ) {
        let id = ObjectIdentifier(tabManager)
        guard observers[id] == nil else { return }
        observers[id] = MobileWorkspaceListObserver(
            tabManager: tabManager,
            focusEventSequenceService: focusEventSequenceService,
            notificationStore: notificationStore
        )
    }

    func removeObserver(for tabManager: TabManager) {
        observers.removeValue(forKey: ObjectIdentifier(tabManager))
    }
}
