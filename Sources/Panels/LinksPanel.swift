import AppKit
import Combine
import Foundation

@MainActor
final class LinksPanel: Panel, ObservableObject {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .links

    private(set) weak var workspace: Workspace?
    let workspaceId: UUID
    let titleFetcher: LinkTitleFetcher

    var displayTitle: String {
        String(localized: "linksPane.title", defaultValue: "Links")
    }

    var displayIcon: String? { "link" }

    @Published private(set) var focusFlashToken: Int = 0

    init(workspace: Workspace, titleFetcher: LinkTitleFetcher) {
        self.id = UUID()
        self.workspace = workspace
        self.workspaceId = workspace.id
        self.titleFetcher = titleFetcher
    }

    func focus() {}

    func unfocus() {}

    func close() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }
}
