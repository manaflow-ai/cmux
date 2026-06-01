import CmuxExtensionKit
import Observation
import SwiftUI

@main
@Observable
public final class StubAgentSidebarExtension: @MainActor CmuxSidebarExtension {
    public static let manifest = CmuxExtensionManifest(
        id: "dev.example.stub-agent-sidebar",
        displayName: String(localized: "stubAgent.manifest.displayName", defaultValue: "Stub Agent Sidebar"),
        readScopes: [
            .workspaceList,
            .workspaceMetadata,
            .surfaceMetadata,
        ],
        actionScopes: [
            .createWorkspace,
            .selectWorkspace,
            .navigateWorkspace,
        ]
    )

    public private(set) var snapshot: CmuxSidebarSnapshot?
    @ObservationIgnored
    private var host: CmuxSidebarHost?

    public required init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(snapshot?.workspaces ?? []) { workspace in
                Button(workspace.title.isEmpty ? workspace.id.uuidString : workspace.title) {
                    Task { @MainActor in
                        try? await self.selectWorkspace(workspace.id)
                    }
                }
            }

            Button(String(localized: "stubAgent.createWorkspace", defaultValue: "Create Workspace")) {
                Task { @MainActor in
                    try? await self.createWorkspace()
                }
            }
        }
        .padding()
    }

    public func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
    }

    private func selectWorkspace(_ id: UUID) async throws {
        guard let host else { return }
        try await host.selectWorkspace(id)
    }

    private func createWorkspace() async throws {
        guard let host else { return }
        try await host.createWorkspace(
            title: String(localized: "stubAgent.createdWorkspaceTitle", defaultValue: "SDK Proof"),
            select: true
        )
    }
}
