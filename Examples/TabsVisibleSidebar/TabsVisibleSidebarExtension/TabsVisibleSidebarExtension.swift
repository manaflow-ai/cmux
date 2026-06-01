import CmuxExtensionKit
import Observation
import SwiftUI

@main
@Observable
@MainActor
final class TabsVisibleSidebarExtension: CmuxSidebarExtension {
    static let manifest = CMUXExtensionManifest(
        id: "co.manaflow.TabsVisibleSidebar.Extension",
        displayName: "Tabs Visible Sidebar",
        requestedScopes: [
            .workspaceList,
            .workspaceMetadata,
            .surfaceMetadata,
        ],
        requestedActionScopes: [
            .selectWorkspace,
            .selectSurface,
        ]
    )

    private(set) var snapshot: CMUXSidebarSnapshot?
    private(set) var errorText: String?
    var expandedWorkspaceIDs: Set<UUID> = []

    @ObservationIgnored
    private var host: CmuxSidebarHost?

    required init() {}

    var body: some View {
        TabsVisibleSidebarView(extensionModel: self)
    }

    func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
        errorText = nil

        if let selectedWorkspaceID = context.snapshot.selectedWorkspaceID {
            expandedWorkspaceIDs.insert(selectedWorkspaceID)
        }
    }

    func connectionErrorDidChange(_ message: String?) {
        errorText = message
    }

    func selectWorkspace(_ workspaceID: UUID) {
        guard let host else { return }
        expandedWorkspaceIDs.insert(workspaceID)
        Task { @MainActor in
            apply(await host.selectWorkspace(workspaceID))
        }
    }

    func selectSurface(workspaceID: UUID, surfaceID: UUID) {
        guard let host else { return }
        expandedWorkspaceIDs.insert(workspaceID)
        Task { @MainActor in
            apply(await host.selectSurface(workspaceID: workspaceID, surfaceID: surfaceID))
        }
    }

    private func apply(_ result: CMUXExtensionActionResult) {
        if result.accepted {
            errorText = nil
        } else {
            errorText = result.message ?? String(localized: "tabsVisible.actionDenied", defaultValue: "cmux did not allow that action")
        }
    }
}
