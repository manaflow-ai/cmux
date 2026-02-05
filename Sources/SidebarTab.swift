import Foundation
import SwiftUI
import Bonsplit
import Combine

/// SidebarTab replaces the old Tab class.
/// Each sidebar tab contains one BonsplitController that manages split panes and nested tabs.
@MainActor
final class SidebarTab: Identifiable, ObservableObject {
    let id: UUID
    @Published var title: String
    @Published var customTitle: String?
    @Published var isPinned: Bool = false
    @Published var currentDirectory: String

    /// The bonsplit controller managing the split panes for this sidebar tab
    let bonsplitController: BonsplitController

    /// Mapping from bonsplit TabID to our Panel instances
    @Published private(set) var panels: [UUID: any Panel] = [:]

    /// Subscriptions for panel updates (e.g., browser title changes)
    private var panelSubscriptions: [UUID: AnyCancellable] = [:]

    /// The currently focused pane's panel ID
    var focusedPanelId: UUID? {
        guard let paneId = bonsplitController.focusedPaneId,
              let tab = bonsplitController.selectedTab(inPane: paneId) else {
            return nil
        }
        return panelIdFromTabId(tab.id)
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
            sidebarTabId: id,
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
            tabIdToPanelId[tabId] = terminalPanel.id
        }

        // Close the default Welcome tab(s)
        for welcomeTabId in welcomeTabIds {
            bonsplitController.closeTab(welcomeTabId)
        }

        // Set ourselves as delegate
        bonsplitController.delegate = self
    }

    // MARK: - Tab ID to Panel ID Mapping

    /// Mapping from bonsplit TabID to panel UUID
    private var tabIdToPanelId: [TabID: UUID] = [:]

    func panelIdFromTabId(_ tabId: TabID) -> UUID? {
        tabIdToPanelId[tabId]
    }

    func tabIdFromPanelId(_ panelId: UUID) -> TabID? {
        tabIdToPanelId.first { $0.value == panelId }?.key
    }

    // MARK: - Panel Access

    func panel(for tabId: TabID) -> (any Panel)? {
        guard let panelId = panelIdFromTabId(tabId) else { return nil }
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
        if let tabId = tabIdFromPanelId(panelId) {
            bonsplitController.updateTab(tabId, title: trimmed)
        }

        // If this is the only panel and no custom title, update sidebar tab title
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
            sidebarTabId: id,
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: inheritedConfig
        )
        panels[newPanel.id] = newPanel

        // Find the pane containing the source panel
        guard let sourceTabId = tabIdFromPanelId(panelId) else { return nil }
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

        tabIdToPanelId[newTabId] = newPanel.id

        return newPanel
    }

    /// Create a new nested tab in the specified pane with a terminal panel
    @discardableResult
    func newTerminalTab(inPane paneId: PaneID) -> TerminalPanel? {
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
            sidebarTabId: id,
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

        tabIdToPanelId[newTabId] = newPanel.id
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
        guard let sourceTabId = tabIdFromPanelId(panelId) else { return nil }
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
        guard let newPaneId = bonsplitController.splitPane(paneId, orientation: orientation) else {
            return nil
        }

        // Create browser panel
        let browserPanel = BrowserPanel(sidebarTabId: id, initialURL: url)
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

        tabIdToPanelId[newTabId] = browserPanel.id
        return browserPanel
    }

    /// Create a new browser tab in the specified pane
    @discardableResult
    func newBrowserTab(inPane paneId: PaneID, url: URL? = nil) -> BrowserPanel? {
        let browserPanel = BrowserPanel(sidebarTabId: id, initialURL: url)
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

        tabIdToPanelId[newTabId] = browserPanel.id

        // Subscribe to browser title changes to update the bonsplit tab
        let subscription = browserPanel.$pageTitle
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak browserPanel] _ in
                guard let self = self,
                      let browserPanel = browserPanel,
                      let tabId = self.tabIdFromPanelId(browserPanel.id) else { return }
                self.bonsplitController.updateTab(tabId, title: browserPanel.displayTitle)
            }
        panelSubscriptions[browserPanel.id] = subscription

        return browserPanel
    }

    /// Close a panel
    func closePanel(_ panelId: UUID) {
        guard let tabId = tabIdFromPanelId(panelId) else { return }

        // Close the tab in bonsplit (this triggers delegate callback)
        bonsplitController.closeTab(tabId)
    }

    // MARK: - Focus Management

    func focusPanel(_ panelId: UUID) {
        guard let tabId = tabIdFromPanelId(panelId) else { return }
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

    // MARK: - Bonsplit Tab Navigation

    /// Select the next tab in the currently focused pane
    func selectNextBonsplitTab() {
        bonsplitController.selectNextTab()

        // Focus the newly selected panel
        if let panelId = focusedPanelId, let panel = panels[panelId] {
            panel.focus()
        }
    }

    /// Select the previous tab in the currently focused pane
    func selectPreviousBonsplitTab() {
        bonsplitController.selectPreviousTab()

        // Focus the newly selected panel
        if let panelId = focusedPanelId, let panel = panels[panelId] {
            panel.focus()
        }
    }

    /// Create a new terminal tab in the currently focused pane
    @discardableResult
    func newTerminalTabInFocusedPane() -> TerminalPanel? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        return newTerminalTab(inPane: focusedPaneId)
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
            sidebarTabId: id,
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
            tabIdToPanelId[newTabId] = newPanel.id
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

extension SidebarTab: BonsplitDelegate {
    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool {
        // Check if the panel needs close confirmation
        guard let panelId = panelIdFromTabId(tab.id),
              let terminalPanel = terminalPanel(for: panelId) else {
            return true
        }
        return !terminalPanel.needsConfirmClose()
    }

    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {
        // Clean up our panel
        guard let panelId = panelIdFromTabId(tabId) else {
            #if DEBUG
            NSLog("[SidebarTab] didCloseTab: no panelId for tabId")
            #endif
            return
        }

        #if DEBUG
        NSLog("[SidebarTab] didCloseTab panelId=\(panelId) remainingPanels=\(panels.count - 1) remainingPanes=\(controller.allPaneIds.count)")
        #endif

        if let panel = panels[panelId] {
            panel.close()
        }
        panels.removeValue(forKey: panelId)
        tabIdToPanelId.removeValue(forKey: tabId)
        panelDirectories.removeValue(forKey: panelId)
        panelTitles.removeValue(forKey: panelId)
        panelSubscriptions.removeValue(forKey: panelId)
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        // Focus the selected panel
        guard let panelId = panelIdFromTabId(tab.id),
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
              let panelId = panelIdFromTabId(tab.id),
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
            if let panelId = panelIdFromTabId(tab.id),
               let terminalPanel = terminalPanel(for: panelId),
               terminalPanel.needsConfirmClose() {
                return false
            }
        }
        return true
    }

    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {
        // Panels are cleaned up via didCloseTab callbacks
    }

    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {
        // If the new pane is empty, we could auto-populate it
        // For now, let the caller handle this
    }
}
