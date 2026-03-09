import Foundation
import Combine
import Bonsplit

// MARK: - SharedWorkspaceStore

/// Singleton that coordinates shared tabs across multiple windows.
/// Each window has its own TabManager, but in shared mode they all keep their
/// `tabs` arrays synchronized through this store. selectedTabId stays per-window
/// on each TabManager (zero view reference changes needed).
@MainActor
class SharedWorkspaceStore {
    static var shared: SharedWorkspaceStore? = {
        guard SharedTabsSettings.isEnabled() else { return nil }
        return SharedWorkspaceStore()
    }()

    /// Canonical tab list. Updated by the source TabManager on mutation.
    private(set) var tabs: [Workspace] = []

    /// Maps workspace ID to the owning window's UUID.
    @Published private(set) var ownershipByTab: [UUID: UUID] = [:]

    /// Registered TabManagers. WeakRef so closed windows are cleaned up.
    private var registeredManagers: NSHashTable<TabManager> = .weakObjects()

    /// Guard against re-entrant broadcast during sync.
    private var isBroadcasting = false

    func register(_ manager: TabManager) {
        registeredManagers.add(manager)
    }

    func unregister(_ manager: TabManager) {
        registeredManagers.remove(manager)
    }

    /// Called by a TabManager after modifying its `tabs` array.
    /// Broadcasts the change to all other registered TabManagers.
    func broadcastTabsUpdate(from source: TabManager) {
        guard !isBroadcasting else { return }
        isBroadcasting = true
        defer { isBroadcasting = false }

        tabs = source.tabs

        for manager in registeredManagers.allObjects {
            guard manager !== source else { continue }
            manager.receiveSyncedTabs(source.tabs)
        }
    }

    // MARK: - Ownership

    /// Atomically releases the old tab and claims the new one, notifying the
    /// previous owner to vacate. Batches both mutations into a single
    /// `@Published` update so subscribers only fire once.
    func switchOwnership(
        from oldWorkspaceId: UUID?,
        to newWorkspaceId: UUID,
        forWindow windowId: UUID
    ) {
        // Release old tab if owned by this window.
        if let oldId = oldWorkspaceId, ownershipByTab[oldId] == windowId {
            ownershipByTab.removeValue(forKey: oldId)
        }

        // Claim new tab.
        let previousOwner = ownershipByTab[newWorkspaceId]
        ownershipByTab[newWorkspaceId] = windowId

        // If we stole from another window, tell it to vacate directly.
        if let previousOwner, previousOwner != windowId {
            for manager in registeredManagers.allObjects {
                guard manager.windowId == previousOwner else { continue }
                manager.handleTabStolen(newWorkspaceId)
                break
            }
        }
    }

    /// Claims a single tab without releasing another (used during init).
    @discardableResult
    func claim(workspaceId: UUID, forWindow windowId: UUID) -> UUID? {
        let previous = ownershipByTab[workspaceId]
        ownershipByTab[workspaceId] = windowId
        return previous
    }

    /// Releases ownership if the given window owns it.
    func release(workspaceId: UUID, fromWindow windowId: UUID) {
        if ownershipByTab[workspaceId] == windowId {
            ownershipByTab.removeValue(forKey: workspaceId)
        }
    }

    /// Returns the owning window ID, or nil if unclaimed.
    func owner(of workspaceId: UUID) -> UUID? {
        ownershipByTab[workspaceId]
    }

    /// Releases all tabs owned by a window (called on window close).
    func releaseAllTabs(fromWindow windowId: UUID) {
        ownershipByTab = ownershipByTab.filter { $0.value != windowId }
    }

    /// Returns the first unclaimed tab, or nil.
    func firstUnclaimedTab() -> Workspace? {
        tabs.first { owner(of: $0.id) == nil }
    }
}
