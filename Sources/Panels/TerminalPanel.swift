import Foundation
import CmuxTerminalCore
import Combine
import AppKit
import Bonsplit
import CmuxTerminal
import CmuxWorkspaces

struct AgentHibernationPanelState {
    let agent: SessionRestorableAgentSnapshot
    let hibernatedAt: Date
    let lastActivityAt: Date

    var agentDisplayName: String {
        agent.agentDisplayName
    }
}

enum AgentHibernationResumePreparation: Equatable {
    case unavailable
    case resumed(queuedStartupInput: Bool)

    var didResume: Bool {
        if case .resumed = self { return true }
        return false
    }

    var queuedStartupInput: Bool {
        if case .resumed(let queuedStartupInput) = self { return queuedStartupInput }
        return false
    }
}

/// TerminalPanel wraps an existing TerminalSurface and conforms to the Panel protocol.
/// This allows TerminalSurface to be used within the bonsplit-based layout system.
@MainActor
final class TerminalPanel: Panel, ObservableObject {
    enum TextBoxInputFocusIntent: Equatable {
        case hidden
        case terminal
        case textBox
    }

    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .terminal

    /// The underlying terminal surface
    let surface: TerminalSurface

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

    var ownedSessionScrollbackReplayFileURL: URL? = nil
    /// The workspace-env key/value pairs this panel inherited from its workspace's
    /// `workspaceEnvironment` at creation. The same panel travels when a surface is
    /// moved between workspaces, so a respawn uses these to drop the (possibly
    /// previous) workspace's variables and re-apply the current workspace's. The
    /// value (not just the key) is tracked so an explicit per-surface override that
    /// happens to share a workspace key (e.g. a layout `env` AWS_PROFILE=staging in
    /// a workspace with AWS_PROFILE=prod) is preserved on respawn rather than being
    /// stripped and replaced by the workspace value (issue #5995).
    var seededWorkspaceEnvironment: [String: String] = [:]

    /// Published title from the terminal process
    @Published private(set) var title: String = "Terminal"

    /// Published directory from the terminal
    @Published private(set) var directory: String = ""

    @Published private(set) var tmuxLayoutReport: TmuxPaneLayoutReport?
    let shellActivity = TerminalPanelShellActivityModel()
    let textBoxState = TerminalPanelTextBoxState()
    @Published var isTextBoxActive: Bool = false
    @Published var textBoxContent: String = ""
    @Published var textBoxAttachments: [TextBoxAttachment] = []
    weak var textBoxInputView: TextBoxInputTextView?
    // TextBox composer state below is internal (not private) because the subsystem's
    // methods live in TerminalPanel+TextBoxInput.swift; extensions cannot add storage.
    var shouldFocusTextBoxWhenAvailable = false
    var shouldOpenTextBoxFilePickerWhenAvailable = false
    var shouldHideTextBoxOnNextEscape = false
    var textBoxInputFocusIntent: TextBoxInputFocusIntent = .hidden
    var preservedTextBoxAttributedContent: NSAttributedString?
    var restoredTextBoxDraft: SessionTextBoxInputDraftSnapshot?
    var isClosingPanel = false
    var didDiscardTextBoxContentForClose = false
#if DEBUG
    struct DebugTextBoxInlineFixture {
        let localURL: URL?
        let beforeText: String
        let afterText: String
    }

    var pendingDebugTextBoxInlineFixture: DebugTextBoxInlineFixture?

    var debugHasPendingTextBoxFocusRequest: Bool {
        shouldFocusTextBoxWhenAvailable || shouldOpenTextBoxFilePickerWhenAvailable
    }

    var debugHasTextBoxHideEscapeArm: Bool {
        shouldHideTextBoxOnNextEscape
    }
#endif

    /// Search state for find functionality
    @Published var searchState: TerminalSurface.SearchState? {
        didSet {
            surface.searchState = searchState
        }
    }

    /// Bump this token to force SwiftUI to call `updateNSView` on `GhosttyTerminalView`,
    /// which re-attaches the hosted view after bonsplit close/reparent operations.
    ///
    /// Without this, certain pane-close sequences can leave terminal views detached
    /// (hostedView.window == nil) until the user switches workspaces.
    @Published var viewReattachToken: UInt64 = 0

    @Published private(set) var agentHibernationState: AgentHibernationPanelState?

    var onRequestWorkspacePaneFlash: ((WorkspaceAttentionFlashReason) -> Void)?
    var onRequestAgentHibernationResume: ((Bool) -> Bool)?

    private var cancellables = Set<AnyCancellable>()

    var displayTitle: String {
        title.isEmpty ? "Terminal" : title
    }

    var displayIcon: String? {
        "terminal.fill"
    }

    func updateShellActivityState(_ state: PanelShellActivityState) {
        if shellActivity.state != state {
            shellActivity.state = state
        }
        textBoxState.updateShellActivityState(state)
    }

    var isDirty: Bool {
        // Bonsplit's "dirty" indicator is a very small dot in the tab strip.
        //
        // For terminals, `ghostty_surface_needs_confirm_quit` is driven by shell integration
        // heuristics and can be transiently (or permanently) wrong, which results in a dot
        // showing on every new terminal. That reads as a notification/alert and is misleading.
        //
        // We still honor `needsConfirmClose()` when actually closing a panel; we just don't
        // surface it as a tab-level dirty indicator.
        false
    }

    var isAgentHibernated: Bool {
        agentHibernationState != nil
    }

    /// The hosted NSView for embedding in SwiftUI
    var hostedView: GhosttySurfaceScrollView {
        surface.hostedView
    }

    var requestedWorkingDirectory: String? {
        surface.requestedWorkingDirectory
    }

    init(workspaceId: UUID, surface: TerminalSurface) {
        self.id = surface.id
        self.workspaceId = workspaceId
        self.surface = surface
        // Subscribe to surface's search state changes
        surface.$searchState
            .sink { [weak self] state in
                if self?.searchState !== state {
                    self?.searchState = state
                }
            }
            .store(in: &cancellables)
    }

    /// Create a new terminal panel with a fresh surface
    convenience init(
        id: UUID = UUID(),
        workspaceId: UUID,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_SPLIT,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        initialCommand: String? = nil,
        tmuxStartCommand: String? = nil,
        initialInput: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:],
        focusPlacement: TerminalSurfaceFocusPlacement = .workspace,
        runtimeSpawnPolicy: TerminalSurfaceRuntimeSpawnPolicy = .immediate
    ) {
        let surface = TerminalSurface(
            id: id,
            tabId: workspaceId,
            context: context,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            portOrdinal: portOrdinal,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment,
            focusPlacement: focusPlacement, runtimeSpawnPolicy: runtimeSpawnPolicy,
            preparePaneHost: { Self.prepareNotificationScrollReplay(for: $0, environment: additionalEnvironment) }
        )
        self.init(workspaceId: workspaceId, surface: surface)
        if Self.startsAtOwnedPrompt(
            configTemplate: configTemplate,
            initialCommand: initialCommand,
            tmuxStartCommand: tmuxStartCommand,
            initialInput: initialInput
        ) {
            updateShellActivityState(.promptIdle)
        }
    }

    private static func startsAtOwnedPrompt(
        configTemplate: CmuxSurfaceConfigTemplate?,
        initialCommand: String?,
        tmuxStartCommand: String?,
        initialInput: String?
    ) -> Bool {
        isBlank(initialCommand) &&
            isBlank(tmuxStartCommand) &&
            isBlank(initialInput) &&
            isBlank(configTemplate?.command) &&
            isBlank(configTemplate?.initialInput)
    }

    private static func isBlank(_ value: String?) -> Bool {
        value?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true
    }

    func updateTitle(_ newTitle: String) {
        let trimmed = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && title != trimmed {
            title = trimmed
        }
    }

    func updateDirectory(_ newDirectory: String) {
        let trimmed = newDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty && directory != trimmed {
            directory = trimmed
        }
    }

    func updateWorkspaceId(_ newWorkspaceId: UUID) {
        workspaceId = newWorkspaceId
        surface.updateWorkspaceId(newWorkspaceId)
    }

    func updateTmuxLayoutReport(_ report: TmuxPaneLayoutReport?) {
        guard tmuxLayoutReport != report else { return }
        tmuxLayoutReport = report
    }

    func focus() {
        if isAgentHibernated {
            _ = requestAgentHibernationResume(focus: true)
            return
        }
        focusTerminalSurface(respectForeignFirstResponder: true)
    }

    @discardableResult
    func focusTerminalSurface(
        respectForeignFirstResponder: Bool,
        clearTextBoxHideArm: Bool = true
    ) -> Bool {
        if clearTextBoxHideArm {
            shouldHideTextBoxOnNextEscape = false
        }
        if isTextBoxActive,
           respectForeignFirstResponder,
           textBoxInputFocusIntent == .textBox {
            hostedView.yieldTerminalSurfaceFocusForForeignResponder(reason: "textbox.preserveFocusIntent")
            hostedView.setActive(false)
            return true
        }
        if isTextBoxActive {
            textBoxInputFocusIntent = .terminal
            shouldFocusTextBoxWhenAvailable = false
            shouldOpenTextBoxFilePickerWhenAvailable = false
        }
        // `unfocus()` force-disables active state to stop stale retries from stealing focus.
        // Re-enable it immediately for explicit focus requests (socket/UI) so ensureFocus can run.
        hostedView.preparePanelFocusIntentForActivation(.surface)
        hostedView.setActive(true)
        guard let focusWindow = surface.uiWindow ?? hostedView.window else {
            surface.setFocus(false)
            return false
        }
        guard AppDelegate.shared?.allowsTerminalKeyboardFocus(
            workspaceId: workspaceId,
            panelId: id,
            in: focusWindow
        ) != false else {
            surface.setFocus(false)
            return false
        }
        surface.setFocus(true)
        hostedView.ensureFocus(
            for: workspaceId,
            surfaceId: id,
            respectForeignFirstResponder: respectForeignFirstResponder
        )
        return true
    }

    func unfocus() {
        surface.setFocus(false)
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
        // Cancel any pending focus work items so an inactive terminal can't steal first responder
        // back from another surface (notably WKWebView) during rapid focus changes in tests.
        //
        // Also flip the hosted view's active state immediately: SwiftUI focus propagation can lag
        // by a runloop tick, and `requestFocus` retries that are already executing can otherwise
        // schedule new work items that fire after we navigate away.
        hostedView.setActive(false)
    }

    func close() {
        isClosingPanel = true
        discardTextBoxContentForClose()
        removeOwnedSessionScrollbackReplayArtifact()
        // Detach from the window portal on real close so stale hosted views
        // cannot remain above browser panes after split close.
        surface.beginPortalCloseLifecycle(reason: "panel.close")
#if DEBUG
        let frame = String(format: "%.1fx%.1f", hostedView.frame.width, hostedView.frame.height)
        let bounds = String(format: "%.1fx%.1f", hostedView.bounds.width, hostedView.bounds.height)
        cmuxDebugLog(
            "surface.panel.close.begin panel=\(id.uuidString.prefix(5)) " +
            "workspace=\(workspaceId.uuidString.prefix(5)) runtimeSurface=\(surface.surface != nil ? 1 : 0) " +
            "inWindow=\(surface.isViewInWindow ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0) frame=\(frame) bounds=\(bounds)"
        )
#endif
        unfocus()
        hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
#if DEBUG
        cmuxDebugLog(
            "surface.panel.close.end panel=\(id.uuidString.prefix(5)) " +
            "inWindow=\(surface.isViewInWindow ? 1 : 0) hasSuperview=\(hostedView.superview != nil ? 1 : 0) " +
            "hidden=\(hostedView.isHidden ? 1 : 0)"
        )
#endif
        surface.teardownSurface()
    }

    func enterAgentHibernation(
        agent: SessionRestorableAgentSnapshot,
        lastActivityAt: Date,
        hibernatedAt: Date = Date()
    ) {
        agentHibernationState = AgentHibernationPanelState(
            agent: agent,
            hibernatedAt: hibernatedAt,
            lastActivityAt: lastActivityAt
        )
        unfocus()
        searchState = nil
        hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
        surface.suspendRuntimeSurfaceForAgentHibernation(reason: "agentHibernation")
        requestViewReattach()
    }

    @discardableResult
    func prepareAgentHibernationResume() -> AgentHibernationResumePreparation {
        guard let state = agentHibernationState else {
            return .unavailable
        }
        let resumeStartupInput = state.agent.resumeStartupInput()
        agentHibernationState = nil
        surface.prepareAgentHibernationResume(initialInput: resumeStartupInput)
        requestViewReattach()
        surface.requestBackgroundSurfaceStartIfNeeded()
        return .resumed(queuedStartupInput: resumeStartupInput != nil)
    }

    func requestViewReattach() {
        viewReattachToken &+= 1
    }

    /// Monotonic model ownership epoch across container transfers and local
    /// representable reattachments. This takes precedence over host creation
    /// order when a move rolls back to an earlier view.
    var portalHostOwnershipGeneration: UInt64 {
        surface.currentPortalHostOwnershipGeneration() &+ viewReattachToken
    }

    func recordPortalHostOwnershipChange() {
        requestViewReattach()
    }

    // MARK: - Terminal-specific methods

    @discardableResult
    func sendText(_ text: String) -> Bool {
        resumeForExplicitInputIfNeeded()
        return surface.sendText(text)
    }

    func sendInput(_ text: String) {
        _ = sendInputResult(text)
    }

    @discardableResult
    func sendInputResult(_ text: String) -> TerminalSurface.InputSendResult {
        resumeForExplicitInputIfNeeded()
        return surface.sendInputResult(text)
    }

    @discardableResult
    func sendNamedKeyResult(_ keyName: String) -> TerminalSurface.NamedKeySendResult {
        resumeForExplicitInputIfNeeded()
        return surface.sendNamedKey(keyName)
    }

    @discardableResult
    func sendNamedKey(_ keyName: String) -> Bool {
        switch sendNamedKeyResult(keyName) {
        case .sent, .queued:
            return true
        case .unknownKey, .inputQueueFull, .surfaceUnavailable, .processExited:
            return false
        }
    }

    func performBindingAction(_ action: String) -> Bool {
        guard !isAgentHibernated else { return false }
        return surface.performExplicitInputBindingAction(action)
    }

    @discardableResult
    func clearScreenKeepingScrollback() -> Bool {
        resumeForExplicitInputIfNeeded()
        return surface.clearScreenKeepingScrollback()
    }

    private func resumeForExplicitInputIfNeeded() {
        guard isAgentHibernated else { return }
        _ = requestAgentHibernationResume(focus: false)
    }

    @discardableResult
    private func requestAgentHibernationResume(focus: Bool) -> Bool {
        guard isAgentHibernated else { return false }
        if let onRequestAgentHibernationResume {
            return onRequestAgentHibernationResume(focus)
        }
        return prepareAgentHibernationResume().didResume
    }

    func hasSelection() -> Bool {
        surface.hasSelection()
    }

    func needsConfirmClose() -> Bool {
        surface.needsConfirmClose()
    }

    func shouldPersistScrollbackForSessionSnapshot() -> Bool {
        // Session restore only replays terminal output into a fresh shell. If Ghostty
        // says we are not safely at a prompt, replaying that state later is misleading.
        !surface.needsConfirmClose()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        guard NotificationPaneFlashSettings.isEnabled() else { return }

        switch TmuxOverlayExperimentSettings.target() {
        case .bonsplitPane:
            if let onRequestWorkspacePaneFlash {
                onRequestWorkspacePaneFlash(reason)
                return
            }
            hostedView.triggerFlash(style: GhosttySurfaceScrollView.flashStyle(for: reason))
        case .surface, .tmuxActivePane:
            hostedView.triggerFlash(style: GhosttySurfaceScrollView.flashStyle(for: reason))
        }
    }

    func triggerNotificationDismissFlash() {
        triggerFlash(reason: .notificationDismiss)
    }

    func applyWindowBackgroundIfActive() {
        surface.applyWindowBackgroundIfActive()
    }

    func captureFocusIntent(in window: NSWindow?) -> PanelFocusIntent {
        guard !isAgentHibernated else { return .panel }
        if textBoxOwnsResponder(window?.firstResponder) {
            return .terminal(.textBoxInput)
        }
        return .terminal(hostedView.capturePanelFocusIntent(in: window))
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        guard !isAgentHibernated else { return .panel }
        if isTextBoxActive, textBoxInputFocusIntent == .textBox {
            return .terminal(.textBoxInput)
        }
        return .terminal(hostedView.preferredPanelFocusIntentForActivation())
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        guard !isAgentHibernated else { return }
        guard case .terminal(let target) = intent else { return }
        switch target {
        case .surface, .findField:
            if isTextBoxActive {
                textBoxInputFocusIntent = .terminal
                shouldFocusTextBoxWhenAvailable = false
            }
            hostedView.preparePanelFocusIntentForActivation(target)
        case .textBoxInput:
            textBoxInputFocusIntent = .textBox
            isTextBoxActive = true
            shouldFocusTextBoxWhenAvailable = true
        }
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        if isAgentHibernated {
            return requestAgentHibernationResume(focus: true)
        }
        switch intent {
        case .panel:
            focus()
            return true
        case .terminal(let target):
            switch target {
            case .surface:
                return focusTerminalSurface(respectForeignFirstResponder: false)
            case .textBoxInput:
                return focusTextBoxInput()
            case .findField:
                return hostedView.restorePanelFocusIntent(target)
            }
        default:
            return false
        }
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        guard !isAgentHibernated else { return nil }
        _ = window
        if textBoxOwnsResponder(responder) {
            return .terminal(.textBoxInput)
        }
        guard let intent = hostedView.ownedPanelFocusIntent(for: responder) else { return nil }
        return .terminal(intent)
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard !isAgentHibernated else { return false }
        guard case .terminal(let target) = intent else { return false }
        if target == .textBoxInput {
            guard let firstResponder = window.firstResponder,
                  textBoxOwnsResponder(firstResponder) else {
                return false
            }
            surface.setFocus(false)
            window.makeFirstResponder(nil)
            return true
        }
        return hostedView.yieldPanelFocusIntent(target, in: window)
    }
}
