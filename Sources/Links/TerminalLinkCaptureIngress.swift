import CmuxTerminalCore
import Foundation

/// Delivers captured links to the MainActor-owned workspace model.
@MainActor
final class TerminalLinkCaptureIngress {
    typealias WorkspaceResolver = @MainActor (_ preferredWorkspaceID: UUID, _ panelID: UUID?) -> Workspace?

    private let workspaceResolver: WorkspaceResolver

    init(workspaceResolver: @escaping WorkspaceResolver) {
        self.workspaceResolver = workspaceResolver
    }

    func ingest(
        _ links: [TerminalCapturedLink],
        workspaceID: UUID,
        sourcePanelId: UUID?,
        settings: LinkCaptureSettingsSnapshot
    ) {
        guard settings.enabled,
              !links.isEmpty,
              let workspace = workspaceResolver(workspaceID, sourcePanelId) else {
            return
        }
        let sourceTitle = sourcePanelId.flatMap { workspace.panelTitles[$0] }
        workspace.linksState.ingest(
            links,
            sourcePanelId: sourcePanelId,
            sourceSurfaceTitle: sourceTitle,
            configuration: settings.ingestConfiguration
        )
    }
}
