import Foundation
import SwiftUI

/// State for a single pane (leaf node in the split tree)
@Observable
final class PaneState: Identifiable {
    let id: PaneID
    var tabs: [SurfaceItem]
    var selectedTabId: UUID?

    init(
        id: PaneID = PaneID(),
        tabs: [SurfaceItem] = [],
        selectedTabId: UUID? = nil
    ) {
        self.id = id
        self.tabs = tabs
        self.selectedTabId = selectedTabId ?? tabs.first?.id
    }

    /// Currently selected tab
    var selectedTab: SurfaceItem? {
        tabs.first { $0.id == selectedTabId }
    }

    /// Select a tab by ID
    func selectTab(_ tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        selectedTabId = tabId
    }

    /// Add a new tab
    func addTab(_ tab: SurfaceItem, select: Bool = true) {
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = tab.isPinned ? pinnedCount : tabs.count
        tabs.insert(tab, at: insertIndex)
        if select {
            selectedTabId = tab.id
        }
    }

    /// Insert a tab at a specific index
    func insertTab(_ tab: SurfaceItem, at index: Int, select: Bool = true) {
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let requested = min(max(0, index), tabs.count)
        let safeIndex: Int
        if tab.isPinned {
            safeIndex = min(requested, pinnedCount)
        } else {
            safeIndex = max(requested, pinnedCount)
        }
        tabs.insert(tab, at: safeIndex)
        if select {
            selectedTabId = tab.id
        }
    }

    /// Remove a tab and return it
    @discardableResult
    func removeTab(_ tabId: UUID) -> SurfaceItem? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        let tab = tabs.remove(at: index)

        // If we removed the selected tab, keep the index stable when possible:
        // prefer selecting the tab that moved into the removed tab's slot (the "next" tab),
        // and only fall back to selecting the previous tab when we removed the last tab.
        if selectedTabId == tabId {
            if !tabs.isEmpty {
                let newIndex = min(index, max(0, tabs.count - 1))
                selectedTabId = tabs[newIndex].id
            } else {
                selectedTabId = nil
            }
        }

        return tab
    }

    /// Move a tab within this pane
    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard tabs.indices.contains(sourceIndex),
              destinationIndex >= 0, destinationIndex <= tabs.count else { return }

        // Treat dropping "on itself" or "after itself" as a no-op.
        // This avoids remove/insert churn that can cause brief visual artifacts during drag/drop.
        if destinationIndex == sourceIndex || destinationIndex == sourceIndex + 1 {
            return
        }

        let tab = tabs.remove(at: sourceIndex)
        let requestedIndex = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let adjustedIndex: Int
        if tab.isPinned {
            adjustedIndex = min(requestedIndex, pinnedCount)
        } else {
            adjustedIndex = max(requestedIndex, pinnedCount)
        }
        let safeIndex = min(max(0, adjustedIndex), tabs.count)
        tabs.insert(tab, at: safeIndex)
    }
}

extension PaneState: Equatable {
    static func == (lhs: PaneState, rhs: PaneState) -> Bool {
        lhs.id == rhs.id
    }
}
