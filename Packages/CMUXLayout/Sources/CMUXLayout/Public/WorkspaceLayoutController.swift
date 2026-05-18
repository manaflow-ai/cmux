import Foundation
import SwiftUI

/// Main controller for the split tab bar system
@MainActor
@Observable
public final class WorkspaceLayoutController {

    public struct ExternalTabDropRequest {
        public enum Destination {
            case insert(targetPane: PaneID, targetIndex: Int?)
            case split(targetPane: PaneID, orientation: LayoutOrientation, insertFirst: Bool)
        }

        public let tabId: SurfaceID
        public let sourcePaneId: PaneID
        public let destination: Destination

        public init(tabId: SurfaceID, sourcePaneId: PaneID, destination: Destination) {
            self.tabId = tabId
            self.sourcePaneId = sourcePaneId
            self.destination = destination
        }
    }

    public struct ExternalFileDropRequest {
        public let urls: [URL]
        public let destination: ExternalTabDropRequest.Destination

        public init(urls: [URL], destination: ExternalTabDropRequest.Destination) {
            self.urls = urls
            self.destination = destination
        }
    }

    // MARK: - Delegate

    /// Delegate for receiving callbacks about tab bar events
    public weak var delegate: WorkspaceLayoutDelegate?

    // MARK: - Configuration

    /// Configuration for behavior and appearance
    public var configuration: WorkspaceLayoutConfiguration

    /// Canvas substrate shared by split panes, freeform overview, and scrolling-column layouts.
    public private(set) var canvasDocument: CanvasDocument

    /// Whether the host app should present the canvas overview/navigation surface.
    public private(set) var isCanvasOverviewActive: Bool = false

    /// Canvas item currently targeted by overview keyboard or pointer navigation.
    public private(set) var focusedCanvasItemID: LayoutItemID?

    /// When false, drop delegates reject all drags. Set to false for inactive workspaces
    /// so their views (kept alive in a ZStack for state preservation) don't intercept drags
    /// meant for the active workspace.
    @ObservationIgnored public var isInteractive: Bool = true {
        didSet { internalController.isInteractive = isInteractive }
    }

    /// Whether pane tab shortcut hints are currently actionable.
    ///
    /// Pane focus is internal to CMUXLayout, but host apps can move keyboard focus
    /// to external controls while keeping the focused pane selected. Set this
    /// to false when pane-number shortcuts should not currently be advertised.
    public var tabShortcutHintsEnabled: Bool = true {
        didSet { internalController.tabShortcutHintsEnabled = tabShortcutHintsEnabled }
    }

    /// Handler for file/URL drops from external apps (e.g., Finder).
    /// Called when files are dropped onto a pane's content area.
    /// Return `true` if the drop was handled.
    @ObservationIgnored public var onFileDrop: ((_ urls: [URL], _ paneId: PaneID) -> Bool)? {
        didSet { internalController.onFileDrop = onFileDrop }
    }

    /// Handler for tab drops originating from another CMUXLayout controller (e.g. another workspace/window).
    /// Return `true` when the drop has been handled by the host application.
    @ObservationIgnored public var onExternalTabDrop: ((ExternalTabDropRequest) -> Bool)?

    /// Handler for file drops from external apps, routed through pane drop zones.
    /// Return `true` when the drop has been handled by the host application.
    @ObservationIgnored public var onExternalFileDrop: ((ExternalFileDropRequest) -> Bool)?

    /// Host-provided destinations for the tab context menu's Move Surface submenu.
    @ObservationIgnored public var tabContextMoveDestinationsProvider: ((SurfaceID, PaneID) -> [SurfaceMoveDestination])?

    /// Called when the user explicitly requests to close a tab from the tab strip UI.
    /// Internal host-driven closes should not use this hook.
    @ObservationIgnored public var onTabCloseRequest: ((_ tabId: SurfaceID, _ paneId: PaneID) -> Void)?

    // MARK: - Internal State

    internal var internalController: SplitViewController

    // MARK: - Initialization

    /// Create a new controller with the specified configuration
    public init(configuration: WorkspaceLayoutConfiguration = .default) {
        let internalController = SplitViewController()
        self.configuration = configuration
        self.internalController = internalController
        self.canvasDocument = CanvasDocument.defaultScrollingColumns(
            panes: internalController.rootNode.allPaneIds
        )
        self.focusedCanvasItemID = self.canvasDocument.items.first { item in
            guard case .pane(let paneID) = item.content else { return false }
            return paneID == internalController.focusedPaneId
        }?.id
    }

    // MARK: - SurfaceTab Operations

    /// Create a new tab in the focused pane (or specified pane)
    /// - Parameters:
    ///   - title: The tab title
    ///   - icon: Optional SF Symbol name for the tab icon
    ///   - iconImageData: Optional image data (PNG recommended) for the tab icon. When present, takes precedence over `icon`.
    ///   - kind: Consumer-defined tab kind identifier (e.g. "terminal", "browser")
    ///   - hasCustomTitle: Whether the tab title came from a custom user override
    ///   - isDirty: Whether the tab shows a dirty indicator
    ///   - showsNotificationBadge: Whether the tab shows an "unread/activity" badge
    ///   - isLoading: Whether the tab shows an activity/loading indicator (e.g. spinning icon)
    ///   - isPinned: Whether the tab should be treated as pinned
    ///   - pane: Optional pane to add the tab to (defaults to focused pane)
    /// - Returns: The SurfaceID of the created tab, or nil if creation was vetoed by delegate
    @discardableResult
    public func createTab(
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = "doc.text",
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false,
        inPane pane: PaneID? = nil
    ) -> SurfaceID? {
        let tabId = SurfaceID()
        let tab = SurfaceTab(
            id: tabId,
            title: title,
            hasCustomTitle: hasCustomTitle,
            icon: icon,
            iconImageData: iconImageData,
            kind: kind,
            isDirty: isDirty,
            showsNotificationBadge: showsNotificationBadge,
            isLoading: isLoading,
            isPinned: isPinned
        )
        let targetPane = pane ?? focusedPaneId ?? PaneID(id: internalController.rootNode.allPaneIds.first!.id)

        // Check with delegate
        if delegate?.splitTabBar(self, shouldCreateTab: tab, inPane: targetPane) == false {
            return nil
        }

        // Calculate insertion index based on configuration
        let insertIndex: Int?
        switch configuration.newTabPosition {
        case .current:
            // Insert after the currently selected tab
            if let paneState = internalController.rootNode.findPane(PaneID(id: targetPane.id)),
               let selectedTabId = paneState.selectedTabId,
               let currentIndex = paneState.tabs.firstIndex(where: { $0.id == selectedTabId }) {
                insertIndex = currentIndex + 1
            } else {
                // No selected tab, append to end
                insertIndex = nil
            }
        case .end:
            insertIndex = nil
        }

        // Create internal SurfaceItem
        let tabItem = SurfaceItem(
            id: tabId.id,
            title: title,
            hasCustomTitle: hasCustomTitle,
            icon: icon,
            iconImageData: iconImageData,
            kind: kind,
            isDirty: isDirty,
            showsNotificationBadge: showsNotificationBadge,
            isLoading: isLoading,
            isPinned: isPinned
        )
        internalController.addTab(tabItem, toPane: PaneID(id: targetPane.id), atIndex: insertIndex)
        syncCanvasDocumentWithCurrentLayout()

        // Notify delegate
        delegate?.splitTabBar(self, didCreateTab: tab, inPane: targetPane)

        return tabId
    }

    /// Request the delegate to create a new tab of the given kind in a pane.
    /// The delegate is responsible for the actual creation logic.
    public func requestNewTab(kind: String, inPane pane: PaneID) {
        delegate?.splitTabBar(self, didRequestNewTab: kind, inPane: pane)
    }

    /// Request the delegate to handle a host-defined tab bar action.
    public func requestCustomAction(_ identifier: String, inPane pane: PaneID) {
        delegate?.splitTabBar(self, didRequestCustomAction: identifier, inPane: pane)
    }

    /// Request the delegate to handle a tab context-menu action.
    public func requestSurfaceContextAction(_ action: SurfaceContextAction, for tabId: SurfaceID, inPane pane: PaneID) {
        guard let tab = tab(tabId) else { return }
        delegate?.splitTabBar(self, didRequestSurfaceContextAction: action, for: tab, inPane: pane)
    }

    /// Request the delegate to move a tab to a host-provided destination.
    public func requestTabMove(toDestination destinationId: String, for tabId: SurfaceID, inPane pane: PaneID) {
        guard let tab = tab(tabId) else { return }
        delegate?.splitTabBar(self, didRequestTabMoveToDestination: destinationId, for: tab, inPane: pane)
    }

    /// Update an existing tab's metadata
    /// - Parameters:
    ///   - tabId: The tab to update
    ///   - title: New title (pass nil to keep current)
    ///   - icon: New icon (pass nil to keep current, pass .some(nil) to remove icon)
    ///   - iconImageData: New icon image data (pass nil to keep current, pass .some(nil) to remove)
    ///   - kind: New tab kind (pass nil to keep current, pass .some(nil) to clear)
    ///   - hasCustomTitle: New custom-title state (pass nil to keep current)
    ///   - isDirty: New dirty state (pass nil to keep current)
    ///   - showsNotificationBadge: New badge state (pass nil to keep current)
    ///   - isLoading: New loading/busy state (pass nil to keep current)
    ///   - isPinned: New pinned state (pass nil to keep current)
    public func updateTab(
        _ tabId: SurfaceID,
        title: String? = nil,
        icon: String?? = nil,
        iconImageData: Data?? = nil,
        kind: String?? = nil,
        hasCustomTitle: Bool? = nil,
        isDirty: Bool? = nil,
        showsNotificationBadge: Bool? = nil,
        isLoading: Bool? = nil,
        isPinned: Bool? = nil
    ) {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return }

        if let title = title {
            pane.tabs[tabIndex].title = title
        }
        if let icon = icon {
            pane.tabs[tabIndex].icon = icon
        }
        if let iconImageData = iconImageData {
            pane.tabs[tabIndex].iconImageData = iconImageData
        }
        if let kind = kind {
            pane.tabs[tabIndex].kind = kind
        }
        if let hasCustomTitle = hasCustomTitle {
            pane.tabs[tabIndex].hasCustomTitle = hasCustomTitle
        }
        if let isDirty = isDirty {
            pane.tabs[tabIndex].isDirty = isDirty
        }
        if let showsNotificationBadge = showsNotificationBadge {
            pane.tabs[tabIndex].showsNotificationBadge = showsNotificationBadge
        }
        if let isLoading = isLoading {
            pane.tabs[tabIndex].isLoading = isLoading
        }
        if let isPinned = isPinned {
            pane.tabs[tabIndex].isPinned = isPinned
        }
    }

    /// Close a tab by ID
    /// - Parameter tabId: The tab to close
    /// - Returns: true if the tab was closed, false if vetoed by delegate
    @discardableResult
    public func closeTab(_ tabId: SurfaceID) -> Bool {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return false }
        return closeTab(tabId, with: tabIndex, in: pane)
    }
    
    /// Close a tab by ID in a specific pane.
    /// - Parameter tabId: The tab to close
    /// - Parameter paneId: The pane in which to close the tab
    public func closeTab(_ tabId: SurfaceID, inPane paneId: PaneID) -> Bool {
        guard let pane = internalController.rootNode.findPane(paneId),
              let tabIndex = pane.tabs.firstIndex(where: { $0.id == tabId.id }) else {
            return false
        }
        
        return closeTab(tabId, with: tabIndex, in: pane)
    }
    
    /// Internal helper to close a tab given its index in a pane
    /// - Parameter tabId: The tab to close
    /// - Parameter tabIndex: The position of the tab within the pane
    /// - Parameter pane: The pane in which to close the tab
    private func closeTab(_ tabId: SurfaceID, with tabIndex: Int, in pane: PaneState) -> Bool {
        let tabItem = pane.tabs[tabIndex]
        let tab = SurfaceTab(from: tabItem)
        let paneId = pane.id

        // Check with delegate
        if delegate?.splitTabBar(self, shouldCloseTab: tab, inPane: paneId) == false {
            return false
        }

        internalController.closeTab(tabId.id, inPane: pane.id)
        syncCanvasDocumentWithCurrentLayout()

        // Notify delegate
        delegate?.splitTabBar(self, didCloseTab: tabId, fromPane: paneId)
        notifyGeometryChange()

        return true
    }

    /// Select a tab by ID
    /// - Parameter tabId: The tab to select
    public func selectTab(_ tabId: SurfaceID) {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return }

        pane.selectTab(tabId.id)
        internalController.focusPane(pane.id)

        // Notify delegate
        let tab = SurfaceTab(from: pane.tabs[tabIndex])
        delegate?.splitTabBar(self, didSelectTab: tab, inPane: pane.id)
    }

    /// Move a tab to a specific pane (and optional index) inside this controller.
    /// - Parameters:
    ///   - tabId: The tab to move.
    ///   - targetPaneId: Destination pane.
    ///   - index: Optional destination index. When nil, appends at the end.
    /// - Returns: true if moved.
    @discardableResult
    public func moveTab(_ tabId: SurfaceID, toPane targetPaneId: PaneID, atIndex index: Int? = nil) -> Bool {
        guard let (sourcePane, sourceIndex) = findTabInternal(tabId) else { return false }
        guard let targetPane = internalController.rootNode.findPane(PaneID(id: targetPaneId.id)) else { return false }

        let tabItem = sourcePane.tabs[sourceIndex]
        let movedTab = SurfaceTab(from: tabItem)
        let sourcePaneId = sourcePane.id

        if sourcePaneId == targetPane.id {
            // Reorder within same pane.
            let destinationIndex: Int = {
                if let index { return max(0, min(index, sourcePane.tabs.count)) }
                return sourcePane.tabs.count
            }()
            sourcePane.moveTab(from: sourceIndex, to: destinationIndex)
            sourcePane.selectTab(tabItem.id)
            internalController.focusPane(sourcePane.id)
            delegate?.splitTabBar(self, didSelectTab: movedTab, inPane: sourcePane.id)
            notifyGeometryChange()
            return true
        }

        internalController.moveTab(tabItem, from: sourcePaneId, to: targetPane.id, atIndex: index)
        syncCanvasDocumentWithCurrentLayout()
        delegate?.splitTabBar(self, didMoveTab: movedTab, fromPane: sourcePaneId, toPane: targetPane.id)
        notifyGeometryChange()
        return true
    }

    /// Reorder a tab within its pane.
    /// - Parameters:
    ///   - tabId: The tab to reorder.
    ///   - toIndex: Destination index.
    /// - Returns: true if reordered.
    @discardableResult
    public func reorderTab(_ tabId: SurfaceID, toIndex: Int) -> Bool {
        guard let (pane, sourceIndex) = findTabInternal(tabId) else { return false }
        let destinationIndex = max(0, min(toIndex, pane.tabs.count))
        pane.moveTab(from: sourceIndex, to: destinationIndex)
        pane.selectTab(tabId.id)
        internalController.focusPane(pane.id)
        if let tabIndex = pane.tabs.firstIndex(where: { $0.id == tabId.id }) {
            let tab = SurfaceTab(from: pane.tabs[tabIndex])
            delegate?.splitTabBar(self, didSelectTab: tab, inPane: pane.id)
        }
        notifyGeometryChange()
        return true
    }

    /// Move to previous tab in focused pane
    public func selectPreviousTab() {
        internalController.selectPreviousTab()
        notifyTabSelection()
    }

    /// Move to next tab in focused pane
    public func selectNextTab() {
        internalController.selectNextTab()
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
    public func splitPane(
        _ paneId: PaneID? = nil,
        orientation: LayoutOrientation,
        withTab tab: SurfaceTab? = nil,
        initialDividerPosition: CGFloat? = nil
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }

        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return nil }

        // Check with delegate
        if delegate?.splitTabBar(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        let internalTab: SurfaceItem?
        if let tab {
            internalTab = SurfaceItem(
                id: tab.id.id,
                title: tab.title,
                hasCustomTitle: tab.hasCustomTitle,
                icon: tab.icon,
                iconImageData: tab.iconImageData,
                kind: tab.kind,
                isDirty: tab.isDirty,
                showsNotificationBadge: tab.showsNotificationBadge,
                isLoading: tab.isLoading,
                isPinned: tab.isPinned
            )
        } else {
            internalTab = nil
        }

        // Perform split
        internalController.splitPane(
            PaneID(id: targetPaneId.id),
            orientation: orientation,
            with: internalTab,
            initialDividerPosition: initialDividerPosition
        )
        syncCanvasDocumentWithCurrentLayout()

        // Find new pane (will be focused after split)
        let newPaneId = focusedPaneId!

        // Notify delegate
        delegate?.splitTabBar(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

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
    public func splitPane(
        _ paneId: PaneID? = nil,
        orientation: LayoutOrientation,
        withTab tab: SurfaceTab,
        insertFirst: Bool,
        initialDividerPosition: CGFloat? = nil
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }

        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return nil }

        // Check with delegate
        if delegate?.splitTabBar(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        let internalTab = SurfaceItem(
            id: tab.id.id,
            title: tab.title,
            hasCustomTitle: tab.hasCustomTitle,
            icon: tab.icon,
            iconImageData: tab.iconImageData,
            kind: tab.kind,
            isDirty: tab.isDirty,
            showsNotificationBadge: tab.showsNotificationBadge,
            isLoading: tab.isLoading,
            isPinned: tab.isPinned
        )

        // Perform split with insertion side.
        internalController.splitPaneWithTab(
            PaneID(id: targetPaneId.id),
            orientation: orientation,
            tab: internalTab,
            insertFirst: insertFirst,
            initialDividerPosition: initialDividerPosition
        )
        syncCanvasDocumentWithCurrentLayout()

        let newPaneId = focusedPaneId!

        // Notify delegate
        delegate?.splitTabBar(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

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
    public func splitPane(
        _ paneId: PaneID? = nil,
        orientation: LayoutOrientation,
        movingTab tabId: SurfaceID,
        insertFirst: Bool
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }

        // Find the existing tab and its source pane.
        guard let (sourcePane, tabIndex) = findTabInternal(tabId) else { return nil }
        let tabItem = sourcePane.tabs[tabIndex]

        // Default target to the tab's current pane to match edge-drop behavior on the source pane.
        let targetPaneId = paneId ?? sourcePane.id

        // Check with delegate
        if delegate?.splitTabBar(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        // Remove from source first.
        sourcePane.removeTab(tabItem.id)

        if sourcePane.tabs.isEmpty {
            if sourcePane.id == targetPaneId {
                // Keep a placeholder tab so the original pane isn't left "tabless".
                // This makes the empty side closable via tab close, and avoids apps
                // needing to special-case empty panes.
                sourcePane.addTab(SurfaceItem(title: "Empty", icon: nil), select: true)
            } else if internalController.rootNode.allPaneIds.count > 1 {
                // If the source pane is now empty, close it (unless it's also the split target).
                internalController.closePane(sourcePane.id)
            }
        }

        // Perform split with the moved tab.
        internalController.splitPaneWithTab(
            PaneID(id: targetPaneId.id),
            orientation: orientation,
            tab: tabItem,
            insertFirst: insertFirst
        )
        syncCanvasDocumentWithCurrentLayout()

        let newPaneId = focusedPaneId!

        // Notify delegate
        delegate?.splitTabBar(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

        notifyGeometryChange()

        return newPaneId
    }

    /// Close a specific pane
    /// - Parameter paneId: The pane to close
    /// - Returns: true if the pane was closed, false if vetoed by delegate
    @discardableResult
    public func closePane(_ paneId: PaneID) -> Bool {
        // Don't close if it's the last pane and not allowed
        if !configuration.allowCloseLastPane && internalController.rootNode.allPaneIds.count <= 1 {
            return false
        }

        // Check with delegate
        if delegate?.splitTabBar(self, shouldClosePane: paneId) == false {
            return false
        }

        internalController.closePane(PaneID(id: paneId.id))
        syncCanvasDocumentWithCurrentLayout()

        // Notify delegate
        delegate?.splitTabBar(self, didClosePane: paneId)

        notifyGeometryChange()

        return true
    }

    // MARK: - Focus Management

    /// Currently focused pane ID
    public var focusedPaneId: PaneID? {
        guard let internalId = internalController.focusedPaneId else { return nil }
        return internalId
    }

    /// Focus a specific pane
    public func focusPane(_ paneId: PaneID) {
        internalController.focusPane(PaneID(id: paneId.id))
        if let item = canvasItem(forPane: paneId) {
            focusedCanvasItemID = item.id
        }
        delegate?.splitTabBar(self, didFocusPane: paneId)
    }

    /// Navigate focus in a direction
    public func navigateFocus(direction: NavigationDirection) {
        internalController.navigateFocus(direction: direction)
        if let focusedPaneId {
            delegate?.splitTabBar(self, didFocusPane: focusedPaneId)
        }
    }

    /// Find the closest pane in the requested direction from the given pane.
    public func adjacentPane(to paneId: PaneID, direction: NavigationDirection) -> PaneID? {
        internalController.adjacentPane(to: paneId, direction: direction)
    }

    // MARK: - Split Zoom

    /// Currently zoomed pane ID, if any.
    public var zoomedPaneId: PaneID? {
        internalController.zoomedPaneId
    }

    public var isSplitZoomed: Bool {
        internalController.zoomedPaneId != nil
    }

    @discardableResult
    public func clearPaneZoom() -> Bool {
        internalController.clearPaneZoom()
    }

    /// Toggle zoom for a pane. When zoomed, only that pane is rendered in the split area.
    /// Passing nil toggles the currently focused pane.
    @discardableResult
    public func togglePaneZoom(inPane paneId: PaneID? = nil) -> Bool {
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return false }
        return internalController.togglePaneZoom(targetPaneId)
    }

    // MARK: - Context Menu Shortcut Hints

    /// Keyboard shortcuts to display in tab context menus, keyed by context action.
    /// Set by the host app to sync with its customizable keyboard shortcut settings.
    public var contextMenuShortcuts: [SurfaceContextAction: KeyboardShortcut] = [:]

    // MARK: - Canvas API

    public var canvasLayoutPolicy: CanvasLayoutPolicy {
        canvasDocument.policy
    }

    public var canvasViewport: CanvasViewport {
        canvasDocument.viewport
    }

    public func setCanvasLayoutPolicy(_ policy: CanvasLayoutPolicy) {
        canvasDocument.policy = policy
        syncCanvasDocumentWithCurrentLayout()
    }

    public func setCanvasViewport(_ viewport: CanvasViewport) {
        canvasDocument.viewport = viewport
    }

    public func setCanvasViewportScale(_ scale: Double) {
        canvasDocument.viewport.setScale(scale)
    }

    public func panCanvasViewport(screenDelta: CGSize, scale: CGFloat, viewportSize: CGSize) {
        let safeScale = max(0.0001, scale)
        var viewport = canvasDocument.viewport
        viewport.setVisibleRect(
            PixelRect(
                x: viewport.visibleRect.x - Double(screenDelta.width / safeScale),
                y: viewport.visibleRect.y - Double(screenDelta.height / safeScale),
                width: max(1, Double(viewportSize.width / safeScale)),
                height: max(1, Double(viewportSize.height / safeScale))
            )
        )
        canvasDocument.viewport = viewport
    }

    public func enterCanvasOverview(
        policy: CanvasLayoutPolicy? = nil,
        scale: Double? = nil,
        focusing itemID: LayoutItemID? = nil
    ) {
        if let policy {
            canvasDocument.policy = policy
        }
        if let scale {
            canvasDocument.viewport.setScale(scale)
        }
        syncCanvasDocumentWithCurrentLayout()
        isCanvasOverviewActive = true

        if let itemID, canvasDocument.items.contains(where: { $0.id == itemID }) {
            focusedCanvasItemID = itemID
            return
        }

        focusCanvasItemForFocusedPaneOrFirst()
    }

    public func exitCanvasOverview() {
        isCanvasOverviewActive = false
    }

    @discardableResult
    public func setPaneZoom(_ paneID: PaneID?) -> Bool {
        if zoomedPaneId == paneID {
            return true
        }
        if zoomedPaneId != nil {
            _ = clearPaneZoom()
        }
        guard let paneID else {
            return true
        }
        return internalController.togglePaneZoom(paneID)
    }

    @discardableResult
    public func focusCanvasItem(_ itemID: LayoutItemID) -> Bool {
        syncCanvasDocumentWithCurrentLayout()
        guard canvasDocument.items.contains(where: { $0.id == itemID }) else { return false }
        focusedCanvasItemID = itemID
        return true
    }

    @discardableResult
    public func navigateCanvasFocus(direction: NavigationDirection) -> LayoutItemID? {
        syncCanvasDocumentWithCurrentLayout()
        guard !canvasDocument.items.isEmpty else {
            focusedCanvasItemID = nil
            return nil
        }

        let currentItem = focusedCanvasItemID.flatMap(canvasItem(id:))
            ?? focusedPaneId.flatMap(canvasItem(forPane:))
            ?? canvasDocument.items.first

        guard let currentItem else { return nil }
        guard let nextItem = bestCanvasNeighbor(from: currentItem, direction: direction) else {
            focusedCanvasItemID = currentItem.id
            return currentItem.id
        }

        focusedCanvasItemID = nextItem.id
        return nextItem.id
    }

    public func moveCanvasItem(_ itemID: LayoutItemID, to frame: PixelRect) {
        canvasDocument.moveItem(itemID, to: frame)
        syncCanvasDocumentWithCurrentLayout()
    }

    public func resizeCanvasItem(_ itemID: LayoutItemID, to frame: PixelRect) {
        canvasDocument.resizeItem(itemID, to: frame)
        syncCanvasDocumentWithCurrentLayout()
    }

    public func canvasItem(id itemID: LayoutItemID) -> CanvasItem? {
        canvasDocument.items.first { $0.id == itemID }
    }

    public func canvasItem(forPane paneID: PaneID) -> CanvasItem? {
        canvasDocument.items.first { item in
            guard case .pane(let itemPaneID) = item.content else { return false }
            return itemPaneID == paneID
        }
    }

    @discardableResult
    public func focusPane(forCanvasItem itemID: LayoutItemID) -> PaneID? {
        syncCanvasDocumentWithCurrentLayout()
        guard let item = canvasItem(id: itemID) else { return nil }

        switch item.content {
        case .pane(let paneID):
            guard internalController.rootNode.findPane(paneID) != nil else { return nil }
            focusedCanvasItemID = itemID
            focusPane(paneID)
            return paneID
        case .surface(let surfaceID):
            guard let (pane, _) = findTabInternal(surfaceID) else { return nil }
            focusedCanvasItemID = itemID
            selectSurface(surfaceID)
            return pane.id
        case .group:
            return nil
        }
    }

    @discardableResult
    public func activateCanvasItem(_ itemID: LayoutItemID) -> PaneID? {
        guard let paneID = focusPane(forCanvasItem: itemID) else { return nil }
        exitCanvasOverview()
        return paneID
    }

    @discardableResult
    public func activateFocusedCanvasItem() -> PaneID? {
        guard let focusedCanvasItemID else { return nil }
        return activateCanvasItem(focusedCanvasItemID)
    }

    public func canvasSnapshot() -> CanvasDocument {
        return canvasDocument
    }

    public func canvasSceneSnapshot(activeItemID: LayoutItemID? = nil) -> CanvasSceneSnapshot {
        return CanvasSceneSnapshot(
            document: canvasDocument,
            focusedItemID: focusedCanvasItemID,
            activeItemID: activeItemID
        )
    }

    // MARK: - Query Methods

    /// Create a surface in the focused pane (or specified pane).
    @discardableResult
    public func createSurface(
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = "doc.text",
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false,
        inPane pane: PaneID? = nil
    ) -> SurfaceID? {
        createTab(
            title: title,
            hasCustomTitle: hasCustomTitle,
            icon: icon,
            iconImageData: iconImageData,
            kind: kind,
            isDirty: isDirty,
            showsNotificationBadge: showsNotificationBadge,
            isLoading: isLoading,
            isPinned: isPinned,
            inPane: pane
        )
    }

    @discardableResult
    public func closeSurface(_ surfaceId: SurfaceID) -> Bool {
        closeTab(surfaceId)
    }

    public func selectSurface(_ surfaceId: SurfaceID) {
        selectTab(surfaceId)
    }

    @discardableResult
    public func moveSurface(_ surfaceId: SurfaceID, toPane paneId: PaneID, atIndex index: Int? = nil) -> Bool {
        moveTab(surfaceId, toPane: paneId, atIndex: index)
    }

    public var allSurfaceIds: [SurfaceID] {
        allTabIds
    }

    public func surface(_ surfaceId: SurfaceID) -> SurfaceTab? {
        tab(surfaceId)
    }

    public func surfaces(inPane paneId: PaneID) -> [SurfaceTab] {
        tabs(inPane: paneId)
    }

    public func selectedSurface(inPane paneId: PaneID) -> SurfaceTab? {
        selectedTab(inPane: paneId)
    }

    /// Get all tab IDs
    public var allTabIds: [SurfaceID] {
        internalController.rootNode.allPanes.flatMap { pane in
            pane.tabs.map { SurfaceID(id: $0.id) }
        }
    }

    /// Get all pane IDs
    public var allPaneIds: [PaneID] {
        internalController.rootNode.allPaneIds
    }

    /// Get tab metadata by ID
    public func tab(_ tabId: SurfaceID) -> SurfaceTab? {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return nil }
        return SurfaceTab(from: pane.tabs[tabIndex])
    }

    /// Get tabs in a specific pane
    public func tabs(inPane paneId: PaneID) -> [SurfaceTab] {
        guard let pane = internalController.rootNode.findPane(PaneID(id: paneId.id)) else {
            return []
        }
        return pane.tabs.map { SurfaceTab(from: $0) }
    }

    /// Get selected tab in a pane
    public func selectedTab(inPane paneId: PaneID) -> SurfaceTab? {
        guard let pane = internalController.rootNode.findPane(PaneID(id: paneId.id)),
              let selected = pane.selectedTab else {
            return nil
        }
        return SurfaceTab(from: selected)
    }

    // MARK: - Geometry Query API

    /// Get current layout snapshot with pixel coordinates
    public func layoutSnapshot() -> PaneLayoutSnapshot {
        let containerFrame = internalController.containerFrame
        let paneBounds = internalController.rootNode.computePaneBounds()

        let paneGeometries = paneBounds.map { bounds -> PaneGeometry in
            let pane = internalController.rootNode.findPane(bounds.paneId)
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
                tabIds: pane?.tabs.map { $0.id.uuidString } ?? []
            )
        }

        return PaneLayoutSnapshot(
            containerFrame: PixelRect(from: containerFrame),
            panes: paneGeometries,
            focusedPaneId: focusedPaneId?.id.uuidString,
            timestamp: Date().timeIntervalSince1970
        )
    }

    /// Get full tree structure for external consumption
    public func treeSnapshot() -> ExternalTreeNode {
        let containerFrame = internalController.containerFrame
        return buildExternalTree(from: internalController.rootNode, containerFrame: containerFrame)
    }

    private func buildExternalTree(from node: SplitNode, containerFrame: CGRect, bounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> ExternalTreeNode {
        switch node {
        case .pane(let paneState):
            let pixelFrame = PixelRect(
                x: Double(bounds.minX * containerFrame.width + containerFrame.origin.x),
                y: Double(bounds.minY * containerFrame.height + containerFrame.origin.y),
                width: Double(bounds.width * containerFrame.width),
                height: Double(bounds.height * containerFrame.height)
            )
            let tabs = paneState.tabs.map { ExternalTab(id: $0.id.uuidString, title: $0.title) }
            let paneNode = ExternalPaneNode(
                id: paneState.id.id.uuidString,
                frame: pixelFrame,
                tabs: tabs,
                selectedTabId: paneState.selectedTabId?.uuidString
            )
            return .pane(paneNode)

        case .split(let splitState):
            let dividerPos = splitState.dividerPosition
            let firstBounds: CGRect
            let secondBounds: CGRect

            switch splitState.orientation {
            case .horizontal:
                firstBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                     width: bounds.width * dividerPos, height: bounds.height)
                secondBounds = CGRect(x: bounds.minX + bounds.width * dividerPos, y: bounds.minY,
                                      width: bounds.width * (1 - dividerPos), height: bounds.height)
            case .vertical:
                firstBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                     width: bounds.width, height: bounds.height * dividerPos)
                secondBounds = CGRect(x: bounds.minX, y: bounds.minY + bounds.height * dividerPos,
                                      width: bounds.width, height: bounds.height * (1 - dividerPos))
            }

            let splitNode = ExternalSplitNode(
                id: splitState.id.uuidString,
                orientation: splitState.orientation == .horizontal ? "horizontal" : "vertical",
                dividerPosition: Double(splitState.dividerPosition),
                first: buildExternalTree(from: splitState.first, containerFrame: containerFrame, bounds: firstBounds),
                second: buildExternalTree(from: splitState.second, containerFrame: containerFrame, bounds: secondBounds)
            )
            return .split(splitNode)
        }
    }

    /// Check if a split exists by ID
    public func findSplit(_ splitId: UUID) -> Bool {
        return internalController.findSplit(splitId) != nil
    }

    // MARK: - Geometry Update API

    /// Set divider position for a split node (0.0-1.0)
    /// - Parameters:
    ///   - position: The new divider position (clamped to 0.1-0.9)
    ///   - splitId: The UUID of the split to update
    ///   - fromExternal: Set to true to suppress outgoing notifications (prevents loops)
    /// - Returns: true if the split was found and updated
    @discardableResult
    public func setDividerPosition(_ position: CGFloat, forSplit splitId: UUID, fromExternal: Bool = false) -> Bool {
        guard let split = internalController.findSplit(splitId) else { return false }

        if fromExternal {
            internalController.isExternalUpdateInProgress = true
        }

        // Clamp position to valid range
        let clampedPosition = min(max(position, 0.1), 0.9)
        split.dividerPosition = clampedPosition
        syncCanvasDocumentWithCurrentLayout()

        if fromExternal {
            // Use a slight delay to allow the UI to update before re-enabling notifications
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.internalController.isExternalUpdateInProgress = false
            }
        }

        return true
    }

    /// Update container frame (called when window moves/resizes)
    public func setContainerFrame(_ frame: CGRect) {
        internalController.containerFrame = frame
        syncCanvasDocumentWithCurrentLayout()
    }

    /// Notify geometry change to delegate (internal use)
    /// - Parameter isDragging: Whether the change is due to active divider dragging
    internal func notifyGeometryChange(isDragging: Bool = false) {
        guard !internalController.isExternalUpdateInProgress else { return }

        // If dragging, check if delegate wants notifications during drag
        if isDragging {
            let shouldNotify = delegate?.splitTabBar(self, shouldNotifyDuringDrag: true) ?? false
            guard shouldNotify else { return }
        }

        if isDragging {
            // Debounce drag updates to avoid flooding delegates during divider moves.
            let now = Date().timeIntervalSince1970
            let debounceInterval: TimeInterval = 0.05
            guard now - internalController.lastGeometryNotificationTime >= debounceInterval else { return }
            internalController.lastGeometryNotificationTime = now
        }

        let snapshot = layoutSnapshot()
        delegate?.splitTabBar(self, didChangeGeometry: snapshot)
    }

    // MARK: - Private Helpers

    private func syncCanvasDocumentWithCurrentLayout() {
        let nextItems: [CanvasItem]
        switch canvasDocument.policy {
        case .scrollingColumns:
            nextItems = scrollingColumnCanvasItems()
        case .freeform:
            nextItems = freeformCanvasItemsPreservingExistingFrames()
        }
        if canvasDocument.items != nextItems {
            canvasDocument.items = nextItems
        }
        reconcileFocusedCanvasItem()
    }

    private func scrollingColumnCanvasItems() -> [CanvasItem] {
        let panes = internalController.rootNode.allPaneIds
        guard !panes.isEmpty else { return [] }

        let containerFrame = internalController.containerFrame
        let visibleRect = canvasDocument.viewport.visibleRect
        let columnWidth: Double
        let columnHeight: Double
        if containerFrame.width > 1, containerFrame.height > 1 {
            columnWidth = Double(containerFrame.width)
            columnHeight = Double(containerFrame.height)
        } else if visibleRect.width > 1, visibleRect.height > 1 {
            columnWidth = visibleRect.width
            columnHeight = visibleRect.height
        } else {
            columnWidth = 1_200
            columnHeight = 800
        }

        return CanvasDocument.defaultScrollingColumns(
            panes: panes,
            viewport: canvasDocument.viewport,
            columnWidth: columnWidth,
            columnHeight: columnHeight
        ).items
    }

    private func freeformCanvasItemsPreservingExistingFrames() -> [CanvasItem] {
        let fallback = scrollingColumnCanvasItems()
        let existingByPane = Dictionary(uniqueKeysWithValues: canvasDocument.items.compactMap { item -> (PaneID, CanvasItem)? in
            guard case .pane(let paneID) = item.content else { return nil }
            return (paneID, item)
        })

        return fallback.map { item in
            guard case .pane(let paneID) = item.content,
                  let existing = existingByPane[paneID] else {
                return item
            }
            return existing
        }
    }

    private func reconcileFocusedCanvasItem() {
        if let focusedCanvasItemID,
           canvasDocument.items.contains(where: { $0.id == focusedCanvasItemID }) {
            return
        }
        focusCanvasItemForFocusedPaneOrFirst()
    }

    private func focusCanvasItemForFocusedPaneOrFirst() {
        if let focusedPaneId,
           let item = canvasDocument.items.first(where: { item in
               guard case .pane(let paneID) = item.content else { return false }
               return paneID == focusedPaneId
           }) {
            focusedCanvasItemID = item.id
            return
        }

        focusedCanvasItemID = canvasDocument.items.first?.id
    }

    private func bestCanvasNeighbor(from currentItem: CanvasItem, direction: NavigationDirection) -> CanvasItem? {
        let epsilon = 0.001
        let candidates = canvasDocument.items.filter { item in
            guard item.id != currentItem.id else { return false }
            switch direction {
            case .left:
                return item.frame.maxX <= currentItem.frame.minX + epsilon
            case .right:
                return item.frame.minX >= currentItem.frame.maxX - epsilon
            case .up:
                return item.frame.maxY <= currentItem.frame.minY + epsilon
            case .down:
                return item.frame.minY >= currentItem.frame.maxY - epsilon
            }
        }

        return candidates
            .map { item -> (item: CanvasItem, overlap: Double, distance: Double) in
                let overlap: Double
                let distance: Double

                switch direction {
                case .left, .right:
                    overlap = max(0, min(currentItem.frame.maxY, item.frame.maxY) - max(currentItem.frame.minY, item.frame.minY))
                    distance = direction == .left
                        ? currentItem.frame.minX - item.frame.maxX
                        : item.frame.minX - currentItem.frame.maxX
                case .up, .down:
                    overlap = max(0, min(currentItem.frame.maxX, item.frame.maxX) - max(currentItem.frame.minX, item.frame.minX))
                    distance = direction == .up
                        ? currentItem.frame.minY - item.frame.maxY
                        : item.frame.minY - currentItem.frame.maxY
                }

                return (item, overlap, distance)
            }
            .sorted { lhs, rhs in
                if abs(lhs.overlap - rhs.overlap) > epsilon {
                    return lhs.overlap > rhs.overlap
                }
                if abs(lhs.distance - rhs.distance) > epsilon {
                    return lhs.distance < rhs.distance
                }
                if lhs.item.zIndex != rhs.item.zIndex {
                    return lhs.item.zIndex < rhs.item.zIndex
                }
                return lhs.item.id.description < rhs.item.id.description
            }
            .first?
            .item
    }

    private func findTabInternal(_ tabId: SurfaceID) -> (PaneState, Int)? {
        for pane in internalController.rootNode.allPanes {
            if let index = pane.tabs.firstIndex(where: { $0.id == tabId.id }) {
                return (pane, index)
            }
        }
        return nil
    }

    private func notifyTabSelection() {
        guard let pane = internalController.focusedPane,
              let tabItem = pane.selectedTab else { return }
        let tab = SurfaceTab(from: tabItem)
        delegate?.splitTabBar(self, didSelectTab: tab, inPane: pane.id)
    }
}

private extension PixelRect {
    var minX: Double { x }
    var maxX: Double { x + width }
    var minY: Double { y }
    var maxY: Double { y + height }
}
