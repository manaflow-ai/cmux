import CmuxTerminalCore
import Foundation

/// Delivers captured links to the MainActor-owned workspace model.
@MainActor
final class TerminalLinkCaptureIngress {
    typealias WorkspaceResolver = @MainActor (UUID) -> Workspace?

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
              let workspace = workspaceResolver(workspaceID) else {
            return
        }
        let sourceTitle = sourcePanelId.flatMap { workspace.panelTitles[$0] }
        for link in links {
            workspace.linksState.ingest(
                url: link.url,
                origin: WorkspaceCapturedLinkOrigin(link.source),
                sourcePanelId: sourcePanelId,
                sourceSurfaceTitle: sourceTitle,
                configuration: settings.ingestConfiguration
            )
        }
    }
}
