import CmuxExtensionKit
import SwiftUI

@main
final class SurfaceStatusExtension: @MainActor CmuxSidebarExtension {
    static let manifest = CmuxExtensionManifest(
        id: "dev.vincent.cmux.surface-status-sidebar",
        displayName: String(localized: "surfaceSidebar.manifest.displayName", defaultValue: "Surface Status"),
        readScopes: [
            .workspaceList,
            .workspaceMetadata,
            .surfaceMetadata,
        ],
        actionScopes: [
            .selectWorkspace,
            .selectSurface,
        ]
    )

    private let model = SidebarConnectionModel()

    required init() {}

    var body: some View {
        SurfaceStatusSidebarView(model: model)
    }

    func update(context: CmuxSidebarContext) {
        model.update(context: context)
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        model.connectionStatusDidChange(status)
    }
}
