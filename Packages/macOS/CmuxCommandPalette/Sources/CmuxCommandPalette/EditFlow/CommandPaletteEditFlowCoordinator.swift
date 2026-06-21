import Foundation

/// `@MainActor` orchestrator for the command palette's two name-editing flows:
/// the workspace/tab rename flow and the workspace-description flow.
///
/// The rename flow has three entry points (rename the selected workspace,
/// rename the focused tab, and the two "open + begin" palette commands) and two
/// state transitions (seed the editor and enter ``CommandPaletteMode/renameInput(_:)``,
/// then validate and apply the proposed name). The workspace-description flow
/// has the same shape on its seed side (begin from the selected workspace or the
/// "open + begin" command, then seed the editor and enter
/// ``CommandPaletteMode/workspaceDescriptionInput(_:)``). This coordinator owns
/// that logic against the package's ``CommandPalettePresentationModel``; every
/// app-target read or write (workspace lookup, title mutation, focus reset,
/// debug-state sync, present, dismiss, beep, DEBUG log) is reached through a
/// ``CommandPaletteEditFlowHost`` passed per call.
///
/// The workspace-description *apply* step stays app-side (it reads the live tab
/// model back for its DEBUG log and formats it through the app/UI debug helpers),
/// so it is not routed through this coordinator; only the begin/open/seed
/// transitions, which mutate the package presentation model, live here.
///
/// ## Isolation
///
/// Every mutator and reader of these flows runs on the main actor (palette
/// commands, the submit handler, and SwiftUI-driven keyboard handling all hop to
/// main), so the coordinator is `@MainActor`. It does no I/O.
///
/// ## Faithful lift
///
/// The seed/validate/apply sequence, the empty-name normalization
/// (`trimmingCharacters(in: .whitespacesAndNewlines)`, empty becomes `nil`), the
/// beep-and-abort guards, the ordering of focus-reset relative to the mode
/// change, and the workspace-description DEBUG log lines and their position
/// relative to the focus reset and debug-state sync reproduce the legacy in-host
/// code byte-for-byte. The host stays a per-call parameter, not stored,
/// mirroring the palette's other coordinators.
@MainActor
public struct CommandPaletteEditFlowCoordinator {
    /// Creates an edit-flow coordinator.
    public init() {}

    // MARK: Rename flow

    /// Begins renaming the host's selected workspace, beeping if none exists.
    public func beginRenameWorkspace(
        host: some CommandPaletteEditFlowHost,
        presentation: CommandPalettePresentationModel
    ) {
        guard let target = host.commandPaletteEditFlowSelectedWorkspaceRenameTarget() else {
            host.commandPaletteEditFlowBeep()
            return
        }
        startRename(target, host: host, presentation: presentation)
    }

    /// Begins renaming the host's focused tab, beeping if none is focused.
    public func beginRenameTab(
        host: some CommandPaletteEditFlowHost,
        presentation: CommandPalettePresentationModel
    ) {
        guard let target = host.commandPaletteEditFlowFocusedTabRenameTarget() else {
            host.commandPaletteEditFlowBeep()
            return
        }
        startRename(target, host: host, presentation: presentation)
    }

    /// Presents the palette if needed, then begins renaming the focused tab.
    public func openRenameTabInput(
        host: some CommandPaletteEditFlowHost,
        presentation: CommandPalettePresentationModel
    ) {
        if !host.commandPaletteEditFlowIsPresented {
            host.commandPaletteEditFlowPresent()
        }
        beginRenameTab(host: host, presentation: presentation)
    }

    /// Presents the palette if needed, then begins renaming the selected
    /// workspace.
    public func openRenameWorkspaceInput(
        host: some CommandPaletteEditFlowHost,
        presentation: CommandPalettePresentationModel
    ) {
        if !host.commandPaletteEditFlowIsPresented {
            host.commandPaletteEditFlowPresent()
        }
        beginRenameWorkspace(host: host, presentation: presentation)
    }

    /// Seeds the rename editor with the target's current name and enters the
    /// rename-input mode, then resets focus to the rename editor.
    public func startRename(
        _ target: CommandPaletteRenameTarget,
        host: some CommandPaletteEditFlowHost,
        presentation: CommandPalettePresentationModel
    ) {
        presentation.renameDraft = target.currentName
        host.commandPaletteEditFlowSetShouldFocusWorkspaceDescriptionEditor(false)
        presentation.mode = .renameInput(target)
        host.commandPaletteEditFlowResetRenameFocus()
        host.commandPaletteEditFlowSyncDebugState()
    }

    /// Applies the current rename draft if the palette is still in the rename
    /// input mode for `target`.
    public func continueRename(
        target: CommandPaletteRenameTarget,
        host: some CommandPaletteEditFlowHost,
        presentation: CommandPalettePresentationModel
    ) {
        guard case .renameInput(let activeTarget) = presentation.mode,
              activeTarget == target else { return }
        applyRename(target: target, proposedName: presentation.renameDraft, host: host, presentation: presentation)
    }

    /// Validates `proposedName`, applies the rename to the workspace or tab, and
    /// dismisses the palette. An empty (after trimming) name clears the custom
    /// title.
    public func applyRename(
        target: CommandPaletteRenameTarget,
        proposedName: String,
        host: some CommandPaletteEditFlowHost,
        presentation: CommandPalettePresentationModel
    ) {
        let trimmedName = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedName: String? = trimmedName.isEmpty ? nil : trimmedName

        switch target.kind {
        case .workspace(let workspaceId):
            host.commandPaletteEditFlowSetWorkspaceTitle(workspaceId: workspaceId, title: normalizedName)
        case .tab(let workspaceId, let panelId):
            guard host.commandPaletteEditFlowSetTabTitle(
                workspaceId: workspaceId,
                panelId: panelId,
                title: normalizedName
            ) else {
                host.commandPaletteEditFlowBeep()
                return
            }
        }

        host.commandPaletteEditFlowDismiss()
    }

    // MARK: Workspace-description flow

    /// Begins editing the host's selected workspace's description, beeping if no
    /// workspace is selected.
    public func beginWorkspaceDescription(
        host: some CommandPaletteEditFlowHost,
        presentation: CommandPalettePresentationModel
    ) {
        guard let target = host.commandPaletteEditFlowSelectedWorkspaceDescriptionTarget() else {
            host.commandPaletteEditFlowBeep()
            return
        }
        startWorkspaceDescription(target, host: host, presentation: presentation)
    }

    /// Presents the palette if needed, then begins editing the selected
    /// workspace's description.
    ///
    /// The open-flow's bracketing DEBUG `open begin`/`open end` log lines stay in
    /// the app forward (they read the app/UI window-debug summary), so this method
    /// owns only the present-guard and the begin call.
    public func openWorkspaceDescriptionInput(
        host: some CommandPaletteEditFlowHost,
        presentation: CommandPalettePresentationModel
    ) {
        if !host.commandPaletteEditFlowIsPresented {
            host.commandPaletteEditFlowPresent()
        }
        beginWorkspaceDescription(host: host, presentation: presentation)
    }

    /// Seeds the workspace-description editor with the target's current
    /// description and enters the description-input mode, then resets focus to
    /// the description editor and syncs the per-window debug state.
    public func startWorkspaceDescription(
        _ target: CommandPaletteWorkspaceDescriptionTarget,
        host: some CommandPaletteEditFlowHost,
        presentation: CommandPalettePresentationModel
    ) {
        host.commandPaletteEditFlowDebugLog(
            "palette.wsDescription.flow.start workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "descLen=\((target.currentDescription as NSString).length) " +
            "presented=\(host.commandPaletteEditFlowIsPresented ? 1 : 0) " +
            "modeBefore=\(presentation.mode.debugModeLabel)"
        )
        presentation.workspaceDescriptionDraft = target.currentDescription
        presentation.workspaceDescriptionHeight = host.commandPaletteEditFlowDefaultWorkspaceDescriptionHeight
        presentation.pendingTextSelectionBehavior = nil
        presentation.mode = .workspaceDescriptionInput(target)
        host.commandPaletteEditFlowResetWorkspaceDescriptionFocus()
        host.commandPaletteEditFlowDebugLog(
            "palette.wsDescription.flow.armed workspace=\(target.workspaceId.uuidString.prefix(8)) " +
            "height=\(String(format: "%.1f", presentation.workspaceDescriptionHeight)) " +
            "modeAfter=\(presentation.mode.debugModeLabel)"
        )
        host.commandPaletteEditFlowSyncDebugState()
    }
}
