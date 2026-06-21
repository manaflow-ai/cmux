public import Foundation

/// Read-and-act seam the host fills so ``CommandPaletteEditFlowCoordinator`` can
/// drive the command palette's rename and workspace-description flows without
/// importing any app-target workspace, tab, or window type.
///
/// The coordinator owns each flow's state transitions on the
/// ``CommandPalettePresentationModel`` (which draft to seed, which
/// ``CommandPaletteMode`` to enter, when to dismiss). Everything that requires
/// the host's concrete workspace/tab model, AppKit, app `@State`, or the
/// app/UI-package DEBUG helpers stays on the conformer side and is reached
/// through this protocol:
///
/// - Resolving a rename target for the selected workspace or the focused tab,
///   and the description target for the selected workspace (the host performs
///   the lookup and computes the display text).
/// - Emitting the system beep when there is nothing to rename or describe.
/// - Mutating the workspace title, tab title, and the per-window "should focus
///   the workspace-description editor" flag.
/// - Resetting the rename or description input focus, synchronizing the
///   per-window debug state, presenting the palette, and dismissing it.
/// - Supplying the default workspace-description editor height, the window debug
///   summary, and the DEBUG log sink, all of which live in the app/UI target.
///
/// Mirroring the package's other palette seams, the host is a value-typed
/// SwiftUI `View` that is reconstructed every render, so the coordinator never
/// stores it: each driving method takes the current host.
@MainActor
public protocol CommandPaletteEditFlowHost {
    /// Whether the command palette is currently presented in the host window.
    var commandPaletteEditFlowIsPresented: Bool { get }

    /// The default initial height for the workspace-description editor, owned by
    /// the app/UI target's multiline text editor representable.
    var commandPaletteEditFlowDefaultWorkspaceDescriptionHeight: CGFloat { get }

    /// Resolves the rename target for the host's selected workspace, or `nil`
    /// when there is no selected workspace. The host performs the lookup and
    /// computes the workspace's current display name.
    func commandPaletteEditFlowSelectedWorkspaceRenameTarget() -> CommandPaletteRenameTarget?

    /// Resolves the rename target for the host's focused tab, or `nil` when
    /// there is no focused panel. The host performs the lookup and computes the
    /// tab's current display name.
    func commandPaletteEditFlowFocusedTabRenameTarget() -> CommandPaletteRenameTarget?

    /// Resolves the description target for the host's selected workspace, or
    /// `nil` when there is no selected workspace. The host performs the lookup
    /// and reads the workspace's current custom description.
    func commandPaletteEditFlowSelectedWorkspaceDescriptionTarget() -> CommandPaletteWorkspaceDescriptionTarget?

    /// Emits the system beep used when a flow cannot start.
    func commandPaletteEditFlowBeep()

    /// Sets the host's per-window "should focus the workspace-description editor"
    /// flag. The rename flow clears it so the rename editor takes focus.
    func commandPaletteEditFlowSetShouldFocusWorkspaceDescriptionEditor(_ shouldFocus: Bool)

    /// Resets the palette input focus to the rename editor, applying the host's
    /// configured rename-input focus policy.
    func commandPaletteEditFlowResetRenameFocus()

    /// Resets the palette input focus to the workspace-description editor,
    /// applying the host's configured description-input focus policy.
    func commandPaletteEditFlowResetWorkspaceDescriptionFocus()

    /// Synchronizes the per-window palette debug state for the observed window.
    func commandPaletteEditFlowSyncDebugState()

    /// Presents the command palette seeded with the commands-list initial query.
    /// Called by the open-rename and open-description entry points when the
    /// palette is not presented.
    func commandPaletteEditFlowPresent()

    /// Dismisses the command palette, restoring focus to the prior responder.
    func commandPaletteEditFlowDismiss()

    /// Applies a workspace title rename. `title` is `nil` to clear the custom
    /// title and fall back to the generated name.
    func commandPaletteEditFlowSetWorkspaceTitle(workspaceId: UUID, title: String?)

    /// Applies a tab title rename. Returns `false` when the workspace no longer
    /// exists, so the coordinator can beep and abort exactly as before.
    func commandPaletteEditFlowSetTabTitle(workspaceId: UUID, panelId: UUID, title: String?) -> Bool

    /// Emits a DEBUG-only command-palette log line for the description seed
    /// flow. The `message` autoclosure is only evaluated inside the host's
    /// `#if DEBUG` sink, so release builds never build the string (matching the
    /// legacy `#if DEBUG cmuxDebugLog(...)` sites).
    func commandPaletteEditFlowDebugLog(_ message: @autoclosure () -> String)
}
