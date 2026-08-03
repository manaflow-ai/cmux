import CmuxExtensionKit
import Foundation
import Observation

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

    public var presentation: CmuxSidebarPresentation {
        var children: [CmuxSidebarPresentationNode] = []
        if let errorText {
            children.append(.panel(.text(errorText, style: .secondary)))
        }
        children.append(contentsOf: (snapshot?.workspaces ?? []).map { workspace in
            .button(
                CmuxSidebarPresentationButton(
                    id: "workspace:\(workspace.id.uuidString)",
                    title: workspace.title.isEmpty ? workspace.id.uuidString : workspace.title,
                    systemImageName: "folder"
                )
            )
        })
        children.append(
            .button(
                CmuxSidebarPresentationButton(
                    id: "create",
                    title: String(localized: "stubAgent.createWorkspace", defaultValue: "Create Workspace"),
                    systemImageName: "plus"
                )
            )
        )
        return CmuxSidebarPresentation(
            root: .inset(
                .all(12),
                .stack(axis: .vertical, spacing: 8, children: children)
            )
        )
    }

    public func update(context: CmuxSidebarContext) {
        snapshot = context.snapshot
        host = context.host
        errorText = nil
    }

    public func handlePresentationAction(_ id: String) async {
        if id == "create" {
            await apply { try await createWorkspace() }
            return
        }
        guard id.hasPrefix("workspace:"),
              let workspaceID = UUID(uuidString: String(id.dropFirst("workspace:".count))) else { return }
        await apply { try await selectWorkspace(workspaceID) }
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
