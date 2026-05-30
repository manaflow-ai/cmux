import CmuxExtensionKit
import SwiftUI

@main
final class SampleSidebarExtension: CmuxSidebarExtension {
    static let manifest = CMUXExtensionManifest(
        id: "co.manaflow.CMUXExtKitSampleSidebarApp.Extension",
        displayName: "CMUX Sample Sidebar Extension",
        requestedScopes: [
            .workspaceList,
            .workspaceMetadata,
            .surfaceMetadata,
            .notifications,
            .networkPorts,
            .pullRequests,
        ],
        requestedActionScopes: [
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

    func connectionErrorDidChange(_ message: String?) {
        model.connectionErrorDidChange(message)
    }
}
