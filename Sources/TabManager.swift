import AppKit
import SwiftUI
import Foundation
import Bonsplit

// MARK: - Tab Type Alias for Backwards Compatibility
// The old Tab class is replaced by Workspace
typealias Tab = Workspace

@MainActor
class TabManager: ObservableObject {
    @Published var tabs: [Workspace] = []
    @Published var selectedTabId: UUID? {
        didSet {
            guard selectedTabId != oldValue else { return }
            let previousTabId = oldValue
            if let previousTabId,
               let previousPanelId = focusedPanelId(for: previousTabId) {
                lastFocusedPanelByTab[previousTabId] = previousPanelId
            }
            if !isNavigatingHistory, let selectedTabId {
                recordTabInHistory(selectedTabId)
            }
            DispatchQueue.main.async { [weak self] in
                self?.focusSelectedTabPanel(previousTabId: previousTabId)
                self?.updateWindowTitleForSelectedTab()
                if let selectedTabId = self?.selectedTabId {
                    self?.markFocusedPanelReadIfActive(tabId: selectedTabId)
                }
            }
        }
    }
    private var observers: [NSObjectProtocol] = []
    private var suppressFocusFlash = false
    private var lastFocusedPanelByTab: [UUID: UUID] = [:]

    // Recent tab history for back/forward navigation (like browser history)
    private var tabHistory: [UUID] = []
    private var historyIndex: Int = -1
    private var isNavigatingHistory = false
    private let maxHistorySize = 50

    init() {
        addWorkspace()
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidSetTitle,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            guard let title = notification.userInfo?[GhosttyNotificationKey.title] as? String else { return }
            self.updatePanelTitle(tabId: tabId, panelId: surfaceId, title: title)
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: .ghosttyDidFocusSurface,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let tabId = notification.userInfo?[GhosttyNotificationKey.tabId] as? UUID else { return }
            guard let surfaceId = notification.userInfo?[GhosttyNotificationKey.surfaceId] as? UUID else { return }
            self.markPanelReadOnFocusIfActive(tabId: tabId, panelId: surfaceId)
        })
    }

    var selectedWorkspace: Workspace? {
        guard let selectedTabId else { return nil }
        return tabs.first(where: { $0.id == selectedTabId })
    }

    // Keep selectedTab as convenience alias
    var selectedTab: Workspace? { selectedWorkspace }

    // MARK: - Surface/Panel Compatibility Layer

    /// Returns the focused terminal surface for the selected workspace
    var selectedSurface: TerminalSurface? {
        selectedWorkspace?.focusedTerminalPanel?.surface
    }

    /// Returns the focused panel's terminal panel (if it is a terminal)
    var selectedTerminalPanel: TerminalPanel? {
        selectedWorkspace?.focusedTerminalPanel
    }

    var isFindVisible: Bool {
        selectedTerminalPanel?.searchState != nil
    }

    var canUseSelectionForFind: Bool {
        selectedTerminalPanel?.hasSelection() == true
    }

    func startSearch() {
        guard let panel = selectedTerminalPanel else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
        NSLog("Find: startSearch workspace=%@ panel=%@", panel.workspaceId.uuidString, panel.id.uuidString)
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("start_search")
    }

    func searchSelection() {
        guard let panel = selectedTerminalPanel else { return }
        if panel.searchState == nil {
            panel.searchState = TerminalSurface.SearchState()
        }
        NSLog("Find: searchSelection workspace=%@ panel=%@", panel.workspaceId.uuidString, panel.id.uuidString)
        NotificationCenter.default.post(name: .ghosttySearchFocus, object: panel.surface)
        _ = panel.performBindingAction("search_selection")
    }

    func findNext() {
        _ = selectedTerminalPanel?.performBindingAction("search:next")
    }

    func findPrevious() {
        _ = selectedTerminalPanel?.performBindingAction("search:previous")
    }

    func hideFind() {
        selectedTerminalPanel?.searchState = nil
    }

    @discardableResult
    func addWorkspace() -> Workspace {
        let workingDirectory = preferredWorkingDirectoryForNewTab()
        let newWorkspace = Workspace(title: "Terminal \(tabs.count + 1)", workingDirectory: workingDirectory)
        let insertIndex = newTabInsertIndex()
        if insertIndex >= 0 && insertIndex <= tabs.count {
            tabs.insert(newWorkspace, at: insertIndex)
        } else {
            tabs.append(newWorkspace)
        }
        selectedTabId = newWorkspace.id
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: newWorkspace.id]
        )
        return newWorkspace
    }

    // Keep addTab as convenience alias
    @discardableResult
    func addTab() -> Workspace { addWorkspace() }

    private func newTabInsertIndex() -> Int {
        guard let selectedTabId,
              let index = tabs.firstIndex(where: { $0.id == selectedTabId }) else {
            return tabs.count
        }
        let selectedTab = tabs[index]
        if selectedTab.isPinned {
            let lastPinnedIndex = tabs.lastIndex(where: { $0.isPinned }) ?? -1
            return min(lastPinnedIndex + 1, tabs.count)
        }
        return min(index + 1, tabs.count)
    }

    private func preferredWorkingDirectoryForNewTab() -> String? {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
            return nil
        }
        let focusedDirectory = tab.focusedPanelId
            .flatMap { tab.panelDirectories[$0] }
        let candidate = focusedDirectory ?? tab.currentDirectory
        let normalized = normalizeDirectory(candidate)
        let trimmed = normalized.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : normalized
    }

    func moveTabToTop(_ tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        guard index != 0 else { return }
        let tab = tabs.remove(at: index)
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = tab.isPinned ? 0 : pinnedCount
        tabs.insert(tab, at: insertIndex)
    }

    func moveTabsToTop(_ tabIds: Set<UUID>) {
        guard !tabIds.isEmpty else { return }
        let selectedTabs = tabs.filter { tabIds.contains($0.id) }
        guard !selectedTabs.isEmpty else { return }
        let remainingTabs = tabs.filter { !tabIds.contains($0.id) }
        let selectedPinned = selectedTabs.filter { $0.isPinned }
        let selectedUnpinned = selectedTabs.filter { !$0.isPinned }
        let remainingPinned = remainingTabs.filter { $0.isPinned }
        let remainingUnpinned = remainingTabs.filter { !$0.isPinned }
        tabs = selectedPinned + remainingPinned + selectedUnpinned + remainingUnpinned
    }

    func setCustomTitle(tabId: UUID, title: String?) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        tabs[index].setCustomTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tabs[index])
        }
    }

    func clearCustomTitle(tabId: UUID) {
        setCustomTitle(tabId: tabId, title: nil)
    }

    func togglePin(tabId: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return }
        let tab = tabs[index]
        setPinned(tab, pinned: !tab.isPinned)
    }

    func setPinned(_ tab: Workspace, pinned: Bool) {
        guard tab.isPinned != pinned else { return }
        tab.isPinned = pinned
        reorderTabForPinnedState(tab)
    }

    private func reorderTabForPinnedState(_ tab: Workspace) {
        guard let index = tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        tabs.remove(at: index)
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = min(pinnedCount, tabs.count)
        tabs.insert(tab, at: insertIndex)
    }

    // MARK: - Surface Directory Updates (Backwards Compatibility)

    func updateSurfaceDirectory(tabId: UUID, surfaceId: UUID, directory: String) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        let normalized = normalizeDirectory(directory)
        tab.updatePanelDirectory(panelId: surfaceId, directory: normalized)
    }

    private func normalizeDirectory(_ directory: String) -> String {
        let trimmed = directory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return directory }
        if trimmed.hasPrefix("file://"), let url = URL(string: trimmed) {
            if !url.path.isEmpty {
                return url.path
            }
        }
        return trimmed
    }

    func closeWorkspace(_ workspace: Workspace) {
        guard tabs.count > 1 else { return }

        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: workspace.id)

        if let index = tabs.firstIndex(where: { $0.id == workspace.id }) {
            tabs.remove(at: index)

            if selectedTabId == workspace.id {
                if index > 0 {
                    selectedTabId = tabs[index - 1].id
                } else {
                    selectedTabId = tabs.first?.id
                }
            }
        }
    }

    // Keep closeTab as convenience alias
    func closeTab(_ tab: Workspace) { closeWorkspace(tab) }
    func closeCurrentTabWithConfirmation() { closeCurrentWorkspaceWithConfirmation() }

    func closeCurrentWorkspace() {
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspace(workspace)
    }

    func closeCurrentPanelWithConfirmation() {
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }),
              let focusedPanelId = tab.focusedPanelId else { return }
        closePanelWithConfirmation(tab: tab, panelId: focusedPanelId)
    }

    func closeCurrentWorkspaceWithConfirmation() {
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspaceIfRunningProcess(workspace)
    }

    func selectWorkspace(_ workspace: Workspace) {
        selectedTabId = workspace.id
    }

    // Keep selectTab as convenience alias
    func selectTab(_ tab: Workspace) { selectWorkspace(tab) }

    private func confirmClose(title: String, message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    private func closeWorkspaceIfRunningProcess(_ workspace: Workspace) {
        guard tabs.count > 1 else { return }
        if workspaceNeedsConfirmClose(workspace),
           !confirmClose(
               title: "Close tab?",
               message: "This will close the current tab and all of its panels."
           ) {
            return
        }
        closeWorkspace(workspace)
    }

    private func closePanelWithConfirmation(tab: Workspace, panelId: UUID) {
        let hasMultiplePanels = tab.panels.count > 1 || tab.bonsplitController.allPaneIds.count > 1
        guard hasMultiplePanels else {
            closeWorkspaceIfRunningProcess(tab)
            return
        }

        if let terminalPanel = tab.terminalPanel(for: panelId),
           terminalPanel.needsConfirmClose() {
            guard confirmClose(
                title: "Close panel?",
                message: "This will close the current split panel in this tab."
            ) else { return }
        }

        tab.closePanel(panelId)
    }

    func closePanelWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        closePanelWithConfirmation(tab: tab, panelId: surfaceId)
    }

    private func workspaceNeedsConfirmClose(_ workspace: Workspace) -> Bool {
        workspace.needsConfirmClose()
    }

    func titleForTab(_ tabId: UUID) -> String? {
        tabs.first(where: { $0.id == tabId })?.title
    }

    // MARK: - Panel/Surface ID Access

    /// Returns the focused panel ID for a tab (replaces focusedSurfaceId)
    func focusedPanelId(for tabId: UUID) -> UUID? {
        tabs.first(where: { $0.id == tabId })?.focusedPanelId
    }

    /// Returns the focused panel if it's a BrowserPanel, nil otherwise
    var focusedBrowserPanel: BrowserPanel? {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return nil }
        return tab.panels[panelId] as? BrowserPanel
    }

    /// Backwards compatibility: returns the focused surface ID
    func focusedSurfaceId(for tabId: UUID) -> UUID? {
        focusedPanelId(for: tabId)
    }

    func rememberFocusedSurface(tabId: UUID, surfaceId: UUID) {
        lastFocusedPanelByTab[tabId] = surfaceId
    }

    func applyWindowBackgroundForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let terminalPanel = tab.focusedTerminalPanel else { return }
        terminalPanel.applyWindowBackgroundIfActive()
    }

    private func focusSelectedTabPanel(previousTabId: UUID?) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }

        // Try to restore previous focus
        if let restoredPanelId = lastFocusedPanelByTab[selectedTabId],
           tab.panels[restoredPanelId] != nil,
           tab.focusedPanelId != restoredPanelId {
            tab.focusPanel(restoredPanelId)
        }

        // Focus the panel
        guard let panelId = tab.focusedPanelId,
              let panel = tab.panels[panelId] else { return }

        // Unfocus previous tab's panel
        if let previousTabId,
           let previousTab = tabs.first(where: { $0.id == previousTabId }),
           let previousPanelId = previousTab.focusedPanelId,
           let previousPanel = previousTab.panels[previousPanelId] {
            previousPanel.unfocus()
        }

        panel.focus()

        // For terminal panels, ensure proper focus handling
        if let terminalPanel = panel as? TerminalPanel {
            terminalPanel.hostedView.ensureFocus(for: selectedTabId, surfaceId: panelId)
        }
    }

    private func markFocusedPanelReadIfActive(tabId: UUID) {
        let shouldSuppressFlash = suppressFocusFlash
        suppressFocusFlash = false
        guard !shouldSuppressFlash else { return }
        guard AppFocusState.isAppActive() else { return }
        guard let panelId = focusedPanelId(for: tabId) else { return }
        markPanelReadOnFocusIfActive(tabId: tabId, panelId: panelId)
    }

    private func markPanelReadOnFocusIfActive(tabId: UUID, panelId: UUID) {
        guard selectedTabId == tabId else { return }
        guard !suppressFocusFlash else { return }
        guard AppFocusState.isAppActive() else { return }
        guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
        guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: panelId) else { return }
        if let tab = tabs.first(where: { $0.id == tabId }) {
            tab.triggerNotificationFocusFlash(panelId: panelId, requiresSplit: false, shouldFocus: false)
        }
        notificationStore.markRead(forTabId: tabId, surfaceId: panelId)
    }

    private func updatePanelTitle(tabId: UUID, panelId: UUID, title: String) {
        guard !title.isEmpty else { return }
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.updatePanelTitle(panelId: panelId, title: title)

        // Update window title if this is the selected tab and focused panel
        if selectedTabId == tabId && tab.focusedPanelId == panelId {
            updateWindowTitle(for: tab)
        }
    }

    func focusedSurfaceTitleDidChange(tabId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              let focusedPanelId = tab.focusedPanelId,
              let title = tab.panelTitles[focusedPanelId] else { return }
        tab.applyProcessTitle(title)
        if selectedTabId == tabId {
            updateWindowTitle(for: tab)
        }
    }

    private func updateWindowTitleForSelectedTab() {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else {
            updateWindowTitle(for: nil)
            return
        }
        updateWindowTitle(for: tab)
    }

    private func updateWindowTitle(for tab: Workspace?) {
        let title = windowTitle(for: tab)
        let targetWindow = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first
        targetWindow?.title = title
    }

    private func windowTitle(for tab: Workspace?) -> String {
        guard let tab else { return "cmuxterm" }
        let trimmedTitle = tab.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedTitle.isEmpty {
            return trimmedTitle
        }
        let trimmedDirectory = tab.currentDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedDirectory.isEmpty ? "cmuxterm" : trimmedDirectory
    }

    func focusTab(_ tabId: UUID, surfaceId: UUID? = nil, suppressFlash: Bool = false) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        selectedTabId = tabId
        NotificationCenter.default.post(
            name: .ghosttyDidFocusTab,
            object: nil,
            userInfo: [GhosttyNotificationKey.tabId: tabId]
        )

        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.unhide(nil)
            if let window = NSApp.keyWindow ?? NSApp.windows.first {
                window.makeKeyAndOrderFront(nil)
            }
        }

        if let surfaceId {
            if !suppressFlash {
                focusSurface(tabId: tabId, surfaceId: surfaceId)
            } else if let tab = tabs.first(where: { $0.id == tabId }) {
                tab.focusPanel(surfaceId)
            }
        }
    }

    func focusTabFromNotification(_ tabId: UUID, surfaceId: UUID? = nil) {
        let wasSelected = selectedTabId == tabId
        let desiredPanelId = surfaceId ?? tabs.first(where: { $0.id == tabId })?.focusedPanelId
#if DEBUG
        if let desiredPanelId {
            AppDelegate.shared?.armJumpUnreadFocusRecord(tabId: tabId, surfaceId: desiredPanelId)
        }
#endif
        suppressFocusFlash = true
        focusTab(tabId, surfaceId: desiredPanelId, suppressFlash: true)
        if wasSelected {
            suppressFocusFlash = false
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self,
                  let tab = self.tabs.first(where: { $0.id == tabId }) else { return }
            let targetPanelId = desiredPanelId ?? tab.focusedPanelId
            guard let targetPanelId,
                  tab.panels[targetPanelId] != nil else { return }
            guard let notificationStore = AppDelegate.shared?.notificationStore else { return }
            guard notificationStore.hasUnreadNotification(forTabId: tabId, surfaceId: targetPanelId) else { return }
            tab.triggerNotificationFocusFlash(panelId: targetPanelId, requiresSplit: false, shouldFocus: true)
            notificationStore.markRead(forTabId: tabId, surfaceId: targetPanelId)
        }
    }

    func focusSurface(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        tab.focusPanel(surfaceId)
    }

    func selectNextTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let nextIndex = (currentIndex + 1) % tabs.count
        selectedTabId = tabs[nextIndex].id
    }

    func selectPreviousTab() {
        guard let currentId = selectedTabId,
              let currentIndex = tabs.firstIndex(where: { $0.id == currentId }) else { return }
        let prevIndex = (currentIndex - 1 + tabs.count) % tabs.count
        selectedTabId = tabs[prevIndex].id
    }

    func selectTab(at index: Int) {
        guard index >= 0 && index < tabs.count else { return }
        selectedTabId = tabs[index].id
    }

    func selectLastTab() {
        guard let lastTab = tabs.last else { return }
        selectedTabId = lastTab.id
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane of the selected workspace
    func selectNextSurface() {
        selectedWorkspace?.selectNextSurface()
    }

    /// Select the previous surface in the currently focused pane of the selected workspace
    func selectPreviousSurface() {
        selectedWorkspace?.selectPreviousSurface()
    }

    /// Select a surface by index in the currently focused pane of the selected workspace
    func selectSurface(at index: Int) {
        selectedWorkspace?.selectSurface(at: index)
    }

    /// Select the last surface in the currently focused pane of the selected workspace
    func selectLastSurface() {
        selectedWorkspace?.selectLastSurface()
    }

    /// Create a new terminal surface in the focused pane of the selected workspace
    func newSurface() {
        selectedWorkspace?.newTerminalSurfaceInFocusedPane()
    }

    // MARK: - Split Creation

    /// Create a new split in the current tab
    func createSplit(direction: SplitDirection) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }),
              let focusedPanelId = tab.focusedPanelId else { return }
        _ = newSplit(tabId: selectedTabId, surfaceId: focusedPanelId, direction: direction)
    }

    // MARK: - Pane Focus Navigation

    /// Move focus to an adjacent pane in the specified direction
    func movePaneFocus(direction: NavigationDirection) {
        guard let selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedTabId }) else { return }
        tab.moveFocus(direction: direction)
    }

    // MARK: - Recent Tab History Navigation

    private func recordTabInHistory(_ tabId: UUID) {
        // If we're not at the end of history, truncate forward history
        if historyIndex < tabHistory.count - 1 {
            tabHistory = Array(tabHistory.prefix(historyIndex + 1))
        }

        // Don't add duplicate consecutive entries
        if tabHistory.last == tabId {
            return
        }

        tabHistory.append(tabId)

        // Trim history if it exceeds max size
        if tabHistory.count > maxHistorySize {
            tabHistory.removeFirst(tabHistory.count - maxHistorySize)
        }

        historyIndex = tabHistory.count - 1
    }

    func navigateBack() {
        guard historyIndex > 0 else { return }

        // Find the previous valid tab in history (skip closed tabs)
        var targetIndex = historyIndex - 1
        while targetIndex >= 0 {
            let tabId = tabHistory[targetIndex]
            if tabs.contains(where: { $0.id == tabId }) {
                isNavigatingHistory = true
                historyIndex = targetIndex
                selectedTabId = tabId
                isNavigatingHistory = false
                return
            }
            // Remove closed tab from history
            tabHistory.remove(at: targetIndex)
            historyIndex -= 1
            targetIndex -= 1
        }
    }

    func navigateForward() {
        guard historyIndex < tabHistory.count - 1 else { return }

        // Find the next valid tab in history (skip closed tabs)
        let targetIndex = historyIndex + 1
        while targetIndex < tabHistory.count {
            let tabId = tabHistory[targetIndex]
            if tabs.contains(where: { $0.id == tabId }) {
                isNavigatingHistory = true
                historyIndex = targetIndex
                selectedTabId = tabId
                isNavigatingHistory = false
                return
            }
            // Remove closed tab from history
            tabHistory.remove(at: targetIndex)
            // Don't increment targetIndex since we removed the element
        }
    }

    var canNavigateBack: Bool {
        historyIndex > 0 && tabHistory.prefix(historyIndex).contains { tabId in
            tabs.contains { $0.id == tabId }
        }
    }

    var canNavigateForward: Bool {
        historyIndex < tabHistory.count - 1 && tabHistory.suffix(from: historyIndex + 1).contains { tabId in
            tabs.contains { $0.id == tabId }
        }
    }

    // MARK: - Split Operations (Backwards Compatibility)

    /// Create a new split in the specified direction
    /// Returns the new panel's ID (which is also the surface ID for terminals)
    func newSplit(tabId: UUID, surfaceId: UUID, direction: SplitDirection) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newTerminalSplit(
            from: surfaceId,
            orientation: direction.orientation,
            insertFirst: direction.insertFirst
        )?.id
    }

    /// Move focus in the specified direction
    func moveSplitFocus(tabId: UUID, surfaceId: UUID, direction: NavigationDirection) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }
        tab.moveFocus(direction: direction)
        return true
    }

    /// Resize split - not directly supported by bonsplit, but we can adjust divider positions
    func resizeSplit(tabId: UUID, surfaceId: UUID, direction: ResizeDirection, amount: UInt16) -> Bool {
        // Bonsplit handles resize through its own divider dragging
        // This is a no-op for now as bonsplit manages divider positions internally
        return false
    }

    /// Equalize splits - not directly supported by bonsplit
    func equalizeSplits(tabId: UUID) -> Bool {
        // Bonsplit doesn't have a built-in equalize feature
        // This would require manually setting all divider positions to 0.5
        return false
    }

    /// Toggle zoom on a panel - bonsplit doesn't have zoom support
    func toggleSplitZoom(tabId: UUID, surfaceId: UUID) -> Bool {
        // Bonsplit doesn't have zoom support
        return false
    }

    /// Close a surface/panel
    func closeSurface(tabId: UUID, surfaceId: UUID) -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return false }

        // If this is the only panel and only tab, create a new one
        if tab.panels.count <= 1 && tabs.count == 1 {
            tab.createReplacementTerminalPanel()
        }

        tab.closePanel(surfaceId)
        AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tabId, surfaceId: surfaceId)

        // If tab is now empty and there are other tabs, close it
        if tab.panels.isEmpty && tabs.count > 1 {
            closeWorkspace(tab)
        }

        return true
    }

    // MARK: - Browser Panel Operations

    /// Create a new browser panel in a split
    func newBrowserSplit(tabId: UUID, fromPanelId: UUID, orientation: SplitOrientation, url: URL? = nil) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newBrowserSplit(from: fromPanelId, orientation: orientation, url: url)?.id
    }

    /// Create a new browser surface in a pane
    func newBrowserSurface(tabId: UUID, inPane paneId: PaneID, url: URL? = nil) -> UUID? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.newBrowserSurface(inPane: paneId, url: url)?.id
    }

    /// Get a browser panel by ID
    func browserPanel(tabId: UUID, panelId: UUID) -> BrowserPanel? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.browserPanel(for: panelId)
    }

    /// Open a browser in the currently focused pane (as a new surface)
    func openBrowser(url: URL? = nil) {
        guard let tabId = selectedTabId,
              let tab = tabs.first(where: { $0.id == tabId }),
              let focusedPaneId = tab.bonsplitController.focusedPaneId else { return }
        _ = tab.newBrowserSurface(inPane: focusedPaneId, url: url)
    }

    /// Get a terminal panel by ID
    func terminalPanel(tabId: UUID, panelId: UUID) -> TerminalPanel? {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return nil }
        return tab.terminalPanel(for: panelId)
    }

    /// Get the panel for a surface ID (terminal panels use surface ID as panel ID)
    func surface(for tabId: UUID, surfaceId: UUID) -> TerminalSurface? {
        terminalPanel(tabId: tabId, panelId: surfaceId)?.surface
    }
}

// MARK: - Direction Types for Backwards Compatibility

/// Split direction for backwards compatibility with old API
enum SplitDirection {
    case left, right, up, down

    var isHorizontal: Bool {
        self == .left || self == .right
    }

    var orientation: SplitOrientation {
        isHorizontal ? .horizontal : .vertical
    }

    /// If true, insert the new pane on the "first" side (left/top).
    /// If false, insert on the "second" side (right/bottom).
    var insertFirst: Bool {
        self == .left || self == .up
    }
}

/// Resize direction for backwards compatibility
enum ResizeDirection {
    case left, right, up, down
}

extension Notification.Name {
    static let ghosttyDidSetTitle = Notification.Name("ghosttyDidSetTitle")
    static let ghosttyDidFocusTab = Notification.Name("ghosttyDidFocusTab")
    static let ghosttyDidFocusSurface = Notification.Name("ghosttyDidFocusSurface")
    static let browserFocusAddressBar = Notification.Name("browserFocusAddressBar")
    static let browserDidExitAddressBar = Notification.Name("browserDidExitAddressBar")
}
