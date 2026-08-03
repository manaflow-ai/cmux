import CmuxExtensionKit

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

    var presentation: CmuxSidebarPresentation {
        SampleSidebarPresentation.make(model: model)
    }

    func update(context: CmuxSidebarContext) {
        model.update(context: context)
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        model.connectionStatusDidChange(status)
    }

    func handlePresentationAction(_ id: String) async {
        await model.handlePresentationAction(id)
    }
}
