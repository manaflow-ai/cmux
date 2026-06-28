import CmuxWorkspaces
import Foundation

/// App-side witness that flattens the live `Workspace` god state into the
/// `Sendable` value inputs the package-pure ``WorkspaceCreationInheritanceResolver``
/// consumes, fulfilling the ``WorkspaceCreationInheritanceReading`` seam.
///
/// The reads here are lifted one-for-one from the legacy
/// `TabManager.terminalPanelForWorkspaceConfigInheritanceSource` and
/// `TabManager.cachedInheritedTerminalFontPointsForNewWorkspace` bodies: the
/// remembered config-inheritance panel, every terminal panel sorted by
/// `id.uuidString`, each panel's live-surface flag, and the remembered terminal
/// font lineage.
extension Workspace: WorkspaceCreationInheritanceReading {
    var configInheritancePanelSource: WorkspaceConfigInheritancePanelSource {
        let orderedTerminalPanels = panels.values
            .compactMap { $0 as? TerminalPanel }
            .sorted(by: { $0.id.uuidString < $1.id.uuidString })
        var liveSurfacePanelIds: Set<UUID> = []
        for terminalPanel in orderedTerminalPanels
        where terminalPanel.surface.hasLiveSurface && terminalPanel.surface.surface != nil {
            liveSurfacePanelIds.insert(terminalPanel.id)
        }
        return WorkspaceConfigInheritancePanelSource(
            rememberedPanelId: lastRememberedTerminalPanelForConfigInheritance()?.id,
            orderedTerminalPanelIds: orderedTerminalPanels.map { $0.id },
            liveSurfacePanelIds: liveSurfacePanelIds
        )
    }

    var rememberedTerminalFontPointsForConfigInheritance: Float? {
        lastRememberedTerminalFontPointsForConfigInheritance()
    }
}
