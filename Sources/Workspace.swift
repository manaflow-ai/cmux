import Foundation
import SwiftUI
import Bonsplit
import Combine

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
        if let tabId = bonsplitController.createTab(
            title: title,
            icon: "terminal",
            isDirty: false
        ) {
            surfaceIdToPanelId[tabId] = terminalPanel.id
        }

        // Close the default Welcome tab(s)
        for welcomeTabId in welcomeTabIds {
            bonsplitController.closeTab(welcomeTabId)
        }

        // Set ourselves as delegate
        bonsplitController.delegate = self
    }

    // MARK: - Surface ID to Panel ID Mapping

    /// Mapping from bonsplit TabID (surface ID) to panel UUID
    private var surfaceIdToPanelId: [TabID: UUID] = [:]

    func panelIdFromSurfaceId(_ surfaceId: TabID) -> UUID? {
        surfaceIdToPanelId[surfaceId]
    }

    func surfaceIdFromPanelId(_ panelId: UUID) -> TabID? {
        surfaceIdToPanelId.first { $0.value == panelId }?.key
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

    // MARK: - Panel Operations

    /// Create a new split with a terminal panel
    @discardableResult
    func newTerminalSplit(
        from panelId: UUID,
        orientation: SplitOrientation
    ) -> TerminalPanel? {
        guard let sourcePanel = terminalPanel(for: panelId) else { return nil }

        // Get inherited config from source terminal
        let inheritedConfig: ghostty_surface_config_s? = if let existing = sourcePanel.surface.surface {
            ghostty_surface_inherited_config(existing, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        } else {
            nil
        }

        // Create new terminal panel
        let newPanel = TerminalPanel(
            workspaceId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig
        )
        panels[newPanel.id] = newPanel

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

        // Create the split - this creates a new empty pane
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation) else {
            panels.removeValue(forKey: newPanel.id)
            return nil
        }

        // Create a tab in the new pane for our panel
        guard let newTabId = bonsplitController.createTab(
            title: newPanel.displayTitle,
            icon: newPanel.displayIcon,
            isDirty: newPanel.isDirty,
            inPane: newPaneId
        ) else {
            panels.removeValue(forKey: newPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = newPanel.id

        return newPanel
    }

    /// Create a new surface (nested tab) in the specified pane with a terminal panel
    @discardableResult
    func newTerminalSurface(inPane paneId: PaneID) -> TerminalPanel? {
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
        return newPanel
    }

    /// Create a new browser panel split
    @discardableResult
    func newBrowserSplit(
        from panelId: UUID,
        orientation: SplitOrientation,
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

        // Create the split
        // Mark this split as programmatic so didSplitPane doesn't auto-create a terminal.
        isProgrammaticSplit = true
        defer { isProgrammaticSplit = false }
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation) else {
            return nil
        }

        // Create browser panel
        let browserPanel = BrowserPanel(workspaceId: id, initialURL: url)
        panels[browserPanel.id] = browserPanel

        // Create tab in the new pane
        guard let newTabId = bonsplitController.createTab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            isDirty: browserPanel.isDirty,
            inPane: newPaneId
        ) else {
            panels.removeValue(forKey: browserPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = browserPanel.id
        return browserPanel
    }

    /// Create a new browser surface in the specified pane
    @discardableResult
    func newBrowserSurface(inPane paneId: PaneID, url: URL? = nil) -> BrowserPanel? {
        let browserPanel = BrowserPanel(workspaceId: id, initialURL: url)
        panels[browserPanel.id] = browserPanel

        guard let newTabId = bonsplitController.createTab(
            title: browserPanel.displayTitle,
            icon: browserPanel.displayIcon,
            isDirty: browserPanel.isDirty,
            inPane: paneId
        ) else {
            panels.removeValue(forKey: browserPanel.id)
            return nil
        }

        surfaceIdToPanelId[newTabId] = browserPanel.id

        // Subscribe to browser title changes to update the bonsplit tab
        let subscription = browserPanel.$pageTitle
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak browserPanel] _ in
                guard let self = self,
                      let browserPanel = browserPanel,
                      let tabId = self.surfaceIdFromPanelId(browserPanel.id) else { return }
                self.bonsplitController.updateTab(tabId, title: browserPanel.displayTitle)
            }
        panelSubscriptions[browserPanel.id] = subscription

        return browserPanel
    }

    /// Close a panel
    func closePanel(_ panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }

        // Close the tab in bonsplit (this triggers delegate callback)
        bonsplitController.closeTab(tabId)
    }

    // MARK: - Focus Management

    func focusPanel(_ panelId: UUID) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }
        bonsplitController.selectTab(tabId)

        // Also focus the underlying panel
        if let panel = panels[panelId] {
            panel.focus()
        }
    }

    func moveFocus(direction: NavigationDirection) {
        bonsplitController.navigateFocus(direction: direction)

        // Focus the newly selected panel
        if let panelId = focusedPanelId, let panel = panels[panelId] {
            panel.focus()
        }
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane
    func selectNextSurface() {
        bonsplitController.selectNextTab()

        // Focus the newly selected panel
        if let panelId = focusedPanelId, let panel = panels[panelId] {
            panel.focus()
        }
    }

    /// Select the previous surface in the currently focused pane
    func selectPreviousSurface() {
        bonsplitController.selectPreviousTab()

        // Focus the newly selected panel
        if let panelId = focusedPanelId, let panel = panels[panelId] {
            panel.focus()
        }
    }

    /// Select a surface by index in the currently focused pane
    func selectSurface(at index: Int) {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard index >= 0 && index < tabs.count else { return }
        bonsplitController.selectTab(tabs[index].id)

        // Focus the newly selected panel
        if let panelId = focusedPanelId, let panel = panels[panelId] {
            panel.focus()
        }
    }

    /// Select the last surface in the currently focused pane
    func selectLastSurface() {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = tabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let panelId = focusedPanelId, let panel = panels[panelId] {
            panel.focus()
        }
    }

    /// Create a new terminal surface in the currently focused pane
    @discardableResult
    func newTerminalSurfaceInFocusedPane() -> TerminalPanel? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        return newTerminalSurface(inPane: focusedPaneId)
    }

    // MARK: - Flash/Notification Support

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
}

// MARK: - BonsplitDelegate

extension Workspace: BonsplitDelegate {
    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        // Check if the panel needs close confirmation
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let terminalPanel = terminalPanel(for: panelId) else {
            return true
        }
        return !terminalPanel.needsConfirmClose()
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        // Clean up our panel
        guard let panelId = panelIdFromSurfaceId(tabId) else {
            #if DEBUG
            NSLog("[Workspace] didCloseTab: no panelId for tabId")
            #endif
            return
        }

        #if DEBUG
        NSLog("[Workspace] didCloseTab panelId=\(panelId) remainingPanels=\(panels.count - 1) remainingPanes=\(controller.allPaneIds.count)")
        #endif

        if let panel = panels[panelId] {
            panel.close()
        }
        panels.removeValue(forKey: panelId)
        surfaceIdToPanelId.removeValue(forKey: tabId)
        panelDirectories.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)

        // After a tab close, remaining terminals may need a refresh
        // (bonsplit may collapse the pane and trigger layout changes).
        refreshAllTerminals()
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        // Focus the selected panel
        guard let panelId = panelIdFromSurfaceId(tab.id),
              let panel = panels[panelId] else {
            return
        }

        // Unfocus all other panels
        for (id, p) in panels where id != panelId {
            p.unfocus()
        }

        panel.focus()

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

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        // When a pane is focused, focus its selected tab's panel
        guard let tab = controller.selectedTab(inPane: pane),
              let panelId = panelIdFromSurfaceId(tab.id),
              let panel = panels[panelId] else {
            return
        }

        // Unfocus all other panels
        for (id, p) in panels where id != panelId {
            p.unfocus()
        }

        panel.focus()

        // Apply window background for terminal
        if let terminalPanel = panel as? TerminalPanel {
            terminalPanel.applyWindowBackgroundIfActive()
        }
    }

    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool {
        // Check if any panel in this pane needs close confirmation
        let tabs = controller.tabs(inPane: pane)
        for tab in tabs {
            if let panelId = panelIdFromSurfaceId(tab.id),
               let terminalPanel = terminalPanel(for: panelId),
               terminalPanel.needsConfirmClose() {
                return false
            }
        }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        // Panels are cleaned up via didCloseTab callbacks.
        refreshAllTerminals()
    }

    /// Force-refresh all remaining terminal surfaces after layout changes.
    /// After bonsplit tree restructuring, views may be temporarily not in a window.
    /// We poll until all terminal surfaces have their views back in the window,
    /// then force a refresh. Uses ghostty_surface_draw (sync=true) to force a
    /// frame even when ghostty_surface_set_size is a no-op (same dimensions).
    private func refreshAllTerminals() {
        // Immediate refresh for surfaces already in the window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.refreshTerminalsInWindow()
        }
        // Poll for surfaces not yet in the window (during tree restructuring)
        pollForOrphanedSurfaces(attempts: 0)
    }

    /// Refresh terminal surfaces that are currently in a window.
    private func refreshTerminalsInWindow() {
        for panel in panels.values {
            if let tp = panel as? TerminalPanel, tp.surface.isViewInWindow {
                tp.surface.forceRefresh()
            }
        }
    }

    /// Poll until all terminal surfaces are in a window, then refresh them.
    /// Max ~3 seconds (30 attempts * 100ms).
    private func pollForOrphanedSurfaces(attempts: Int) {
        let maxAttempts = 30
        guard attempts < maxAttempts else {
            #if DEBUG
            NSLog("[Workspace] pollForOrphanedSurfaces: timed out after \(maxAttempts) attempts")
            #endif
            // Final attempt: refresh whatever we can
            for panel in panels.values {
                if let tp = panel as? TerminalPanel {
                    tp.surface.forceRefresh()
                }
            }
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }

            let orphaned = self.panels.values.contains { panel in
                if let tp = panel as? TerminalPanel {
                    return !tp.surface.isViewInWindow
                }
                return false
            }

            if orphaned {
                // Some surfaces still not in window, keep polling
                self.pollForOrphanedSurfaces(attempts: attempts + 1)
            } else {
                // All surfaces in window — refresh them all
                for panel in self.panels.values {
                    if let tp = panel as? TerminalPanel {
                        tp.surface.forceRefresh()
                    }
                }
            }
        }
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
        // Only auto-create a terminal if the split came from bonsplit UI.
        // Programmatic splits via newTerminalSplit() set isProgrammaticSplit and handle their own panels.
        guard !isProgrammaticSplit else { return }

        // If the new pane already has a tab, this split moved an existing tab (drag-to-split).
        // Don't auto-create another terminal on top of the moved content.
        guard controller.tabs(inPane: newPane).isEmpty else { return }

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
    }
}
