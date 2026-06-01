import CmuxExtensionKit
import Observation
import SwiftUI

@main
@Observable
@MainActor
public final class StubAgentSidebarExtension: CmuxSidebarExtension {
    public static let manifest = CMUXExtensionManifest(
        id: "dev.example.stub-agent-sidebar",
        displayName: String(localized: "stubAgent.manifest.displayName", defaultValue: "Stub Agent Sidebar"),
        requestedScopes: [
            .workspaceList,
            .workspaceMetadata,
            .surfaceMetadata,
        ],
        requestedActionScopes: [
            .createWorkspace,
            .selectWorkspace,
            .navigateWorkspace,
        ]
    )

    public private(set) var snapshot: CMUXSidebarSnapshot?
    private var host: CmuxSidebarHost?

    public required init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot?.workspaces ?? []) { workspace in
                Button(workspace.title.isEmpty ? workspace.id.uuidString : workspace.title) {
                    self.selectWorkspace(workspace.id)
                }
            }

            Button(String(localized: "stubAgent.createWorkspace", defaultValue: "Create Workspace")) {
                self.createWorkspace()
            }
        }
        .padding()
    }

    public func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
    }

    private func selectWorkspace(_ id: UUID) {
        guard let host else { return }
        Task { @MainActor in
            _ = await host.selectWorkspace(id)
        }
    }

    private func createWorkspace() {
        guard let host else { return }
        Task { @MainActor in
            _ = await host.createWorkspace(
                title: String(localized: "stubAgent.createdWorkspaceTitle", defaultValue: "SDK Proof"),
                select: true
            )
        }
    }
}
