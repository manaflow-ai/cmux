import AppKit
import Foundation

struct FeedFocusSnapshot: Equatable {
    var selectedItemId: UUID?
    var isKeyboardActive: Bool

    init(selectedItemId: UUID? = nil, isKeyboardActive: Bool = false) {
        self.selectedItemId = selectedItemId
        self.isKeyboardActive = isKeyboardActive
    }
}

protocol FeedKeyboardFocusResponder: AnyObject {}

enum MainWindowKeyboardFocusIntent: Equatable {
    case terminal(workspaceId: UUID, panelId: UUID)
    case rightSidebar(mode: RightSidebarMode)
}

enum MainWindowFocusToggleDestination: Equatable {
    case terminal
    case rightSidebar
}

@MainActor
final class MainWindowFocusController {
    private enum EffectiveFocusOwner {
        case terminal
        case rightSidebar
        case unknown
    }

    let windowId: UUID

    private weak var window: NSWindow?
    private weak var tabManager: TabManager?
    private weak var fileExplorerState: FileExplorerState?
    private weak var rightSidebarHost: RightSidebarKeyboardFocusView?
    private weak var fileExplorerHost: FileExplorerContainerView?
    private weak var sessionHost: SessionIndexKeyboardFocusView?
    private weak var feedHost: FeedKeyboardFocusView?

    private(set) var intent: MainWindowKeyboardFocusIntent? {
        didSet {
            syncBonsplitTabShortcutHintEligibility()
        }
    }
    private var lastRightSidebarMode: RightSidebarMode?
    private var pendingRightSidebarFirstItemFocusMode: RightSidebarMode?
    private var pendingFileSearchFocus = false
    private var feedSelectedItemId: UUID?
    private var lastPublishedFeedFocusSnapshot = FeedFocusSnapshot()

    init(
        windowId: UUID,
        window: NSWindow?,
        tabManager: TabManager,
        fileExplorerState: FileExplorerState?
    ) {
        self.windowId = windowId
        self.window = window
        self.tabManager = tabManager
        self.fileExplorerState = fileExplorerState
        self.lastRightSidebarMode = fileExplorerState?.mode
    }

    func update(
        window: NSWindow?,
        tabManager: TabManager,
        fileExplorerState: FileExplorerState?
    ) {
        self.window = window
        self.tabManager = tabManager
        self.fileExplorerState = fileExplorerState
        if lastRightSidebarMode == nil {
            lastRightSidebarMode = fileExplorerState?.mode
        }
        syncBonsplitTabShortcutHintEligibility()
        publishFeedFocusSnapshot()
    }

    func registerRightSidebarHost(_ host: RightSidebarKeyboardFocusView) {
        rightSidebarHost = host
    }

    func registerFileExplorerHost(_ host: FileExplorerContainerView) {
        fileExplorerHost = host
        focusRegisteredRightSidebarEndpointIfNeeded(mode: .files)
    }

    func registerSessionHost(_ host: SessionIndexKeyboardFocusView) {
        sessionHost = host
        focusRegisteredRightSidebarEndpointIfNeeded(mode: .sessions)
    }

    func registerFeedHost(_ host: FeedKeyboardFocusView) {
        feedHost = host
        publishFeedFocusSnapshot(force: true)
        focusRegisteredRightSidebarEndpointIfNeeded(mode: .feed)
    }

    func noteRightSidebarInteraction(mode: RightSidebarMode) {
        lastRightSidebarMode = mode
        pendingRightSidebarFirstItemFocusMode = nil
        pendingFileSearchFocus = false
        intent = .rightSidebar(mode: mode)
        if mode != .feed {
            feedSelectedItemId = nil
        }
        publishFeedFocusSnapshot()
    }

    func noteTerminalInteraction(workspaceId: UUID, panelId: UUID) {
        pendingRightSidebarFirstItemFocusMode = nil
        pendingFileSearchFocus = false
        intent = .terminal(workspaceId: workspaceId, panelId: panelId)
        publishFeedFocusSnapshot()
    }

    func allowsTerminalFocus(workspaceId: UUID, panelId: UUID) -> Bool {
        switch intent {
        case .rightSidebar:
            return false
        case .terminal, nil:
            return true
        }
    }

    func allowsBonsplitTabShortcutHints(workspaceId: UUID) -> Bool {
        guard tabManager?.selectedTabId == workspaceId else { return false }
        switch intent {
        case .rightSidebar:
            return false
        case .terminal(let focusedWorkspaceId, _):
            return focusedWorkspaceId == workspaceId
        case nil:
            return true
        }
    }

    func ownsRightSidebarFocus(_ responder: NSResponder) -> Bool {
        if let host = rightSidebarHost, responder === host {
            return true
        }
        if responder is FeedKeyboardFocusResponder {
            return true
        }
        if fileExplorerHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        if sessionHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        if feedHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        return false
    }

    func shouldRestoreTerminalFocusWhenRightSidebarHides(currentResponder: NSResponder?) -> Bool {
        if case .rightSidebar = intent {
            return true
        }
        guard let currentResponder else { return false }
        return ownsRightSidebarFocus(currentResponder)
    }

    @discardableResult
    func restoreTerminalFocusAfterRightSidebarHiddenIfNeeded() -> Bool {
        guard shouldRestoreTerminalFocusWhenRightSidebarHides(currentResponder: window?.firstResponder) else {
            return false
        }
        return focusTerminalOrReleaseRightSidebarFocus(clearUnavailableIntent: true)
    }

    @discardableResult
    func restoreFocusedPanelFocusFromRightSidebarIfNeeded(currentResponder: NSResponder? = nil) -> Bool {
        let responder = currentResponder ?? window?.firstResponder
        let ownsResponder = responder.map(ownsRightSidebarFocus) ?? false
        let ownsIntent: Bool = {
            if case .rightSidebar = intent {
                return true
            }
            return false
        }()
        guard ownsResponder || ownsIntent else {
            return false
        }

        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return focusTerminalOrReleaseRightSidebarFocus(clearUnavailableIntent: true)
        }

        pendingRightSidebarFirstItemFocusMode = nil

        if panel is TerminalPanel {
            return focusTerminal()
        }

        intent = nil
        if let window,
           let responder,
           ownsRightSidebarFocus(responder) {
            _ = window.makeFirstResponder(nil)
        }
        publishFeedFocusSnapshot()
        workspace.focusPanel(panelId)
        return panel.restoreFocusIntent(panel.preferredFocusIntentForActivation())
    }

    @discardableResult
    func restoreTargetAfterWindowBecameKey() -> Bool {
        guard case .rightSidebar(let mode) = intent else {
            return false
        }
        if let responder = window?.firstResponder,
           ownsRightSidebarFocus(responder) {
            publishFeedFocusSnapshot()
            return true
        }
        if pendingFileSearchFocus, mode == .files {
            return focusFileSearch()
        }
        return focusRightSidebar(
            mode: mode,
            focusFirstItem: pendingRightSidebarFirstItemFocusMode == mode
        )
    }

    @discardableResult
    func selectFeedItem(_ id: UUID, focusFeed: Bool) -> Bool {
        feedSelectedItemId = id
        lastRightSidebarMode = .feed
        pendingRightSidebarFirstItemFocusMode = nil
        pendingFileSearchFocus = false
        intent = .rightSidebar(mode: .feed)
        publishFeedFocusSnapshot()

        guard focusFeed else {
            return true
        }
        return focusRightSidebar(mode: .feed, focusFirstItem: false)
    }

    func feedFocusSnapshot() -> FeedFocusSnapshot {
        guard feedSelectedItemId != nil else {
            return FeedFocusSnapshot()
        }
        return FeedFocusSnapshot(
            selectedItemId: feedSelectedItemId,
            isKeyboardActive: isFeedKeyboardIntentActive()
        )
    }

    func syncAfterResponderChange() {
        guard let responder = window?.firstResponder else {
            publishFeedFocusSnapshot()
            return
        }
        if let terminal = terminalFocusRequest(for: responder) {
            noteTerminalInteraction(workspaceId: terminal.workspaceId, panelId: terminal.panelId)
            return
        }
        if let mode = rightSidebarModeOwning(responder) {
            lastRightSidebarMode = mode
            pendingRightSidebarFirstItemFocusMode = nil
            pendingFileSearchFocus = false
            intent = .rightSidebar(mode: mode)
            if mode != .feed {
                feedSelectedItemId = nil
            }
            publishFeedFocusSnapshot()
            return
        }
        publishFeedFocusSnapshot()
    }

    @discardableResult
    func focusRightSidebar(mode requestedMode: RightSidebarMode? = nil, focusFirstItem: Bool = true) -> Bool {
        guard let state = fileExplorerState else { return false }
        let mode = requestedMode ?? lastRightSidebarMode ?? state.mode
        lastRightSidebarMode = mode
        pendingRightSidebarFirstItemFocusMode = focusFirstItem ? mode : nil
        pendingFileSearchFocus = false
        intent = .rightSidebar(mode: mode)
        if mode != .feed {
            feedSelectedItemId = nil
        }
        publishFeedFocusSnapshot()
        yieldCurrentTerminalSurfaceFocus(reason: "rightSidebarFocus")
        state.setVisible(true)
        if state.mode != mode {
            state.mode = mode
        }

        let modeResult: Bool
        switch mode {
        case .files:
            modeResult = fileExplorerHost?.focusOutline() == true
        case .sessions:
            if focusFirstItem {
                sessionHost?.focusFirstItemFromCoordinator()
            }
            modeResult = sessionHost?.focusHostFromCoordinator() == true
        case .feed:
            if focusFirstItem {
                feedHost?.focusFirstItemFromCoordinator()
            }
            modeResult = feedHost?.focusHostFromCoordinator() == true
        }
        if modeResult {
            pendingRightSidebarFirstItemFocusMode = nil
        }
        let fallbackResult = modeResult ? false : focusFallbackRightSidebarHost()
        let result = modeResult || fallbackResult || pendingRightSidebarFirstItemFocusMode == mode
        publishFeedFocusSnapshot()
        return result
    }

    @discardableResult
    func focusFileSearch() -> Bool {
        guard let state = fileExplorerState else { return false }
        lastRightSidebarMode = .files
        pendingRightSidebarFirstItemFocusMode = nil
        pendingFileSearchFocus = true
        feedSelectedItemId = nil
        intent = .rightSidebar(mode: .files)
        publishFeedFocusSnapshot()
        yieldCurrentTerminalSurfaceFocus(reason: "fileSearchFocus")
        state.setVisible(true)
        if state.mode != .files {
            state.mode = .files
        }

        let modeResult = fileExplorerHost?.focusSearchField() == true
        if modeResult {
            pendingFileSearchFocus = false
        }
        let fallbackResult = modeResult ? false : focusFallbackRightSidebarHost()
        let result = modeResult || fallbackResult || pendingFileSearchFocus
        publishFeedFocusSnapshot()
        return result
    }

    @discardableResult
    func toggleRightSidebarOrTerminalFocus(
        mode requestedMode: RightSidebarMode? = nil,
        focusFirstItem: Bool = true
    ) -> Bool {
        switch focusToggleDestination() {
        case .terminal:
            return focusTerminalOrReleaseRightSidebarFocus(clearUnavailableIntent: true)
        case .rightSidebar:
            return focusRightSidebar(mode: requestedMode, focusFirstItem: focusFirstItem)
        }
    }

    func focusToggleDestination(currentResponder: NSResponder? = nil) -> MainWindowFocusToggleDestination {
        switch effectiveFocusOwner(currentResponder: currentResponder) {
        case .rightSidebar:
            return .terminal
        case .terminal, .unknown:
            return .rightSidebar
        }
    }

    @discardableResult
    func focusTerminal() -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return false
        }
        let terminalPanel: TerminalPanel? = {
            if let focusedPanelId = workspace.focusedPanelId,
               let terminalPanel = workspace.terminalPanel(for: focusedPanelId) {
                return terminalPanel
            }
            return workspace.focusedTerminalPanel
        }()
        guard let terminalPanel else { return false }
        pendingRightSidebarFirstItemFocusMode = nil
        pendingFileSearchFocus = false
        intent = .terminal(workspaceId: workspace.id, panelId: terminalPanel.id)
        publishFeedFocusSnapshot()
        workspace.focusPanel(terminalPanel.id)
        terminalPanel.hostedView.ensureFocus(
            for: workspace.id,
            surfaceId: terminalPanel.id,
            respectForeignFirstResponder: false
        )
        return terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    private func focusTerminalOrReleaseRightSidebarFocus(clearUnavailableIntent: Bool) -> Bool {
        let focused = focusTerminal()
        if focused {
            return true
        }

        if let window,
           let responder = window.firstResponder,
           ownsRightSidebarFocus(responder) {
            window.makeFirstResponder(nil)
        }

        pendingRightSidebarFirstItemFocusMode = nil
        pendingFileSearchFocus = false
        if clearUnavailableIntent, case .rightSidebar = intent {
            intent = nil
        }
        publishFeedFocusSnapshot()
        return false
    }

    private func effectiveFocusOwner(currentResponder: NSResponder? = nil) -> EffectiveFocusOwner {
        if let responder = currentResponder ?? window?.firstResponder {
            if terminalFocusRequest(for: responder) != nil {
                return .terminal
            }
            if rightSidebarModeOwning(responder) != nil {
                return .rightSidebar
            }
        }

        switch intent {
        case .terminal:
            return .terminal
        case .rightSidebar:
            return .rightSidebar
        case nil:
            return .unknown
        }
    }

    private func focusRegisteredRightSidebarEndpointIfNeeded(mode: RightSidebarMode) {
        let shouldFocusEndpoint = pendingRightSidebarFirstItemFocusMode == mode ||
            (pendingFileSearchFocus && mode == .files)
        guard case .rightSidebar(let targetMode) = intent,
              targetMode == mode,
              shouldFocusEndpoint else {
            return
        }
        let result: Bool
        switch mode {
        case .files:
            if pendingFileSearchFocus {
                result = fileExplorerHost?.focusSearchField() == true
            } else {
                result = fileExplorerHost?.focusOutline() == true
            }
        case .sessions:
            sessionHost?.focusFirstItemFromCoordinator()
            result = sessionHost?.focusHostFromCoordinator() == true
        case .feed:
            feedHost?.focusFirstItemFromCoordinator()
            result = feedHost?.focusHostFromCoordinator() == true
        }
        if result {
            pendingRightSidebarFirstItemFocusMode = nil
            pendingFileSearchFocus = false
        }
        publishFeedFocusSnapshot()
    }

    private func focusFallbackRightSidebarHost() -> Bool {
        guard let window,
              let host = rightSidebarHost else {
            return false
        }
        return window.makeFirstResponder(host)
    }

    private func yieldCurrentTerminalSurfaceFocus(reason: String) {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return
        }
        let terminalPanel: TerminalPanel? = {
            if let focusedPanelId = workspace.focusedPanelId,
               let terminalPanel = workspace.terminalPanel(for: focusedPanelId) {
                return terminalPanel
            }
            return workspace.focusedTerminalPanel
        }()
        terminalPanel?.hostedView.yieldTerminalSurfaceFocusForForeignResponder(reason: reason)
    }

    private func isFeedKeyboardIntentActive() -> Bool {
        if case .rightSidebar(.feed) = intent {
            return true
        }
        if let responder = window?.firstResponder,
           rightSidebarModeOwning(responder) == .feed {
            return true
        }
        return false
    }

    private func publishFeedFocusSnapshot(force: Bool = false) {
        let snapshot = feedFocusSnapshot()
        guard force || snapshot != lastPublishedFeedFocusSnapshot else { return }
        lastPublishedFeedFocusSnapshot = snapshot
        feedHost?.applyFocusSnapshotFromController(snapshot)
    }

    func syncBonsplitTabShortcutHintEligibility() {
        guard let tabManager else { return }
        for workspace in tabManager.tabs {
            let enabled = allowsBonsplitTabShortcutHints(workspaceId: workspace.id)
            if workspace.bonsplitController.tabShortcutHintsEnabled != enabled {
                workspace.bonsplitController.tabShortcutHintsEnabled = enabled
            }
        }
    }

    private func rightSidebarModeOwning(_ responder: NSResponder) -> RightSidebarMode? {
        if let host = rightSidebarHost, responder === host {
            return fileExplorerState?.mode ?? lastRightSidebarMode
        }
        if fileExplorerHost?.ownsKeyboardFocus(responder) == true {
            return .files
        }
        if sessionHost?.ownsKeyboardFocus(responder) == true {
            return .sessions
        }
        if feedHost?.ownsKeyboardFocus(responder) == true || responder is FeedKeyboardFocusResponder {
            return .feed
        }
        return nil
    }

    private struct TerminalFocusRequest {
        let workspaceId: UUID
        let panelId: UUID
    }

    private func terminalFocusRequest(for responder: NSResponder?) -> TerminalFocusRequest? {
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id else {
            return nil
        }
        return TerminalFocusRequest(workspaceId: workspaceId, panelId: panelId)
    }
}
