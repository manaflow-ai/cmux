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

@MainActor
final class MainWindowFocusController {
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
        intent = .rightSidebar(mode: mode)
        if mode != .feed {
            feedSelectedItemId = nil
        }
        publishFeedFocusSnapshot()
    }

    func noteTerminalInteraction(workspaceId: UUID, panelId: UUID) {
        pendingRightSidebarFirstItemFocusMode = nil
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
        if focusTerminal() {
            return true
        }
        pendingRightSidebarFirstItemFocusMode = nil
        intent = nil
        publishFeedFocusSnapshot()
        return false
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

    private func focusRegisteredRightSidebarEndpointIfNeeded(mode: RightSidebarMode) {
        guard case .rightSidebar(let targetMode) = intent,
              targetMode == mode,
              pendingRightSidebarFirstItemFocusMode == mode else {
            return
        }
        let result: Bool
        switch mode {
        case .files:
            result = fileExplorerHost?.focusOutline() == true
        case .sessions:
            sessionHost?.focusFirstItemFromCoordinator()
            result = sessionHost?.focusHostFromCoordinator() == true
        case .feed:
            feedHost?.focusFirstItemFromCoordinator()
            result = feedHost?.focusHostFromCoordinator() == true
        }
        if result {
            pendingRightSidebarFirstItemFocusMode = nil
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
