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

struct MainWindowFocusRestoreTarget: Equatable {
    fileprivate struct MainPanelTarget: Equatable {
        let workspaceId: UUID
        let panelId: UUID
        let intent: PanelFocusIntent
    }

    fileprivate enum RightSidebarTarget: Equatable {
        case host
        case outline
        case searchField
        case firstItem
        case dockSurface(UUID)
    }

    fileprivate struct RightSidebarDestination: Equatable {
        let mode: RightSidebarMode
        let target: RightSidebarTarget
    }

    fileprivate enum Destination: Equatable {
        case mainPanel(MainPanelTarget)
        case rightSidebar(RightSidebarDestination)
    }

    fileprivate let destination: Destination
}

@MainActor
final class MainWindowFocusController {
    private enum EffectiveFocusOwner {
        case mainPanel
        case rightSidebar
        case unknown
    }

    private enum RightSidebarFocusTarget: Equatable {
        case host
        case outline
        case searchField
        case firstItem
        case dockSurface(UUID)
    }

    private struct RightSidebarFocusRequest: Equatable {
        let id: UInt64
        let mode: RightSidebarMode
        let target: RightSidebarFocusTarget
    }

    private enum RightSidebarFocusState: Equatable {
        case inactive
        case requested(RightSidebarFocusRequest)
        case focused(mode: RightSidebarMode, target: RightSidebarFocusTarget)

        var mode: RightSidebarMode? {
            switch self {
            case .inactive:
                return nil
            case .requested(let request):
                return request.mode
            case .focused(let mode, _):
                return mode
            }
        }

        var request: RightSidebarFocusRequest? {
            if case .requested(let request) = self {
                return request
            }
            return nil
        }
    }

    let windowId: UUID

    private weak var window: NSWindow?
    private weak var tabManager: TabManager?
    private weak var fileExplorerState: FileExplorerState?
    private weak var rightSidebarHost: RightSidebarKeyboardFocusView?
    private weak var fileExplorerHost: FileExplorerContainerView?
    private weak var fileSearchHost: FileExplorerContainerView?
    private weak var feedHost: FeedKeyboardFocusView?
    private weak var dockHost: DockKeyboardFocusView?

    private(set) var intent: MainWindowKeyboardFocusIntent? {
        didSet {
            syncBonsplitTabShortcutHintEligibility()
        }
    }
    private var rememberedRightSidebarMode: RightSidebarMode?
    private var nextRightSidebarFocusRequestId: UInt64 = 0
    private var rightSidebarFocusState: RightSidebarFocusState = .inactive
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
        self.rememberedRightSidebarMode = fileExplorerState?.mode
    }

    func update(
        window: NSWindow?,
        tabManager: TabManager,
        fileExplorerState: FileExplorerState?
    ) {
        self.window = window
        self.tabManager = tabManager
        self.fileExplorerState = fileExplorerState
        if rememberedRightSidebarMode == nil {
            rememberedRightSidebarMode = fileExplorerState?.mode
        }
        syncBonsplitTabShortcutHintEligibility()
        publishFeedFocusSnapshot()
    }

    func registerRightSidebarHost(_ host: RightSidebarKeyboardFocusView) {
        rightSidebarHost = host
        if let mode = rightSidebarFocusState.request?.mode {
            focusRegisteredRightSidebarEndpointIfNeeded(mode: mode)
        }
    }

    func registerFileExplorerHost(_ host: FileExplorerContainerView) {
        let mode = host.representedRightSidebarMode()
        switch mode {
        case .files:
            fileExplorerHost = host
        case .find:
            fileSearchHost = host
        case .sessions, .feed, .dock:
            break
        }
        focusRegisteredRightSidebarEndpointIfNeeded(mode: mode)
    }

    func registerFeedHost(_ host: FeedKeyboardFocusView) {
        feedHost = host
        publishFeedFocusSnapshot(force: true)
        focusRegisteredRightSidebarEndpointIfNeeded(mode: .feed)
    }

    func registerDockHost(_ host: DockKeyboardFocusView) {
        dockHost = host
        focusRegisteredRightSidebarEndpointIfNeeded(mode: .dock)
    }

    func noteRightSidebarInteraction(mode: RightSidebarMode) {
        rememberedRightSidebarMode = mode
        rightSidebarFocusState = .focused(mode: mode, target: .host)
        intent = .rightSidebar(mode: mode)
        if mode != .feed {
            feedSelectedItemId = nil
        }
        publishFeedFocusSnapshot()
    }

    func noteDockTerminalInteraction(surfaceId: UUID) {
        rememberedRightSidebarMode = .dock
        rightSidebarFocusState = .focused(mode: .dock, target: .dockSurface(surfaceId))
        intent = .rightSidebar(mode: .dock)
        feedSelectedItemId = nil
        publishFeedFocusSnapshot()
    }

    func noteTerminalInteraction(workspaceId: UUID, panelId: UUID) {
        noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)
    }

    func noteMainPanelInteraction(workspaceId: UUID, panelId: UUID) {
        rightSidebarFocusState = .inactive
        intent = .mainPanel(workspaceId: workspaceId, panelId: panelId)
        publishFeedFocusSnapshot()
    }

    func captureFocusRestoreTarget() -> MainWindowFocusRestoreTarget? {
        if let responder = window?.firstResponder,
           let target = captureFocusRestoreTarget(owning: responder) {
            return target
        }

        if let target = captureFocusRestoreTargetFromIntent() {
            return target
        }

        return captureSelectedMainPanelFocusRestoreTarget()
    }

    func captureFocusRestoreTarget(owning responder: NSResponder) -> MainWindowFocusRestoreTarget? {
        if let dockSurfaceId = dockHost?.focusedSurfaceIdFromCoordinator(for: responder) {
            return rightSidebarFocusRestoreTarget(mode: .dock, target: .dockSurface(dockSurfaceId))
        }

        if let mode = rightSidebarModeOwning(responder) {
            return rightSidebarFocusRestoreTarget(
                mode: mode,
                target: rightSidebarRestoreTarget(mode: mode, responder: responder)
            )
        }

        return captureMainPanelFocusRestoreTarget(owning: responder)
    }

    func captureFocusRestoreTarget(
        workspaceId: UUID,
        panelId: UUID,
        fallbackIntent: PanelFocusIntent
    ) -> MainWindowFocusRestoreTarget? {
        guard let panel = tabManager?.tabs
            .first(where: { $0.id == workspaceId })?
            .panels[panelId] else {
            return nil
        }
        let capturedIntent = panel.captureFocusIntent(in: window)
        return mainPanelFocusRestoreTarget(
            workspaceId: workspaceId,
            panelId: panelId,
            intent: capturedIntent == .panel ? fallbackIntent : capturedIntent
        )
    }

    @discardableResult
    func restoreFocus(_ target: MainWindowFocusRestoreTarget) -> Bool {
        switch target.destination {
        case .mainPanel(let panel):
            return restoreMainPanelFocus(
                workspaceId: panel.workspaceId,
                panelId: panel.panelId,
                intent: panel.intent
            )
        case .rightSidebar(let sidebar):
            return restoreRightSidebarFocus(mode: sidebar.mode, target: sidebar.target)
        }
    }

    func allowsTerminalFocus(workspaceId: UUID, panelId: UUID) -> Bool {
        if TerminalSurfaceRegistry.shared.isRightSidebarDockSurface(id: panelId) {
            return true
        }
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
        if feedHost?.ownsKeyboardFocus(responder) == true {
            return true
        }
        if dockHost?.ownsKeyboardFocus(responder) == true {
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

        rightSidebarFocusState = .inactive

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
        guard case .rightSidebar(let mode) = intent else {
            return false
        }
        if let responder = window?.firstResponder,
           rightSidebarModeOwning(responder) == mode {
            publishFeedFocusSnapshot()
            return true
        }
        if let stateTarget = rightSidebarRestoreTargetFromState(mode: mode) {
            return restoreRightSidebarFocus(mode: mode, target: stateTarget)
        }
        if mode == .find {
            return focusFileSearch()
        }
        return focusRightSidebar(
            mode: mode,
            focusFirstItem: false
        )
    }

    @discardableResult
    func selectFeedItem(_ id: UUID, focusFeed: Bool) -> Bool {
        feedSelectedItemId = id
        rememberedRightSidebarMode = .feed
        rightSidebarFocusState = .focused(mode: .feed, target: .host)
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
        syncAfterResponderChange(responder: window?.firstResponder)
    }

#if DEBUG
    var debugPendingRightSidebarFocusMode: RightSidebarMode? {
        rightSidebarFocusState.request?.mode
    }

    func debugSyncAfterResponderChange(responder: NSResponder?) {
        syncAfterResponderChange(responder: responder)
    }
#endif

    private func syncAfterResponderChange(responder: NSResponder?) {
        guard let responder else {
            publishFeedFocusSnapshot()
            return
        }
        if let terminal = terminalFocusRequest(for: responder) {
            if rightSidebarFocusState.request != nil {
                publishFeedFocusSnapshot()
                return
            }
            noteTerminalInteraction(workspaceId: terminal.workspaceId, panelId: terminal.panelId)
            return
        }
        if let mode = rightSidebarModeOwning(responder) {
            let isFallbackSidebarHost = rightSidebarHost.map { responder === $0 } ?? false
            if !canAcceptRightSidebarResponderFocus(
                mode: mode,
                isFallbackSidebarHost: isFallbackSidebarHost
            ) {
                publishFeedFocusSnapshot()
                return
            }
            rememberedRightSidebarMode = mode
            completeRightSidebarFocusFromResponder(mode: mode, responder: responder, isFallbackSidebarHost: isFallbackSidebarHost)
            intent = .rightSidebar(mode: mode)
            if mode != .feed {
                feedSelectedItemId = nil
            }
            publishFeedFocusSnapshot()
            return
        }
        if rightSidebarFocusState.request != nil {
            publishFeedFocusSnapshot()
            return
        }
        if let mainPanel = selectedFocusedPanelRequest(owning: responder) {
            noteMainPanelInteraction(workspaceId: mainPanel.workspaceId, panelId: mainPanel.panelId)
            return
        }
        publishFeedFocusSnapshot()
    }

    private func canAcceptRightSidebarResponderFocus(
        mode responderMode: RightSidebarMode,
        isFallbackSidebarHost: Bool
    ) -> Bool {
        guard let request = rightSidebarFocusState.request else {
            return true
        }
        if responderMode != request.mode {
            return false
        }
        if isFallbackSidebarHost, request.target != .host {
            return false
        }
        return true
    }

    private func completeRightSidebarFocusFromResponder(
        mode responderMode: RightSidebarMode,
        responder: NSResponder,
        isFallbackSidebarHost: Bool
    ) {
        guard let request = rightSidebarFocusState.request else {
            if case .focused(let focusedMode, let target) = rightSidebarFocusState,
               focusedMode == responderMode,
               responderMode == .dock,
               case .dockSurface = target,
               dockHost.map({ responder === $0 }) == true {
                return
            }
            rightSidebarFocusState = .focused(mode: responderMode, target: .host)
            return
        }
        guard request.mode == responderMode else { return }
        if isFallbackSidebarHost, request.target != .host {
            return
        }
        rightSidebarFocusState = .focused(mode: request.mode, target: request.target)
    }

    @discardableResult
    func focusRightSidebar(mode requestedMode: RightSidebarMode? = nil, focusFirstItem: Bool = true) -> Bool {
        guard let state = fileExplorerState else { return false }
        let mode = requestedMode ?? rememberedRightSidebarMode ?? state.mode
        let target = rightSidebarFocusTarget(mode: mode, focusFirstItem: focusFirstItem)
        return focusRightSidebar(mode: mode, target: target, terminalYieldReason: "rightSidebarFocus")
    }

    @discardableResult
    private func focusRightSidebar(
        mode: RightSidebarMode,
        target: RightSidebarFocusTarget,
        terminalYieldReason: String = "rightSidebarFocus"
    ) -> Bool {
        guard let state = fileExplorerState else { return false }
        rememberedRightSidebarMode = mode
        beginRightSidebarFocusRequest(mode: mode, target: target)
        intent = .rightSidebar(mode: mode)
        if mode != .feed {
            feedSelectedItemId = nil
        }
        publishFeedFocusSnapshot()
        yieldCurrentTerminalSurfaceFocus(reason: terminalYieldReason)
        state.setVisible(true)
        if state.mode != mode {
            state.mode = mode
        }

        let modeResult = focusRightSidebarEndpoint(mode: mode, target: target)
        if modeResult {
            rightSidebarFocusState = .focused(mode: mode, target: target)
        }
        let fallbackResult = modeResult ? false : focusFallbackRightSidebarHost()
        if fallbackResult, target == .host {
            rightSidebarFocusState = .focused(mode: mode, target: .host)
        }
        let result = modeResult || fallbackResult || rightSidebarFocusState.request?.mode == mode
        publishFeedFocusSnapshot()
        return result
    }

    @discardableResult
    func focusFileSearch() -> Bool {
        return focusRightSidebar(
            mode: .find,
            target: .searchField,
            terminalYieldReason: "fileSearchFocus"
        )
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
        rightSidebarFocusState = .inactive
        intent = .mainPanel(workspaceId: workspace.id, panelId: terminalPanel.id)
        publishFeedFocusSnapshot()
        workspace.focusPanel(terminalPanel.id)
        terminalPanel.hostedView.ensureFocus(
            for: workspace.id,
            surfaceId: terminalPanel.id,
            respectForeignFirstResponder: false
        )
        return terminalPanel.hostedView.isSurfaceViewFirstResponder()
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

    private func selectedFocusedPanelRequest(owning responder: NSResponder) -> FocusedPanelRequest? {
        guard let window,
              let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return nil
        }
        if let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId],
           panel.ownedFocusIntent(for: responder, in: window) != nil {
            return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
        }
        for (panelId, panel) in workspace.panels {
            guard panelId != workspace.focusedPanelId,
                  panel.ownedFocusIntent(for: responder, in: window) != nil else {
                continue
            }
            return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
        }
        return nil
    }

    private func captureMainPanelFocusRestoreTarget(owning responder: NSResponder) -> MainWindowFocusRestoreTarget? {
        guard let window,
              let tabManager else {
            return nil
        }

        if let workspace = tabManager.selectedWorkspace,
           let target = captureMainPanelFocusRestoreTarget(in: workspace, owning: responder, window: window) {
            return target
        }

        let selectedWorkspaceId = tabManager.selectedTabId
        for workspace in tabManager.tabs where workspace.id != selectedWorkspaceId {
            if let target = captureMainPanelFocusRestoreTarget(in: workspace, owning: responder, window: window) {
                return target
            }
        }

        return nil
    }

    private func captureMainPanelFocusRestoreTarget(
        in workspace: Workspace,
        owning responder: NSResponder,
        window: NSWindow
    ) -> MainWindowFocusRestoreTarget? {
        if let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId],
           let focusIntent = panel.ownedFocusIntent(for: responder, in: window) {
            return mainPanelFocusRestoreTarget(
                workspaceId: workspace.id,
                panelId: panelId,
                intent: focusIntent
            )
        }

        for (panelId, panel) in workspace.panels where panelId != workspace.focusedPanelId {
            guard let focusIntent = panel.ownedFocusIntent(for: responder, in: window) else {
                continue
            }
            return mainPanelFocusRestoreTarget(
                workspaceId: workspace.id,
                panelId: panelId,
                intent: focusIntent
            )
        }

        return nil
    }

    private func captureSelectedMainPanelFocusRestoreTarget() -> MainWindowFocusRestoreTarget? {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return nil
        }
        return mainPanelFocusRestoreTarget(
            workspaceId: workspace.id,
            panelId: panelId,
            intent: panel.captureFocusIntent(in: window)
        )
    }

    private func captureFocusRestoreTargetFromIntent() -> MainWindowFocusRestoreTarget? {
        switch intent {
        case .mainPanel(let workspaceId, let panelId):
            guard let panel = tabManager?.tabs
                .first(where: { $0.id == workspaceId })?
                .panels[panelId] else {
                return nil
            }
            return mainPanelFocusRestoreTarget(
                workspaceId: workspaceId,
                panelId: panelId,
                intent: panel.captureFocusIntent(in: window)
            )
        case .rightSidebar(let mode):
            return rightSidebarFocusRestoreTarget(
                mode: mode,
                target: rightSidebarRestoreTargetFromState(mode: mode) ?? .host
            )
        case nil:
            return nil
        }
    }

    private func mainPanelFocusRestoreTarget(
        workspaceId: UUID,
        panelId: UUID,
        intent: PanelFocusIntent
    ) -> MainWindowFocusRestoreTarget {
        MainWindowFocusRestoreTarget(
            destination: .mainPanel(
                MainWindowFocusRestoreTarget.MainPanelTarget(
                    workspaceId: workspaceId,
                    panelId: panelId,
                    intent: intent
                )
            )
        )
    }

    private func rightSidebarFocusRestoreTarget(
        mode: RightSidebarMode,
        target: MainWindowFocusRestoreTarget.RightSidebarTarget
    ) -> MainWindowFocusRestoreTarget {
        MainWindowFocusRestoreTarget(
            destination: .rightSidebar(
                MainWindowFocusRestoreTarget.RightSidebarDestination(
                    mode: mode,
                    target: target
                )
            )
        )
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

        rightSidebarFocusState = .inactive
        if clearUnavailableIntent, case .rightSidebar = intent {
            intent = nil
        }
        publishFeedFocusSnapshot()
        return false
    }

    @discardableResult
    private func restoreMainPanelFocus(
        workspaceId: UUID,
        panelId: UUID,
        intent focusIntent: PanelFocusIntent
    ) -> Bool {
        guard let tabManager,
              let workspace = tabManager.tabs.first(where: { $0.id == workspaceId }),
              let panel = workspace.panels[panelId] else {
            return false
        }

        if let window, !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
        }

        rightSidebarFocusState = .inactive
        intent = .mainPanel(workspaceId: workspaceId, panelId: panelId)
        publishFeedFocusSnapshot()

        tabManager.focusTab(
            workspaceId,
            surfaceId: panelId,
            suppressFlash: true,
            focusIntent: focusIntent
        )
        return panel.restoreFocusIntent(focusIntent)
    }

    @discardableResult
    private func restoreRightSidebarFocus(
        mode: RightSidebarMode,
        target: MainWindowFocusRestoreTarget.RightSidebarTarget
    ) -> Bool {
        if case .dockSurface(let surfaceId) = target {
            return restoreDockSurfaceFocus(surfaceId: surfaceId)
        }

        return focusRightSidebar(
            mode: mode,
            target: rightSidebarFocusTarget(for: target),
            terminalYieldReason: "restoreRightSidebarFocus"
        )
    }

    @discardableResult
    private func restoreDockSurfaceFocus(surfaceId: UUID) -> Bool {
        guard let state = fileExplorerState else { return false }

        rememberedRightSidebarMode = .dock
        beginRightSidebarFocusRequest(mode: .dock, target: .dockSurface(surfaceId))
        intent = .rightSidebar(mode: .dock)
        feedSelectedItemId = nil
        publishFeedFocusSnapshot()
        yieldCurrentTerminalSurfaceFocus(reason: "restoreDockSurfaceFocus")
        state.setVisible(true)
        if state.mode != .dock {
            state.mode = .dock
        }

        if dockHost?.focusSurfaceFromCoordinator(surfaceId) == true {
            rightSidebarFocusState = .focused(mode: .dock, target: .dockSurface(surfaceId))
            publishFeedFocusSnapshot()
            return true
        }

        publishFeedFocusSnapshot()
        return rightSidebarFocusState.request?.mode == .dock
    }

    private func effectiveFocusOwner(currentResponder: NSResponder? = nil) -> EffectiveFocusOwner {
        if let responder = currentResponder ?? window?.firstResponder {
            if terminalFocusRequest(for: responder) != nil {
                return .mainPanel
            }
            if rightSidebarModeOwning(responder) != nil {
                return .rightSidebar
            }
            if selectedFocusedPanelRequest(owning: responder) != nil {
                return .mainPanel
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
        guard let request = rightSidebarFocusState.request else {
            return
        }
        guard case .rightSidebar(let targetMode) = intent,
              targetMode == mode,
              request.mode == mode else {
            return
        }
        let result = focusRightSidebarEndpoint(mode: mode, target: request.target)
        if result {
            rightSidebarFocusState = .focused(mode: mode, target: request.target)
        } else if request.target == .host, focusFallbackRightSidebarHost() {
            rightSidebarFocusState = .focused(mode: mode, target: .host)
        }
        publishFeedFocusSnapshot()
    }

    private func beginRightSidebarFocusRequest(mode: RightSidebarMode, target: RightSidebarFocusTarget) {
        nextRightSidebarFocusRequestId &+= 1
        rightSidebarFocusState = .requested(
            RightSidebarFocusRequest(
                id: nextRightSidebarFocusRequestId,
                mode: mode,
                target: target
            )
        )
    }

    private func rightSidebarFocusTarget(
        mode: RightSidebarMode,
        focusFirstItem: Bool
    ) -> RightSidebarFocusTarget {
        switch mode {
        case .files:
            return .outline
        case .find:
            return .searchField
        case .sessions:
            return .host
        case .feed:
            return focusFirstItem ? .firstItem : .host
        case .dock:
            return focusFirstItem ? .firstItem : .host
        }
    }

    private func rightSidebarRestoreTarget(
        mode: RightSidebarMode,
        responder: NSResponder
    ) -> MainWindowFocusRestoreTarget.RightSidebarTarget {
        if mode == .files {
            return .outline
        }
        if mode == .find {
            return .searchField
        }
        if mode == .dock,
           let dockSurfaceId = dockHost?.focusedSurfaceIdFromCoordinator(for: responder) {
            return .dockSurface(dockSurfaceId)
        }
        if let stateTarget = rightSidebarRestoreTargetFromState(mode: mode) {
            return stateTarget
        }
        return .host
    }

    private func rightSidebarRestoreTargetFromState(
        mode: RightSidebarMode
    ) -> MainWindowFocusRestoreTarget.RightSidebarTarget? {
        switch rightSidebarFocusState {
        case .inactive:
            return nil
        case .requested(let request):
            guard request.mode == mode else { return nil }
            return rightSidebarRestoreTarget(for: request.target)
        case .focused(let focusedMode, let target):
            guard focusedMode == mode else { return nil }
            return rightSidebarRestoreTarget(for: target)
        }
    }

    private func rightSidebarRestoreTarget(
        for target: RightSidebarFocusTarget
    ) -> MainWindowFocusRestoreTarget.RightSidebarTarget {
        switch target {
        case .host:
            return .host
        case .outline:
            return .outline
        case .searchField:
            return .searchField
        case .firstItem:
            return .firstItem
        case .dockSurface(let surfaceId):
            return .dockSurface(surfaceId)
        }
    }

    private func rightSidebarFocusTarget(
        for target: MainWindowFocusRestoreTarget.RightSidebarTarget
    ) -> RightSidebarFocusTarget {
        switch target {
        case .host:
            return .host
        case .outline:
            return .outline
        case .searchField:
            return .searchField
        case .firstItem:
            return .firstItem
        case .dockSurface(let surfaceId):
            return .dockSurface(surfaceId)
        }
    }

    private func focusRightSidebarEndpoint(
        mode: RightSidebarMode,
        target: RightSidebarFocusTarget
    ) -> Bool {
        switch mode {
        case .files:
            return fileExplorerHost?.focusOutline() == true
        case .find:
            return fileSearchHost?.focusSearchField() == true
        case .sessions:
            return false
        case .feed:
            if target == .firstItem {
                feedHost?.focusFirstItemFromCoordinator()
            }
            return feedHost?.focusHostFromCoordinator() == true
        case .dock:
            switch target {
            case .firstItem:
                return dockHost?.focusFirstItemFromCoordinator() == true
            case .host:
                return dockHost?.focusHostFromCoordinator() == true
            case .dockSurface(let surfaceId):
                return dockHost?.focusSurfaceFromCoordinator(surfaceId) == true
            case .outline, .searchField:
                return false
            }
        }
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
        if rightSidebarFocusState.mode == .feed {
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
            return fileExplorerState?.mode ?? rememberedRightSidebarMode
        }
        if fileExplorerHost?.ownsKeyboardFocus(responder) == true {
            return .files
        }
        if fileSearchHost?.ownsKeyboardFocus(responder) == true {
            return .find
        }
        if dockHost?.ownsKeyboardFocus(responder) == true {
            return .dock
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
        if TerminalSurfaceRegistry.shared.isRightSidebarDockSurface(id: panelId) {
            return nil
        }
        return TerminalFocusRequest(workspaceId: workspaceId, panelId: panelId)
    }
}
