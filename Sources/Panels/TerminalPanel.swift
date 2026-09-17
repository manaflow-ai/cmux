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
    private enum TextBoxInputFocusIntent: Equatable {
        case hidden
        case terminal
        case textBox
    }

    let id: UUID
    let panelType: PanelType = .terminal

    /// The underlying terminal surface
    let surface: TerminalSurface

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

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
    private var shouldFocusTextBoxWhenAvailable = false
    private var shouldOpenTextBoxFilePickerWhenAvailable = false
    private var shouldHideTextBoxOnNextEscape = false
    private var textBoxInputFocusIntent: TextBoxInputFocusIntent = .hidden
    private var preservedTextBoxAttributedContent: NSAttributedString?
    private var restoredTextBoxDraft: SessionTextBoxInputDraftSnapshot?
    private var isClosingPanel = false
    private var didDiscardTextBoxContentForClose = false
#if DEBUG
    private struct DebugTextBoxInlineFixture {
        let localURL: URL?
        let beforeText: String
        let afterText: String
    }

    private var pendingDebugTextBoxInlineFixture: DebugTextBoxInlineFixture?

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

    func recordTextBoxLaunchCommand(_ command: String) {
        guard let boundedContext = TextBoxAgentDetection.boundedLaunchCommandContext(from: command) else { return }
        textBoxState.recordLaunchCommand(boundedContext)
    }

    func clearTextBoxLaunchCommand() {
        textBoxState.clearLaunchCommand()
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
            focusPlacement: focusPlacement,
            runtimeSpawnPolicy: runtimeSpawnPolicy
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

    func preferTextBoxInputWhenActivated() {
        isTextBoxActive = true
        textBoxInputFocusIntent = .textBox
        shouldFocusTextBoxWhenAvailable = true
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
        focusTextBoxIfNeeded()
    }

    func showTextBoxInputWhenAvailable() {
        isTextBoxActive = true
        textBoxInputFocusIntent = .terminal
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
    }

    func registerTextBoxInputView(_ view: TextBoxInputTextView) {
        textBoxInputView = view
        // Registration runs from NSViewRepresentable.makeNSView; restoring drafts here must not
        // write SwiftUI/Combine bindings while SwiftUI is constructing the subtree.
        if let restoredTextBoxDraft {
            self.restoredTextBoxDraft = nil
            view.installSessionDraft(restoredTextBoxDraft, notifyingTextChange: false)
        } else if let preservedTextBoxAttributedContent {
            self.preservedTextBoxAttributedContent = nil
            view.installPreservedContent(preservedTextBoxAttributedContent, notifyingTextChange: false)
        }
        focusTextBoxIfNeeded()
#if DEBUG
        applyPendingDebugTextBoxInlineFixtureIfNeeded()
#endif
    }

    func textBoxInputViewDidMoveToWindow(_ view: TextBoxInputTextView) {
        guard textBoxInputView === view else { return }
        focusTextBoxIfNeeded()
#if DEBUG
        applyPendingDebugTextBoxInlineFixtureIfNeeded()
#endif
    }


    @discardableResult
    func toggleTextBoxInput() -> Bool {
        if isTextBoxActive {
            hideTextBoxInput()
            return true
        }

        return focusTextBoxInput()
    }

    @discardableResult
    func focusTextBoxInputOrTerminal() -> Bool {
        if isTextBoxActive,
           textBoxInputFocusIntent == .textBox {
            shouldHideTextBoxOnNextEscape = false
            let didFocusTerminal = focusTerminalSurface(respectForeignFirstResponder: false)
            if !didFocusTerminal {
                textBoxInputFocusIntent = .textBox
            }
            return didFocusTerminal
        }

        return focusTextBoxInput()
    }

    @discardableResult
    func attachFileToTextBoxInput() -> Bool {
        textBoxInputFocusIntent = .textBox
        isTextBoxActive = true
        shouldFocusTextBoxWhenAvailable = true
        shouldOpenTextBoxFilePickerWhenAvailable = true
        shouldHideTextBoxOnNextEscape = false
        let hasMountedTextBox = textBoxInputView?.window != nil
        let didFocusTextBox = focusTextBoxIfNeeded()
        return didFocusTextBox || !hasMountedTextBox
    }

    func textBoxDidBecomeFocused() {
        shouldHideTextBoxOnNextEscape = false
        isTextBoxActive = true
        textBoxInputFocusIntent = .textBox
        surface.setFocus(false)
        hostedView.setActive(false)
    }

    func terminalDidBecomeFocused() {
        guard isTextBoxActive else { return }
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        textBoxInputFocusIntent = .terminal
    }

    func handleTextBoxEscape() {
        let hadTextBoxView = textBoxInputView != nil
        let didFocusTerminal = focusTerminalSurface(
            respectForeignFirstResponder: false,
            clearTextBoxHideArm: false
        )
        shouldHideTextBoxOnNextEscape = isTextBoxActive && (hadTextBoxView || didFocusTerminal)
    }

    @discardableResult
    func consumeTextBoxHideEscapeIfArmed(in window: NSWindow?) -> Bool {
        guard isTextBoxActive,
              shouldHideTextBoxOnNextEscape else {
            return false
        }
        guard textBoxOrSurfaceOwnsEscapeContext(in: window) else {
            shouldHideTextBoxOnNextEscape = false
            return false
        }
        hideTextBoxInput()
        return true
    }

    func clearTextBoxHideEscapeArm() {
        shouldHideTextBoxOnNextEscape = false
    }

    private func hideTextBoxInput() {
        shouldHideTextBoxOnNextEscape = false
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        textBoxInputFocusIntent = .hidden
        preserveTextBoxContentFromView()
        isTextBoxActive = false
        textBoxInputView = nil
        focusTerminalSurface(respectForeignFirstResponder: false)
    }

    private func preserveTextBoxContentFromView() {
        guard let textBoxInputView else { return }
        preserveTextBoxContentForUnmount(from: textBoxInputView)
    }

    func preserveTextBoxContentForUnmount(from textBoxInputView: TextBoxInputTextView) {
        // Dismantle can run while AttributeGraph is destroying this subtree. Cache only
        // non-published draft state here; normal editing keeps the published bindings current.
        if isClosingPanel {
            assert(
                didDiscardTextBoxContentForClose,
                "close() must discard TextBox content before SwiftUI dismantles the TextBox view"
            )
            recordTextBoxViewUnmounted(textBoxInputView)
            return
        }
        let preservedContent = textBoxInputView.attributedContentForPreservation()
        textBoxInputView.invalidatePendingAttachmentUploads()
        preservedTextBoxAttributedContent = NSAttributedString(
            attributedString: preservedContent
        )
        recordTextBoxViewUnmounted(textBoxInputView)
    }

    private func recordTextBoxViewUnmounted(_ textBoxInputView: TextBoxInputTextView) {
        guard self.textBoxInputView === textBoxInputView else { return }
        self.textBoxInputView = nil
    }

    private func discardTextBoxContentForClose(from textBoxInputView: TextBoxInputTextView? = nil) {
        didDiscardTextBoxContentForClose = true
        let currentTextView = textBoxInputView ?? self.textBoxInputView
        let attachmentsToCleanup = currentTextView?.inlineAttachments() ?? textBoxAttachments
        if let currentTextView {
            currentTextView.clearContent(cleanupAttachmentFiles: true)
            currentTextView.discardUndoHistoryAndCleanupPendingAttachmentFiles()
        } else if !attachmentsToCleanup.isEmpty {
            let cleanupTextView = TextBoxInputTextView(frame: NSRect(x: 0, y: 0, width: 1, height: 1))
            cleanupTextView.cleanupDisposableAttachmentFiles(
                attachmentsToCleanup,
                preservingActiveInlineAttachments: false
            )
        }
        restoredTextBoxDraft = nil
        preservedTextBoxAttributedContent = nil
        textBoxContent = ""
        textBoxAttachments = []
        isTextBoxActive = false
        textBoxInputFocusIntent = .hidden
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
        if self.textBoxInputView === currentTextView {
            self.textBoxInputView = nil
        }
    }

    func sessionTextBoxDraftSnapshot() -> SessionTextBoxInputDraftSnapshot? {
        if let textBoxInputView {
            return textBoxInputView.sessionDraftSnapshot(isActive: isTextBoxActive)
        }

        if let restoredTextBoxDraft {
            return restoredTextBoxDraft
        }

        if let preservedTextBoxAttributedContent {
            return TextBoxInputTextView.sessionDraftSnapshot(
                from: preservedTextBoxAttributedContent,
                isActive: isTextBoxActive
            )
        }

        return TextBoxInputTextView.sessionDraftSnapshot(
            text: textBoxContent,
            attachments: textBoxAttachments,
            isActive: isTextBoxActive
        )
    }

    func restoreSessionTextBoxDraft(_ draft: SessionTextBoxInputDraftSnapshot?) {
        guard let draft,
              !draft.parts.isEmpty else {
            restoredTextBoxDraft = nil
            preservedTextBoxAttributedContent = nil
            textBoxContent = ""
            textBoxAttachments = []
            isTextBoxActive = false
            textBoxInputFocusIntent = .hidden
            shouldFocusTextBoxWhenAvailable = false
            shouldOpenTextBoxFilePickerWhenAvailable = false
            shouldHideTextBoxOnNextEscape = false
            return
        }

        restoredTextBoxDraft = draft
        preservedTextBoxAttributedContent = nil
        textBoxContent = TextBoxInputTextView.plainText(from: draft)
        textBoxAttachments = TextBoxInputTextView.attachments(from: draft)
        isTextBoxActive = draft.isActive
        textBoxInputFocusIntent = draft.isActive ? .textBox : .hidden
        shouldFocusTextBoxWhenAvailable = false
        shouldOpenTextBoxFilePickerWhenAvailable = false
        shouldHideTextBoxOnNextEscape = false
    }

    @discardableResult
    private func focusTextBoxIfNeeded() -> Bool {
        guard shouldFocusTextBoxWhenAvailable,
              isTextBoxActive,
              let textBoxInputView,
              let window = textBoxInputView.window else { return false }
        guard window.makeFirstResponder(textBoxInputView) else { return false }
        shouldFocusTextBoxWhenAvailable = false
        textBoxInputFocusIntent = .textBox
        surface.setFocus(false)
        hostedView.setActive(false)
        if shouldOpenTextBoxFilePickerWhenAvailable {
            shouldOpenTextBoxFilePickerWhenAvailable = false
            textBoxInputView.openFilePicker()
        }
        return true
    }

    @discardableResult
    private func focusTextBoxInput() -> Bool {
        textBoxInputFocusIntent = .textBox
        isTextBoxActive = true
        shouldFocusTextBoxWhenAvailable = true
        shouldHideTextBoxOnNextEscape = false
        let hasMountedTextBox = textBoxInputView?.window != nil
        let didFocusTextBox = focusTextBoxIfNeeded()
        return didFocusTextBox || !hasMountedTextBox
    }

#if DEBUG
    @discardableResult
    func installDebugTextBoxInlineFixture(
        localURL: URL?,
        beforeText: String,
        afterText: String
    ) -> Bool {
        textBoxInputFocusIntent = .textBox
        isTextBoxActive = true
        shouldFocusTextBoxWhenAvailable = true

        let fixture = DebugTextBoxInlineFixture(
            localURL: localURL?.standardizedFileURL,
            beforeText: beforeText,
            afterText: afterText
        )

        pendingDebugTextBoxInlineFixture = fixture
        applyPendingDebugTextBoxInlineFixtureIfNeeded()
        return true
    }

    private func applyPendingDebugTextBoxInlineFixtureIfNeeded() {
        guard let fixture = pendingDebugTextBoxInlineFixture,
              let textBoxInputView,
              let textBoxWindow = textBoxInputView.window,
              textBoxWindow === hostedView.window else { return }
        pendingDebugTextBoxInlineFixture = nil
        applyDebugTextBoxInlineFixture(fixture, to: textBoxInputView)
    }

    private func applyDebugTextBoxInlineFixture(
        _ fixture: DebugTextBoxInlineFixture,
        to textBoxInputView: TextBoxInputTextView
    ) {
        textBoxInputView.window?.makeFirstResponder(textBoxInputView)
        let attachment = fixture.localURL.map {
                TextBoxAttachment(
                    localURL: $0,
                    submissionText: TextBoxAttachment.submissionText(forLocalFileURL: $0)
                )
        }
        textBoxContent = fixture.beforeText + fixture.afterText
        textBoxAttachments = attachment.map { [$0] } ?? []
        textBoxInputView.installInlineControlFixture(
            attachment,
            beforeText: fixture.beforeText,
            afterText: fixture.afterText
        )
        textBoxContent = textBoxInputView.plainText()
        textBoxAttachments = textBoxInputView.inlineAttachments()
    }
#endif

    func focus() {
        if isAgentHibernated {
            _ = requestAgentHibernationResume(focus: true)
            return
        }
        focusTerminalSurface(respectForeignFirstResponder: true)
    }

    @discardableResult
    private func focusTerminalSurface(
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
        // The surface will be cleaned up by its deinit
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
        return surface.performBindingAction(action)
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

    private func textBoxOwnsResponder(_ responder: NSResponder?) -> Bool {
        guard let responder,
              let textBoxInputView else { return false }
        if responder === textBoxInputView {
            return true
        }
        guard let view = responder as? NSView else { return false }
        return view.isDescendant(of: textBoxInputView)
    }

    private func textBoxOrSurfaceOwnsResponder(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        if window === hostedView.window,
           hostedView.isSurfaceViewFirstResponder() {
            return true
        }
        guard let responder = window.firstResponder else { return false }
        if textBoxOwnsResponder(responder) {
            return true
        }
        return hostedView.ownedPanelFocusIntent(for: responder) == .surface
    }

    private func textBoxOrSurfaceOwnsEscapeContext(in window: NSWindow?) -> Bool {
        guard let window else { return false }
        return textBoxOrSurfaceOwnsResponder(in: window)
    }
}
