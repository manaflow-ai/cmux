import CmuxExtensionKit
import SwiftUI

@main
final class SampleSidebarExtension: @MainActor CmuxSidebarExtension {
    static let manifest = CmuxExtensionManifest(
        id: "co.manaflow.CMUXExtKitSampleSidebarApp.Extension",
        displayName: String(localized: "sampleSidebar.manifest.displayName", defaultValue: "CMUX Sample Sidebar Extension"),
        readScopes: [
            .workspaceList,
            .workspaceMetadata,
            .surfaceMetadata,
            .notifications,
            .networkPorts,
            .pullRequests,
        ],
        actionScopes: [
            .createSurface,
            .selectWorkspace,
            .selectSurface,
            .navigateWorkspace,
            .navigateSurface,
        ]
    )

    private let model = SidebarConnectionModel()

    required init() {}

    var body: some View {
        SampleSidebarView(model: model)
    }

    func update(context: CmuxSidebarContext) {
        model.update(context: context)
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        model.connectionStatusDidChange(status)
    }
}
