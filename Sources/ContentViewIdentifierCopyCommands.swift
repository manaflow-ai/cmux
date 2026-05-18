import AppKit
import Foundation

extension ContentView {
    func appendIdentifierCopyCommandContributions(
        to contributions: inout [CommandPaletteCommandContribution],
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        panelSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) {
        func constant(_ value: String) -> (CommandPaletteContextSnapshot) -> String {
            { _ in value }
        }

        let workspaceCommands: [(id: String, title: String, keywords: [String])] = [
            (
                "palette.copyWorkspaceID",
                String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
                ["copy", "workspace", "id", "identifier"]
            ),
            (
                "palette.copyWorkspaceIDAndRef",
                String(localized: "command.copyWorkspaceIDAndRef.title", defaultValue: "Copy Workspace ID and Ref"),
                ["copy", "workspace", "id", "identifier", "ref", "reference"]
            ),
        ]
        contributions += workspaceCommands.map { command in
            CommandPaletteCommandContribution(
                commandId: command.id,
                title: constant(command.title),
                subtitle: workspaceSubtitle,
                keywords: command.keywords,
                when: { $0.bool(CommandPaletteContextKeys.hasWorkspace) }
            )
        }

        let panelCommands: [(id: String, title: String, keywords: [String], requiresPane: Bool)] = [
            (
                "palette.copyPaneID",
                String(localized: "command.copyPaneID.title", defaultValue: "Copy Pane ID"),
                ["copy", "pane", "split", "id", "identifier"],
                true
            ),
            (
                "palette.copySurfaceID",
                String(localized: "command.copySurfaceID.title", defaultValue: "Copy Surface ID"),
                ["copy", "surface", "tab", "id", "identifier"],
                false
            ),
            (
                "palette.copyIdentifiers",
                String(localized: "terminalContextMenu.copyIdentifiers", defaultValue: "Copy IDs"),
                ["copy", "ids", "identifiers", "workspace", "pane", "surface", "ref", "reference"],
                false
            ),
        ]
        contributions += panelCommands.map { command in
            CommandPaletteCommandContribution(
                commandId: command.id,
                title: constant(command.title),
                subtitle: panelSubtitle,
                keywords: command.keywords,
                when: {
                    command.requiresPane
                        ? $0.bool(CommandPaletteContextKeys.panelHasPane)
                        : $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                }
            )
        }
    }

    func registerIdentifierCopyCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.copyWorkspaceID") { copySelectedWorkspaceIdentifiers(includeRefs: false) }
        registry.register(commandId: "palette.copyWorkspaceIDAndRef") { copySelectedWorkspaceIdentifiers(includeRefs: true) }
        registry.register(commandId: "palette.copyPaneID") { copyFocusedPaneIdentifier() }
        registry.register(commandId: "palette.copySurfaceID") { copyFocusedSurfaceIdentifier() }
        registry.register(commandId: "palette.copyIdentifiers") { copyFocusedWorkspacePaneSurfaceIdentifiers() }
    }

    private func copySelectedWorkspaceIdentifiers(includeRefs: Bool) {
        guard let workspaceId = tabManager.selectedWorkspace?.id else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds([workspaceId], includeRefs: includeRefs)
    }

    private func focusedPanelIdentifierContext() -> (workspaceId: UUID, paneId: UUID?, surfaceId: UUID)? {
        guard let panelContext = focusedPanelContext else { return nil }
        return (
            workspaceId: panelContext.workspace.id,
            paneId: panelContext.workspace.paneId(forPanelId: panelContext.panelId)?.id,
            surfaceId: panelContext.panelId
        )
    }

    private func copyFocusedPaneIdentifier() {
        guard let paneId = focusedPanelIdentifierContext()?.paneId else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(WorkspaceSurfaceIdentifierClipboardText.makePane(paneId: paneId))
    }

    private func copyFocusedSurfaceIdentifier() {
        guard let context = focusedPanelIdentifierContext() else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(WorkspaceSurfaceIdentifierClipboardText.makeSurface(surfaceId: context.surfaceId))
    }

    private func copyFocusedWorkspacePaneSurfaceIdentifiers() {
        guard let context = focusedPanelIdentifierContext() else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                workspaceId: context.workspaceId,
                paneId: context.paneId,
                surfaceId: context.surfaceId,
                includeRefs: true
            )
        )
    }
}
