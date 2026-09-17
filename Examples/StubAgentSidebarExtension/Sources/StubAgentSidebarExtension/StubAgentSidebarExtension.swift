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
    public private(set) var errorText: String?

    @ObservationIgnored
    private var host: CmuxSidebarHost?

    public required init() {}

    public var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ForEach(snapshot?.workspaces ?? []) { workspace in
                Button(workspace.title.isEmpty ? workspace.id.uuidString : workspace.title) {
                    Task { @MainActor in
                        await self.apply { try await self.selectWorkspace(workspace.id) }
                    }
                }
            }

            Button(String(localized: "stubAgent.createWorkspace", defaultValue: "Create Workspace")) {
                Task { @MainActor in
                    await self.apply { try await self.createWorkspace() }
                }
            }
        }
        .padding()
    }

    public func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
        errorText = nil
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

    private func apply(_ operation: () async throws -> Void) async {
        do {
            try await operation()
            errorText = nil
        } catch CmuxSidebarActionError.rejected(let message) {
            errorText = message
        } catch CmuxSidebarActionError.cancelled {
            errorText = nil
        } catch {
            errorText = String(localized: "stubAgent.actionDenied", defaultValue: "cmux did not allow that action")
        }
    }
}
