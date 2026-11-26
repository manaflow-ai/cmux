import CmuxCommandPalette
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
            (
                "palette.copyWorkspaceLink",
                String(localized: "command.copyWorkspaceLink.title", defaultValue: "Copy Workspace Link"),
                ["copy", "workspace", "link", "url", "deeplink", "deep link"]
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

        let panelCommands: [(
            id: String,
            title: String,
            keywords: [String],
            requiresPane: Bool,
            requiresDeepLinks: Bool
        )] = [
            (
                "palette.copyPaneID",
                String(localized: "command.copyPaneID.title", defaultValue: "Copy Pane ID"),
                ["copy", "pane", "split", "id", "identifier"],
                true,
                false
            ),
            (
                "palette.copyPaneLink",
                String(localized: "command.copyPaneLink.title", defaultValue: "Copy Pane Link"),
                ["copy", "pane", "split", "link", "url", "deeplink", "deep link"],
                true,
                true
            ),
            (
                "palette.copySurfaceID",
                String(localized: "command.copySurfaceID.title", defaultValue: "Copy Surface ID"),
                ["copy", "surface", "tab", "id", "identifier"],
                false,
                false
            ),
            (
                "palette.copySurfaceLink",
                String(localized: "command.copySurfaceLink.title", defaultValue: "Copy Surface Link"),
                ["copy", "surface", "tab", "link", "url", "deeplink", "deep link"],
                false,
                true
            ),
            (
                "palette.copyIdentifiers",
                String(localized: "terminalContextMenu.copyIdentifiers", defaultValue: "Copy IDs"),
                ["copy", "ids", "identifiers", "workspace", "pane", "surface", "ref", "reference"],
                false,
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
                    let hasRequiredPanel = command.requiresPane
                        ? $0.bool(CommandPaletteContextKeys.panelHasPane)
                        : $0.bool(CommandPaletteContextKeys.hasFocusedPanel)
                    return hasRequiredPanel && (
                        !command.requiresDeepLinks || $0.bool(
                            CommandPaletteContextKeys.panelSupportsDeepLinks
                        )
                    )
                }
            )
        }
    }

    func registerIdentifierCopyCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        dockTarget: BrowserActionTarget? = nil
    ) {
        registry.register(commandId: "palette.copyWorkspaceID") { copySelectedWorkspaceIdentifiers(includeRefs: false) }
        registry.register(commandId: "palette.copyWorkspaceIDAndRef") { copySelectedWorkspaceIdentifiers(includeRefs: true) }
        registry.register(commandId: "palette.copyWorkspaceLink") { copySelectedWorkspaceLink() }
        registry.register(commandId: "palette.copyPaneID") { copyFocusedPaneIdentifier(dockTarget: dockTarget) }
        registry.register(commandId: "palette.copyPaneLink") { copyFocusedPaneLink(dockTarget: dockTarget) }
        registry.register(commandId: "palette.copySurfaceID") { copyFocusedSurfaceIdentifier(dockTarget: dockTarget) }
        registry.register(commandId: "palette.copySurfaceLink") { copyFocusedSurfaceLink(dockTarget: dockTarget) }
        registry.register(commandId: "palette.copyIdentifiers") {
            copyFocusedWorkspacePaneSurfaceIdentifiers(
                dockTarget: dockTarget
            )
        }
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

    private func focusedPanelIdentifierContext(
        dockTarget: BrowserActionTarget? = nil
    ) -> (workspaceId: UUID, paneId: UUID?, surfaceId: UUID)? {
        if let dockTarget,
           let dock = AppDelegate.shared?.dock(
               resolving: dockTarget
           ),
           dock.panels[dockTarget.panelId] != nil {
            return (
                workspaceId: dock.workspaceId,
                paneId: dock.paneId(forPanelId: dockTarget.panelId)?.id,
                surfaceId: dockTarget.panelId
            )
        }
        guard let panelContext = focusedPanelContext else { return nil }
        return (
            workspaceId: panelContext.workspace.id,
            paneId: panelContext.workspace.paneId(forPanelId: panelContext.panelId)?.id,
            surfaceId: panelContext.panelId
        )
    }

    private func copyFocusedPaneIdentifier(
        dockTarget: BrowserActionTarget? = nil
    ) {
        guard let paneId = focusedPanelIdentifierContext(
            dockTarget: dockTarget
        )?.paneId else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(WorkspaceSurfaceIdentifierClipboardText.makePane(paneId: paneId))
    }

    private func copyFocusedPaneLink(
        dockTarget: BrowserActionTarget? = nil
    ) {
        if dockTarget != nil {
            NSSound.beep()
            return
        }
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

    private func copyFocusedSurfaceIdentifier(
        dockTarget: BrowserActionTarget? = nil
    ) {
        guard let context = focusedPanelIdentifierContext(
            dockTarget: dockTarget
        ) else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(WorkspaceSurfaceIdentifierClipboardText.makeSurface(surfaceId: context.surfaceId))
    }

    private func copyFocusedSurfaceLink(
        dockTarget: BrowserActionTarget? = nil
    ) {
        if dockTarget != nil {
            NSSound.beep()
            return
        }
        guard let panelContext = focusedPanelContext,
              let link = WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                workspace: panelContext.workspace,
                panelId: panelContext.panelId
              ) else {
            NSSound.beep()
            return
        }
        WorkspaceSurfaceIdentifierClipboardText.copy(link)
    }

    private func copyFocusedWorkspacePaneSurfaceIdentifiers(
        dockTarget: BrowserActionTarget? = nil
    ) {
        guard let context = focusedPanelIdentifierContext(
            dockTarget: dockTarget
        ) else {
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
