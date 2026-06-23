import AppKit
import Combine
import Foundation

@MainActor
final class WorkspaceTasksPanel: Panel, ObservableObject {
    let id = UUID()
    let panelType: PanelType = .workspaceTasks

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
