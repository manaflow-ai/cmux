import Foundation

extension TabManager {
    func moveTabsToTopForNotificationPriority(_ tabIdsInPriorityOrder: [UUID]) {
        let tabById = Dictionary(uniqueKeysWithValues: tabs.map { ($0.id, $0) })
        var seenIds = Set<UUID>()
        let orderedUnpinnedIds = tabIdsInPriorityOrder.reduce(into: [UUID]()) { result, tabId in
            guard seenIds.insert(tabId).inserted,
                  let tab = tabById[tabId],
                  !tab.isPinned else {
                return
            }
            result.append(tabId)
        }
        guard !orderedUnpinnedIds.isEmpty else { return }

        let pinnedCount = tabs.filter(\.isPinned).count
        for (offset, tabId) in orderedUnpinnedIds.enumerated() {
            _ = workspaceReordering.reorderWorkspace(tabId: tabId, toIndex: pinnedCount + offset)
        }
    }
}
