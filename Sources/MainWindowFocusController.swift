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
    case mainPanel(workspaceId: UUID, panelId: UUID)
    case rightSidebar(mode: RightSidebarMode)
}

enum MainWindowFocusToggleDestination: Equatable {
    case terminal
    case rightSidebar
}

enum MainWindowFindShortcutTarget: Equatable {
    case mainPanelFind
    case rightSidebarFileSearch
    case none
}

@MainActor
final class MainWindowFocusController {
    private enum EffectiveFocusOwner {
        case mainPanel
        case rightSidebar
        case unknown
    }

    let windowId: UUID

    private weak var window: NSWindow?
    private weak var tabManager: TabManager?
    private weak var fileExplorerState: FileExplorerState?
    private weak var rightSidebarHost: RightSidebarKeyboardFocusView?
    private weak var fileExplorerHost: FileExplorerContainerView?
    private weak var fileSearchHost: FileExplorerContainerView?
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

#if DEBUG
    private func debugFocusNow() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private func debugFocusElapsedMs(_ startedAt: TimeInterval) -> String {
        String(format: "%.2f", max(0, (ProcessInfo.processInfo.systemUptime - startedAt) * 1000.0))
    }

    private func debugResponderLabel(_ responder: NSResponder?) -> String {
        guard let responder else { return "nil" }
        return String(describing: type(of: responder))
    }

    private func debugIntentLabel(_ intent: MainWindowKeyboardFocusIntent?) -> String {
        switch intent {
        case .mainPanel(let workspaceId, let panelId):
            return "mainPanel:\(workspaceId.uuidString.prefix(5)):\(panelId.uuidString.prefix(5))"
        case .rightSidebar(let mode):
            return "rightSidebar:\(mode.rawValue)"
        case nil:
            return "nil"
        }
    }

    private func debugFocusState() -> String {
        let windowNumber = window?.windowNumber ?? -1
        let key = window?.isKeyWindow == true ? 1 : 0
        let visible = window?.isVisible == true ? 1 : 0
        let firstResponder = debugResponderLabel(window?.firstResponder)
        let selected = tabManager?.selectedTabId.map { String($0.uuidString.prefix(8)) } ?? "nil"
        let workspaceCount = tabManager?.tabs.count ?? 0
        let mode = fileExplorerState?.mode.rawValue ?? "nil"
        let sidebarVisible = fileExplorerState?.isVisible == true ? 1 : 0
        return "windowId=\(windowId.uuidString.prefix(8)) win=\(windowNumber) key=\(key) visible=\(visible) selected=\(selected) workspaces=\(workspaceCount) intent=\(debugIntentLabel(intent)) sidebarVisible=\(sidebarVisible) mode=\(mode) pendingFirst=\(pendingRightSidebarFirstItemFocusMode?.rawValue ?? "nil") pendingFind=\(pendingFileSearchFocus ? 1 : 0) fr=\(firstResponder)"
    }
#endif

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
        let mode = host.representedRightSidebarMode()
        switch mode {
        case .files:
            fileExplorerHost = host
        case .find:
            fileSearchHost = host
        case .sessions, .feed:
            break
        }
        focusRegisteredRightSidebarEndpointIfNeeded(mode: mode)
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
        noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)
    }

    func noteMainPanelInteraction(workspaceId: UUID, panelId: UUID) {
        pendingRightSidebarFirstItemFocusMode = nil
        pendingFileSearchFocus = false
        intent = .mainPanel(workspaceId: workspaceId, panelId: panelId)
        publishFeedFocusSnapshot()
    }

    func allowsTerminalFocus(workspaceId: UUID, panelId: UUID) -> Bool {
        switch intent {
        case .rightSidebar:
            return false
        case .mainPanel, nil:
            return true
        }
    }

    func allowsBonsplitTabShortcutHints(workspaceId: UUID) -> Bool {
        guard tabManager?.selectedTabId == workspaceId else { return false }
        switch intent {
        case .rightSidebar:
            return false
        case .mainPanel(let focusedWorkspaceId, _):
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
        if fileExplorerHost?.ownsKeyboardFocus(responder) == true ||
            fileSearchHost?.ownsKeyboardFocus(responder) == true {
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
        pendingFileSearchFocus = false

        if panel is TerminalPanel {
            return focusTerminal()
        }

        intent = .mainPanel(workspaceId: workspace.id, panelId: panelId)
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
#if DEBUG
        let focusStartedAt = debugFocusNow()
        cmuxDebugLog("activation.focus.restoreAfterKey.begin \(debugFocusState())")
#endif
        guard case .rightSidebar(let mode) = intent else {
#if DEBUG
            cmuxDebugLog(
                "activation.focus.restoreAfterKey.end result=0 reason=notRightSidebar elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return false
        }
        if let responder = window?.firstResponder,
           ownsRightSidebarFocus(responder) {
            publishFeedFocusSnapshot()
#if DEBUG
            cmuxDebugLog(
                "activation.focus.restoreAfterKey.end result=1 reason=alreadySidebarResponder elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return true
        }
        if pendingFileSearchFocus, mode == .find {
            let result = focusFileSearch()
#if DEBUG
            cmuxDebugLog(
                "activation.focus.restoreAfterKey.end result=\(result ? 1 : 0) route=fileSearch elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return result
        }
        let result = focusRightSidebar(
            mode: mode,
            focusFirstItem: pendingRightSidebarFirstItemFocusMode == mode
        )
#if DEBUG
        cmuxDebugLog(
            "activation.focus.restoreAfterKey.end result=\(result ? 1 : 0) route=rightSidebar elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
        )
#endif
        return result
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
#if DEBUG
        let focusStartedAt = debugFocusNow()
        let beforeIntent = debugIntentLabel(intent)
        let beforeResponder = debugResponderLabel(window?.firstResponder)
#endif
        guard let responder = window?.firstResponder else {
            publishFeedFocusSnapshot()
#if DEBUG
            cmuxDebugLog(
                "activation.focus.syncAfterResponder.end route=noResponder beforeIntent=\(beforeIntent) beforeFr=\(beforeResponder) elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return
        }
        if let terminal = terminalFocusRequest(for: responder) {
            noteTerminalInteraction(workspaceId: terminal.workspaceId, panelId: terminal.panelId)
#if DEBUG
            cmuxDebugLog(
                "activation.focus.syncAfterResponder.end route=terminal beforeIntent=\(beforeIntent) beforeFr=\(beforeResponder) elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return
        }
        if let mode = rightSidebarModeOwning(responder) {
            lastRightSidebarMode = mode
            let isFallbackSidebarHost = rightSidebarHost.map { responder === $0 } ?? false
            if !isFallbackSidebarHost || pendingRightSidebarFirstItemFocusMode != mode {
                pendingRightSidebarFirstItemFocusMode = nil
            }
            if !isFallbackSidebarHost || !pendingFileSearchFocus || mode != .find {
                pendingFileSearchFocus = false
            }
            intent = .rightSidebar(mode: mode)
            if mode != .feed {
                feedSelectedItemId = nil
            }
            publishFeedFocusSnapshot()
#if DEBUG
            cmuxDebugLog(
                "activation.focus.syncAfterResponder.end route=rightSidebar mode=\(mode.rawValue) beforeIntent=\(beforeIntent) beforeFr=\(beforeResponder) elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return
        }
        if let mainPanel = selectedFocusedBrowserPanelRequest() {
            noteMainPanelInteraction(workspaceId: mainPanel.workspaceId, panelId: mainPanel.panelId)
#if DEBUG
            cmuxDebugLog(
                "activation.focus.syncAfterResponder.end route=browser beforeIntent=\(beforeIntent) beforeFr=\(beforeResponder) elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return
        }
        publishFeedFocusSnapshot()
#if DEBUG
        cmuxDebugLog(
            "activation.focus.syncAfterResponder.end route=unknown beforeIntent=\(beforeIntent) beforeFr=\(beforeResponder) elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
        )
#endif
    }

    @discardableResult
    func focusRightSidebar(mode requestedMode: RightSidebarMode? = nil, focusFirstItem: Bool = true) -> Bool {
#if DEBUG
        let focusStartedAt = debugFocusNow()
        cmuxDebugLog(
            "activation.focus.rightSidebar.begin requested=\(requestedMode?.rawValue ?? "nil") focusFirst=\(focusFirstItem ? 1 : 0) \(debugFocusState())"
        )
#endif
        guard let state = fileExplorerState else {
#if DEBUG
            cmuxDebugLog(
                "activation.focus.rightSidebar.end result=0 reason=noState elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return false
        }
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
        case .find:
            modeResult = fileSearchHost?.focusSearchField() == true
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
#if DEBUG
        cmuxDebugLog(
            "activation.focus.rightSidebar.end result=\(result ? 1 : 0) modeResult=\(modeResult ? 1 : 0) fallback=\(fallbackResult ? 1 : 0) elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
        )
#endif
        return result
    }

    @discardableResult
    func focusFileSearch() -> Bool {
#if DEBUG
        let focusStartedAt = debugFocusNow()
        cmuxDebugLog("activation.focus.fileSearch.begin \(debugFocusState())")
#endif
        guard let state = fileExplorerState else {
#if DEBUG
            cmuxDebugLog(
                "activation.focus.fileSearch.end result=0 reason=noState elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return false
        }
        lastRightSidebarMode = .find
        pendingRightSidebarFirstItemFocusMode = nil
        pendingFileSearchFocus = true
        feedSelectedItemId = nil
        intent = .rightSidebar(mode: .find)
        publishFeedFocusSnapshot()
        yieldCurrentTerminalSurfaceFocus(reason: "fileSearchFocus")
        state.setVisible(true)
        if state.mode != .find {
            state.mode = .find
        }

        let modeResult = fileSearchHost?.focusSearchField() == true
        if modeResult {
            pendingFileSearchFocus = false
        }
        let fallbackResult = modeResult ? false : focusFallbackRightSidebarHost()
        let result = modeResult || fallbackResult || pendingFileSearchFocus
        publishFeedFocusSnapshot()
#if DEBUG
        cmuxDebugLog(
            "activation.focus.fileSearch.end result=\(result ? 1 : 0) modeResult=\(modeResult ? 1 : 0) fallback=\(fallbackResult ? 1 : 0) elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
        )
#endif
        return result
    }

    @discardableResult
    func toggleRightSidebarOrTerminalFocus(
        mode requestedMode: RightSidebarMode? = nil,
        focusFirstItem: Bool = true
    ) -> Bool {
        switch focusToggleDestination() {
        case .terminal:
            return restoreFocusedPanelFocusFromRightSidebarIfNeeded(currentResponder: window?.firstResponder)
        case .rightSidebar:
            return focusRightSidebar(mode: requestedMode, focusFirstItem: focusFirstItem)
        }
    }

    func focusToggleDestination(currentResponder: NSResponder? = nil) -> MainWindowFocusToggleDestination {
        switch effectiveFocusOwner(currentResponder: currentResponder) {
        case .rightSidebar:
            return .terminal
        case .mainPanel, .unknown:
            return .rightSidebar
        }
    }

    func findShortcutTarget(currentResponder: NSResponder? = nil) -> MainWindowFindShortcutTarget {
        let responder = currentResponder ?? window?.firstResponder
        if let responder {
            if let mode = rightSidebarModeOwning(responder) {
                return findShortcutTarget(forRightSidebarMode: mode)
            }
            if terminalFocusRequest(for: responder) != nil {
                return .mainPanelFind
            }
            if selectedFocusedPanelIsBrowser() {
                return .mainPanelFind
            }
            if case .rightSidebar(let mode) = intent {
                return findShortcutTarget(forRightSidebarMode: mode)
            }
            return .mainPanelFind
        }

        if case .rightSidebar(let mode) = intent {
            return findShortcutTarget(forRightSidebarMode: mode)
        }
        return .mainPanelFind
    }

    @discardableResult
    func focusTerminal() -> Bool {
#if DEBUG
        let focusStartedAt = debugFocusNow()
        cmuxDebugLog("activation.focus.terminal.begin \(debugFocusState())")
#endif
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace else {
#if DEBUG
            cmuxDebugLog(
                "activation.focus.terminal.end result=0 reason=noWorkspace elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return false
        }
        let terminalPanel: TerminalPanel? = {
            if let focusedPanelId = workspace.focusedPanelId,
               let terminalPanel = workspace.terminalPanel(for: focusedPanelId) {
                return terminalPanel
            }
            return workspace.focusedTerminalPanel
        }()
        guard let terminalPanel else {
#if DEBUG
            cmuxDebugLog(
                "activation.focus.terminal.end result=0 reason=noTerminalPanel elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
            )
#endif
            return false
        }
        pendingRightSidebarFirstItemFocusMode = nil
        pendingFileSearchFocus = false
        intent = .mainPanel(workspaceId: workspace.id, panelId: terminalPanel.id)
        publishFeedFocusSnapshot()
        workspace.focusPanel(terminalPanel.id)
        terminalPanel.hostedView.ensureFocus(
            for: workspace.id,
            surfaceId: terminalPanel.id,
            respectForeignFirstResponder: false
        )
        let result = terminalPanel.hostedView.isSurfaceViewFirstResponder()
#if DEBUG
        cmuxDebugLog(
            "activation.focus.terminal.end result=\(result ? 1 : 0) surface=\(terminalPanel.id.uuidString.prefix(8)) elapsedMs=\(debugFocusElapsedMs(focusStartedAt)) \(debugFocusState())"
        )
#endif
        return result
    }

    private func findShortcutTarget(forRightSidebarMode mode: RightSidebarMode) -> MainWindowFindShortcutTarget {
        mode == .files ? .rightSidebarFileSearch : .none
    }

    private func selectedFocusedPanelIsBrowser() -> Bool {
        selectedFocusedBrowserPanelRequest() != nil
    }

    private struct FocusedPanelRequest {
        let workspaceId: UUID
        let panelId: UUID
    }

    private func selectedFocusedBrowserPanelRequest() -> FocusedPanelRequest? {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        guard panel is BrowserPanel else {
            return nil
        }
        return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
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
                return .mainPanel
            }
            if rightSidebarModeOwning(responder) != nil {
                return .rightSidebar
            }
        }

        switch intent {
        case .mainPanel:
            return .mainPanel
        case .rightSidebar:
            return .rightSidebar
        case nil:
            return .unknown
        }
    }

    private func focusRegisteredRightSidebarEndpointIfNeeded(mode: RightSidebarMode) {
        let shouldFocusEndpoint = pendingRightSidebarFirstItemFocusMode == mode ||
            (pendingFileSearchFocus && mode == .find)
        guard case .rightSidebar(let targetMode) = intent,
              targetMode == mode,
              shouldFocusEndpoint else {
            return
        }
        let result: Bool
        switch mode {
        case .files:
            result = fileExplorerHost?.focusOutline() == true
        case .find:
            result = fileSearchHost?.focusSearchField() == true
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
        if fileSearchHost?.ownsKeyboardFocus(responder) == true {
            return .find
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
