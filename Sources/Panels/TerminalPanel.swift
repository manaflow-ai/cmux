import Foundation
import Combine
import AppKit

/// TerminalPanel wraps an existing TerminalSurface and conforms to the Panel protocol.
/// This allows TerminalSurface to be used within the WorkspaceSplit-based layout system.
@MainActor
final class TerminalPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .terminal

    /// The underlying terminal surface
    let surface: TerminalSurface

    /// The workspace ID this panel belongs to
    private(set) var workspaceId: UUID

    /// Published title from the terminal process
    @Published private(set) var title: String = "Terminal"

    /// Published directory from the terminal
    @Published private(set) var directory: String = ""

    @Published private(set) var tmuxLayoutReport: TmuxPaneLayoutReport?

    /// Search state for find functionality
    @Published var searchState: TerminalSurface.SearchState? {
        didSet {
            surface.searchState = searchState
        }
    }

    var onRequestWorkspacePaneFlash: ((WorkspaceAttentionFlashReason) -> Void)?

    private var cancellables = Set<AnyCancellable>()

    var displayTitle: String {
        title.isEmpty ? "Terminal" : title
    }

    var displayIcon: String? {
        "terminal.fill"
    }

    var isDirty: Bool {
        // WorkspaceSplit's "dirty" indicator is a very small dot in the tab strip.
        //
        // For terminals, `ghostty_surface_needs_confirm_quit` is driven by shell integration
        // heuristics and can be transiently (or permanently) wrong, which results in a dot
        // showing on every new terminal. That reads as a notification/alert and is misleading.
        //
        // We still honor `needsConfirmClose()` when actually closing a panel; we just don't
        // surface it as a tab-level dirty indicator.
        false
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
        workspaceId: UUID,
        context: ghostty_surface_context_e = GHOSTTY_SURFACE_CONTEXT_SPLIT,
        configTemplate: CmuxSurfaceConfigTemplate? = nil,
        workingDirectory: String? = nil,
        portOrdinal: Int = 0,
        initialCommand: String? = nil,
        initialEnvironmentOverrides: [String: String] = [:],
        additionalEnvironment: [String: String] = [:]
    ) {
        let surface = TerminalSurface(
            tabId: workspaceId,
            context: context,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
            initialCommand: initialCommand,
            initialEnvironmentOverrides: initialEnvironmentOverrides,
            additionalEnvironment: additionalEnvironment
        )
        surface.portOrdinal = portOrdinal
        self.init(workspaceId: workspaceId, surface: surface)
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
        surface.setFocus(true)
        // `unfocus()` force-disables active state to stop stale retries from stealing focus.
        // Re-enable it immediately for explicit focus requests (socket/UI) so ensureFocus can run.
        hostedView.setActive(true)
        hostedView.ensureFocus(for: workspaceId, surfaceId: id)
    }

    func unfocus() {
        surface.setFocus(false)
        // Cancel any pending focus work items so an inactive terminal can't steal first responder
        // back from another surface (notably WKWebView) during rapid focus changes in tests.
        //
        // Also flip the hosted view's active state immediately: SwiftUI focus propagation can lag
        // by a runloop tick, and `requestFocus` retries that are already executing can otherwise
        // schedule new work items that fire after we navigate away.
        hostedView.setActive(false)
    }

    func close() {
        // The surface will be cleaned up by its deinit
        unfocus()
        hostedView.setVisibleInUI(false)
        hostedView.removeFromSuperview()
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
        surface.teardownSurface()
    }

    // MARK: - Terminal-specific methods

    func sendText(_ text: String) {
        surface.sendText(text)
    }

    func sendInput(_ text: String) {
        surface.sendInput(text)
    }

    func performBindingAction(_ action: String) -> Bool {
        surface.performBindingAction(action)
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
        case .workspacePane:
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
        .terminal(hostedView.capturePanelFocusIntent(in: window))
    }

    func preferredFocusIntentForActivation() -> PanelFocusIntent {
        .terminal(hostedView.preferredPanelFocusIntentForActivation())
    }

    func prepareFocusIntentForActivation(_ intent: PanelFocusIntent) {
        guard case .terminal(let target) = intent else { return }
        hostedView.preparePanelFocusIntentForActivation(target)
    }

    @discardableResult
    func restoreFocusIntent(_ intent: PanelFocusIntent) -> Bool {
        switch intent {
        case .panel:
            focus()
            return true
        case .terminal(let target):
            return hostedView.restorePanelFocusIntent(target)
        default:
            return false
        }
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = window
        guard let intent = hostedView.ownedPanelFocusIntent(for: responder) else { return nil }
        return .terminal(intent)
    }

    @discardableResult
    func yieldFocusIntent(_ intent: PanelFocusIntent, in window: NSWindow) -> Bool {
        guard case .terminal(let target) = intent else { return false }
        return hostedView.yieldPanelFocusIntent(target, in: window)
    }
}
