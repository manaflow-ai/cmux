import AppKit
import SwiftUI
import Foundation
import Bonsplit
import CoreVideo

// MARK: - Tab Type Alias for Backwards Compatibility
// The old Tab class is replaced by Workspace
typealias Tab = Workspace

#if DEBUG
// Sample the actual IOSurface-backed terminal layer at vsync cadence so UI tests can reliably
// catch a single compositor-frame blank flash and any transient compositor scaling (stretched text).
//
// This is DEBUG-only and used only for UI tests; no polling or display-link loops exist in normal app runtime.
fileprivate final class VsyncIOSurfaceTimelineState {
    struct Target {
        let label: String
        let sample: @MainActor () -> GhosttySurfaceScrollView.DebugFrameSample?
    }

    let frameCount: Int
    let closeFrame: Int
    let lock = NSLock()

    var framesWritten = 0
    var inFlight = false
    var finished = false

    var scheduledActions: [(frame: Int, action: () -> Void)] = []
    var nextActionIndex: Int = 0

    var targets: [Target] = []

    // Results
    var firstBlank: (label: String, frame: Int)?
    var firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?
    var trace: [String] = []

    var link: CVDisplayLink?
    var continuation: CheckedContinuation<Void, Never>?

    init(frameCount: Int, closeFrame: Int) {
        self.frameCount = frameCount
        self.closeFrame = closeFrame
    }

    func tryBeginCapture() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if finished { return false }
        if inFlight { return false }
        inFlight = true
        return true
    }

    func endCapture() {
        lock.lock()
        inFlight = false
        lock.unlock()
    }

    func finish() {
        lock.lock()
        if finished {
            lock.unlock()
            return
        }
        finished = true
        let cont = continuation
        continuation = nil
        lock.unlock()
        cont?.resume()
    }
}

fileprivate func cmuxVsyncIOSurfaceTimelineCallback(
    _ displayLink: CVDisplayLink,
    _ inNow: UnsafePointer<CVTimeStamp>,
    _ inOutputTime: UnsafePointer<CVTimeStamp>,
    _ flagsIn: CVOptionFlags,
    _ flagsOut: UnsafeMutablePointer<CVOptionFlags>,
    _ ctx: UnsafeMutableRawPointer?
) -> CVReturn {
    guard let ctx else { return kCVReturnSuccess }
    let st = Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).takeUnretainedValue()
    if !st.tryBeginCapture() { return kCVReturnSuccess }

    // Sample on the main thread synchronously so we don't "miss" a single compositor frame.
    // (The previous Task/@MainActor hop could be delayed long enough to skip the blank frame.)
    DispatchQueue.main.sync {
        defer { st.endCapture() }
        guard st.framesWritten < st.frameCount else { return }

        while st.nextActionIndex < st.scheduledActions.count {
            let next = st.scheduledActions[st.nextActionIndex]
            if next.frame != st.framesWritten { break }
            st.nextActionIndex += 1
            next.action()
        }

        for t in st.targets {
            guard let s = t.sample() else { continue }

            if st.firstBlank == nil, s.isProbablyBlank {
                st.firstBlank = (label: t.label, frame: st.framesWritten)
            }

            let iosW = s.iosurfaceWidthPx
            let iosH = s.iosurfaceHeightPx
            let expW = s.expectedWidthPx
            let expH = s.expectedHeightPx
            if st.firstSizeMismatch == nil,
               iosW > 0, iosH > 0, expW > 0, expH > 0 {
                let dw = abs(iosW - expW)
                let dh = abs(iosH - expH)
                if dw > 2 || dh > 2 {
                    st.firstSizeMismatch = (
                        label: t.label,
                        frame: st.framesWritten,
                        ios: "\(iosW)x\(iosH)",
                        expected: "\(expW)x\(expH)"
                    )
                }
            }

            if st.trace.count < 200 {
                st.trace.append("\(st.framesWritten):\(t.label):blank=\(s.isProbablyBlank ? 1 : 0):ios=\(iosW)x\(iosH):exp=\(expW)x\(expH):key=\(s.layerContentsKey)")
            }
        }

        st.framesWritten += 1
    }

    // Stop/resume outside the main-thread sync block to avoid reentrancy issues.
    if st.framesWritten >= st.frameCount, let link = st.link {
        CVDisplayLinkStop(link)
        st.finish()
        Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
    }

    return kCVReturnSuccess
}
#endif

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

#if DEBUG
    private var didSetupSplitCloseRightUITest = false
    private var didSetupUITestFocusShortcuts = false
#endif

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

#if DEBUG
        setupUITestFocusShortcutsIfNeeded()
        setupSplitCloseRightUITestIfNeeded()
#endif
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
#if DEBUG
        UITestRecorder.incrementInt("addTabInvocations")
        UITestRecorder.record([
            "tabCount": String(tabs.count),
            "selectedTabId": newWorkspace.id.uuidString
        ])
#endif
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
                // Keep the "focused index" stable when possible:
                // - If we closed workspace i and there is still a workspace at index i, focus it (the one that moved up).
                // - Otherwise (we closed the last workspace), focus the new last workspace (i-1).
                let newIndex = min(index, max(0, tabs.count - 1))
                selectedTabId = tabs[newIndex].id
            }
        }
    }

    /// Detach a workspace from this window without closing its panels.
    /// Used by the socket API for cross-window moves.
    @discardableResult
    func detachWorkspace(tabId: UUID) -> Workspace? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }

        let removed = tabs.remove(at: index)
        lastFocusedPanelByTab.removeValue(forKey: removed.id)

        if tabs.isEmpty {
            // The UI assumes each window always has at least one workspace.
            _ = addWorkspace()
            return removed
        }

        if selectedTabId == removed.id {
            let nextIndex = min(index, max(0, tabs.count - 1))
            selectedTabId = tabs[nextIndex].id
        }

        return removed
    }

    /// Attach an existing workspace to this window.
    func attachWorkspace(_ workspace: Workspace, at index: Int? = nil, select: Bool = true) {
        let insertIndex: Int = {
            guard let index else { return tabs.count }
            return max(0, min(index, tabs.count))
        }()
        tabs.insert(workspace, at: insertIndex)
        if select {
            selectedTabId = workspace.id
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
#if DEBUG
        UITestRecorder.incrementInt("closePanelInvocations")
#endif
        guard let selectedId = selectedTabId,
              let tab = tabs.first(where: { $0.id == selectedId }),
              let focusedPanelId = tab.focusedPanelId else { return }
        closePanelWithConfirmation(tab: tab, panelId: focusedPanelId)
    }

    func closeCurrentWorkspaceWithConfirmation() {
#if DEBUG
        UITestRecorder.incrementInt("closeTabInvocations")
#endif
        guard let selectedId = selectedTabId,
              let workspace = tabs.first(where: { $0.id == selectedId }) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func closeWorkspaceWithConfirmation(_ workspace: Workspace) {
        closeWorkspaceIfRunningProcess(workspace)
    }

    func closeWorkspaceWithConfirmation(tabId: UUID) {
        guard let workspace = tabs.first(where: { $0.id == tabId }) else { return }
        closeWorkspaceWithConfirmation(workspace)
    }

    func selectWorkspace(_ workspace: Workspace) {
        selectedTabId = workspace.id
    }

    // Keep selectTab as convenience alias
    func selectTab(_ tab: Workspace) { selectWorkspace(tab) }

    private func confirmClose(title: String, message: String, acceptCmdD: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Close")
        alert.addButton(withTitle: "Cancel")

        // macOS convention: Cmd+D = confirm destructive close (e.g. "Don't Save").
        // We only opt into this for the "close last workspace => close window" path to avoid
        // conflicting with app-level Cmd+D (split right) during normal usage.
        if acceptCmdD, let closeButton = alert.buttons.first {
            closeButton.keyEquivalent = "d"
            closeButton.keyEquivalentModifierMask = [.command]

            // Keep Return/Enter behavior by explicitly setting the default button cell.
            alert.window.defaultButtonCell = closeButton.cell as? NSButtonCell
        }

        return alert.runModal() == .alertFirstButtonReturn
    }

    private func closeWorkspaceIfRunningProcess(_ workspace: Workspace) {
        let willCloseWindow = tabs.count <= 1
        if workspaceNeedsConfirmClose(workspace),
           !confirmClose(
               title: "Close workspace?",
               message: "This will close the workspace and all of its panels.",
               acceptCmdD: willCloseWindow
           ) {
            return
        }
        if tabs.count <= 1 {
            // Last workspace in this window: close the window (Cmd+Shift+W behavior).
            AppDelegate.shared?.closeMainWindowContainingTabId(workspace.id)
        } else {
            closeWorkspace(workspace)
        }
    }

    private func closePanelWithConfirmation(tab: Workspace, panelId: UUID) {
        // Cmd+W closes the focused Bonsplit tab (a "tab" in the UI). When the workspace only has
        // a single tab left, closing it should close the workspace (and possibly the window),
        // rather than creating a replacement terminal.
        let isLastTabInWorkspace = tab.panels.count <= 1
        if isLastTabInWorkspace {
            let willCloseWindow = tabs.count <= 1
            let needsConfirm = workspaceNeedsConfirmClose(tab)
            if needsConfirm {
                let message = willCloseWindow
                    ? "This will close the last tab and close the window."
                    : "This will close the last tab and close its workspace."
                guard confirmClose(
                    title: "Close tab?",
                    message: message,
                    acceptCmdD: willCloseWindow
                ) else { return }
            }

            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tab.id)
            if willCloseWindow {
                AppDelegate.shared?.closeMainWindowContainingTabId(tab.id)
            } else {
                closeWorkspace(tab)
            }
            return
        }

        if let terminalPanel = tab.terminalPanel(for: panelId),
           terminalPanel.needsConfirmClose() {
            guard confirmClose(
                title: "Close tab?",
                message: "This will close the current tab.",
                acceptCmdD: false
            ) else { return }
        }

        // We already confirmed (if needed); bypass Bonsplit's delegate gating.
        tab.closePanel(panelId, force: true)
    }

    func closePanelWithConfirmation(tabId: UUID, surfaceId: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabId }) else { return }
        closePanelWithConfirmation(tab: tab, panelId: surfaceId)
    }

    private func workspaceNeedsConfirmClose(_ workspace: Workspace) -> Bool {
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_FORCE_CONFIRM_CLOSE_WORKSPACE"] == "1" {
            return true
        }
#endif
        return workspace.needsConfirmClose()
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

        // Closing the last panel of a workspace should close the workspace. If this is the last
        // workspace in the window, close the window. (This matches iTerm2-style behavior when the
        // shell exits via Ctrl+D.)
        if tab.panels.count <= 1 {
            AppDelegate.shared?.notificationStore?.clearNotifications(forTabId: tabId)

            if tabs.count <= 1 {
                AppDelegate.shared?.closeMainWindowContainingTabId(tabId)
            } else {
                closeWorkspace(tab)
            }
            return true
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

    /// Flash the currently focused panel so the user can visually confirm focus.
    func triggerFocusFlash() {
        guard let tab = selectedWorkspace,
              let panelId = tab.focusedPanelId else { return }
        tab.triggerFocusFlash(panelId: panelId)
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

#if DEBUG
    private func setupUITestFocusShortcutsIfNeeded() {
        guard !didSetupUITestFocusShortcuts else { return }
        didSetupUITestFocusShortcuts = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_FOCUS_SHORTCUTS"] == "1" else { return }

        // UI tests can't record arrow keys via the shortcut recorder. Use letter-based shortcuts
        // so tests can reliably drive pane navigation without mouse clicks.
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "h", command: true, shift: false, option: false, control: true),
            for: .focusLeft
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "l", command: true, shift: false, option: false, control: true),
            for: .focusRight
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "k", command: true, shift: false, option: false, control: true),
            for: .focusUp
        )
        KeyboardShortcutSettings.setShortcut(
            StoredShortcut(key: "j", command: true, shift: false, option: false, control: true),
            for: .focusDown
        )
    }

    private func setupSplitCloseRightUITestIfNeeded() {
        guard !didSetupSplitCloseRightUITest else { return }
        didSetupSplitCloseRightUITest = true

        let env = ProcessInfo.processInfo.environment
        guard env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SETUP"] == "1" else { return }
        guard let path = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATH"], !path.isEmpty else { return }
        let visualMode = env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_VISUAL"] == "1"
        let shotsDir = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_SHOTS_DIR"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let visualIterations = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_ITERATIONS"] ?? "20").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 20
        let burstFrames = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_BURST_FRAMES"] ?? "6").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 6
        let closeDelayMs = Int((env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_CLOSE_DELAY_MS"] ?? "70").trimmingCharacters(in: .whitespacesAndNewlines)) ?? 70
        let pattern = (env["CMUX_UI_TEST_SPLIT_CLOSE_RIGHT_PATTERN"] ?? "close_right")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard let tab = self.selectedWorkspace else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing selected workspace"], at: path)
                    return
                }

                if let terminal = tab.focusedTerminalPanel {
                    self.writeSplitCloseRightTestData([
                        "preTerminalAttached": terminal.hostedView.window != nil ? "1" : "0",
                        "preTerminalSurfaceNil": terminal.surface.surface == nil ? "1" : "0"
                    ], at: path)
                    if terminal.hostedView.window == nil || terminal.surface.surface == nil {
                        self.writeSplitCloseRightTestData(["setupError": "Initial terminal not ready (not attached or surface nil)"], at: path)
                        return
                    }
                } else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing initial focused terminal panel"], at: path)
                    return
                }

                guard let topLeftPanelId = tab.focusedPanelId else {
                    self.writeSplitCloseRightTestData(["setupError": "Missing initial focused panel"], at: path)
                    return
                }

                if visualMode {
                    // Visual repro mode: repeat the split/close sequence many times and write
                    // screenshots to `shotsDir`. This avoids relying on XCUITest to click hover-only
                    // close buttons, while still exercising the "close unfocused right tabs" path.
                    self.writeSplitCloseRightTestData([
                        "visualMode": "1",
                        "visualIterations": String(visualIterations),
                        "visualDone": "0"
                    ], at: path)

                    await self.runSplitCloseRightVisualRepro(
                        tab: tab,
                        topLeftPanelId: topLeftPanelId,
                        path: path,
                        shotsDir: shotsDir,
                        iterations: max(1, min(visualIterations, 60)),
                        burstFrames: max(0, min(burstFrames, 80)),
                        closeDelayMs: max(0, min(closeDelayMs, 500)),
                        pattern: pattern
                    )

                    self.writeSplitCloseRightTestData(["visualDone": "1"], at: path)
                    return
                }

                // Layout goal: 2x2 grid (2 top, 2 bottom), then close both right panels.
                // Order matters: split down first, then split right in each row (matches UI shortcut repro).
                guard let bottomLeft = tab.newTerminalSplit(from: topLeftPanelId, orientation: .vertical) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-left split"], at: path)
                    return
                }
                guard let bottomRight = tab.newTerminalSplit(from: bottomLeft.id, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create bottom-right split"], at: path)
                    return
                }
                tab.focusPanel(topLeftPanelId)
                guard let topRight = tab.newTerminalSplit(from: topLeftPanelId, orientation: .horizontal) else {
                    self.writeSplitCloseRightTestData(["setupError": "Failed to create top-right split"], at: path)
                    return
                }

                self.writeSplitCloseRightTestData([
                    "tabId": tab.id.uuidString,
                    "topLeftPanelId": topLeftPanelId.uuidString,
                    "bottomLeftPanelId": bottomLeft.id.uuidString,
                    "topRightPanelId": topRight.id.uuidString,
                    "bottomRightPanelId": bottomRight.id.uuidString,
                    "createdPaneCount": String(tab.bonsplitController.allPaneIds.count),
                    "createdPanelCount": String(tab.panels.count)
                ], at: path)

                DebugUIEventCounters.resetEmptyPanelAppearCount()

                // Close the two right panes via the same path as Cmd+W.
                tab.focusPanel(topRight.id)
                tab.closePanel(topRight.id, force: true)
                tab.focusPanel(bottomRight.id)
                tab.closePanel(bottomRight.id, force: true)

                // Record a single final state snapshot (no polling).
                let paneIds = tab.bonsplitController.allPaneIds
                let bonsplitTabCount = tab.bonsplitController.allTabIds.count
                let panelCount = tab.panels.count

                var missingSelectedTabCount = 0
                var missingPanelMappingCount = 0
                var selectedTerminalCount = 0
                var selectedTerminalAttachedCount = 0
                var selectedTerminalZeroSizeCount = 0
                var selectedTerminalSurfaceNilCount = 0

                for paneId in paneIds {
                    guard let selected = tab.bonsplitController.selectedTab(inPane: paneId) else {
                        missingSelectedTabCount += 1
                        continue
                    }
                    guard let panel = tab.panel(for: selected.id) else {
                        missingPanelMappingCount += 1
                        continue
                    }
                    if let terminal = panel as? TerminalPanel {
                        selectedTerminalCount += 1
                        if terminal.hostedView.window != nil {
                            selectedTerminalAttachedCount += 1
                        }
                        let size = terminal.hostedView.bounds.size
                        if size.width < 5 || size.height < 5 {
                            selectedTerminalZeroSizeCount += 1
                        }
                        if terminal.surface.surface == nil {
                            selectedTerminalSurfaceNilCount += 1
                        }
                    }
                }

                self.writeSplitCloseRightTestData([
                    "finalPaneCount": String(paneIds.count),
                    "finalBonsplitTabCount": String(bonsplitTabCount),
                    "finalPanelCount": String(panelCount),
                    "missingSelectedTabCount": String(missingSelectedTabCount),
                    "missingPanelMappingCount": String(missingPanelMappingCount),
                    "emptyPanelAppearCount": String(DebugUIEventCounters.emptyPanelAppearCount),
                    "selectedTerminalCount": String(selectedTerminalCount),
                    "selectedTerminalAttachedCount": String(selectedTerminalAttachedCount),
                    "selectedTerminalZeroSizeCount": String(selectedTerminalZeroSizeCount),
                    "selectedTerminalSurfaceNilCount": String(selectedTerminalSurfaceNilCount),
                ], at: path)
            }
        }
    }

	    @MainActor
	    private func runSplitCloseRightVisualRepro(
	        tab: Workspace,
	        topLeftPanelId: UUID,
	        path: String,
	        shotsDir: String,
	        iterations: Int,
	        burstFrames: Int,
	        closeDelayMs: Int,
	        pattern: String
	    ) async {
        _ = shotsDir // legacy: screenshots removed in favor of IOSurface sampling

        func sendText(_ panelId: UUID, _ text: String) {
            guard let tp = tab.terminalPanel(for: panelId) else { return }
            tp.surface.sendText(text)
        }

        // Sample a stable top strip of the IOSurface. We print output at the top of the viewport
        // so this region will contain non-background pixels when the surface is healthy.
        let sampleCrop = CGRect(x: 0.08, y: 0.08, width: 0.84, height: 0.22)

        for i in 1...iterations {
            // Reset to a single pane: close everything except the top-left panel.
            tab.focusPanel(topLeftPanelId)
            let toClose = Array(tab.panels.keys).filter { $0 != topLeftPanelId }
            for pid in toClose {
                tab.closePanel(pid, force: true)
            }

            // Create the 2x2 grid. The bug is order-dependent, so support multiple patterns.
            let topLeftId = topLeftPanelId
            let topRight: TerminalPanel
            let bottomLeft: TerminalPanel
            let bottomRight: TerminalPanel

            switch pattern {
            case "close_right_lrtd":
                // User repro: split left/right first, then split top/down in each column.
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let bl = tab.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from left (iteration \(i))"], at: path)
                    return
                }
                guard let br = tab.newTerminalSplit(from: tr.id, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from right (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            default:
                // Default: split top/down first, then split left/right in each row.
                guard let bl = tab.newTerminalSplit(from: topLeftId, orientation: .vertical) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split down from top-left (iteration \(i))"], at: path)
                    return
                }
                guard let br = tab.newTerminalSplit(from: bl.id, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from bottom-left (iteration \(i))"], at: path)
                    return
                }
                guard let tr = tab.newTerminalSplit(from: topLeftId, orientation: .horizontal) else {
                    writeSplitCloseRightTestData(["setupError": "Failed to split right from top-left (iteration \(i))"], at: path)
                    return
                }
                topRight = tr
                bottomLeft = bl
                bottomRight = br
            }

            // Fill left panes with visible content.
            sendText(topLeftId, "printf '\\033[2J\\033[H'; for i in {1..120}; do echo CMUX_SPLIT_TOPLEFT_\(i); done\r")
            sendText(bottomLeft.id, "printf '\\033[2J\\033[H'; for i in {1..120}; do echo CMUX_SPLIT_BOTTOMLEFT_\(i); done\r")

            let desiredFrames = max(16, min(burstFrames, 60))
            let closeFrame = min(6, max(1, desiredFrames / 4))
            let markerFrame = min(desiredFrames - 1, closeFrame + 8)

            let actionClose: () -> Void = {
                switch pattern {
                case "close_bottom":
                    tab.focusPanel(bottomRight.id)
                    tab.closePanel(bottomRight.id, force: true)
                    tab.focusPanel(bottomLeft.id)
                    tab.closePanel(bottomLeft.id, force: true)
                default:
                    tab.focusPanel(topRight.id)
                    tab.closePanel(topRight.id, force: true)
                    tab.focusPanel(bottomRight.id)
                    tab.closePanel(bottomRight.id, force: true)
                }
            }

            let actionMarker: () -> Void = {
                let token = UUID().uuidString.prefix(8)
                let marker = "CMUX_AFTER_CLOSE_\(pattern)_\(i)_\(token)"
                // Keep marker in the sampled region: clear + print at top.
                sendText(topLeftId, "printf '\\033[2J\\033[H'; echo \(marker)\r")
            }

            let targets: [(label: String, view: GhosttySurfaceScrollView)] = {
                switch pattern {
                case "close_bottom":
                    return [("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                            ("TR", topRight.surface.hostedView)]
                default:
                    return [("TL", tab.terminalPanel(for: topLeftId)!.surface.hostedView),
                            ("BL", bottomLeft.surface.hostedView)]
                }
            }()

            let result = await captureVsyncIOSurfaceTimeline(
                frameCount: desiredFrames,
                closeFrame: closeFrame,
                crop: sampleCrop,
                targets: targets,
                actions: [
                    (frame: closeFrame, action: actionClose),
                    (frame: markerFrame, action: actionMarker),
                ]
            )

            writeSplitCloseRightTestData([
                "pattern": pattern,
                "iteration": String(i),
                "closeDelayMs": String(closeDelayMs),
                "timelineFrameCount": String(desiredFrames),
                "timelineCloseFrame": String(closeFrame),
                "timelineMarkerFrame": String(markerFrame),
                "timelineFirstBlank": result.firstBlank.map { "\($0.label)@\($0.frame)" } ?? "",
                "timelineFirstSizeMismatch": result.firstSizeMismatch.map { "\($0.label)@\($0.frame):ios=\($0.ios):exp=\($0.expected)" } ?? "",
                "timelineTrace": result.trace.joined(separator: "|"),
                "visualLastIteration": String(i),
            ], at: path)

            if let firstBlank = result.firstBlank {
                writeSplitCloseRightTestData([
                    "blankFrameSeen": "1",
                    "blankObservedIteration": String(i),
                    "blankObservedAt": "\(firstBlank.label)@\(firstBlank.frame)"
                ], at: path)
                return
            }

            if let firstMismatch = result.firstSizeMismatch {
                writeSplitCloseRightTestData([
                    "sizeMismatchSeen": "1",
                    "sizeMismatchObservedIteration": String(i),
                    "sizeMismatchObservedAt": "\(firstMismatch.label)@\(firstMismatch.frame):ios=\(firstMismatch.ios):exp=\(firstMismatch.expected)"
                ], at: path)
                return
            }
        }
	    }

	    @MainActor
	    private func captureVsyncIOSurfaceTimeline(
	        frameCount: Int,
	        closeFrame: Int,
	        crop: CGRect,
	        targets: [(label: String, view: GhosttySurfaceScrollView)],
	        actions: [(frame: Int, action: () -> Void)] = []
	    ) async -> (firstBlank: (label: String, frame: Int)?, firstSizeMismatch: (label: String, frame: Int, ios: String, expected: String)?, trace: [String]) {
	        guard frameCount > 0 else { return (nil, nil, []) }

	        let st = VsyncIOSurfaceTimelineState(frameCount: frameCount, closeFrame: closeFrame)
	        st.scheduledActions = actions.sorted(by: { $0.frame < $1.frame })
	        st.nextActionIndex = 0
	        st.targets = targets.map { t in
	            VsyncIOSurfaceTimelineState.Target(label: t.label, sample: { @MainActor in
	                t.view.debugSampleIOSurface(normalizedCrop: crop)
	            })
	        }

	        let unmanaged = Unmanaged.passRetained(st)
	        let ctx = unmanaged.toOpaque()

	        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
	            st.continuation = cont
	            var link: CVDisplayLink?
	            CVDisplayLinkCreateWithActiveCGDisplays(&link)
	            guard let link else {
	                st.finish()
	                Unmanaged<VsyncIOSurfaceTimelineState>.fromOpaque(ctx).release()
	                return
	            }
	            st.link = link

	            CVDisplayLinkSetOutputCallback(link, cmuxVsyncIOSurfaceTimelineCallback, ctx)
	            CVDisplayLinkStart(link)
	        }

	        return (st.firstBlank, st.firstSizeMismatch, st.trace)
	    }

    private func writeSplitCloseRightTestData(_ updates: [String: String], at path: String) {
        var payload = loadSplitCloseRightTestData(at: path)
        for (key, value) in updates {
            payload[key] = value
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    private func loadSplitCloseRightTestData(at path: String) -> [String: String] {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: String] else {
            return [:]
        }
        return object
    }
#endif
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
