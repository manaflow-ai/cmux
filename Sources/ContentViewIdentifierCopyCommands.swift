import CmuxCommandPalette
import AppKit
import Foundation

extension ContentView {
    static func identifierCopyExecutionResult(
        didWrite: Bool
    ) -> CmuxActionExecutionResult {
        didWrite
            ? .completed
            : .failed(
                code: "clipboard_write_failed",
                message: String(
                    localized: "action.error.identifierCopyFailed",
                    defaultValue: "The identifiers could not be copied."
                )
            )
    }

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

        let panelCommands: [(id: String, title: String, keywords: [String], requiresPane: Bool)] = [
            (
                "palette.copyPaneID",
                String(localized: "command.copyPaneID.title", defaultValue: "Copy Pane ID"),
                ["copy", "pane", "split", "id", "identifier"],
                true
            ),
            (
                "palette.copyPaneLink",
                String(localized: "command.copyPaneLink.title", defaultValue: "Copy Pane Link"),
                ["copy", "pane", "split", "link", "url", "deeplink", "deep link"],
                true
            ),
            (
                "palette.copySurfaceID",
                String(localized: "command.copySurfaceID.title", defaultValue: "Copy Surface ID"),
                ["copy", "surface", "tab", "id", "identifier"],
                false
            ),
            (
                "palette.copySurfaceLink",
                String(localized: "command.copySurfaceLink.title", defaultValue: "Copy Surface Link"),
                ["copy", "surface", "tab", "link", "url", "deeplink", "deep link"],
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

    func registerIdentifierCopyCommandHandlers(
        _ registry: inout CommandPaletteHandlerRegistry,
        context: CommandPaletteActionContext,
        pasteboard: NSPasteboard = .general
    ) {
        registry.register(commandId: "palette.copyWorkspaceID") { invocation in
            copySelectedWorkspaceIdentifiers(
                context: context,
                includeRefs: false,
                pasteboard: pasteboard,
                invocation: invocation
            )
        }
        registry.register(commandId: "palette.copyWorkspaceIDAndRef") { invocation in
            copySelectedWorkspaceIdentifiers(
                context: context,
                includeRefs: true,
                pasteboard: pasteboard,
                invocation: invocation
            )
        }
        registry.register(commandId: "palette.copyWorkspaceLink") { invocation in
            copySelectedWorkspaceLink(
                context: context,
                pasteboard: pasteboard,
                invocation: invocation
            )
        }
        registry.register(commandId: "palette.copyPaneID") { invocation in
            copyFocusedPaneIdentifier(
                context: context,
                pasteboard: pasteboard,
                invocation: invocation
            )
        }
        registry.register(commandId: "palette.copyPaneLink") { invocation in
            copyFocusedPaneLink(
                context: context,
                pasteboard: pasteboard,
                invocation: invocation
            )
        }
        registry.register(commandId: "palette.copySurfaceID") { invocation in
            copyFocusedSurfaceIdentifier(
                context: context,
                pasteboard: pasteboard,
                invocation: invocation
            )
        }
        registry.register(commandId: "palette.copySurfaceLink") { invocation in
            copyFocusedSurfaceLink(
                context: context,
                pasteboard: pasteboard,
                invocation: invocation
            )
        }
        registry.register(commandId: "palette.copyIdentifiers") { invocation in
            copyFocusedWorkspacePaneSurfaceIdentifiers(
                context: context,
                pasteboard: pasteboard,
                invocation: invocation
            )
        }
    }

    private func copySelectedWorkspaceIdentifiers(
        context: CommandPaletteActionContext,
        includeRefs: Bool,
        pasteboard: NSPasteboard,
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult {
        guard let workspaceId = identifierCopyWorkspace(context: context)?.id else {
            return identifierCopyTargetUnavailable(invocation: invocation)
        }
        return identifierCopyResult(
            didWrite: WorkspaceSurfaceIdentifierClipboardText.copyWorkspaceIds(
                [workspaceId],
                includeRefs: includeRefs,
                to: pasteboard
            ),
            invocation: invocation
        )
    }

    private func copySelectedWorkspaceLink(
        context: CommandPaletteActionContext,
        pasteboard: NSPasteboard,
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult {
        guard let workspace = identifierCopyWorkspace(context: context) else {
            return identifierCopyTargetUnavailable(invocation: invocation)
        }
        // Links encode the restart-stable id so they survive an app relaunch.
        return identifierCopyResult(
            didWrite: WorkspaceSurfaceIdentifierClipboardText.copy(
                WorkspaceSurfaceIdentifierClipboardText.makeWorkspaceLink(workspaceId: workspace.stableId),
                to: pasteboard
            ),
            invocation: invocation
        )
    }

    private func focusedPanelIdentifierContext(
        context: CommandPaletteActionContext
    ) -> (workspaceId: UUID, paneId: UUID?, surfaceId: UUID)? {
        guard let (workspace, panelID, _) = context.panel() else { return nil }
        return (
            workspaceId: workspace.id,
            paneId: workspace.paneId(forPanelId: panelID)?.id,
            surfaceId: panelID
        )
    }

    private func identifierCopyWorkspace(
        context: CommandPaletteActionContext
    ) -> Workspace? {
        guard context.target.windowID == windowId,
              context.owningWindowID == windowId,
              let workspace = context.workspace() else {
            return nil
        }
        if context.target.panelID != nil, context.panel() == nil {
            return nil
        }
        return workspace
    }

    private func copyFocusedPaneIdentifier(
        context: CommandPaletteActionContext,
        pasteboard: NSPasteboard,
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult {
        guard context.target.windowID == windowId,
              context.owningWindowID == windowId,
              let paneId = focusedPanelIdentifierContext(context: context)?.paneId else {
            return identifierCopyTargetUnavailable(invocation: invocation)
        }
        return identifierCopyResult(
            didWrite: WorkspaceSurfaceIdentifierClipboardText.copy(
                WorkspaceSurfaceIdentifierClipboardText.makePane(paneId: paneId),
                to: pasteboard
            ),
            invocation: invocation
        )
    }

    private func copyFocusedPaneLink(
        context: CommandPaletteActionContext,
        pasteboard: NSPasteboard,
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult {
        guard context.target.windowID == windowId,
              context.owningWindowID == windowId,
              let (workspace, panelID, _) = context.panel(),
              let paneId = workspace.paneId(forPanelId: panelID)?.id else {
            return identifierCopyTargetUnavailable(invocation: invocation)
        }
        // The workspace route is restart-stable; panes have no persisted
        // identity, so the pane segment stays session-scoped.
        return identifierCopyResult(
            didWrite: WorkspaceSurfaceIdentifierClipboardText.copy(
                WorkspaceSurfaceIdentifierClipboardText.makePaneLink(
                    workspaceId: workspace.stableId,
                    paneId: paneId
                ),
                to: pasteboard
            ),
            invocation: invocation
        )
    }

    private func copyFocusedSurfaceIdentifier(
        context: CommandPaletteActionContext,
        pasteboard: NSPasteboard,
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult {
        guard context.target.windowID == windowId,
              context.owningWindowID == windowId,
              let context = focusedPanelIdentifierContext(context: context) else {
            return identifierCopyTargetUnavailable(invocation: invocation)
        }
        return identifierCopyResult(
            didWrite: WorkspaceSurfaceIdentifierClipboardText.copy(
                WorkspaceSurfaceIdentifierClipboardText.makeSurface(surfaceId: context.surfaceId),
                to: pasteboard
            ),
            invocation: invocation
        )
    }

    private func copyFocusedSurfaceLink(
        context: CommandPaletteActionContext,
        pasteboard: NSPasteboard,
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult {
        guard context.target.windowID == windowId,
              context.owningWindowID == windowId,
              let (workspace, _, panel) = context.panel() else {
            return identifierCopyTargetUnavailable(invocation: invocation)
        }
        // Links encode the restart-stable ids so they survive an app relaunch.
        return identifierCopyResult(
            didWrite: WorkspaceSurfaceIdentifierClipboardText.copy(
                WorkspaceSurfaceIdentifierClipboardText.makeSurfaceLink(
                    workspaceId: workspace.stableId,
                    surfaceId: panel.stableSurfaceId
                ),
                to: pasteboard
            ),
            invocation: invocation
        )
    }

    private func copyFocusedWorkspacePaneSurfaceIdentifiers(
        context: CommandPaletteActionContext,
        pasteboard: NSPasteboard,
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult {
        guard context.target.windowID == windowId,
              context.owningWindowID == windowId,
              let context = focusedPanelIdentifierContext(context: context) else {
            return identifierCopyTargetUnavailable(invocation: invocation)
        }
        return identifierCopyResult(
            didWrite: WorkspaceSurfaceIdentifierClipboardText.copy(
                WorkspaceSurfaceIdentifierClipboardText.makeWorkspacePaneSurfaceIdentifiers(
                    workspaceId: context.workspaceId,
                    paneId: context.paneId,
                    surfaceId: context.surfaceId,
                    includeRefs: true
                ),
                to: pasteboard
            ),
            invocation: invocation
        )
    }

    private func identifierCopyTargetUnavailable(
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult {
        if invocation.source == .commandPalette {
            NSSound.beep()
        }
        return .targetUnavailable
    }

    private func identifierCopyResult(
        didWrite: Bool,
        invocation: CmuxActionInvocation
    ) -> CmuxActionExecutionResult {
        let result = Self.identifierCopyExecutionResult(didWrite: didWrite)
        if !didWrite {
            if invocation.source == .commandPalette {
                NSSound.beep()
            }
        }
        return result
    }
}
