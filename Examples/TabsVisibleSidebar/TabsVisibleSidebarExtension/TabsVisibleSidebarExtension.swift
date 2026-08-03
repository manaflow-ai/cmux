import CmuxExtensionKit
import Foundation
import Observation

@main
@Observable
final class TabsVisibleSidebarExtension: @MainActor CmuxSidebarExtension {
    static let manifest = CmuxExtensionManifest(
        id: "co.manaflow.TabsVisibleSidebar.Extension",
        displayName: String(localized: "tabsVisible.manifest.displayName", defaultValue: "Tabs Visible Sidebar"),
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

    private(set) var snapshot: CmuxSidebarSnapshot?
    private(set) var errorText: String?
    var expandedWorkspaceIDs: Set<UUID> = []

    @ObservationIgnored
    private var host: CmuxSidebarHost?

    required init() {}

    var presentation: CmuxSidebarPresentation {
        TabsVisibleSidebarPresentation.make(
            snapshot: snapshot,
            errorText: errorText,
            expandedWorkspaceIDs: expandedWorkspaceIDs
        )
    }

    func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
        errorText = nil

        if let selectedWorkspaceID = context.snapshot.selectedWorkspaceID {
            expandedWorkspaceIDs.insert(selectedWorkspaceID)
        }
    }

    func connectionStatusDidChange(_ status: CmuxSidebarConnectionStatus) {
        switch status {
        case .connected:
            errorText = nil
        case .waitingForHost:
            errorText = String(localized: "tabsVisible.waitingForHost", defaultValue: "Waiting for cmux")
        case .error(let message):
            errorText = message
        }
    }

    func handlePresentationAction(_ id: String) async {
        let components = id.split(separator: ":", omittingEmptySubsequences: false)
        guard let kind = components.first else { return }
        switch kind {
        case "toggle" where components.count == 2:
            guard let workspaceID = UUID(uuidString: String(components[1])) else { return }
            if expandedWorkspaceIDs.contains(workspaceID) {
                expandedWorkspaceIDs.remove(workspaceID)
            } else {
                expandedWorkspaceIDs.insert(workspaceID)
            }
        case "workspace" where components.count == 2:
            guard let workspaceID = UUID(uuidString: String(components[1])) else { return }
            await selectWorkspace(workspaceID)
        case "surface" where components.count == 3:
            guard let workspaceID = UUID(uuidString: String(components[1])),
                  let surfaceID = UUID(uuidString: String(components[2])) else { return }
            await selectSurface(workspaceID: workspaceID, surfaceID: surfaceID)
        default:
            return
        }
    }

    private func selectWorkspace(_ workspaceID: UUID) async {
        guard let host else { return }
        expandedWorkspaceIDs.insert(workspaceID)
        await apply { try await host.selectWorkspace(workspaceID) }
    }

    private func selectSurface(workspaceID: UUID, surfaceID: UUID) async {
        guard let host else { return }
        expandedWorkspaceIDs.insert(workspaceID)
        await apply { try await host.selectSurface(workspaceID: workspaceID, surfaceID: surfaceID) }
    }

    private func apply(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            errorText = nil
        } catch CmuxSidebarActionError.rejected(let message) {
            errorText = message
        } catch {
            errorText = String(localized: "tabsVisible.actionDenied", defaultValue: "cmux did not allow that action")
        }
    }
}
