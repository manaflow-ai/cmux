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
    private weak var focusAnchorView: RightSidebarToolFocusAnchorView?

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

    func attachFocusAnchor(_ anchor: RightSidebarToolFocusAnchorView?) {
        focusAnchorView = anchor
    }

    func close() {
        focusAnchorView = nil
    }

    func focus() {
        guard let anchor = focusAnchorView,
              let window = anchor.window else { return }
        _ = window.makeFirstResponder(anchor)
    }

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    func ownedFocusIntent(for responder: NSResponder, in window: NSWindow) -> PanelFocusIntent? {
        _ = window
        guard focusAnchorView?.ownsKeyboardFocus(responder) == true else { return nil }
        return .panel
    }
}
