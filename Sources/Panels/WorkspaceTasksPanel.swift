import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class WorkspaceTasksPanel: Panel {
    // `Panel` still inherits `ObservableObject`; this class satisfies that
    // requirement through `Panel` while keeping task-list state on `Workspace`.
    let id = UUID()
    let panelType: PanelType = .workspaceTasks

    @ObservationIgnored
    private(set) weak var workspace: Workspace?

    init(workspace: Workspace) {
        self.workspace = workspace
    }

    var displayTitle: String {
        String(localized: "workspaceTasks.surface.title", defaultValue: "Workspace Tasks")
    }

    var displayIcon: String? { "checklist" }

    var isFocusedInWorkspace: Bool {
        workspace?.focusedPanelId == id
    }

    func reattach(to workspace: Workspace) {
        self.workspace = workspace
    }

    func close() {
        workspace = nil
    }

    func focus() {}

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }
}
