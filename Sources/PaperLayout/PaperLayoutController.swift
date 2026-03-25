import Foundation
import SwiftUI

// MARK: - Configuration

struct PaperLayoutConfiguration: Sendable {
    var allowSplits: Bool
    var allowCloseTabs: Bool
    var allowCloseLastPane: Bool
    var allowTabReordering: Bool
    var allowCrossPaneTabMove: Bool
    var autoCloseEmptyPanes: Bool
    var contentViewLifecycle: ContentViewLifecycle
    var newTabPosition: NewTabPosition
    var appearance: Appearance

    static let `default` = PaperLayoutConfiguration()

    init(
        allowSplits: Bool = true,
        allowCloseTabs: Bool = true,
        allowCloseLastPane: Bool = false,
        allowTabReordering: Bool = true,
        allowCrossPaneTabMove: Bool = true,
        autoCloseEmptyPanes: Bool = true,
        contentViewLifecycle: ContentViewLifecycle = .keepAllAlive,
        newTabPosition: NewTabPosition = .current,
        appearance: Appearance = .default
    ) {
        self.allowSplits = allowSplits
        self.allowCloseTabs = allowCloseTabs
        self.allowCloseLastPane = allowCloseLastPane
        self.allowTabReordering = allowTabReordering
        self.allowCrossPaneTabMove = allowCrossPaneTabMove
        self.autoCloseEmptyPanes = autoCloseEmptyPanes
        self.contentViewLifecycle = contentViewLifecycle
        self.newTabPosition = newTabPosition
        self.appearance = appearance
    }

    struct Appearance: Sendable {
        struct ChromeColors: Sendable {
            public var backgroundHex: String?
            public var borderHex: String?
            public init(backgroundHex: String? = nil, borderHex: String? = nil) {
                self.backgroundHex = backgroundHex
                self.borderHex = borderHex
            }
        }

        var tabBarHeight: CGFloat
        var tabMinWidth: CGFloat
        var tabMaxWidth: CGFloat
        var tabSpacing: CGFloat
        var minimumPaneWidth: CGFloat
        var animationDuration: Double
        var enableAnimations: Bool
        var chromeColors: ChromeColors
        var showSplitButtons: Bool
        var splitButtonTooltips: SplitButtonTooltips

        static let `default` = Appearance()

        init(
            tabBarHeight: CGFloat = 33,
            tabMinWidth: CGFloat = 140,
            tabMaxWidth: CGFloat = 220,
            tabSpacing: CGFloat = 0,
            minimumPaneWidth: CGFloat = 100,
            animationDuration: Double = 0.175,
            enableAnimations: Bool = true,
            chromeColors: ChromeColors = ChromeColors(),
            showSplitButtons: Bool = true,
            splitButtonTooltips: SplitButtonTooltips = .default
        ) {
            self.tabBarHeight = tabBarHeight
            self.tabMinWidth = tabMinWidth
            self.tabMaxWidth = tabMaxWidth
            self.tabSpacing = tabSpacing
            self.minimumPaneWidth = minimumPaneWidth
            self.animationDuration = animationDuration
            self.enableAnimations = enableAnimations
            self.chromeColors = chromeColors
            self.showSplitButtons = showSplitButtons
            self.splitButtonTooltips = splitButtonTooltips
        }

        struct SplitButtonTooltips: Sendable, Equatable {
            public var newTerminal: String
            public var newBrowser: String
            public var splitRight: String
            public var splitDown: String
            public static let `default` = SplitButtonTooltips()
            public init(
                newTerminal: String = "New Terminal",
                newBrowser: String = "New Browser",
                splitRight: String = "Split Right",
                splitDown: String = "Split Down"
            ) {
                self.newTerminal = newTerminal
                self.newBrowser = newBrowser
                self.splitRight = splitRight
                self.splitDown = splitDown
            }
        }
    }
}

// MARK: - External Tab Drop

struct ExternalTabDropRequest: Sendable {
    enum Destination: Sendable {
        case insert(pane: PaneID, index: Int)
        case split(pane: PaneID, orientation: SplitOrientation)
    }

    let tabId: TabID
    let title: String
    let kind: String?
    let destination: Destination

    init(tabId: TabID, title: String, kind: String?, destination: Destination) {
        self.tabId = tabId
        self.title = title
        self.kind = kind
        self.destination = destination
    }
}

// MARK: - Controller

@MainActor
@Observable
public final class PaperLayoutController {

    // MARK: - State

    /// Ordered list of panes on the horizontal canvas, left to right.
    private(set) var panes: [PaperPane] = []

    /// Index of the focused pane in the `panes` array.
    var focusedPaneIndex: Int? {
        didSet {
            if let idx = focusedPaneIndex, idx >= 0, idx < panes.count {
                delegate?.paperLayout(self, didFocusPane: panes[idx].id)
            }
        }
    }

    /// Current horizontal scroll offset of the viewport. This is the value used
    /// for SwiftUI .offset() and portal compensation. Updated every frame during
    /// animated scrolls so the portal stays in sync with the visual position.
    var viewportOffset: CGFloat = 0 {
        didSet {
            Self.currentViewportOffset = viewportOffset
            if viewportOffset != oldValue {
                notifyGeometryChange()
            }
        }
    }

    private var targetViewportOffset: CGFloat = 0
    private var animationStartOffset: CGFloat = 0
    private var animationStartTime: CFTimeInterval = 0
    private var animationTimer: DispatchSourceTimer?

    /// Global viewport offset readable by the portal system.
    @MainActor static var currentViewportOffset: CGFloat = 0

    /// Animate the viewport offset to a target value over the configured duration.
    func animateViewportOffset(to target: CGFloat) {
        let duration = configuration.appearance.enableAnimations
            ? configuration.appearance.animationDuration
            : 0

        // Cancel any in-progress animation
        animationTimer?.cancel()
        animationTimer = nil

        if duration <= 0 || abs(target - viewportOffset) < 1 {
            viewportOffset = target
            return
        }

        targetViewportOffset = target
        animationStartOffset = viewportOffset
        animationStartTime = CACurrentMediaTime()

        // ~120fps timer on the main queue
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .milliseconds(8))
        timer.setEventHandler { [weak self] in
            self?.animationTick()
        }
        animationTimer = timer
        timer.resume()
    }

    private func animationTick() {
        let elapsed = CACurrentMediaTime() - animationStartTime
        let duration = configuration.appearance.animationDuration
        let progress = min(elapsed / duration, 1.0)

        // Ease-in-out cubic
        let t: Double
        if progress < 0.5 {
            t = 4 * progress * progress * progress
        } else {
            let p = -2 * progress + 2
            t = 1 - p * p * p / 2
        }

        viewportOffset = animationStartOffset + (targetViewportOffset - animationStartOffset) * t

        if progress >= 1.0 {
            viewportOffset = targetViewportOffset
            animationTimer?.cancel()
            animationTimer = nil
        }
    }

    /// Width of the visible viewport (set by GeometryReader on each layout pass).
    var viewportWidth: CGFloat = 0

    /// Height of the visible viewport.
    var viewportHeight: CGFloat = 0

    /// Whether the user is currently interacting (dragging dividers, gesture scrolling, etc.)
    var isInteractive: Bool = true

    // MARK: - Configuration

    var configuration: PaperLayoutConfiguration

    // MARK: - Delegate

    weak var delegate: PaperLayoutDelegate?

    // MARK: - Callbacks

    var onFileDrop: ((_ urls: [URL], _ pane: PaneID) -> Bool)?
    var onExternalTabDrop: ((_ request: ExternalTabDropRequest) -> Void)?
    var onTabCloseRequest: ((_ tabId: TabID) -> Void)?

    // MARK: - Context Menu

    var contextMenuShortcuts: ContextMenuShortcuts = ContextMenuShortcuts()

    // MARK: - Init

    init(configuration: PaperLayoutConfiguration = .default) {
        self.configuration = configuration
    }

    // MARK: - Pane ID Accessors

    var focusedPaneId: PaneID? {
        guard let idx = focusedPaneIndex, idx >= 0, idx < panes.count else { return nil }
        return panes[idx].id
    }

    var allPaneIds: [PaneID] {
        panes.map(\.id)
    }

    var allTabIds: [TabID] {
        panes.flatMap { pane in pane.tabs.map { TabID(id: $0.id) } }
    }

    func pane(_ paneId: PaneID) -> PaperPane? {
        panes.first { $0.id == paneId }
    }

    func paneIndex(_ paneId: PaneID) -> Int? {
        panes.firstIndex { $0.id == paneId }
    }

    // MARK: - Tab Queries

    func tab(_ tabId: TabID) -> PaperTab? {
        for pane in panes {
            if let item = pane.tabs.first(where: { $0.id == tabId.id }) {
                return PaperTab(from: item)
            }
        }
        return nil
    }

    func tabs(inPane paneId: PaneID) -> [PaperTab] {
        guard let pane = pane(paneId) else { return [] }
        return pane.tabs.map { PaperTab(from: $0) }
    }

    func selectedTab(inPane paneId: PaneID) -> PaperTab? {
        guard let pane = pane(paneId), let sel = pane.selectedTab else { return nil }
        return PaperTab(from: sel)
    }

    func paneId(forTab tabId: TabID) -> PaneID? {
        for pane in panes {
            if pane.tabs.contains(where: { $0.id == tabId.id }) {
                return pane.id
            }
        }
        return nil
    }

    // MARK: - Tab CRUD

    @discardableResult
    func createTab(
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = "doc.text",
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false,
        inPane paneId: PaneID
    ) -> TabID? {
        guard let pane = pane(paneId) else { return nil }

        let item = PaperTabItem(
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
        let tab = PaperTab(from: item)

        if delegate?.paperLayout(self, shouldCreateTab: tab, inPane: paneId) == false {
            return nil
        }

        pane.addTab(item, select: true)
        delegate?.paperLayout(self, didCreateTab: tab, inPane: paneId)
        notifyGeometryChange()
        return tab.id
    }

    @discardableResult
    func createTab(
        id: TabID,
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = "doc.text",
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false,
        inPane paneId: PaneID
    ) -> TabID? {
        guard let pane = pane(paneId) else { return nil }

        let item = PaperTabItem(
            id: id.id,
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
        let tab = PaperTab(from: item)

        if delegate?.paperLayout(self, shouldCreateTab: tab, inPane: paneId) == false {
            return nil
        }

        pane.addTab(item, select: true)
        delegate?.paperLayout(self, didCreateTab: tab, inPane: paneId)
        notifyGeometryChange()
        return tab.id
    }

    func closeTab(_ tabId: TabID) {
        guard let pane = panes.first(where: { $0.tabs.contains(where: { $0.id == tabId.id }) }) else { return }
        guard let item = pane.tab(tabId.id) else { return }
        let tab = PaperTab(from: item)

        if delegate?.paperLayout(self, shouldCloseTab: tab, inPane: pane.id) == false {
            return
        }

        pane.removeTab(tabId.id)
        delegate?.paperLayout(self, didCloseTab: tabId, fromPane: pane.id)

        // Auto-close empty pane
        if pane.tabs.isEmpty && configuration.autoCloseEmptyPanes {
            closePane(pane.id)
        }

        notifyGeometryChange()
    }

    func updateTab(
        _ tabId: TabID,
        title: String? = nil,
        hasCustomTitle: Bool? = nil,
        icon: String? = nil,
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool? = nil,
        showsNotificationBadge: Bool? = nil,
        isLoading: Bool? = nil,
        isPinned: Bool? = nil
    ) {
        for pane in panes {
            guard let idx = pane.tabs.firstIndex(where: { $0.id == tabId.id }) else { continue }
            if let title { pane.tabs[idx].title = title }
            if let hasCustomTitle { pane.tabs[idx].hasCustomTitle = hasCustomTitle }
            if let icon { pane.tabs[idx].icon = icon }
            if let iconImageData { pane.tabs[idx].iconImageData = iconImageData }
            if let kind { pane.tabs[idx].kind = kind }
            if let isDirty { pane.tabs[idx].isDirty = isDirty }
            if let showsNotificationBadge { pane.tabs[idx].showsNotificationBadge = showsNotificationBadge }
            if let isLoading { pane.tabs[idx].isLoading = isLoading }
            if let isPinned { pane.tabs[idx].isPinned = isPinned }
            return
        }
    }

    @discardableResult
    func selectTab(_ tabId: TabID) -> Bool {
        for (idx, pane) in panes.enumerated() {
            if pane.tabs.contains(where: { $0.id == tabId.id }) {
                pane.selectTab(tabId.id)
                if let item = pane.selectedTab {
                    delegate?.paperLayout(self, didSelectTab: PaperTab(from: item), inPane: pane.id)
                }
                return true
            }
        }
        return false
    }

    func selectNextTab() {
        guard let focusedIdx = focusedPaneIndex, focusedIdx < panes.count else { return }
        let pane = panes[focusedIdx]
        guard let currentId = pane.selectedTabId,
              let currentIndex = pane.tabIndex(currentId),
              currentIndex + 1 < pane.tabs.count else { return }
        let nextTab = pane.tabs[currentIndex + 1]
        pane.selectTab(nextTab.id)
        delegate?.paperLayout(self, didSelectTab: PaperTab(from: nextTab), inPane: pane.id)
    }

    func selectPreviousTab() {
        guard let focusedIdx = focusedPaneIndex, focusedIdx < panes.count else { return }
        let pane = panes[focusedIdx]
        guard let currentId = pane.selectedTabId,
              let currentIndex = pane.tabIndex(currentId),
              currentIndex > 0 else { return }
        let prevTab = pane.tabs[currentIndex - 1]
        pane.selectTab(prevTab.id)
        delegate?.paperLayout(self, didSelectTab: PaperTab(from: prevTab), inPane: pane.id)
    }

    @discardableResult
    func moveTab(_ tabId: TabID, toPane targetPaneId: PaneID, atIndex index: Int? = nil) -> Bool {
        guard let sourcePaneId = paneId(forTab: tabId),
              let sourcePane = pane(sourcePaneId),
              let targetPane = pane(targetPaneId) else { return false }

        guard let item = sourcePane.removeTab(tabId.id) else { return false }

        if let index {
            targetPane.insertTab(item, at: index)
        } else {
            targetPane.addTab(item)
        }

        let tab = PaperTab(from: item)
        delegate?.paperLayout(self, didMoveTab: tab, fromPane: sourcePaneId, toPane: targetPaneId)

        // Auto-close empty source pane
        if sourcePane.tabs.isEmpty && configuration.autoCloseEmptyPanes {
            closePane(sourcePaneId)
        }

        notifyGeometryChange()
        return true
    }

    @discardableResult
    func reorderTab(_ tabId: TabID, toIndex index: Int) -> Bool {
        for pane in panes {
            guard let sourceIndex = pane.tabIndex(tabId.id) else { continue }
            pane.moveTab(from: sourceIndex, to: index)
            return true
        }
        return false
    }

    // MARK: - New Tab Request

    func requestNewTab(kind: String = "terminal", inPane paneId: PaneID) {
        delegate?.paperLayout(self, didRequestNewTab: kind, inPane: paneId)
    }

    func requestTabContextAction(_ action: TabContextAction, for tabId: TabID, inPane paneId: PaneID) {
        guard let tab = tab(tabId) else { return }
        delegate?.paperLayout(self, didRequestTabContextAction: action, for: tab, inPane: paneId)
    }

    // MARK: - Pane Operations

    /// Creates a new pane and adds it to the canvas.
    /// This is the paper WM "new pane" operation: appends a pane to the right without resizing existing panes.
    @discardableResult
    func addPane(width: CGFloat, afterPaneId: PaneID? = nil, withTab tab: PaperTab? = nil) -> PaneID {
        let newPaneId = PaneID()
        // Resolve infinity/zero width using viewport width or a sensible default
        let resolvedWidth: CGFloat
        if !width.isFinite || width <= 0 {
            resolvedWidth = viewportWidth > 0 ? viewportWidth : 800
        } else {
            resolvedWidth = width
        }
        let pane = PaperPane(id: newPaneId, width: resolvedWidth)
        if let tab {
            let item = PaperTabItem(
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
            pane.addTab(item, select: true)
        }

        if let afterPaneId, let idx = paneIndex(afterPaneId) {
            panes.insert(pane, at: idx + 1)
        } else {
            panes.append(pane)
        }

        notifyGeometryChange()
        return newPaneId
    }

    /// Traditional split: halves the source pane and inserts a new pane adjacent to it.
    /// V1: horizontal only. Vertical splits are a no-op.
    @discardableResult
    func splitPane(
        _ paneId: PaneID,
        orientation: SplitOrientation,
        withTab tab: PaperTab? = nil,
        insertFirst: Bool = false
    ) -> PaneID? {
        // V1: only horizontal splits
        guard orientation == .horizontal else { return nil }
        guard let idx = paneIndex(paneId) else { return nil }

        if delegate?.paperLayout(self, shouldSplitPane: paneId, orientation: orientation) == false {
            return nil
        }

        let sourcePane = panes[idx]
        // Resolve infinity width before splitting
        if !sourcePane.width.isFinite || sourcePane.width <= 0 {
            sourcePane.width = viewportWidth > 0 ? viewportWidth : 800
        }
        let halfWidth = max(sourcePane.width / 2, configuration.appearance.minimumPaneWidth)

        // Resize source pane
        sourcePane.width = halfWidth

        // Create new pane
        let newPaneId = PaneID()
        let newPane = PaperPane(id: newPaneId, width: halfWidth)

        if let tab {
            let item = PaperTabItem(
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
            newPane.addTab(item, select: true)
        }

        if insertFirst {
            panes.insert(newPane, at: idx)
            // Adjust focused index if needed
            if let fi = focusedPaneIndex, fi >= idx {
                focusedPaneIndex = fi + 1
            }
        } else {
            panes.insert(newPane, at: idx + 1)
            // Adjust focused index if needed (not necessary when inserting after)
        }

        delegate?.paperLayout(self, didSplitPane: paneId, newPane: newPaneId, orientation: orientation)
        notifyGeometryChange()
        return newPaneId
    }

    /// Split by moving an existing tab from its current pane to a new pane.
    @discardableResult
    func splitPane(
        _ paneId: PaneID,
        orientation: SplitOrientation,
        movingTab tabId: TabID,
        insertFirst: Bool = false
    ) -> PaneID? {
        guard orientation == .horizontal else { return nil }
        guard let sourcePaneId = self.paneId(forTab: tabId),
              let sourcePane = pane(sourcePaneId),
              let item = sourcePane.removeTab(tabId.id) else { return nil }

        let tab = PaperTab(from: item)
        guard let newPaneId = splitPane(paneId, orientation: orientation, withTab: tab, insertFirst: insertFirst) else {
            // Restore the tab if split failed
            sourcePane.addTab(item, select: true)
            return nil
        }

        // Auto-close empty source pane
        if sourcePane.tabs.isEmpty && configuration.autoCloseEmptyPanes {
            closePane(sourcePaneId)
        }

        return newPaneId
    }

    func closePane(_ paneId: PaneID) {
        guard let idx = paneIndex(paneId) else { return }

        if !configuration.allowCloseLastPane && panes.count <= 1 {
            return
        }

        if delegate?.paperLayout(self, shouldClosePane: paneId) == false {
            return
        }

        panes.remove(at: idx)
        delegate?.paperLayout(self, didClosePane: paneId)

        // Adjust focused pane index
        if let fi = focusedPaneIndex {
            if fi == idx {
                // Focus the pane that took this slot, or the last pane
                if panes.isEmpty {
                    focusedPaneIndex = nil
                } else {
                    focusedPaneIndex = min(fi, panes.count - 1)
                }
            } else if fi > idx {
                focusedPaneIndex = fi - 1
            }
        }

        notifyGeometryChange()
    }

    // MARK: - Focus Management

    func focusPane(_ paneId: PaneID) {
        guard let idx = paneIndex(paneId) else { return }
        focusedPaneIndex = idx
    }

    /// Navigate focus left/right on the horizontal strip. Up/down are no-ops for V1.
    func navigateFocus(direction: NavigationDirection) {
        guard let fi = focusedPaneIndex else { return }

        switch direction {
        case .left:
            guard fi > 0 else { return }
            focusedPaneIndex = fi - 1
            scrollToRevealFocusedPane(comingFrom: .right)
        case .right:
            guard fi < panes.count - 1 else { return }
            focusedPaneIndex = fi + 1
            scrollToRevealFocusedPane(comingFrom: .left)
        case .up, .down:
            // No vertical navigation in V1
            break
        }
    }

    /// Returns the adjacent pane in the given direction, or nil if at the edge.
    func adjacentPane(to paneId: PaneID, direction: NavigationDirection) -> PaneID? {
        guard let idx = paneIndex(paneId) else { return nil }
        switch direction {
        case .left:
            return idx > 0 ? panes[idx - 1].id : nil
        case .right:
            return idx < panes.count - 1 ? panes[idx + 1].id : nil
        case .up, .down:
            return nil
        }
    }

    // MARK: - Viewport Scrolling

    enum ScrollDirection {
        case left
        case right
    }

    /// Scroll the viewport the minimum needed to fully reveal the focused pane.
    /// When navigating from the right (i.e., moving left), peeks the pane to the right.
    /// When navigating from the left (i.e., moving right), peeks the pane to the left.
    func scrollToRevealFocusedPane(comingFrom: ScrollDirection? = nil) {
        guard let fi = focusedPaneIndex, fi < panes.count else { return }

        let paneLeft = paneXOffset(at: fi)
        let paneRight = paneLeft + panes[fi].width

        var targetOffset = viewportOffset

        if paneLeft < viewportOffset {
            // Pane is off-screen to the left, scroll left
            targetOffset = paneLeft
        } else if paneRight > viewportOffset + viewportWidth {
            // Pane is off-screen to the right, scroll right
            targetOffset = paneRight - viewportWidth
        }

        // Clamp
        let maxOffset = max(0, totalCanvasWidth - viewportWidth)
        targetOffset = max(0, min(targetOffset, maxOffset))

        animateViewportOffset(to: targetOffset)
    }

    /// Scroll viewport to center a pane (used for new-pane operations).
    func scrollToCenterPane(_ paneId: PaneID) {
        guard let idx = paneIndex(paneId) else { return }
        let paneLeft = paneXOffset(at: idx)
        let paneCenter = paneLeft + panes[idx].width / 2
        var targetOffset = paneCenter - viewportWidth / 2

        let maxOffset = max(0, totalCanvasWidth - viewportWidth)
        targetOffset = max(0, min(targetOffset, maxOffset))

        animateViewportOffset(to: targetOffset)
    }

    // MARK: - Zoom (V1: disabled)

    var zoomedPaneId: PaneID? { nil }
    var isSplitZoomed: Bool { false }
    func clearPaneZoom() {}
    func togglePaneZoom(_ paneId: PaneID) {}

    // MARK: - Geometry

    /// X offset of pane at the given index from the left edge of the canvas.
    func paneXOffset(at index: Int) -> CGFloat {
        var offset: CGFloat = 0
        for i in 0..<min(index, panes.count) {
            offset += panes[i].width
        }
        return offset
    }

    /// Total width of all panes combined.
    var totalCanvasWidth: CGFloat {
        panes.reduce(0) { $0 + $1.width }
    }

    /// Pixel frame of the container (for compatibility with Bonsplit API).
    var containerFrame: CGRect {
        CGRect(x: 0, y: 0, width: viewportWidth, height: viewportHeight)
    }

    func setContainerFrame(_ frame: CGRect) {
        viewportWidth = frame.width
        viewportHeight = frame.height
    }

    func layoutSnapshot() -> LayoutSnapshot {
        let containerRect = PixelRect(from: containerFrame)
        let paneGeometries = panes.enumerated().map { (index, pane) -> PaneGeometry in
            let x = paneXOffset(at: index)
            return PaneGeometry(
                paneId: pane.id.description,
                frame: PixelRect(x: Double(x), y: 0, width: Double(pane.width), height: Double(viewportHeight)),
                selectedTabId: pane.selectedTabId?.uuidString,
                tabIds: pane.tabs.map { $0.id.uuidString }
            )
        }
        return LayoutSnapshot(
            containerFrame: containerRect,
            panes: paneGeometries,
            focusedPaneId: focusedPaneId?.description,
            timestamp: Date().timeIntervalSince1970
        )
    }

    /// Returns a tree snapshot for compatibility with the socket API.
    /// Since paper layout is flat, we wrap panes in a chain of horizontal splits.
    func treeSnapshot() -> ExternalTreeNode {
        guard !panes.isEmpty else {
            return .pane(ExternalPaneNode(id: UUID().uuidString, frame: PixelRect(x: 0, y: 0, width: 0, height: 0), tabs: [], selectedTabId: nil))
        }

        if panes.count == 1 {
            return externalPaneNode(at: 0)
        }

        // Build a right-leaning chain: split(pane0, split(pane1, split(pane2, pane3)))
        var node = externalPaneNode(at: panes.count - 1)
        for i in stride(from: panes.count - 2, through: 0, by: -1) {
            let leftPaneWidth = panes[i].width
            let rightTotalWidth = panes[(i+1)...].reduce(0) { $0 + $1.width }
            let totalWidth = leftPaneWidth + rightTotalWidth
            let dividerPos = totalWidth > 0 ? Double(leftPaneWidth / totalWidth) : 0.5

            node = .split(ExternalSplitNode(
                id: UUID().uuidString,
                orientation: "horizontal",
                dividerPosition: dividerPos,
                first: externalPaneNode(at: i),
                second: node
            ))
        }
        return node
    }

    private func externalPaneNode(at index: Int) -> ExternalTreeNode {
        let pane = panes[index]
        let x = paneXOffset(at: index)
        return .pane(ExternalPaneNode(
            id: pane.id.description,
            frame: PixelRect(x: Double(x), y: 0, width: Double(pane.width), height: Double(viewportHeight)),
            tabs: pane.tabs.map { ExternalTab(id: $0.id.uuidString, title: $0.title) },
            selectedTabId: pane.selectedTabId?.uuidString
        ))
    }

    // MARK: - Divider Position (compatibility)

    /// Find the "split" containing two adjacent panes. Returns a virtual split ID.
    func findSplit(containing paneId: PaneID) -> UUID? {
        // In paper layout, there are no real split nodes. Return nil.
        nil
    }

    /// Set divider position between two adjacent panes (used in session restore).
    func setDividerPosition(_ position: CGFloat, for splitId: UUID) {
        // No-op in paper layout. Pane widths are set directly.
    }

    // MARK: - Geometry Change Notification

    func notifyGeometryChange(isDragging: Bool = false) {
#if DEBUG
        let paneDesc = panes.enumerated().map { (i, p) in
            let w = p.width.isFinite ? "\(Int(p.width))" : "inf"
            return "[\(i):\(p.id.id.uuidString.prefix(5)) w=\(w) tabs=\(p.tabs.count)]"
        }.joined(separator: " ")
        let vpOff = viewportOffset.isFinite ? "\(Int(viewportOffset))" : "inf"
        let vpW = viewportWidth.isFinite ? "\(Int(viewportWidth))" : "inf"
        let canvasW = totalCanvasWidth.isFinite ? "\(Int(totalCanvasWidth))" : "inf"
        dlog("paper.geometry vpOffset=\(vpOff) vpWidth=\(vpW) canvas=\(canvasW) focus=\(focusedPaneIndex ?? -1) panes=\(paneDesc)")
#endif
        let snapshot = layoutSnapshot()
        if isDragging {
            if delegate?.paperLayout(self, shouldNotifyDuringDrag: true) == true {
                delegate?.paperLayout(self, didChangeGeometry: snapshot)
            }
        } else {
            delegate?.paperLayout(self, didChangeGeometry: snapshot)
        }
    }
}
