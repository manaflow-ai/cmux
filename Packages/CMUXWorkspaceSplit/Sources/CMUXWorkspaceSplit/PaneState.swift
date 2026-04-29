import Foundation
import SwiftUI

/// State for a single pane (leaf node in the split tree)
struct PaneState: Identifiable {
    let id: PaneID
    var tabIds: [UUID]
    var selectedTabId: UUID?
    // AppKit tab chrome is driven by snapshots of this pane. Bump explicitly on
    // metadata edits so hosts don't depend on nested array observation quirks.
    var chromeRevision: UInt64 = 0

    init(
        id: PaneID = PaneID(),
        tabIds: [UUID] = [],
        selectedTabId: UUID? = nil
    ) {
        self.id = id
        self.tabIds = tabIds
        self.selectedTabId = selectedTabId ?? tabIds.first
    }

    /// Select a tab by ID
    mutating func selectTab(_ tabId: UUID) {
        guard tabIds.contains(tabId) else { return }
        guard selectedTabId != tabId else { return }
        selectedTabId = tabId
        chromeRevision &+= 1
    }

    /// Add a new tab
    mutating func addTab(_ tabId: UUID, select: Bool = true) {
        tabIds.append(tabId)
        if select {
            selectedTabId = tabId
        }
        chromeRevision &+= 1
    }

    /// Insert a tab at a specific index
    mutating func insertTab(_ tabId: UUID, at index: Int, select: Bool = true) {
        let safeIndex = min(max(0, index), tabIds.count)
        tabIds.insert(tabId, at: safeIndex)
        if select {
            selectedTabId = tabId
        }
        chromeRevision &+= 1
    }

    /// Remove a tab and return it
    @discardableResult
    mutating func removeTab(_ tabId: UUID) -> UUID? {
        guard let index = tabIds.firstIndex(of: tabId) else { return nil }
        let removedTabId = tabIds.remove(at: index)

        // If we removed the selected tab, keep the index stable when possible:
        // prefer selecting the tab that moved into the removed tab's slot (the "next" tab),
        // and only fall back to selecting the previous tab when we removed the last tab.
        if selectedTabId == tabId {
            if !tabIds.isEmpty {
                let newIndex = min(index, max(0, tabIds.count - 1))
                selectedTabId = tabIds[newIndex]
            } else {
                selectedTabId = nil
            }
        }

        chromeRevision &+= 1

        return removedTabId
    }

    /// Move a tab within this pane
    mutating func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard tabIds.indices.contains(sourceIndex),
              destinationIndex >= 0, destinationIndex <= tabIds.count else { return }

        // Treat dropping "on itself" or "after itself" as a no-op.
        // This avoids remove/insert churn that can cause brief visual artifacts during drag/drop.
        if destinationIndex == sourceIndex || destinationIndex == sourceIndex + 1 {
            return
        }

        let tabId = tabIds.remove(at: sourceIndex)
        let requestedIndex = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        let safeIndex = min(max(0, requestedIndex), tabIds.count)
        tabIds.insert(tabId, at: safeIndex)
        chromeRevision &+= 1
    }
}

extension PaneState: Equatable {
    static func == (lhs: PaneState, rhs: PaneState) -> Bool {
        lhs.id == rhs.id
    }
}

import Foundation

/// Represents a pane with its computed bounds in normalized coordinates (0-1)
struct PaneBounds {
    let paneId: PaneID
    let bounds: CGRect
}

/// Recursive structure representing the split tree
/// - pane: A leaf node containing a single pane with tabs
/// - split: A branch node containing two children with a divider
indirect enum SplitNode: Identifiable, Equatable {
    case pane(PaneState)
    case split(SplitState)

    var id: UUID {
        switch self {
        case .pane(let state):
            return state.id.id
        case .split(let state):
            return state.id
        }
    }

    /// Find a pane by its ID
    func findPane(_ paneId: PaneID) -> PaneState? {
        switch self {
        case .pane(let state):
            return state.id == paneId ? state : nil
        case .split(let state):
            return state.first.findPane(paneId) ?? state.second.findPane(paneId)
        }
    }

    /// Mutate a pane in place.
    @discardableResult
    mutating func updatePane(_ paneId: PaneID, _ update: (inout PaneState) -> Void) -> Bool {
        switch self {
        case .pane(var state):
            guard state.id == paneId else { return false }
            update(&state)
            self = .pane(state)
            return true
        case .split(var state):
            if state.first.updatePane(paneId, update) {
                self = .split(state)
                return true
            }
            if state.second.updatePane(paneId, update) {
                self = .split(state)
                return true
            }
            return false
        }
    }

    /// Find the leaf node for a pane by ID.
    func findNode(containing paneId: PaneID) -> SplitNode? {
        switch self {
        case .pane(let state):
            return state.id == paneId ? self : nil
        case .split(let state):
            return state.first.findNode(containing: paneId) ?? state.second.findNode(containing: paneId)
        }
    }

    /// Find a split by its ID.
    func findSplit(_ splitId: UUID) -> SplitState? {
        switch self {
        case .pane:
            return nil
        case .split(let state):
            if state.id == splitId {
                return state
            }
            return state.first.findSplit(splitId) ?? state.second.findSplit(splitId)
        }
    }

    /// Mutate a split in place.
    @discardableResult
    mutating func updateSplit(_ splitId: UUID, _ update: (inout SplitState) -> Void) -> Bool {
        switch self {
        case .pane:
            return false
        case .split(var state):
            if state.id == splitId {
                update(&state)
                self = .split(state)
                return true
            }
            if state.first.updateSplit(splitId, update) {
                self = .split(state)
                return true
            }
            if state.second.updateSplit(splitId, update) {
                self = .split(state)
                return true
            }
            return false
        }
    }

    /// Get all pane IDs in the tree
    var allPaneIds: [PaneID] {
        switch self {
        case .pane(let state):
            return [state.id]
        case .split(let state):
            return state.first.allPaneIds + state.second.allPaneIds
        }
    }

    /// Get all panes in the tree
    var allPanes: [PaneState] {
        switch self {
        case .pane(let state):
            return [state]
        case .split(let state):
            return state.first.allPanes + state.second.allPanes
        }
    }

    /// Find a tab by ID.
    func findTab(_ tabId: TabID) -> (paneId: PaneID, tabIndex: Int)? {
        switch self {
        case .pane(let state):
            guard let tabIndex = state.tabIds.firstIndex(of: tabId.id) else { return nil }
            return (state.id, tabIndex)
        case .split(let state):
            return state.first.findTab(tabId) ?? state.second.findTab(tabId)
        }
    }

    /// Discriminator for detecting structural changes in the tree
    enum NodeType: Equatable {
        case pane
        case split
    }

    var nodeType: NodeType {
        switch self {
        case .pane: return .pane
        case .split: return .split
        }
    }

    static func == (lhs: SplitNode, rhs: SplitNode) -> Bool {
        lhs.id == rhs.id
    }

    /// Compute normalized bounds (0-1) for all panes in the tree
    /// - Parameter availableRect: The rect available for this subtree (starts as unit rect)
    /// - Returns: Array of pane IDs with their computed bounds
    func computePaneBounds(in availableRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [PaneBounds] {
        switch self {
        case .pane(let paneState):
            return [PaneBounds(paneId: paneState.id, bounds: availableRect)]

        case .split(let splitState):
            let dividerPos = splitState.dividerPosition
            let firstRect: CGRect
            let secondRect: CGRect

            switch splitState.orientation {
            case .horizontal:  // Side-by-side: first=LEFT, second=RIGHT
                firstRect = CGRect(x: availableRect.minX, y: availableRect.minY,
                                   width: availableRect.width * dividerPos, height: availableRect.height)
                secondRect = CGRect(x: availableRect.minX + availableRect.width * dividerPos, y: availableRect.minY,
                                    width: availableRect.width * (1 - dividerPos), height: availableRect.height)
            case .vertical:  // Stacked: first=TOP, second=BOTTOM
                firstRect = CGRect(x: availableRect.minX, y: availableRect.minY,
                                   width: availableRect.width, height: availableRect.height * dividerPos)
                secondRect = CGRect(x: availableRect.minX, y: availableRect.minY + availableRect.height * dividerPos,
                                    width: availableRect.width, height: availableRect.height * (1 - dividerPos))
            }

            return splitState.first.computePaneBounds(in: firstRect)
                 + splitState.second.computePaneBounds(in: secondRect)
        }
    }
}
