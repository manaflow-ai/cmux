import CmuxCommandPalette
import AppKit
import Foundation

extension ContentView {
    func identifierCopyCommandContributions(
        workspaceSubtitle: @escaping (CommandPaletteContextSnapshot) -> String,
        panelSubtitle: @escaping (CommandPaletteContextSnapshot) -> String
    ) -> [CommandPaletteCommandContribution] {
        CommandPaletteIdentifierCopyContributionProvider().build(
            strings: CommandPaletteIdentifierCopyContributionProvider.Strings(
                copyWorkspaceID: String(localized: "contextMenu.copyWorkspaceID", defaultValue: "Copy Workspace ID"),
                copyWorkspaceIDAndRef: String(localized: "command.copyWorkspaceIDAndRef.title", defaultValue: "Copy Workspace ID and Ref"),
                copyWorkspaceLink: String(localized: "command.copyWorkspaceLink.title", defaultValue: "Copy Workspace Link"),
                copyPaneID: String(localized: "command.copyPaneID.title", defaultValue: "Copy Pane ID"),
                copyPaneLink: String(localized: "command.copyPaneLink.title", defaultValue: "Copy Pane Link"),
                copySurfaceID: String(localized: "command.copySurfaceID.title", defaultValue: "Copy Surface ID"),
                copySurfaceLink: String(localized: "command.copySurfaceLink.title", defaultValue: "Copy Surface Link"),
                copyIdentifiers: String(localized: "terminalContextMenu.copyIdentifiers", defaultValue: "Copy IDs")
            ),
            workspaceSubtitle: workspaceSubtitle,
            panelSubtitle: panelSubtitle
        )
    }

    func registerIdentifierCopyCommandHandlers(_ registry: inout CommandPaletteHandlerRegistry) {
        registry.register(commandId: "palette.copyWorkspaceID") { copySelectedWorkspaceIdentifiers(includeRefs: false) }
        registry.register(commandId: "palette.copyWorkspaceIDAndRef") { copySelectedWorkspaceIdentifiers(includeRefs: true) }
        registry.register(commandId: "palette.copyWorkspaceLink") { copySelectedWorkspaceLink() }
        registry.register(commandId: "palette.copyPaneID") { copyFocusedPaneIdentifier() }
        registry.register(commandId: "palette.copyPaneLink") { copyFocusedPaneLink() }
        registry.register(commandId: "palette.copySurfaceID") { copyFocusedSurfaceIdentifier() }
        registry.register(commandId: "palette.copySurfaceLink") { copyFocusedSurfaceLink() }
        registry.register(commandId: "palette.copyIdentifiers") { copyFocusedWorkspacePaneSurfaceIdentifiers() }
    }

    private func copySelectedWorkspaceIdentifiers(includeRefs: Bool) {
        guard let workspaceId = tabManager.selectedWorkspace?.id else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds([workspaceId], includeRefs: includeRefs)
    }

    private func copySelectedWorkspaceLink() {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }
        // Links encode the restart-stable id so they survive an app relaunch.
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeWorkspaceLink(workspaceId: workspace.stableId)
        )
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

    private func copyFocusedPaneLink() {
        guard let panelContext = focusedPanelContext,
              let paneId = panelContext.workspace.paneId(forPanelId: panelContext.panelId)?.id else {
            NSSound.beep()
            return
        }
        // The workspace route is restart-stable; panes have no persisted
        // identity, so the pane segment stays session-scoped.
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makePaneLink(
                workspaceId: panelContext.workspace.stableId,
                paneId: paneId
            )
        )
    }

    private func copyFocusedSurfaceIdentifier() {
        guard let context = focusedPanelIdentifierContext() else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(WorkspaceSurfaceIdentifierClipboardText.makeSurface(surfaceId: context.surfaceId))
    }

    private func copyFocusedSurfaceLink() {
        guard let panelContext = focusedPanelContext else {
            NSSound.beep()
            return
        }
        // Links encode the restart-stable ids so they survive an app relaunch.
        WorkspaceSurfaceIdentifierClipboardText.copy(
            WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspaceId: panelContext.workspace.stableId,
                surfaceId: panelContext.panel.stableSurfaceId
            )
        )
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
