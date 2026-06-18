/// The window-agnostic policy for a command-palette open request.
///
/// Each case names one way the palette can be requested (open the command list,
/// the workspace switcher, or one of the rename/edit prompts). The app target
/// resolves the target `NSWindow`, clears browser focus mode, and posts the
/// notification; the per-kind policy that decides *which* notification to post
/// and whether the request marks a pending-open lives here so it stays pure and
/// testable.
public enum CommandPaletteRequestKind: String, Sendable, CaseIterable {
    /// Opens the command list palette.
    case commands
    /// Opens the workspace switcher palette.
    case switcher
    /// Opens the rename-tab prompt.
    case renameTab
    /// Opens the rename-workspace prompt.
    case renameWorkspace
    /// Opens the edit-workspace-description prompt.
    case editWorkspaceDescription

    /// The raw notification name posted for this request.
    ///
    /// These strings are byte-identical to the `cmux.*` `Notification.Name`
    /// literals the app target previously posted inline, so observers keyed on
    /// the existing names are unaffected.
    public var notificationName: String {
        switch self {
        case .commands:
            return "cmux.commandPaletteRequested"
        case .switcher:
            return "cmux.commandPaletteSwitcherRequested"
        case .renameTab:
            return "cmux.commandPaletteRenameTabRequested"
        case .renameWorkspace:
            return "cmux.commandPaletteRenameWorkspaceRequested"
        case .editWorkspaceDescription:
            return "cmux.commandPaletteEditWorkspaceDescriptionRequested"
        }
    }

    /// Whether posting this request should mark the target window pending-open.
    ///
    /// Every request kind marks pending-open today; the property keeps the
    /// policy with the kind so a future non-marking request kind is a local
    /// change rather than a call-site edit.
    public var marksPending: Bool {
        switch self {
        case .commands, .switcher, .renameTab, .renameWorkspace, .editWorkspaceDescription:
            return true
        }
    }
}
