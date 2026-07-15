import Foundation

/// Owns every active mobile workspace observer, their shared host-ordering sequencer,
/// and the single consumer that routes surface-focus notifications by workspace owner.
@MainActor
final class MobileWorkspaceObserverRegistry {
    private var observers: [ObjectIdentifier: MobileWorkspaceListObserver] = [:]
    private var workspaceOwnerByID: [UUID: ObjectIdentifier] = [:]
    private var workspaceIDsByObserver: [ObjectIdentifier: Set<UUID>] = [:]
    private let focusEventSequenceService: MobileWorkspaceFocusEventSequenceService
    private let focusWorkspaceSampler: MobileWorkspaceListObserver.FocusWorkspaceSampler
    private var focusedSurfaceTask: Task<Void, Never>?

    init(
        notificationCenter: NotificationCenter = .default,
        focusEventSequenceService: MobileWorkspaceFocusEventSequenceService? = nil,
        focusWorkspaceSampler: @escaping MobileWorkspaceListObserver.FocusWorkspaceSampler = {
            tabManager,
            workspaceID in
            tabManager.workspacesById[workspaceID]
        }
    ) {
        self.focusEventSequenceService = focusEventSequenceService
            ?? MobileWorkspaceFocusEventSequenceService()
        self.focusWorkspaceSampler = focusWorkspaceSampler
        focusedSurfaceTask = Task { @MainActor [weak self, notificationCenter] in
            for await notification in notificationCenter.notifications(named: .ghosttyDidFocusSurface) {
                self?.routeFocusedSurfaceNotification(notification)
            }
        }
    }

    deinit { focusedSurfaceTask?.cancel() }

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
            workspaceOwnershipDidChange: { [weak self] workspaces in
                self?.reconcileWorkspaceOwnership(for: id, workspaces: workspaces)
            }
        )
    }

    func removeObserver(for tabManager: TabManager) {
        let id = ObjectIdentifier(tabManager)
        removeWorkspaceOwnership(for: id)
        observers.removeValue(forKey: id)
    }

    private func reconcileWorkspaceOwnership(
        for observerID: ObjectIdentifier,
        workspaces: [Workspace]
    ) {
        let nextWorkspaceIDs = Set(workspaces.map(\.id))
        let previousWorkspaceIDs = workspaceIDsByObserver[observerID] ?? []

        for workspaceID in previousWorkspaceIDs.subtracting(nextWorkspaceIDs)
            where workspaceOwnerByID[workspaceID] == observerID {
            workspaceOwnerByID.removeValue(forKey: workspaceID)
        }

        for workspaceID in nextWorkspaceIDs {
            if let previousOwner = workspaceOwnerByID[workspaceID], previousOwner != observerID {
                workspaceIDsByObserver[previousOwner]?.remove(workspaceID)
            }
            workspaceOwnerByID[workspaceID] = observerID
        }
        workspaceIDsByObserver[observerID] = nextWorkspaceIDs
    }

    private func removeWorkspaceOwnership(for observerID: ObjectIdentifier) {
        let workspaceIDs = workspaceIDsByObserver.removeValue(forKey: observerID) ?? []
        for workspaceID in workspaceIDs where workspaceOwnerByID[workspaceID] == observerID {
            workspaceOwnerByID.removeValue(forKey: workspaceID)
        }
    }

    private func routeFocusedSurfaceNotification(_ notification: Notification) {
        guard let workspaceID = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID,
              let observerID = workspaceOwnerByID[workspaceID],
              let observer = observers[observerID] else {
            return
        }
        guard observer.emitFocusedHierarchyUpdateIfOwned(
            workspaceID: workspaceID,
            sampler: focusWorkspaceSampler
        ) else {
            if workspaceOwnerByID[workspaceID] == observerID {
                workspaceOwnerByID.removeValue(forKey: workspaceID)
                workspaceIDsByObserver[observerID]?.remove(workspaceID)
            }
            return
        }
    }
}
