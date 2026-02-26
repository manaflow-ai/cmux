import Foundation
import Combine
import AppKit

/// TerminalPanel wraps an existing TerminalSurface and conforms to the Panel protocol.
/// This allows TerminalSurface to be used within the bonsplit-based layout system.
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

    private var cancellables = Set<AnyCancellable>()

    var displayTitle: String {
        title.isEmpty ? "Terminal" : title
    }

    var displayIcon: String? {
        "terminal.fill"
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

    /// The hosted NSView for embedding in SwiftUI
    var hostedView: GhosttySurfaceScrollView {
        surface.hostedView
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
        configTemplate: ghostty_surface_config_s? = nil,
        workingDirectory: String? = nil,
        additionalEnvironment: [String: String] = [:],
        portOrdinal: Int = 0
    ) {
        let surface = TerminalSurface(
            tabId: workspaceId,
            context: context,
            configTemplate: configTemplate,
            workingDirectory: workingDirectory,
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
        // Detach from the window portal on real close so stale hosted views
        // cannot remain above browser panes after split close.
        unfocus()
        hostedView.setVisibleInUI(false)
        TerminalWindowPortalRegistry.detach(hostedView: hostedView)
    }

    func requestViewReattach() {
        viewReattachToken &+= 1
    }

    // MARK: - Terminal-specific methods

    func sendText(_ text: String) {
        surface.sendText(text)
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

    func triggerFlash() {
        hostedView.triggerFlash()
    }

    func applyWindowBackgroundIfActive() {
        surface.applyWindowBackgroundIfActive()
    }
}
