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

    // When closing multiple tabs quickly (e.g. collapsing a 2x2 into a 1x2), bonsplit + SwiftUI
    // can transiently reparent views. In rare cases Ghostty's renderer doesn't get a redraw after
    // the final layout settles, leaving a pane visually blank/frozen until the user changes focus.
    // Debounce a post-close refresh to nudge all remaining terminal surfaces.
    // Legacy: retained for backward compatibility with in-flight changes, but no longer used.
    // Intentionally no post-close refresh/polling work items. See didCloseTab.

    // When many tabs are created/selected in quick succession, multiple in-flight selection
    // retries can pile up on the main queue. Track a single generation so newer selection
    // requests cancel older retries (including across panes) early.
    private var applyTabSelectionGeneration: UInt64 = 0

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
        orientation: SplitOrientation,
        insertFirst: Bool = false
    ) -> TerminalPanel? {
        guard let sourcePanel = terminalPanel(for: panelId) else { return nil }

        // Get inherited config from source terminal
        let inheritedConfig: ghostty_surface_config_s? = if let existing = sourcePanel.surface.surface {
            ghostty_surface_inherited_config(existing, GHOSTTY_SURFACE_CONTEXT_SPLIT)
        } else {
            nil
        }

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
	        focusPanel(newPanel.id)

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
            // Use the same focus path as socket-driven focus changes so we reliably transfer
            // AppKit first responder between terminal surfaces after heavy split/tab churn.
            focusPanel(newPanel.id)
            applyTabSelectionEventually(tabId: newTabId, inPane: paneId)
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

	        // Subscribe to browser title/loading/favicon changes to update the bonsplit tab.
	        let subscription = Publishers.CombineLatest3(
	            browserPanel.$pageTitle,
	            browserPanel.$isLoading.removeDuplicates(),
	            browserPanel.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak browserPanel] _, isLoading, favicon in
            guard let self = self,
                  let browserPanel = browserPanel,
                  let tabId = self.surfaceIdFromPanelId(browserPanel.id) else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: browserPanel.displayTitle,
                iconImageData: .some(favicon),
                isLoading: isLoading
            )
        }
        panelSubscriptions[browserPanel.id] = subscription

        return browserPanel
    }

    /// Create a new browser surface in the specified pane.
    /// - Parameter focus: nil = focus only if the target pane is already focused (default UI behavior),
    ///                    true = force focus/selection of the new surface,
    ///                    false = never focus (used for internal placeholder repair paths).
    @discardableResult
    func newBrowserSurface(inPane paneId: PaneID, url: URL? = nil, focus: Bool? = nil) -> BrowserPanel? {
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

        // Match terminal behavior: enforce deterministic selection + focus.
        if shouldFocusNewTab {
            bonsplitController.focusPane(paneId)
            bonsplitController.selectTab(newTabId)
            browserPanel.focus()
            applyTabSelectionEventually(tabId: newTabId, inPane: paneId)
        }

        // Subscribe to browser title/loading/favicon changes to update the bonsplit tab.
        let subscription = Publishers.CombineLatest3(
            browserPanel.$pageTitle,
            browserPanel.$isLoading.removeDuplicates(),
            browserPanel.$faviconPNGData.removeDuplicates(by: { $0 == $1 })
        )
        .receive(on: DispatchQueue.main)
        .sink { [weak self, weak browserPanel] _, isLoading, favicon in
            guard let self = self,
                  let browserPanel = browserPanel,
                  let tabId = self.surfaceIdFromPanelId(browserPanel.id) else { return }
            self.bonsplitController.updateTab(
                tabId,
                title: browserPanel.displayTitle,
                iconImageData: .some(favicon),
                isLoading: isLoading
            )
        }
        panelSubscriptions[browserPanel.id] = subscription

        return browserPanel
    }

    /// Close a panel
    func closePanel(_ panelId: UUID, force: Bool = false) {
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }

        if force {
            forceCloseTabIds.insert(tabId)
        }

        // Close the tab in bonsplit (this triggers delegate callback)
        bonsplitController.closeTab(tabId)
    }

    // MARK: - Focus Management

    // Cancel any in-flight selection convergence loops. This is important when the user (or socket)
    // explicitly changes focus: older retries must not steal focus back in a later runloop tick.
    func cancelTabSelectionConvergence() {
        applyTabSelectionGeneration &+= 1
    }

    func focusPanel(_ panelId: UUID) {
#if DEBUG
        let pane = bonsplitController.focusedPaneId?.id.uuidString ?? "nil"
        FocusLogStore.shared.append("Workspace.focusPanel panelId=\\(panelId.uuidString) focusedPane=\\(pane)")
#endif
        guard let tabId = surfaceIdFromPanelId(panelId) else { return }

        cancelTabSelectionConvergence()

        // Capture the currently focused terminal view so we can explicitly move AppKit first
        // responder when focusing another terminal (helps avoid "highlighted but typing goes to
        // another pane" after heavy split/tab mutations).
        let previousTerminalHostedView = focusedTerminalPanel?.hostedView

        // `selectTab` does not necessarily move bonsplit's focused pane. For programmatic focus
        // (socket API, notification click, etc.), ensure the target tab's pane becomes focused
        // so `focusedPanelId` and follow-on focus logic are coherent.
        let targetPaneId = bonsplitController.allPaneIds.first(where: { paneId in
            bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
        })
        if let targetPaneId {
            bonsplitController.focusPane(targetPaneId)
        }

        bonsplitController.selectTab(tabId)

        // Also focus the underlying panel
        if let panel = panels[panelId] {
            panel.focus()

            if let terminalPanel = panel as? TerminalPanel {
                // Avoid re-entrant focus loops when focus was initiated by AppKit first-responder
                // (becomeFirstResponder -> onFocus -> focusPanel).
                if !terminalPanel.hostedView.isSurfaceViewFirstResponder() {
                    terminalPanel.hostedView.moveFocus(from: previousTerminalHostedView)
                }
            }
        }

        // bonsplit selection/focus can lag or "snap back" under heavy churn. Converge on the
        // intended focus target so the surface becomes interactive deterministically.
        if let targetPaneId {
            applyTabSelectionEventually(tabId: tabId, inPane: targetPaneId)
        } else {
            // If the tab isn't discoverable in a pane yet, retry once on the next tick.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard let paneId = self.bonsplitController.allPaneIds.first(where: { paneId in
                    self.bonsplitController.tabs(inPane: paneId).contains(where: { $0.id == tabId })
                }) else { return }
                self.applyTabSelectionEventually(tabId: tabId, inPane: paneId)
            }
        }
    }

    func moveFocus(direction: NavigationDirection) {
        // Cancel any in-flight selection convergence loops so they can't steal focus back
        // after explicit user-driven (or socket-driven) navigation.
        cancelTabSelectionConvergence()

        // Unfocus the currently-focused panel immediately so any in-flight terminal focus retries
        // are canceled before we navigate away. Otherwise, `ensureFocus` can briefly succeed and
        // steal bonsplit focus back to the old pane after navigation (notably in VM tests).
        if let prevPanelId = focusedPanelId, let prev = panels[prevPanelId] {
            prev.unfocus()
        }

        let previousPaneId = bonsplitController.focusedPaneId
        bonsplitController.navigateFocus(direction: direction)

        // Wait for bonsplit to publish the new focused pane before applying selection side-effects.
        // (navigateFocus can update focus on a later runloop tick.)
        scheduleApplyFocusedSelection(afterPaneFocusChangeFrom: previousPaneId)
    }

    private func scheduleApplyFocusedSelection(afterPaneFocusChangeFrom previousPaneId: PaneID?, attempt: Int = 0) {
        let maxAttempts = 80 // ~1.6s worst-case at 20ms ticks
        guard attempt < maxAttempts else { return }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            guard let self else { return }

            let paneId = self.bonsplitController.focusedPaneId
            // If focus hasn't changed yet, keep waiting.
            if paneId == previousPaneId {
                self.scheduleApplyFocusedSelection(afterPaneFocusChangeFrom: previousPaneId, attempt: attempt + 1)
                return
            }

            guard let paneId, let tabId = self.bonsplitController.selectedTab(inPane: paneId)?.id else { return }
            self.applyTabSelection(tabId: tabId, inPane: paneId)
            // Keep converging briefly to survive bonsplit/SwiftUI "snap back" under churn.
            self.applyTabSelectionEventually(tabId: tabId, inPane: paneId)
        }
    }

    // MARK: - Surface Navigation

    /// Select the next surface in the currently focused pane
    func selectNextSurface() {
        cancelTabSelectionConvergence()
        bonsplitController.selectNextTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
            applyTabSelectionEventually(tabId: tabId, inPane: paneId)
        }
    }

    /// Select the previous surface in the currently focused pane
    func selectPreviousSurface() {
        cancelTabSelectionConvergence()
        bonsplitController.selectPreviousTab()

        if let paneId = bonsplitController.focusedPaneId,
           let tabId = bonsplitController.selectedTab(inPane: paneId)?.id {
            applyTabSelection(tabId: tabId, inPane: paneId)
            applyTabSelectionEventually(tabId: tabId, inPane: paneId)
        }
    }

    /// Select a surface by index in the currently focused pane
    func selectSurface(at index: Int) {
        cancelTabSelectionConvergence()
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard index >= 0 && index < tabs.count else { return }
        bonsplitController.selectTab(tabs[index].id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
            applyTabSelectionEventually(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Select the last surface in the currently focused pane
    func selectLastSurface() {
        cancelTabSelectionConvergence()
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return }
        let tabs = bonsplitController.tabs(inPane: focusedPaneId)
        guard let last = tabs.last else { return }
        bonsplitController.selectTab(last.id)

        if let tabId = bonsplitController.selectedTab(inPane: focusedPaneId)?.id {
            applyTabSelection(tabId: tabId, inPane: focusedPaneId)
            applyTabSelectionEventually(tabId: tabId, inPane: focusedPaneId)
        }
    }

    /// Create a new terminal surface in the currently focused pane
    @discardableResult
    func newTerminalSurfaceInFocusedPane() -> TerminalPanel? {
        guard let focusedPaneId = bonsplitController.focusedPaneId else { return nil }
        return newTerminalSurface(inPane: focusedPaneId)
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
        // Avoid racing with later user-driven selection changes.
        guard bonsplitController.focusedPaneId == pane,
              bonsplitController.selectedTab(inPane: pane)?.id == tabId else {
            return
        }

        // Focus the selected panel
        guard let panelId = panelIdFromSurfaceId(tabId),
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

    private func applyTabSelectionEventually(
        tabId: TabID,
        inPane pane: PaneID,
        attempt: Int = 0,
        generation: UInt64? = nil,
        stableCount: Int = 0
    ) {
        let maxAttempts = 150
        guard attempt < maxAttempts else { return }

        let gen: UInt64 = {
            if let generation { return generation }
            applyTabSelectionGeneration &+= 1
            return applyTabSelectionGeneration
        }()
        guard applyTabSelectionGeneration == gen else { return }

        // Nudge bonsplit state towards the desired selection: in some programmatic paths
        // (createTab/selectTab), selection can lag (or a too-early select can be ignored
        // before the view tree finishes updating). Re-apply focus+selection until it sticks.
        if bonsplitController.focusedPaneId != pane {
            bonsplitController.focusPane(pane)
        }
        if bonsplitController.selectedTab(inPane: pane)?.id != tabId {
            bonsplitController.selectTab(tabId)
        }

        let isSelectedAndFocused = bonsplitController.focusedPaneId == pane
            && bonsplitController.selectedTab(inPane: pane)?.id == tabId

        // Selection can "snap back" after we momentarily observe the correct tab (SwiftUI tree
        // commit ordering). Require a consecutive-stability window before stopping retries.
        if isSelectedAndFocused {
            // Only apply side-effects once per stability window; subsequent checks only verify
            // that focus+selection remain stable long enough.
            if stableCount == 0 {
                applyTabSelection(tabId: tabId, inPane: pane)
            }

            // 25 * 0.02s ~= 500ms of stable focus+selection. This is intentionally conservative
            // to survive late SwiftUI "snap back" under heavy split/tab churn.
            if stableCount >= 25 { return }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
            self?.applyTabSelectionEventually(
                tabId: tabId,
                inPane: pane,
                attempt: attempt + 1,
                generation: gen,
                stableCount: isSelectedAndFocused ? stableCount + 1 : 0
            )
        }
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

        if let selectTabId {
            // Defer selection so bonsplit has a chance to fully apply its close mutation first.
            // This makes selection deterministic (next tab if present, otherwise previous).
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard self.bonsplitController.allPaneIds.contains(pane) else { return }
                guard self.bonsplitController.tabs(inPane: pane).contains(where: { $0.id == selectTabId }) else { return }
                // Avoid stealing focus if the user/test has moved on to another pane.
                guard self.bonsplitController.focusedPaneId == pane else { return }
                self.bonsplitController.selectTab(selectTabId)
                self.applyTabSelectionEventually(tabId: selectTabId, inPane: pane)
            }
        }

        // Avoid any post-close polling/forced redraw loops. The view hierarchy should remain
        // stable and always render a tab when tabs exist (bonsplit ensures selection).
    }

    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {
        applyTabSelection(tabId: tab.id, inPane: pane)
    }

    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {
        // When a pane is focused, focus its selected tab's panel
        guard let tab = controller.selectedTab(inPane: pane) else { return }
#if DEBUG
        FocusLogStore.shared.append(
            "Workspace.didFocusPane paneId=\\(pane.id.uuidString) tabId=\\(tab.id.uuidString) focusedPane=\\(controller.focusedPaneId?.id.uuidString ?? \"nil\")"
        )
#endif
        applyTabSelection(tabId: tab.id, inPane: pane)

        // Apply window background for terminal
        if let panelId = panelIdFromSurfaceId(tab.id),
           let terminalPanel = panels[panelId] as? TerminalPanel {
            terminalPanel.applyWindowBackgroundIfActive()
        }
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
        guard !isProgrammaticSplit else { return }

        // If the new pane already has a tab, this split moved an existing tab (drag-to-split).
        //
        // In the "drag the only tab to split edge" case, bonsplit inserts a placeholder "Empty"
        // tab in the source pane to avoid leaving it tabless. In cmuxterm, this is undesirable:
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
        }
    }

    // No post-close polling refresh loop: we rely on view invariants and Ghostty's wakeups.
}
