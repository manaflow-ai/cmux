public import Foundation

/// The `userInfo` keys carried by the
/// ``Foundation/Notification/Name/ghosttyDefaultBackgroundDidChange``
/// notification posted by ``TerminalDefaultBackgroundNotificationDispatcher``.
///
/// These string values are the frozen wire contract observed by the app-target
/// chrome readers (the main window, browser panel, right-sidebar style, update
/// titlebar accessory, and workspace content view). The app target keeps a
/// parallel `GhosttyNotificationKey` constant set whose raw values are identical
/// to these, so a payload written here is read there byte-for-byte regardless of
/// which side constructed the dictionary. The dispatcher drained out of the
/// `GhosttyApp` god type into `CmuxTerminal`; only the appearance/background
/// subset of those keys moved with it, because the remaining
/// `GhosttyNotificationKey` members (scrollbar, cell size, tab/surface id,
/// focus intent, title) are a separate, broadly-shared event vocabulary that
/// stays in the app target until its own slice.
// Frozen Notification.userInfo string-key wire contract mirroring the
// app-target GhosttyNotificationKey constant bag and the package's
// extension Notification.Name event names.
// lint:allow namespace-type — no instance to carry and no receiver type to extend.
public enum TerminalDefaultBackgroundUserInfoKey {
    /// The resolved terminal background color (`NSColor`).
    public static let backgroundColor = "ghostty.backgroundColor"

    /// The resolved terminal background opacity (`Double`).
    public static let backgroundOpacity = "ghostty.backgroundOpacity"

    /// The monotonically increasing event identifier (`NSNumber` wrapping a
    /// `UInt64`) used to drop stale background updates.
    public static let backgroundEventId = "ghostty.backgroundEventId"

    /// The originating source label for the background update (`String`).
    public static let backgroundSource = "ghostty.backgroundSource"

    /// The resolved terminal foreground color (`NSColor`).
    public static let foregroundColor = "ghostty.foregroundColor"

    /// The resolved terminal cursor color (`NSColor`).
    public static let cursorColor = "ghostty.cursorColor"

    /// The resolved terminal cursor text color (`NSColor`).
    public static let cursorTextColor = "ghostty.cursorTextColor"

    /// The resolved terminal selection background color (`NSColor`).
    public static let selectionBackground = "ghostty.selectionBackground"

    /// The resolved terminal selection foreground color (`NSColor`).
    public static let selectionForeground = "ghostty.selectionForeground"
}
