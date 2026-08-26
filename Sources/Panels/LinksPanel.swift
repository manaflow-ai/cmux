import AppKit
import Foundation
import Observation

@MainActor
@Observable
final class LinksPanel: Panel {
    let id: UUID
    let stableSurfaceIdentity = PanelStableSurfaceIdentity()
    let panelType: PanelType = .links

    @ObservationIgnored private(set) weak var workspace: Workspace?
    let workspaceId: UUID
    let titleFetcher: LinkTitleFetcher

    var displayTitle: String {
        String(localized: "linksPane.title", defaultValue: "Links")
    }

    var displayIcon: String? { "link" }

    private(set) var focusFlashToken: Int = 0

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
