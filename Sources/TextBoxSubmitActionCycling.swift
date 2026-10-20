import SwiftUI

extension TextBoxInputContainer {
    func cycleSubmitAction() {
        let currentShouldForceTextEntrySubmit = refreshedShouldForceTextEntrySubmitAfterAgentPrune()
        guard Self.allowsSubmitActionSelection(
            pendingProviderLaunchAction: pendingProviderLaunchAction,
            shouldForceTextEntrySubmit: currentShouldForceTextEntrySubmit
        ) else {
            return
        }
        guard let nextID = Self.nextCycledSubmitActionID(
            defaultSubmitActionID: effectiveSubmitActionID,
            submitActions: submitActions,
            shouldForceTextEntrySubmit: currentShouldForceTextEntrySubmit
        ) else {
            return
        }
        onSelectSubmitAction(nextID)
    }

    private func refreshedShouldForceTextEntrySubmitAfterAgentPrune() -> Bool {
        guard let workspace = surface.owningWorkspace() else {
            return shouldForceTextEntrySubmit
        }
        workspace.clearStaleAgentPIDs(panelId: surface.id, refreshPorts: true)
        let refreshedContext = workspace.terminalPanel(for: surface.id).map {
            WorkspaceContentView.terminalAgentContext(panel: $0, workspace: workspace)
        } ?? terminalAgentContext
        return Self.shouldForceTextEntrySubmit(
            allowsCommandTemplateSubmit: allowsCommandTemplateSubmit,
            terminalAgentContext: refreshedContext
        )
    }
}
