import AppKit
import Combine
import Foundation

/// A pane that shows one workspace's todo status and full checklist. The
/// checklist itself lives on `Workspace.todoState` (the panel holds no copy),
/// so the pane, the sidebar row, the popovers, the CLI, and the socket all
/// read and mutate one source of truth through the shared `Workspace+Todos`
/// entry points. One todo pane exists per workspace
/// (`openOrFocusWorkspaceTodoSurface` dedupes).
@MainActor
final class WorkspaceTodoPanel: Panel, ObservableObject {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .workspaceTodo

    /// The workspace whose todo state this pane renders. Weak: the workspace
    /// owns this panel through `panels`, so a strong reference would cycle.
    private(set) weak var workspace: Workspace?

    /// The owning workspace's identifier (stable even if the weak reference
    /// clears during teardown).
    let workspaceId: UUID

    var displayTitle: String {
        String(localized: "workspaceTodoPane.title", defaultValue: "Todos")
    }

    var displayIcon: String? { "checklist" }

    /// Token incremented to trigger the focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Bumped when an open-or-focus entry point (checklist popover footer,
    /// palette, CLI) lands on this pane, so the add field re-arms even when
    /// the pane was ALREADY focused and `isFocused` never transitions.
    @Published private(set) var addFieldArmToken: Int = 0

    func armAddField() {
        addFieldArmToken += 1
    }

    init(workspace: Workspace) {
        self.id = UUID()
        self.workspace = workspace
        self.workspaceId = workspace.id
    }

    // MARK: - Panel protocol

    func focus() {
        // The pane is chrome + SwiftUI controls; no dedicated first responder.
    }

    func unfocus() {}

    func close() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}
