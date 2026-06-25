public import Foundation

/// The `Notification.Name` constants the command-palette flows post and observe.
///
/// These names are the wire identity of the palette's `NotificationCenter`
/// events: the app target posts them (toggle/open/switcher/submit/dismiss, the
/// rename and edit-description prompts, the selection-move delta, and the
/// rename-input editing intents) and the SwiftUI palette host observes them.
/// Every raw string is byte-identical to the `cmux.*` literal the app target
/// previously declared inline, so existing observers keyed on these names are
/// unaffected. The string halves of the open-request names also match
/// ``CommandPaletteRequestKind/notificationName``, which posts the same events.
extension Notification.Name {
    /// Toggles the command palette open or closed.
    public static let commandPaletteToggleRequested = Notification.Name("cmux.commandPaletteToggleRequested")
    /// Opens the command list palette.
    public static let commandPaletteRequested = Notification.Name("cmux.commandPaletteRequested")
    /// Opens the workspace switcher palette.
    public static let commandPaletteSwitcherRequested = Notification.Name("cmux.commandPaletteSwitcherRequested")
    /// Submits the current palette selection or rename input.
    public static let commandPaletteSubmitRequested = Notification.Name("cmux.commandPaletteSubmitRequested")
    /// Dismisses the open palette.
    public static let commandPaletteDismissRequested = Notification.Name("cmux.commandPaletteDismissRequested")
    /// Opens the rename-tab prompt.
    public static let commandPaletteRenameTabRequested = Notification.Name("cmux.commandPaletteRenameTabRequested")
    /// Opens the rename-workspace prompt.
    public static let commandPaletteRenameWorkspaceRequested = Notification.Name("cmux.commandPaletteRenameWorkspaceRequested")
    /// Opens the edit-workspace-description prompt.
    public static let commandPaletteEditWorkspaceDescriptionRequested = Notification.Name("cmux.commandPaletteEditWorkspaceDescriptionRequested")
    /// Moves the palette selection by the `delta` carried in `userInfo`.
    public static let commandPaletteMoveSelection = Notification.Name("cmux.commandPaletteMoveSelection")
    /// Routes a rename-input editing interaction to the focused rename field.
    public static let commandPaletteRenameInputInteractionRequested = Notification.Name("cmux.commandPaletteRenameInputInteractionRequested")
    /// Routes a delete-backward edit to the focused rename field.
    public static let commandPaletteRenameInputDeleteBackwardRequested = Notification.Name("cmux.commandPaletteRenameInputDeleteBackwardRequested")
}
