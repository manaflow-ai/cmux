public import CmuxSettings

/// A value snapshot of one selectable browser theme mode for the theme-mode
/// popover.
///
/// The popover lives in the package, but `displayName` is resolved app-side
/// (the app bundle owns the `theme.system`/`theme.light`/`theme.dark`
/// localization catalog; resolving from the package bundle would drop the
/// Japanese translations). The app builds one `BrowserThemeModeItem` per
/// `BrowserThemeMode.allCases` with the already-localized name and hands the
/// snapshot to ``BrowserThemeModePopoverView``.
public struct BrowserThemeModeItem: Identifiable, Sendable {
    /// Stable identity, the underlying mode's raw value.
    public let id: String

    /// App-resolved, localized label shown for this mode.
    public let displayName: String

    /// The mode this item selects.
    public let mode: BrowserThemeMode

    /// Creates a snapshot item for a single theme mode.
    /// - Parameters:
    ///   - displayName: The app-localized label to show.
    ///   - mode: The theme mode this item selects.
    public init(displayName: String, mode: BrowserThemeMode) {
        self.id = mode.rawValue
        self.displayName = displayName
        self.mode = mode
    }
}
