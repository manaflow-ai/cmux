import AppKit
import Combine

@MainActor
final class CustomSidebarPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .customSidebar
    let name: String
    let fileURL: URL

    @Published private(set) var focusFlashToken: Int = 0

    private weak var workspace: Workspace?

    init(workspace: Workspace, name: String, fileURL: URL) {
        self.id = UUID()
        self.name = name
        self.fileURL = fileURL
        self.workspace = workspace
    }

    var displayTitle: String { name }
    var displayIcon: String? { "wand.and.stars" }

    var isFocusedInWorkspace: Bool {
        workspace?.focusedPanelId == id
    }

    func reattach(to workspace: Workspace) {
        self.workspace = workspace
    }

    func close() {}
    func focus() {}
    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}
