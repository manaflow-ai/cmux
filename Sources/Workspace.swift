import Foundation
import SwiftUI
import Bonsplit
import Combine

struct SidebarStatusEntry {
    let key: String
    let value: String
    let icon: String?
    let color: String?
    let timestamp: Date
}

enum SidebarLogLevel: String {
    case info
    case progress
    case success
    case warning
    case error
}

struct SidebarLogEntry {
    let message: String
    let level: SidebarLogLevel
    let source: String?
    let timestamp: Date
}

struct SidebarProgressState {
    let value: Double
    let label: String?
}

struct SidebarGitBranchState {
    let branch: String
    let isDirty: Bool
}

/// Workspace represents a sidebar tab.
/// Each workspace contains one BonsplitController that manages split panes and nested surfaces.
@MainActor
final class Workspace: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var customTitle: String?
    @Published var isPinned: Bool = false
    @Published var currentDirectory: String

    /// The bonsplit controller managing the split panes for this workspace
    let bonsplitController: BonsplitController

    /// Mapping from bonsplit TabID to our Panel instances
    @Published private(set) var panels: [UUID: any Panel] = [:]

    /// Subscriptions for panel updates (e.g., browser title changes)
    private var panelSubscriptions: [UUID: AnyCancellable] = [:]

    /// When true, suppresses auto-creation in didSplitPane (programmatic splits handle their own panels)
    private var isProgrammaticSplit = false

    // Closing tabs mutates split layout immediately; terminal views handle their own AppKit
    // layout/size synchronization.

    /// The currently focused pane's panel ID
    var focusedPanelId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: paneId) else {
            return nil
        }
        return panelIdFromSurfaceId(tab.id)
    }

    /// The currently focused terminal panel (if any)
    var focusedTerminalPanel: TerminalPanel? {
        guard let panelId = focusedPanelId,
              let panel = panels[panelId] as? TerminalPanel else {
            return nil
        }
        return panel
    }

    /// Published directory for each panel
    @Published var panelDirectories: [UUID: String] = [:]
    @Published var panelTitles: [UUID: String] = [:]
    @Published var statusEntries: [String: SidebarStatusEntry] = [:]
    @Published var logEntries: [SidebarLogEntry] = []
    @Published var progress: SidebarProgressState?
    @Published var gitBranch: SidebarGitBranchState?
    @Published var surfaceListeningPorts: [UUID: [Int]] = [:]
    @Published var listeningPorts: [Int] = []

    var focusedSurfaceId: UUID? { focusedPanelId }
    var surfaceDirectories: [UUID: String] {
        get { panelDirectories }
        set { panelDirectories = newValue }
    }

    private var processTitle: String

    // MARK: - Initialization

    init(title: String = "Terminal", workingDirectory: String? = nil) {
        self.id = UUID()
        self.processTitle = title
        self.title = title
        self.customTitle = nil

        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let hasWorkingDirectory = !trimmedWorkingDirectory.isEmpty
        self.currentDirectory = hasWorkingDirectory
            ? trimmedWorkingDirectory
            : FileManager.default.homeDirectoryForCurrentUser.path

        // Configure bonsplit with keepAllAlive to preserve terminal state
        // Disable split animations for instant response
        let appearance = BonsplitConfiguration.Appearance(
            enableAnimations: false
        )
        let config = BonsplitConfiguration(
            allowSplits: true,
            allowCloseTabs: true,
            allowCloseLastPane: false,
            allowTabReordering: true,
            allowCrossPaneTabMove: true,
            autoCloseEmptyPanes: true,
            contentViewLifecycle: .keepAllAlive,
            newTabPosition: .current,
            appearance: appearance
        )
        self.bonsplitController = BonsplitController(configuration: config)

        // Remove the default "Welcome" tab that bonsplit creates
        let welcomeTabIds = bonsplitController.allTabIds

        // Create initial terminal panel
        let terminalPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            workingDirectory: hasWorkingDirectory ? trimmedWorkingDirectory : nil
        )
        panels[terminalPanel.id] = terminalPanel

        // Create initial tab in bonsplit and store the mapping
        var initialTabId: TabID?
        if let tabId = bonsplitController.createTab(
            title: title,
            icon: "terminal.fill",
            isDirty: false
        ) {
            surfaceIdToPanelId[tabId] = terminalPanel.id
            initialTabId = tabId
        }

        // Close the default Welcome tab(s)
        for welcomeTabId in welcomeTabIds {
            bonsplitController.closeTab(welcomeTabId)
        }

        // Set ourselves as delegate
        bonsplitController.delegate = self

        // Ensure bonsplit has a focused pane and our didSelectTab handler runs for the
        // initial terminal. bonsplit's createTab selects internally but does not emit
        // didSelectTab, and focusedPaneId can otherwise be nil until user interaction.
        if let initialTabId {
            // Focus the pane containing the initial tab (or the first pane as fallback).
            let paneToFocus: PaneID? = {
                for paneId in bonsplitController.allPaneIds {
                    if bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == initialTabId }) {
                        return paneId
                    }
                }
                return bonsplitController.allPaneIds.first
            }()
            if let paneToFocus {
                bonsplitController.focusPane(paneToFocus)
            }
            bonsplitController.selectTab(initialTabId)
        }
    }

    // MARK: - Surface ID to Panel ID Mapping

    /// Mapping from bonsplit TabID (surface ID) to panel UUID
    private var surfaceIdToPanelId: [TabID: UUID] = [:]

    /// Tab IDs that are allowed to close even if they would normally require confirmation.
    /// This is used by app-level confirmation prompts (e.g., Cmd+W "Close Tab?") so the
    /// Bonsplit delegate doesn't block the close after the user already confirmed.
    private var forceCloseTabIds: Set<TabID> = []

    /// Tab IDs that are currently showing (or about to show) a close confirmation prompt.
    /// Prevents repeated close gestures (e.g., middle-click spam) from stacking dialogs.
    private var pendingCloseConfirmTabIds: Set<TabID> = []

    /// Deterministic tab selection to apply after a tab closes.
    /// Keyed by the closing tab ID, value is the tab ID we want to select next.
    private var postCloseSelectTabId: [TabID: TabID] = [:]
    private var isApplyingTabSelection = false
    private var pendingTabSelection: (tabId: TabID, pane: PaneID)?
    private var isReconcilingFocusState = false
    private var focusReconcileScheduled = false
    private var geometryReconcileScheduled = false

    struct DetachedSurfaceTransfer {
        let panelId: UUID
        let panel: any Panel
        let title: String
        let icon: String?
        let iconImageData: Data?
        let isLoading: Bool
        let directory: String?
        let cachedTitle: String?
    }

    private var detachingTabIds: Set<TabID> = []
    private var pendingDetachedSurfaces: [TabID: DetachedSurfaceTransfer] = [:]

    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        surfaceIdToPanelId[surfaceId]
    }

    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? {
        surfaceIdToPanelId.first { $0.value == panelId }?.key
    }


    private func installBrowserPanelSubscription(_ browserPanel: BrowserPanel) {
        let subscription = Publishers.CombineLatest3(
            browserPanel.$pageTitle.removeDuplicates(),
            browserPanel.$isLoading.removeDuplicates(),
            browserPanel.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak browserPanel] _, isLoading, favicon in
            guard let self = self,
                  let browserPanel = browserPanel,
                  let tabId = self.surfaceIdFromPanelId(browserPanel.id) else { return }
            guard let existing = self.bonsplitController.tab(tabId) else { return }

            let nextTitle = browserPanel.displayTitle
            let titleUpdate: String? = existing.title == nextTitle ? nil : nextTitle
            let faviconUpdate: Data?? = existing.iconImageData == favicon ? nil : .some(favicon)
            let loadingUpdate: Bool? = existing.isLoading == isLoading ? nil : isLoading

            guard titleUpdate != nil || faviconUpdate != nil || loadingUpdate != nil else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: titleUpdate,
                iconImageData: faviconUpdate,
                isLoading: loadingUpdate
            )
        }
        panelSubscriptions[browserPanel.id] = subscription
    }
    // MARK: - Panel Access

    func panel(for surfaceId: TabID) -> (any Panel)? {
        guard let panelId = panelIdFromSurfaceId(surfaceId) else { return nil }
        return panels[panelId]
    }

    func terminalPanel(for panelId: UUID) -> TerminalPanel? {
        panels[panelId] as? TerminalPanel
    }

    func browserPanel(for panelId: UUID) -> BrowserPanel? {
        panels[panelId] as? BrowserPanel
    }

    // MARK: - Title Management

    var hasCustomTitle: Bool {
        let trimmed = customTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return !trimmed.isEmpty
    }

    func applyProcessTitle(_ title: String) {
        processTitle = title
        guard customTitle == nil else { return }
        self.title = title
    }

    func setCustomTitle(_ title: String?) {
        let trimmed = title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty {
            customTitle = nil
            self.title = processTitle
        } else {
            customTitle = trimmed
            self.title = trimmed
        }
    }

    // MARK: - Directory Updates

    func updatePanelDirectory(panelId: UUID, directory: String) {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if panelDirectories[panelId] != trimmed {
            panelDirectories[panelId] = trimmed
        }
        // Update current directory if this is the focused panel
        if panelId == focusedPanelId {
            currentDirectory = trimmed
        }
    }

    func updatePanelTitle(panelId: UUID, title: String) {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if panelTitles[panelId] != trimmed {
            panelTitles[panelId] = trimmed
        }

        // Update bonsplit tab title
        if let tabId = surfaceIdFromPanelId(panelId) {
            bonsplitController.updateTab(tabId, title: trimmed)
        }

        // If this is the only panel and no custom title, update workspace title
        if panels.count == 1, customTitle == nil {
            self.title = trimmed
            processTitle = trimmed
        }
    }

    func pruneSurfaceMetadata(validSurfaceIds: Set<UUID>) {
        panelDirectories = panelDirectories.filter { validSurfaceIds.contains($0.key) }
        panelTitles = panelTitles.filter { validSurfaceIds.contains($0.key) }
        surfaceListeningPorts = surfaceListeningPorts.filter { validSurfaceIds.contains($0.key) }
        recomputeListeningPorts()
    }

    func recomputeListeningPorts() {
        let unique = Set(surfaceListeningPorts.values.flatMap { $0 })
        listeningPorts = unique.sorted()
    }

    // MARK: - Panel Operations

    /// Create a new split with a terminal panel
    @discardableResult
    func newTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false
    ) -> TerminalPanel? {
        // Get inherited config from the source terminal when possible.
        // If the split is initiated from a non-terminal panel (for example browser),
        // fall back to any terminal in the workspace.
        let inheritedConfig: ghostty_surface_config_s? = {
            if let sourceTerminal = terminalPanel(for: panelId),
               let existing = sourceTerminal.surface.surface {
                return ghostty_surface_inherited_config(existing, GHOSTTY_SURFACE_CONTEXT_SPLIT)
            }
            if let fallbackSurface = panels.values
                .compactMap({ ($0 as? TerminalPanel)?.surface.surface })
                .first {
                return ghostty_surface_inherited_config(fallbackSurface, GHOSTTY_SURFACE_CONTEXT_SPLIT)
            }
            return nil
        }()

        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        // Create the new terminal panel.
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig
        )
        panels[newPanel.id] = newPanel

        // Pre-generate the bonsplit tab ID so we can install the panel mapping before bonsplit
        // mutates layout state (avoids transient "Empty Panel" flashes during split).
        let newTab = Bonsplit.Tab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            isDirty: newPanel.isDirty
        )
        surfaceIdToPanelId[newTab.id] = newPanel.id

	        // Capture the source terminal's hosted view before bonsplit mutates focusedPaneId,
	        // so we can hand it to focusPanel as the "move focus FROM" view.
	        let previousHostedView = focusedTerminalPanel?.hostedView

	        // Create the split with the new tab already present in the new pane.
	        isProgrammaticSplit = true
	        defer { isProgrammaticSplit = false }
	        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
	            panels.removeValue(forKey: newPanel.id)
	            surfaceIdToPanelId.removeValue(forKey: newTab.id)
	            return nil
	        }

	        // SplitViewController focuses the newly created pane, but the AppKit first responder can lag
	        // (or remain on the source surface) during SwiftUI/bonsplit structural updates. Explicitly
	        // focus the new panel so model focus + responder chain converge deterministically.
	        focusPanel(newPanel.id, previousHostedView: previousHostedView)

	        return newPanel
	    }

    /// Create a new surface (nested tab) in the specified pane with a terminal panel.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newTerminalSurface(inPane paneId: PaneID, focus: Bool? = nil) -> TerminalPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        // Get an existing terminal panel to inherit config from
        let inheritedConfig: ghostty_surface_config_s? = {
            for panel in panels.values {
                if let terminalPanel = panel as? TerminalPanel,
                   let surface = terminalPanel.surface.surface {
                    return ghostty_surface_inherited_config(surface, GHOSTTY_SURFACE_CONTEXT_SPLIT)
                }
            }
            return nil
        }()

        // Create new terminal panel
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig
        )
        panels[newPanel.id] = newPanel

        // Create tab in bonsplit
        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            isDirty: newPanel.isDirty,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = newPanel.id

        // bonsplit's createTab may not reliably emit didSelectTab, and its internal selection
        // updates can be deferred. Force a deterministic selection + focus path so the new
        // surface becomes interactive immediately (no "frozen until pane switch" state).
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            newPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }
        return newPanel
    }

    /// Create a new browser panel split
    @discardableResult
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
        insertFirst: Bool = false,
        url: URL? = nil
    ) -> BrowserPanel? {
        // Find the pane containing the source panel
        guard let sourceTabId = surfaceIdFromPanelId(panelId) else { return nil }
        var sourcePaneId: PaneID?
        for paneId in bonsplitController.allPaneIds {
            let tabs = bonsplitController.tabs(inPane: paneId)
            if tabs.contains(where: { $0.id == sourceTabId }) {
                sourcePaneId = paneId
                break
            }
        }

        guard let paneId = sourcePaneId else { return nil }

        // Create browser panel
        let browserPanel = BrowserPanel(workspaceId: id, initialURL: url)
        panels[browserPanel.id] = browserPanel

        // Pre-generate the bonsplit tab ID so the mapping exists before the split lands.
        let newTab = Bonsplit.Tab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading
        )
        surfaceIdToPanelId[newTab.id] = browserPanel.id

	        // Create the split with the browser tab already present.
	        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
	        isProgrammaticSplit = true
	        defer { isProgrammaticSplit = false }
	        guard bonsplitController.splitPane(paneId, orientation: orientation, withTab: newTab, insertFirst: insertFirst) != nil else {
	            surfaceIdToPanelId.removeValue(forKey: newTab.id)
	            panels.removeValue(forKey: browserPanel.id)
	            return nil
	        }

	        // See newTerminalSplit: explicitly focus the newly created panel so focus state is
	        // deterministic for both user and socket-driven workflows.
	        focusPanel(browserPanel.id)

        installBrowserPanelSubscription(browserPanel)

        return browserPanel
    }

    /// Create a new browser surface in the specified pane.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newBrowserSurface(
        inPane paneId: PaneID,
        url: URL? = nil,
        focus: Bool? = nil,
        insertAtEnd: Bool = false
    ) -> BrowserPanel? {
        let shouldFocusNewTab = focus ?? (bonsplitController.focusedPaneId == paneId)

        let browserPanel = BrowserPanel(workspaceId: id, initialURL: url)
        panels[browserPanel.id] = browserPanel

        guard let newTabId = bonsplitController.createTab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            isDirty: browserPanel.isDirty,
            isLoading: browserPanel.isLoading,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: browserPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = browserPanel.id

        // Keyboard/browser-open paths want "new tab at end" regardless of global new-tab placement.
        if insertAtEnd {
            let targetIndex = max(0, bonsplitController.tabs(inPane: paneId).count - 1)
            _ = bonsplitController.reorderTab(newTabId, toIndex: targetIndex)
        }

        // Match terminal behavior: enforce deterministic selection + focus.
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            browserPanel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        }

        installBrowserPanelSubscription(browserPanel)

        return browserPanel
    }

    /// Close a panel.
    /// Returns true when a bonsplit tab close request was issued.
    func closePanel(_ panelId: UUID, force: Bool = false) -> Bool {
        if let tabId = surfaceIdFromPanelId(panelId) {
            if force {
                forceCloseTabIds.insert(tabId)
            }
            // Close the tab in bonsplit (this triggers delegate callback)
            return bonsplitController.closeTab(tabId)
        }

        // Mapping can transiently drift during split-tree mutations. If the target panel is
        // currently focused, close whichever tab bonsplit marks selected in that focused pane.
        guard focusedPanelId == panelId,
              let focusedPane = bonsplitController.focusedPaneId,
              let selected = bonsplitController.selectedTab(inPane: focusedPane) else {
            return false
        }

        if force {
            forceCloseTabIds.insert(selected.id)
        }
        return bonsplitController.closeTab(selected.id)
    }

    func paneId(forPanelId panelId: UUID) -> PaneID? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        return bonsplitController.allPaneIds.first { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        }
    }

    func indexInPane(forPanelId panelId: UUID) -> Int? {
        guard let tabId = surfaceIdFromPanelId(panelId),
              let paneId = paneId(forPanelId: panelId) else { return nil }
        return bonsplitController.tabs(inPane: paneId).firstIndex(where: { $0.id == tabId })
    }

    /// Returns the nearest right-side sibling pane for browser placement.
    /// The search is local to the source pane's ancestry in the split tree:
    /// use the closest horizontal ancestor where the source is in the first (left) branch.
    func preferredBrowserTargetPane(fromPanelId panelId: UUID) -> PaneID? {
        guard let sourcePane = paneId(forPanelId: panelId) else { return nil }
        let sourcePaneId = sourcePane.id.uuidString
        let tree = bonsplitController.treeSnapshot()
        guard let path = browserPathToPane(targetPaneId: sourcePaneId, node: tree) else { return nil }

        let layout = bonsplitController.layoutSnapshot()
        let paneFrameById = Dictionary(uniqueKeysWithValues: layout.panes.map { ($0.paneId, $0.frame) })
        let sourceFrame = paneFrameById[sourcePaneId]
        let sourceCenterY = sourceFrame.map { $0.y + ($0.height * 0.5) } ?? 0
        let sourceRightX = sourceFrame.map { $0.x + $0.width } ?? 0

        for crumb in path {
            guard crumb.split.orientation == "horizontal", crumb.branch == .first else { continue }
            var candidateNodes: [ExternalPaneNode] = []
            browserCollectPaneNodes(node: crumb.split.second, into: &candidateNodes)
            if candidateNodes.isEmpty { continue }

            let sorted = candidateNodes.sorted { lhs, rhs in
                let lhsDy = abs((lhs.frame.y + (lhs.frame.height * 0.5)) - sourceCenterY)
                let rhsDy = abs((rhs.frame.y + (rhs.frame.height * 0.5)) - sourceCenterY)
                if lhsDy != rhsDy { return lhsDy < rhsDy }

                let lhsDx = abs(lhs.frame.x - sourceRightX)
                let rhsDx = abs(rhs.frame.x - sourceRightX)
                if lhsDx != rhsDx { return lhsDx < rhsDx }

                if lhs.frame.x != rhs.frame.x { return lhs.frame.x < rhs.frame.x }
                return lhs.id < rhs.id
            }

            for candidate in sorted {
                guard let candidateUUID = UUID(uuidString: candidate.id),
                      candidateUUID != sourcePane.id,
                      let pane = bonsplitController.allPaneIds.first(where: { $0.id == candidateUUID }) else {
                    continue
                }
                return pane
            }
        }

        return nil
    }

    private enum BrowserPaneBranch {
        case first
        case second
    }

    private struct BrowserPaneBreadcrumb {
        let split: ExternalSplitNode
        let branch: BrowserPaneBranch
    }

    private func browserPathToPane(targetPaneId: String, node: ExternalTreeNode) -> [BrowserPaneBreadcrumb]? {
        switch node {
        case .pane(let paneNode):
            return paneNode.id == targetPaneId ? [] : nil
        case .split(let splitNode):
            if var path = browserPathToPane(targetPaneId: targetPaneId, node: splitNode.first) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .first))
                return path
            }
            if var path = browserPathToPane(targetPaneId: targetPaneId, node: splitNode.second) {
                path.append(BrowserPaneBreadcrumb(split: splitNode, branch: .second))
                return path
            }
            return nil
        }
    }

    private func browserCollectPaneNodes(node: ExternalTreeNode, into output: inout [ExternalPaneNode]) {
        switch node {
        case .pane(let paneNode):
            output.append(paneNode)
        case .split(let splitNode):
            browserCollectPaneNodes(node: splitNode.first, into: &output)
            browserCollectPaneNodes(node: splitNode.second, into: &output)
        }
    }

    @discardableResult
    func moveSurface(panelId: UUID, toPane paneId: PaneID, atIndex index: Int? = nil, focus: Bool = true) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.allPaneIds.contains(paneId) else { return false }
        guard bonsplitController.moveTab(tabId, toPane: paneId, atIndex: index) else { return false }

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(tabId)
            focusPanel(panelId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    @discardableResult
    func reorderSurface(panelId: UUID, toIndex index: Int) -> Bool {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return false }
        guard bonsplitController.reorderTab(tabId, toIndex: index) else { return false }

        if let paneId = paneId(forPanelId: panelId) {
            applyTabSelection(tabId: tabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()
        return true
    }

    func detachSurface(panelId: UUID) -> DetachedSurfaceTransfer? {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return nil }
        guard panels[panelId] != nil else { return nil }

        detachingTabIds.insert(tabId)
        forceCloseTabIds.insert(tabId)
        guard bonsplitController.closeTab(tabId) else {
            detachingTabIds.remove(tabId)
            pendingDetachedSurfaces.removeValue(forKey: tabId)
            forceCloseTabIds.remove(tabId)
            return nil
        }

        return pendingDetachedSurfaces.removeValue(forKey: tabId)
    }

    @discardableResult
    func attachDetachedSurface(
        _ detached: DetachedSurfaceTransfer,
        inPane paneId: PaneID,
        atIndex index: Int? = nil,
        focus: Bool = true
    ) -> UUID? {
        guard bonsplitController.allPaneIds.contains(paneId) else { return nil }
        guard panels[detached.panelId] == nil else { return nil }

        panels[detached.panelId] = detached.panel
        if let terminalPanel = detached.panel as? TerminalPanel {
            terminalPanel.updateWorkspaceId(id)
        } else if let browserPanel = detached.panel as? BrowserPanel {
            browserPanel.updateWorkspaceId(id)
            installBrowserPanelSubscription(browserPanel)
        }

        if let directory = detached.directory {
            panelDirectories[detached.panelId] = directory
        }
        if let cachedTitle = detached.cachedTitle {
            panelTitles[detached.panelId] = cachedTitle
        }

        guard let newTabId = bonsplitController.createTab(
            title: detached.title,
            icon: detached.icon,
            iconImageData: detached.iconImageData,
            isDirty: detached.panel.isDirty,
            isLoading: detached.isLoading,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: detached.panelId)
            panelDirectories.removeValue(forKey: detached.panelId)
            panelTitles.removeValue(forKey: detached.panelId)
            panelSubscriptions.removeValue(forKey: detached.panelId)
            return nil
        }

        surfaceIdToPanelId[newTabId] = detached.panelId
        if let index {
            _ = bonsplitController.reorderTab(newTabId, toIndex: index)
        }

        if focus {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            detached.panel.focus()
            applyTabSelection(tabId: newTabId, inPane: paneId)
        } else {
            scheduleFocusReconcile()
        }
        scheduleTerminalGeometryReconcile()

        return detached.panelId
    }
    // MARK: - Focus Management

    func focusPanel(_ panelId: UUID, previousHostedView: GhosttySurfaceScrollView? = nil) {
#if DEBUG
        let pane = bonsplitController.focusedPaneId?.id.uuidString ?? "nil"
        FocusLogStore.shared.append("Workspace.focusPanel panelId=\(panelId.uuidString) focusedPane=\(pane)")
#endif
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        let currentlyFocusedPanelId = focusedPanelId

        // Capture the currently focused terminal view so we can explicitly move AppKit first
        // responder when focusing another terminal (helps avoid "highlighted but typing goes to
        // another pane" after heavy split/tab mutations).
        // When a caller passes an explicit previousHostedView (e.g. during split creation where
        // bonsplit has already mutated focusedPaneId), prefer it over the derived value.
        let previousTerminalHostedView = previousHostedView ?? focusedTerminalPanel?.hostedView

        // `selectTab` does not necessarily move bonsplit's focused pane. For programmatic focus
        // (socket API, notification click, etc.), ensure the target tab's pane becomes focused
        // so `focusedPanelId` and follow-on focus logic are coherent.
        let targetPaneId = bonsplitController.allPaneIds.first(where: { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        })
        let selectionAlreadyConverged: Bool = {
            guard let targetPaneId else { return false }
            return bonsplitController.focusedPaneId == targetPaneId &&
                bonsplitController.selectedTab(inPane: targetPaneId)?.id == tabId
        }()

        if let targetPaneId, !selectionAlreadyConverged {
            bonsplitController.focusPane(targetPaneId)
        }

        if !selectionAlreadyConverged {
            bonsplitController.selectTab(tabId)
        }

        // Also focus the underlying panel
        if let panel = panels[panelId] {
            if currentlyFocusedPanelId != panelId || !selectionAlreadyConverged {
                panel.focus()
            }

            if let terminalPanel = panel as? TerminalPanel {
                // Avoid re-entrant focus loops when focus was initiated by AppKit first-responder
                // (becomeFirstResponder -> onFocus -> focusPanel).
                if !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    terminalPanel.hostedView.moveFocus(from: previousTerminalHostedView)
                }
            }
        }
        if let targetPaneId {
            applyTabSelection(tabId: tabId, inPane: targetPaneId)
        }
    }

    func moveFocus(direction: NavigationDirection) {
        // Unfocus the currently-focused panel before navigating.
        if let prevPanelId = focusedPanelId, let prev = panels[prevPanelId] {
            prev.unfocus()
        }

        bonsplitController.navigateFocus(direction: direction)

        // Always reconcile selection/focus after navigation so AppKit first-responder and
        // bonsplit's focused pane stay aligned, even through split tree mutations.
        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane
    func selectNextSurface() {
        bonsplitController.selectNextTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select the previous surface in the currently focused pane
    func selectPreviousSurface() {
        bonsplitController.selectPreviousTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
        }
    }

    /// Select a surface by index in the currently focused pane
    func selectSurface(at index: Int) {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard index >= 0 && index < tabs.count else { return }
        bonsplitController.selectTab(tabs[index].id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused pane
    func selectLastSurface() {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = tabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Create a new terminal surface in the currently focused pane
    @discardableResult
    func newTerminalSurfaceInFocusedPane(focus: Bool? = nil) -> TerminalPanel? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        return newTerminalSurface(inPane: focusedPaneId, focus: focus)
    }

    // MARK: - Flash/Notification Support

    func triggerFocusFlash(panelId: UUID) {
        if let terminalPanel = terminalPanel(for: panelId) {
            terminalPanel.triggerFlash()
            return
        }
        if let browserPanel = browserPanel(for: panelId) {
            browserPanel.triggerFlash()
            return
        }
    }

    func triggerNotificationFocusFlash(
        panelId: UUID,
        requiresSplit: Bool = false,
        shouldFocus: Bool = true
    ) {
        guard let terminalPanel = terminalPanel(for: panelId) else { return }
        if shouldFocus {
            focusPanel(panelId)
        }
        let isSplit = bonsplitController.allPaneIds.count > 1 || panels.count > 1
        if requiresSplit && !isSplit {
            return
        }
        terminalPanel.triggerFlash()
    }

    func triggerDebugFlash(panelId: UUID) {
        triggerNotificationFocusFlash(panelId: panelId, requiresSplit: false, shouldFocus: true)
    }

    // MARK: - Utility

    /// Create a new terminal panel (used when replacing the last panel)
    @discardableResult
    func createReplacementTerminalPanel() -> TerminalPanel {
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_TAB,
            configTemplate: nil
        )
        panels[newPanel.id] = newPanel

        // Create tab in bonsplit
        if let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            isDirty: newPanel.isDirty
        ) {
            surfaceIdToPanelId[newTabId] = newPanel.id
        }

        return newPanel
    }

    /// Check if any panel needs close confirmation
    func needsConfirmClose() -> Bool {
        for panel in panels.values {
            if let terminalPanel = panel as? TerminalPanel,
               terminalPanel.needsConfirmClose() {
                return true
            }
        }
        return false
    }

    private func reconcileFocusState() {
        guard !isReconcilingFocusState else { return }
        isReconcilingFocusState = true
        defer { isReconcilingFocusState = false }

        // Source of truth: bonsplit focused pane + selected tab.
        // AppKit first responder must converge to this model state, not the other way around.
        var targetPanelId: UUID?

        if let focusedPane = bonsplitController.focusedPaneId,
           let focusedTab = bonsplitController.selectedTab(inPane: focusedPane),
           let mappedPanelId = panelIdFromSurfaceId(focusedTab.id),
           panels[mappedPanelId] != nil {
            targetPanelId = mappedPanelId
        } else {
            for pane in bonsplitController.allPaneIds {
                guard let selectedTab = bonsplitController.selectedTab(inPane: pane),
                      let mappedPanelId = panelIdFromSurfaceId(selectedTab.id),
                      panels[mappedPanelId] != nil else { continue }
                bonsplitController.focusPane(pane)
                bonsplitController.selectTab(selectedTab.id)
                targetPanelId = mappedPanelId
                break
            }
        }

        if targetPanelId == nil, let fallbackPanelId = panels.keys.first {
            targetPanelId = fallbackPanelId
            if let fallbackTabId = surfaceIdFromPanelId(fallbackPanelId),
               let fallbackPane = bonsplitController.allPaneIds.first(where: { paneId in
                   bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == fallbackTabId })
               }) {
                bonsplitController.focusPane(fallbackPane)
                bonsplitController.selectTab(fallbackTabId)
            }
        }

        guard let targetPanelId, let targetPanel = panels[targetPanelId] else { return }

        for (panelId, panel) in panels where panelId != targetPanelId {
            panel.unfocus()
        }

        targetPanel.focus()
        if let terminalPanel = targetPanel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: targetPanelId)
        }
    }

    /// Reconcile focus/first-responder convergence.
    /// Coalesce to the next main-queue turn so bonsplit selection/pane mutations settle first.
    private func scheduleFocusReconcile() {
        guard !focusReconcileScheduled else { return }
        focusReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.focusReconcileScheduled = false
            self.reconcileFocusState()
        }
    }

    /// Reconcile remaining terminal view geometries after split topology changes.
    /// This keeps AppKit bounds and Ghostty surface sizes in sync in the next runloop turn.
    private func scheduleTerminalGeometryReconcile() {
        guard !geometryReconcileScheduled else { return }
        geometryReconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.geometryReconcileScheduled = false

            for panel in self.panels.values {
                guard let terminalPanel = panel as? TerminalPanel else { continue }
                terminalPanel.hostedView.reconcileGeometryNow()
                terminalPanel.surface.forceRefresh()
            }
        }
    }

}

// MARK: - BonsplitDelegate

extension Workspace: BonsplitDelegate {
    @MainActor
    private func confirmClosePanel(for tabId: TabID) async -> Bool {
        let alert = NSAlert()
        alert.messageText = "Close tab?"
        alert.informativeText = "This will close the current tab."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        // Prefer a sheet if we can find a window, otherwise fall back to modal.
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            return await withCheckedContinuation { continuation in
                alert.beginSheetModal(for: window) { response in
                    continuation.resume(returning: response == .alertFirstButtonReturn)
                }
            }
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    /// Apply the side-effects of selecting a tab (unfocus others, focus this panel, update state).
    /// bonsplit doesn't always emit didSelectTab for programmatic selection paths (e.g. createTab).
    private func applyTabSelection(tabId: TabID, inPane pane: PaneID) {
        pendingTabSelection = (tabId: tabId, pane: pane)
        guard !isApplyingTabSelection else { return }
        isApplyingTabSelection = true
        defer {
            isApplyingTabSelection = false
            pendingTabSelection = nil
        }

        var iterations = 0
        while let request = pendingTabSelection {
            pendingTabSelection = nil
            iterations += 1
            if iterations > 8 { break }
            applyTabSelectionNow(tabId: request.tabId, inPane: request.pane)
        }
    }

    private func applyTabSelectionNow(tabId: TabID, inPane pane: PaneID) {
        if bonsplitController.allPaneIds.contains(pane) {
            if bonsplitController.focusedPaneId != pane {
                bonsplitController.focusPane(pane)
            }
            if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }),
               bonsplitController.selectedTab(inPane: pane)?.id != tabId {
                bonsplitController.selectTab(tabId)
            }
        }

        let focusedPane: PaneID
        let selectedTabId: TabID
        if let currentPane = bonsplitController.focusedPaneId,
           let currentTabId = bonsplitController.selectedTab(inPane: currentPane)?.id {
            focusedPane = currentPane
            selectedTabId = currentTabId
        } else if bonsplitController.tabs(inPane: pane).contains(where: { $0.id == tabId }) {
            focusedPane = pane
            selectedTabId = tabId
            bonsplitController.focusPane(focusedPane)
            bonsplitController.selectTab(selectedTabId)
        } else {
            return
        }

        // Focus the selected panel
        guard let panelId = panelIdFromSurfaceId(selectedTabId),
              let panel = panels[panelId] else {
            return
        }

        // Unfocus all other panels
        for (id, p) in panels where id != panelId {
            p.unfocus()
        }

        panel.focus()

        // Converge AppKit first responder with bonsplit's selected tab in the focused pane.
        // Without this, keyboard input can remain on a different terminal than the blue tab indicator.
        if let terminalPanel = panel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: id, surfaceId: panelId)
        }

        // Update current directory if this is a terminal
        if let dir = panelDirectories[panelId] {
            currentDirectory = dir
        }

        // Post notification
        NotificationCenter.default.post(
            name: .ghosttyDidFocusSurface,
            object: nil,
            userInfo: [
                GhosttyNotificationKey.tabId: self.id,
                GhosttyNotificationKey.surfaceId: panelId
            ]
        )
    }

    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        func recordPostCloseSelection() {
            let tabs = controller.tabs(inPane: pane)
            guard let idx = tabs.firstIndex(where: { $0.id == tab.id }) else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
                return
            }

            let target: TabID? = {
                if idx + 1 < tabs.count { return tabs[idx + 1].id }
                if idx > 0 { return tabs[idx - 1].id }
                return nil
            }()

            if let target {
                postCloseSelectTabId[tab.id] = target
            } else {
                postCloseSelectTabId.removeValue(forKey: tab.id)
            }
        }

        if forceCloseTabIds.contains(tab.id) {
            recordPostCloseSelection()
            return true
        }

        // Check if the panel needs close confirmation
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let terminalPanel = terminalPanel(for: panelId) else {
            recordPostCloseSelection()
            return true
        }

        // If confirmation is required, Bonsplit will call into this delegate and we must return false.
        // Show an app-level confirmation, then re-attempt the close with forceCloseTabIds to bypass
        // this gating on the second pass.
        if terminalPanel.needsConfirmClose() {
            if pendingCloseConfirmTabIds.contains(tab.id) {
                return false
            }

            pendingCloseConfirmTabIds.insert(tab.id)
            let tabId = tab.id
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                Task { @MainActor in
                    defer { self.pendingCloseConfirmTabIds.remove(tabId) }

                    // If the tab disappeared while we were scheduling, do nothing.
                    guard self.panelIdFromSurfaceId(tabId) != nil else { return }

                    let confirmed = await self.confirmClosePanel(for: tabId)
                    guard confirmed else { return }

                    self.forceCloseTabIds.insert(tabId)
                    self.bonsplitController.closeTab(tabId)
                }
            }

            return false
        }

        recordPostCloseSelection()
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        forceCloseTabIds.remove(tabId)
        let selectTabId = postCloseSelectTabId.removeValue(forKey: tabId)

        // Clean up our panel
        guard let panelId = panelIdFromSurfaceId(tabId) else {
            #if DEBUG
            NSLog("[Workspace] didCloseTab: no panelId for tabId")
            #endif
            scheduleTerminalGeometryReconcile()
            scheduleFocusReconcile()
            return
        }

        #if DEBUG
        NSLog("[Workspace] didCloseTab panelId=\(panelId) remainingPanels=\(panels.count - 1) remainingPanes=\(controller.allPaneIds.count)")
        #endif

        let isDetaching = detachingTabIds.remove(tabId) != nil
        let panel = panels[panelId]

        if isDetaching, let panel {
            let browserPanel = panel as? BrowserPanel
            pendingDetachedSurfaces[tabId] = DetachedSurfaceTransfer(
                panelId: panelId,
                panel: panel,
                title: panel.displayTitle,
                icon: panel.displayIcon,
                iconImageData: browserPanel?.faviconPNGData,
                isLoading: browserPanel?.isLoading ?? false,
                directory: panelDirectories[panelId],
                cachedTitle: panelTitles[panelId]
            )
        } else {
            panel?.close()
        }

        panels.removeValue(forKey: panelId)
        surfaceIdToPanelId.removeValue(forKey: tabId)
        panelDirectories.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)

        // Keep the workspace invariant: always retain at least one real panel.
        // This prevents runtime close callbacks from ever collapsing into a tabless workspace.
        if panels.isEmpty {
            let replacement = createReplacementTerminalPanel()
            if let replacementTabId = surfaceIdFromPanelId(replacement.id),
               let replacementPane = bonsplitController.allPaneIds.first {
                bonsplitController.focusPane(replacementPane)
                bonsplitController.selectTab(replacementTabId)
                applyTabSelection(tabId: replacementTabId, inPane: replacementPane)
            }
            scheduleTerminalGeometryReconcile()
            scheduleFocusReconcile()
            return
        }

        if let selectTabId,
           bonsplitController.allPaneIds.contains(pane),
           bonsplitController.tabs(inPane: pane).contains(where: { $0.id == selectTabId }),
           bonsplitController.focusedPaneId == pane {
            // Keep selection/focus convergence in the same close transaction to avoid a transient
            // frame where the pane has no selected content.
            bonsplitController.selectTab(selectTabId)
            applyTabSelection(tabId: selectTabId, inPane: pane)
        }

        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        applyTabSelection(tabId: tab.id, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {
        _ = source
        applyTabSelection(tabId: tab.id, inPane: destination)
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        // When a pane is focused, focus its selected tab's panel
        guard let tab = controller.selectedTab(inPane: pane) else { return }
#if DEBUG
        FocusLogStore.shared.append(
            "Workspace.didFocusPane paneId=\(pane.id.uuidString) tabId=\(tab.id) focusedPane=\(controller.focusedPaneId?.id.uuidString ?? "nil")"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: pane)

        // Apply window background for terminal
        if let panelId = panelIdFromSurfaceId(tab.id),
           let terminalPanel = panels[panelId] as? TerminalPanel {
            terminalPanel.applyWindowBackgroundIfActive()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        _ = paneId
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        // Check if any panel in this pane needs close confirmation
        let tabs = controller.tabs(inPane: pane)
        for tab in tabs {
            if forceCloseTabIds.contains(tab.id) { continue }
            if let panelId = panelIdFromSurfaceId(tab.id),
               let terminalPanel = terminalPanel(for: panelId),
               terminalPanel.needsConfirmClose() {
                return false
            }
        }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
        // Only auto-create a terminal if the split came from bonsplit UI.
        // Programmatic splits via newTerminalSplit() set isProgrammaticSplit and handle their own panels.
        guard !isProgrammaticSplit else {
            scheduleTerminalGeometryReconcile()
            return
        }

        // If the new pane already has a tab, this split moved an existing tab (drag-to-split).
        //
        // In the "drag the only tab to split edge" case, bonsplit inserts a placeholder "Empty"
        // tab in the source pane to avoid leaving it tabless. In cmux, this is undesirable:
        // it creates a pane with no real surfaces and leaves an "Empty" tab in the tab bar.
        //
        // Replace placeholder-only source panes with a real terminal surface, then drop the
        // placeholder tabs so the UI stays consistent and pane lists don't contain empties.
        if !controller.tabs(inPane: newPane).isEmpty {
            let originalTabs = controller.tabs(inPane: originalPane)
            let hasRealSurface = originalTabs.contains { panelIdFromSurfaceId($0.id) != nil }
            if !hasRealSurface {
                _ = newTerminalSurface(inPane: originalPane, focus: false)
                for tab in controller.tabs(inPane: originalPane) {
                    if panelIdFromSurfaceId(tab.id) == nil {
                        bonsplitController.closeTab(tab.id)
                    }
                }
            }
            scheduleTerminalGeometryReconcile()
            return
        }

        // Get the focused terminal in the original pane to inherit config from
        guard let sourceTabId = controller.selectedTab(inPane: originalPane)?.id,
              let sourcePanelId = panelIdFromSurfaceId(sourceTabId),
              let sourcePanel = terminalPanel(for: sourcePanelId) else { return }

        let inheritedConfig: ghostty_surface_config_s? = if let existing = sourcePanel.surface.surface {
            ghostty_surface_inherited_config(existing, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        } else {
            nil
        }

        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig
        )
        panels[newPanel.id] = newPanel

        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            isDirty: newPanel.isDirty,
            inPane: newPane
        ) else {
            panels.removeValue(forKey: newPanel.id)
            return
        }

        surfaceIdToPanelId[newTabId] = newPanel.id

        // `createTab` selects the new tab but does not emit didSelectTab; schedule an explicit
        // selection so our focus/unfocus logic runs after this delegate callback returns.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.bonsplitController.focusedPaneId == newPane {
                self.bonsplitController.selectTab(newTabId)
            }
            self.scheduleTerminalGeometryReconcile()
            self.scheduleFocusReconcile()
        }
    }

    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {
        _ = snapshot
        scheduleTerminalGeometryReconcile()
        scheduleFocusReconcile()
    }

    // No post-close polling refresh loop: we rely on view invariants and Ghostty's wakeups.
}
