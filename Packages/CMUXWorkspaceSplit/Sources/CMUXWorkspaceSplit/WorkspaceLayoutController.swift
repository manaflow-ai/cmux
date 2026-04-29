import Foundation
import CoreGraphics
import SwiftUI

@MainActor
struct WorkspaceLayoutExternalTabDropRequest {
    enum Destination {
        case insert(targetPane: PaneID, targetIndex: Int?)
        case split(targetPane: PaneID, orientation: SplitOrientation, insertFirst: Bool)
    }

    let tabId: TabID
    let sourcePaneId: PaneID
    let destination: Destination
}

@MainActor
final class WorkspaceLayoutController {

    // MARK: - Delegate

    /// Delegate for receiving callbacks about tab bar events
    weak var delegate: WorkspaceLayoutDelegate?

    // MARK: - Configuration

    /// Configuration for behavior and appearance
    var configuration: WorkspaceLayoutConfiguration

    // MARK: - Layout State

    /// The root node of the split tree.
    var rootNode: SplitNode

    /// Currently zoomed pane. When set, rendering should only show this pane.
    var zoomedPaneId: PaneID?

    /// Currently focused pane ID.
    var focusedPaneId: PaneID?

    /// Tab currently being dragged (for visual feedback and hit-testing).
    var draggingTabId: TabID?

    /// Monotonic counter incremented on each drag start.
    var dragGeneration: Int = 0

    /// Source pane of the dragging tab.
    var dragSourcePaneId: PaneID?

    /// Non-observable drag session state used by drop delegates.
    var activeDragTabId: TabID?
    var activeDragSourcePaneId: PaneID?

    /// Current frame of the entire split view container.
    var containerFrame: CGRect = .zero

    /// Whether command-hold shortcut hints should be shown for this workspace.
    var tabShortcutHintsEnabled: Bool = true {
        didSet {
            guard tabShortcutHintsEnabled != oldValue else { return }
            notifyGeometryChange()
        }
    }

    /// Flag to prevent notification loops during external updates.
    var isExternalUpdateInProgress: Bool = false

    /// Workspace-owned sink for published layout geometry snapshots.
    var onGeometryChanged: ((LayoutSnapshot) -> Void)?

    // MARK: - Initialization

    /// Create a new controller with the specified configuration
    init(
        configuration: WorkspaceLayoutConfiguration = .default,
        rootNode: SplitNode? = nil
    ) {
        self.configuration = configuration
        if let rootNode {
            self.rootNode = rootNode
        } else {
            let initialPane = PaneState()
            self.rootNode = .pane(initialPane)
            self.focusedPaneId = initialPane.id
        }
    }

    // MARK: - Renderer-facing state

    var renderRootNode: SplitNode {
        zoomedNode ?? rootNode
    }

    var isHandlingLocalTabDrag: Bool {
        currentDragTabId != nil
    }

    var currentDragTabId: TabID? {
        activeDragTabId ?? draggingTabId
    }

    var currentDragSourcePaneId: PaneID? {
        activeDragSourcePaneId ?? dragSourcePaneId
    }

    func beginTabDrag(tabId: TabID, sourcePaneId: PaneID) {
        dragGeneration += 1
        draggingTabId = tabId
        dragSourcePaneId = sourcePaneId
        activeDragTabId = tabId
        activeDragSourcePaneId = sourcePaneId
    }

    func clearDragState() {
        draggingTabId = nil
        dragSourcePaneId = nil
        activeDragTabId = nil
        activeDragSourcePaneId = nil
    }

    // MARK: - WorkspaceLayout.Tab Operations

    /// Create a new tab in the focused pane (or specified pane)
    /// - Parameters:
    ///   - id: Optional stable surface ID to use for the tab
    ///   - title: The tab title
    ///   - isPinned: Whether the tab should be treated as pinned
    ///   - pane: Optional pane to add the tab to (defaults to focused pane)
    /// - Returns: The TabID of the created tab, or nil if creation was vetoed by delegate
    @discardableResult
    func createTab(
        id: TabID? = nil,
        title: String,
        isPinned: Bool = false,
        inPane pane: PaneID? = nil,
        select: Bool = true
    ) -> TabID? {
        let tabId = id ?? TabID()
        guard let targetPane = pane ?? focusedPaneId ?? rootNode.allPaneIds.first.map({ PaneID(id: $0.id) }) else {
            return nil
        }
        guard rootNode.findPane(PaneID(id: targetPane.id)) != nil else {
            return nil
        }

        // Check with delegate
        if delegate?.workspaceSplit(shouldCreateTab: tabId, inPane: targetPane) == false {
            return nil
        }

        // Calculate insertion index based on configuration
        let insertIndex: Int?
        switch configuration.newTabPosition {
        case .current:
            // Insert after the currently selected tab
            if let paneState = rootNode.findPane(PaneID(id: targetPane.id)),
               let selectedTabId = paneState.selectedTabId,
               let currentIndex = paneState.tabIds.firstIndex(of: selectedTabId) {
                insertIndex = currentIndex + 1
            } else {
                // No selected tab, append to end
                insertIndex = nil
            }
        case .end:
            insertIndex = nil
        }

        addTabInternal(
            tabId.id,
            toPane: PaneID(id: targetPane.id),
            atIndex: insertIndex,
            select: select
        )

        // Notify delegate
        delegate?.workspaceSplit(didCreateTab: tabId, inPane: targetPane)

        return tabId
    }

    /// Request the delegate to create a new tab of the given kind in a pane.
    /// The delegate is responsible for the actual creation logic.
    func requestNewTab(kind: WorkspaceLayoutTabKind, inPane pane: PaneID) {
        delegate?.workspaceSplit(didRequestNewTab: kind, inPane: pane)
    }

    /// Request the delegate to handle a tab context-menu action.
    func requestTabContextAction(_ action: TabContextAction, for tabId: TabID, inPane pane: PaneID) {
        guard findTabInternal(tabId) != nil else { return }
        delegate?.workspaceSplit(didRequestTabContextAction: action, for: tabId, inPane: pane)
    }

    /// Update an existing tab's layout-affecting metadata
    /// - Parameters:
    ///   - tabId: The tab to update
    ///   - title: New fallback title (pass nil to keep current)
    ///   - isPinned: New pinned state (pass nil to keep current)
    func updateTab(
        _ tabId: TabID,
        title: String? = nil,
        isPinned: Bool? = nil
    ) {
        guard let (paneId, _) = findTabInternal(tabId) else { return }
        guard title != nil || isPinned != nil else { return }
        rootNode.updatePane(paneId) { pane in
            pane.chromeRevision &+= 1
        }
    }

    /// Close a tab by ID
    /// - Parameter tabId: The tab to close
    /// - Returns: true if the tab was closed, false if vetoed by delegate
    @discardableResult
    func closeTab(_ tabId: TabID) -> Bool {
        guard let (paneId, tabIndex) = findTabInternal(tabId),
              let pane = rootNode.findPane(paneId) else { return false }
        return closeTab(tabId, with: tabIndex, inPane: pane.id)
    }

    /// Close a tab by ID in a specific pane.
    /// - Parameter tabId: The tab to close
    /// - Parameter paneId: The pane in which to close the tab
    func closeTab(_ tabId: TabID, inPane paneId: PaneID) -> Bool {
        guard let pane = rootNode.findPane(paneId),
              let tabIndex = pane.tabIds.firstIndex(of: tabId.id) else {
            return false
        }

        return closeTab(tabId, with: tabIndex, inPane: pane.id)
    }

    /// Internal helper to close a tab given its index in a pane
    /// - Parameter tabId: The tab to close
    /// - Parameter tabIndex: The position of the tab within the pane
    /// - Parameter paneId: The pane in which to close the tab
    func closeTab(_ tabId: TabID, with tabIndex: Int, inPane paneId: PaneID) -> Bool {
        guard configuration.allowCloseTabs else { return false }

        // Check with delegate
        if delegate?.workspaceSplit(shouldCloseTab: tabId, inPane: paneId) == false {
            return false
        }

        performCloseTab(tabId.id, inPane: paneId)

        // Notify delegate
        delegate?.workspaceSplit(didCloseTab: tabId, fromPane: paneId)
        notifyGeometryChange()

        return true
    }

    /// Select a tab by ID
    /// - Parameter tabId: The tab to select
    func selectTab(_ tabId: TabID) {
        guard let (paneId, _) = findTabInternal(tabId) else { return }

        rootNode.updatePane(paneId) { pane in
            pane.selectTab(tabId.id)
        }
        setFocusedPane(paneId)

        // Notify delegate
        delegate?.workspaceSplit(didSelectTab: tabId, inPane: paneId)
    }

    /// Move a tab to a specific pane (and optional index) inside this controller.
    /// - Parameters:
    ///   - tabId: The tab to move.
    ///   - targetPaneId: Destination pane.
    ///   - index: Optional destination index. When nil, appends at the end.
    /// - Returns: true if moved.
    @discardableResult
    func moveTab(_ tabId: TabID, toPane targetPaneId: PaneID, atIndex index: Int? = nil) -> Bool {
        guard let (sourcePaneId, sourceIndex) = findTabInternal(tabId),
              let sourcePane = rootNode.findPane(sourcePaneId),
              let targetPane = rootNode.findPane(PaneID(id: targetPaneId.id)) else { return false }

        let surfaceId = sourcePane.tabIds[sourceIndex]
        if sourcePaneId == targetPane.id {
            guard configuration.allowTabReordering else { return false }

            // Reorder within same pane.
            let destinationIndex: Int = {
                if let index { return max(0, min(index, sourcePane.tabIds.count)) }
                return sourcePane.tabIds.count
            }()
            rootNode.updatePane(sourcePaneId) { pane in
                pane.moveTab(from: sourceIndex, to: destinationIndex)
                pane.selectTab(surfaceId)
            }
            setFocusedPane(sourcePaneId)
            delegate?.workspaceSplit(didSelectTab: tabId, inPane: sourcePaneId)
            notifyGeometryChange()
            return true
        }

        guard configuration.allowCrossPaneTabMove else { return false }

        performMoveTab(surfaceId, from: sourcePaneId, to: targetPane.id, atIndex: index)
        delegate?.workspaceSplit(didMoveTab: tabId, fromPane: sourcePaneId, toPane: targetPane.id)
        notifyGeometryChange()
        return true
    }

    /// Reorder a tab within its pane.
    /// - Parameters:
    ///   - tabId: The tab to reorder.
    ///   - toIndex: Destination index.
    /// - Returns: true if reordered.
    @discardableResult
    func reorderTab(_ tabId: TabID, toIndex: Int) -> Bool {
        guard configuration.allowTabReordering else { return false }

        guard let (paneId, sourceIndex) = findTabInternal(tabId),
              let pane = rootNode.findPane(paneId) else { return false }
        let destinationIndex = max(0, min(toIndex, pane.tabIds.count))
        rootNode.updatePane(paneId) { pane in
            pane.moveTab(from: sourceIndex, to: destinationIndex)
            pane.selectTab(tabId.id)
        }
        setFocusedPane(paneId)
        delegate?.workspaceSplit(didSelectTab: tabId, inPane: paneId)
        notifyGeometryChange()
        return true
    }

    /// Move to previous tab in focused pane
    func selectPreviousTab() {
        selectPreviousTabInternal()
        notifyTabSelection()
    }

    /// Move to next tab in focused pane
    func selectNextTab() {
        selectNextTabInternal()
        notifyTabSelection()
    }

    // MARK: - Split Operations

    /// Split the focused pane (or specified pane)
    /// - Parameters:
    ///   - paneId: Optional pane to split (defaults to focused pane)
    ///   - orientation: Direction to split (horizontal = side-by-side, vertical = stacked)
    ///   - tab: Optional tab to add to the new pane
    /// - Returns: The new pane ID, or nil if vetoed by delegate
    @discardableResult
    func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        withTabId tabId: TabID? = nil,
        focusNewPane: Bool = true
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }

        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId,
              rootNode.findPane(targetPaneId) != nil else { return nil }
        let previousPaneIds = Set(rootNode.allPaneIds)

        // Check with delegate
        if delegate?.workspaceSplit(shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        // Perform split
        performSplitPane(
            PaneID(id: targetPaneId.id),
            orientation: orientation,
            with: tabId?.id,
            focusNewPane: focusNewPane
        )

        guard let newPaneId = Set(rootNode.allPaneIds)
            .subtracting(previousPaneIds)
            .first else { return nil }

        // Notify delegate
        delegate?.workspaceSplit(didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

        notifyGeometryChange()

        return newPaneId
    }

    /// Split a pane and place a specific tab in the newly created pane, choosing which side to insert on.
    ///
    /// This is like `splitPane(_:orientation:withTab:)`, but allows choosing left/top vs right/bottom insertion
    /// without needing to create then move a tab.
    ///
    /// - Parameters:
    ///   - paneId: Optional pane to split (defaults to focused pane).
    ///   - orientation: Direction to split (horizontal = side-by-side, vertical = stacked).
    ///   - tab: The tab to add to the new pane.
    ///   - insertFirst: If true, insert the new pane first (left/top). Otherwise insert second (right/bottom).
    /// - Returns: The new pane ID, or nil if vetoed by delegate.
    @discardableResult
    func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        withTabId tabId: TabID,
        insertFirst: Bool,
        focusNewPane: Bool = true
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }

        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId,
              rootNode.findPane(targetPaneId) != nil else { return nil }
        let previousPaneIds = Set(rootNode.allPaneIds)

        // Check with delegate
        if delegate?.workspaceSplit(shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        // Perform split with insertion side.
        performSplitPaneWithTab(
            PaneID(id: targetPaneId.id),
            orientation: orientation,
            tabId: tabId.id,
            insertFirst: insertFirst,
            focusNewPane: focusNewPane
        )

        guard let newPaneId = Set(rootNode.allPaneIds)
            .subtracting(previousPaneIds)
            .first else { return nil }

        // Notify delegate
        delegate?.workspaceSplit(didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

        notifyGeometryChange()

        return newPaneId
    }

    /// Split a pane by moving an existing tab into the new pane.
    ///
    /// This mirrors the "drag a tab to a pane edge to create a split" interaction:
    /// the tab is removed from its source pane first, then inserted into the newly
    /// created pane on the chosen edge.
    ///
    /// - Parameters:
    ///   - paneId: Optional target pane to split (defaults to the tab's current pane).
    ///   - orientation: Direction to split (horizontal = side-by-side, vertical = stacked).
    ///   - tabId: The existing tab to move into the new pane.
    ///   - insertFirst: If true, the new pane is inserted first (left/top). Otherwise it is inserted second (right/bottom).
    /// - Returns: The new pane ID, or nil if the tab couldn't be found or the split was vetoed.
    @discardableResult
    func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        movingTab tabId: TabID,
        insertFirst: Bool,
        focusNewPane: Bool = true
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }
        let previousPaneIds = Set(rootNode.allPaneIds)

        // Find the existing tab and its source pane.
        guard let (sourcePaneId, tabIndex) = findTabInternal(tabId),
              let sourcePane = rootNode.findPane(sourcePaneId) else { return nil }
        let surfaceId = sourcePane.tabIds[tabIndex]
        let sourceWasSelected = sourcePane.selectedTabId == surfaceId

        // Default target to the tab's current pane to match edge-drop behavior on the source pane.
        let targetPaneId = paneId ?? sourcePaneId
        guard rootNode.findPane(targetPaneId) != nil else { return nil }

        // Check with delegate
        if delegate?.workspaceSplit(shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        // Remove from source first.
        rootNode.updatePane(sourcePaneId) { pane in
            pane.removeTab(surfaceId)
        }

        // Perform split with the moved tab.
        performSplitPaneWithTab(
            PaneID(id: targetPaneId.id),
            orientation: orientation,
            tabId: surfaceId,
            insertFirst: insertFirst,
            focusNewPane: focusNewPane
        )

        guard let newPaneId = Set(rootNode.allPaneIds)
            .subtracting(previousPaneIds)
            .first else {
            rootNode.updatePane(sourcePaneId) { pane in
                pane.insertTab(surfaceId, at: tabIndex, select: sourceWasSelected)
            }
            return nil
        }

        let updatedSourcePane = rootNode.findPane(sourcePaneId)
        if configuration.autoCloseEmptyPanes,
           updatedSourcePane?.tabIds.isEmpty == true,
           sourcePaneId != targetPaneId,
           rootNode.allPaneIds.count > 1 {
            // If the source pane is now empty, close it after the split succeeds.
            performClosePane(sourcePaneId)
        }

        let desiredFocusPaneId = focusNewPane ? newPaneId : targetPaneId
        if rootNode.findPane(desiredFocusPaneId) != nil {
            focusPane(desiredFocusPaneId)
        }

        // Notify delegate
        delegate?.workspaceSplit(didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

        notifyGeometryChange()

        return newPaneId
    }

    /// Close a specific pane
    /// - Parameter paneId: The pane to close
    /// - Returns: true if the pane was closed, false if vetoed by delegate
    @discardableResult
    func closePane(_ paneId: PaneID) -> Bool {
        let paneId = PaneID(id: paneId.id)
        guard rootNode.findPane(paneId) != nil else {
            return false
        }

        // Don't close if it's the last pane and not allowed
        if !configuration.allowCloseLastPane && rootNode.allPaneIds.count <= 1 {
            return false
        }

        // Check with delegate
        if delegate?.workspaceSplit(shouldClosePane: paneId) == false {
            return false
        }

        performClosePane(paneId)
        guard rootNode.findPane(paneId) == nil else {
            return false
        }

        // Notify delegate
        delegate?.workspaceSplit(didClosePane: paneId)

        notifyGeometryChange()

        return true
    }

    // MARK: - Focus Management

    /// Focus a specific pane
    func focusPane(_ paneId: PaneID) {
        setFocusedPane(PaneID(id: paneId.id))
        delegate?.workspaceSplit(didFocusPane: paneId)
    }

    /// Navigate focus in a direction
    func navigateFocus(direction: NavigationDirection) {
        performNavigateFocus(direction: direction)
        if let focusedPaneId {
            delegate?.workspaceSplit(didFocusPane: focusedPaneId)
        }
    }

    /// Find the closest pane in the requested direction from the given pane.
    func adjacentPane(to paneId: PaneID, direction: NavigationDirection) -> PaneID? {
        adjacentPaneInternal(to: paneId, direction: direction)
    }

    // MARK: - Split Zoom

    var isSplitZoomed: Bool {
        zoomedPaneId != nil
    }

    @discardableResult
    func clearPaneZoom() -> Bool {
        clearPaneZoomInternal()
    }

    /// Toggle zoom for a pane. When zoomed, only that pane is rendered in the split area.
    /// Passing nil toggles the currently focused pane.
    @discardableResult
    func togglePaneZoom(inPane paneId: PaneID? = nil) -> Bool {
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return false }
        return togglePaneZoomInternal(targetPaneId)
    }

    // MARK: - Context Menu Shortcut Hints

    /// Keyboard shortcuts to display in tab context menus, keyed by context action.
    /// Set by the host app to sync with its customizable keyboard shortcut settings.
    var contextMenuShortcuts: [TabContextAction: KeyboardShortcut] = [:]

    // MARK: - Query Methods

    /// Get all tab IDs
    var allTabIds: [TabID] {
        rootNode.allPanes.flatMap { pane in
            pane.tabIds.map { TabID(id: $0) }
        }
    }

    /// Get all pane IDs
    var allPaneIds: [PaneID] {
        rootNode.allPaneIds
    }

    /// Get all tab IDs in a specific pane.
    func tabIds(inPane paneId: PaneID) -> [TabID] {
        guard let pane = rootNode.findPane(PaneID(id: paneId.id)) else {
            return []
        }
        return pane.tabIds.map { TabID(id: $0) }
    }

    /// Get the selected tab ID in a pane.
    func selectedTabId(inPane paneId: PaneID) -> TabID? {
        guard let pane = rootNode.findPane(PaneID(id: paneId.id)),
              let selectedTabId = pane.selectedTabId else {
            return nil
        }
        return TabID(id: selectedTabId)
    }

    // MARK: - Geometry Query API

    /// Get current layout snapshot with pixel coordinates
    func layoutSnapshot() -> LayoutSnapshot {
        let containerFrame = containerFrame
        let paneBounds = rootNode.computePaneBounds()

        let paneGeometries = paneBounds.map { bounds -> PaneGeometry in
            let pane = rootNode.findPane(bounds.paneId)
            let pixelFrame = PixelRect(
                x: Double(bounds.bounds.minX * containerFrame.width + containerFrame.origin.x),
                y: Double(bounds.bounds.minY * containerFrame.height + containerFrame.origin.y),
                width: Double(bounds.bounds.width * containerFrame.width),
                height: Double(bounds.bounds.height * containerFrame.height)
            )
            return PaneGeometry(
                paneId: bounds.paneId.id.uuidString,
                frame: pixelFrame,
                selectedTabId: pane?.selectedTabId?.uuidString,
                tabIds: pane?.tabIds.map { $0.uuidString } ?? []
            )
        }

        return LayoutSnapshot(
            containerFrame: PixelRect(from: containerFrame),
            panes: paneGeometries,
            focusedPaneId: focusedPaneId?.id.uuidString,
            timestamp: Date().timeIntervalSince1970
        )
    }

    /// Check if a split exists by ID
    func findSplit(_ splitId: UUID) -> Bool {
        return splitState(splitId) != nil
    }

    // MARK: - Geometry Update API

    /// Set divider position for a split node (0.0-1.0)
    /// - Parameters:
    ///   - position: The new divider position (clamped to 0.1-0.9)
    ///   - splitId: The UUID of the split to update
    ///   - fromExternal: Set to true to suppress outgoing notifications (prevents loops)
    /// - Returns: true if the split was found and updated
    @discardableResult
    func setDividerPosition(_ position: CGFloat, forSplit splitId: UUID, fromExternal: Bool = false) -> Bool {
        guard splitState(splitId) != nil else { return false }

        if fromExternal {
            isExternalUpdateInProgress = true
        }

        // Clamp position to valid range
        let clampedPosition = min(max(position, 0.1), 0.9)
        rootNode.updateSplit(splitId) { split in
            split.dividerPosition = clampedPosition
        }

        if fromExternal {
            // External restore/config loads should suppress only the immediate geometry echo
            // from the same update turn, not an arbitrary timed window.
            DispatchQueue.main.async { [weak self] in
                self?.isExternalUpdateInProgress = false
            }
        }

        return true
    }

    func consumeSplitEntryAnimation(_ splitId: UUID) {
        guard let split = splitState(splitId),
              split.animationOrigin != nil else { return }
        rootNode.updateSplit(splitId) { split in
            split.animationOrigin = nil
        }
    }

    /// Update container frame (called when window moves/resizes)
    func setContainerFrame(_ frame: CGRect) {
        containerFrame = frame
    }

    /// Notify geometry change to delegate (internal use)
    /// - Parameter isDragging: Whether the change is due to active divider dragging
    internal func notifyGeometryChange(isDragging: Bool = false) {
        guard !isExternalUpdateInProgress, !isDragging else { return }
        onGeometryChanged?(layoutSnapshot())
    }

}
