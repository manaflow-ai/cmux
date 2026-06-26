public import Foundation

/// The command-palette interaction and lifecycle signals broadcast over
/// `NotificationCenter`.
///
/// Each case owns the exact notification name string the app target previously
/// declared inline on `extension Notification.Name`. These are the non-open
/// signals (toggle visibility, submit, dismiss, move the selection, and the two
/// rename-input editing events); the *open* requests (command list, switcher,
/// rename/edit prompts) are owned separately by ``CommandPaletteRequestKind``,
/// which also carries the pending-open policy that does not apply here.
///
/// The post sites (`AppDelegate`, `cmuxApp`) and the observe sites
/// (`ContentView`, `TerminalController+ControlDebugContext`) stay app-side; they
/// reach the name through the `Notification.Name.commandPalette*` accessors the
/// god still vends, which now forward to `notificationName` here so each string
/// lives in one place (mirrors ``BrowserOmnibarFocusSignal`` in `CmuxBrowser`).
///
/// The wire shape is unchanged. The names are `"cmux.commandPaletteToggleRequested"`,
/// `"cmux.commandPaletteSubmitRequested"`, `"cmux.commandPaletteDismissRequested"`,
/// `"cmux.commandPaletteMoveSelection"`, `"cmux.commandPaletteRenameInputInteractionRequested"`,
/// and `"cmux.commandPaletteRenameInputDeleteBackwardRequested"`. The
/// `moveSelection` signal carries a `["delta": Int]` `userInfo` payload assembled
/// at the post site.
public enum CommandPaletteSignal: Sendable {
    /// Toggles the command palette open/closed.
    case toggle
    /// Submits the current command-palette selection.
    case submit
    /// Dismisses the command palette.
    case dismiss
    /// Moves the command-palette selection by a delta (carried in `userInfo`).
    case moveSelection
    /// A keystroke interaction inside the rename input field.
    case renameInputInteraction
    /// A delete-backward request inside the rename input field.
    case renameInputDeleteBackward

    /// The `NotificationCenter` name for this signal.
    public var notificationName: Notification.Name {
        switch self {
        case .toggle:
            return Notification.Name("cmux.commandPaletteToggleRequested")
        case .submit:
            return Notification.Name("cmux.commandPaletteSubmitRequested")
        case .dismiss:
            return Notification.Name("cmux.commandPaletteDismissRequested")
        case .moveSelection:
            return Notification.Name("cmux.commandPaletteMoveSelection")
        case .renameInputInteraction:
            return Notification.Name("cmux.commandPaletteRenameInputInteractionRequested")
        case .renameInputDeleteBackward:
            return Notification.Name("cmux.commandPaletteRenameInputDeleteBackwardRequested")
        }
    }
}
