import Foundation

/// A single pane on the paper canvas. Contains an ordered list of tabs.
@Observable
@MainActor
final class PaperPane: Identifiable {
    let id: PaneID
    /// Pixel width of this pane on the canvas. Updated by resize gestures and split operations.
    var width: CGFloat
    var tabs: [PaperTabItem]
    var selectedTabId: UUID?

    init(id: PaneID = PaneID(), width: CGFloat, tabs: [PaperTabItem] = [], selectedTabId: UUID? = nil) {
        self.id = id
        self.width = width
        self.tabs = tabs
        self.selectedTabId = selectedTabId ?? tabs.first?.id
    }

    var selectedTab: PaperTabItem? {
        tabs.first { $0.id == selectedTabId }
    }

    func selectTab(_ tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        selectedTabId = tabId
    }

    func addTab(_ tab: PaperTabItem, select: Bool = true) {
        // Insert after the last pinned tab, or at the end
        let insertIndex: Int
        if tab.isPinned {
            insertIndex = tabs.lastIndex(where: { $0.isPinned }).map { $0 + 1 } ?? 0
        } else {
            insertIndex = tabs.count
        }
        tabs.insert(tab, at: insertIndex)
        if select || selectedTabId == nil {
            selectedTabId = tab.id
        }
    }

    func insertTab(_ tab: PaperTabItem, at index: Int, select: Bool = true) {
        let clampedIndex = min(max(index, 0), tabs.count)
        tabs.insert(tab, at: clampedIndex)
        if select || selectedTabId == nil {
            selectedTabId = tab.id
        }
    }

    @discardableResult
    func removeTab(_ tabId: UUID) -> PaperTabItem? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        let removed = tabs.remove(at: index)
        if selectedTabId == tabId {
            // Select next tab in the same slot, or previous if we were at the end
            if !tabs.isEmpty {
                let newIndex = min(index, tabs.count - 1)
                selectedTabId = tabs[newIndex].id
            } else {
                selectedTabId = nil
            }
        }
        return removed
    }

    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              sourceIndex >= 0, sourceIndex < tabs.count,
              destinationIndex >= 0, destinationIndex <= tabs.count else { return }

        let tab = tabs.remove(at: sourceIndex)
        let adjustedDestination = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        tabs.insert(tab, at: min(adjustedDestination, tabs.count))
    }

    func tab(_ tabId: UUID) -> PaperTabItem? {
        tabs.first { $0.id == tabId }
    }

    func tabIndex(_ tabId: UUID) -> Int? {
        tabs.firstIndex { $0.id == tabId }
    }
}

extension PaperPane: Equatable {
    nonisolated static func == (lhs: PaperPane, rhs: PaperPane) -> Bool {
        lhs.id == rhs.id
    }
}
