/// Pure value snapshot driving the browser-theme popover content (system /
/// light / dark, with the active mode checkmarked).
///
/// Every field is already resolved app-side: each option's stable token (the
/// `BrowserThemeMode` raw value), the `String(localized:)` display name (the
/// catalog keys bind to the app bundle, so localization stays app-side), whether
/// the option is selected, and its accessibility identifier. Holding only
/// `Sendable` values keeps the popover view renderable in this package without
/// reaching back into the app target's `BrowserThemeMode` presentation.
public struct BrowserThemePopoverSnapshot: Sendable {
    /// One selectable theme-mode row in the popover list.
    public struct Option: Identifiable, Sendable {
        /// Stable token (the theme mode raw value) used to key the row and report
        /// the selection back to the app-side forwarder.
        public let id: String
        /// Localized title shown for the option.
        public var displayName: String
        /// Whether this row is the currently selected theme mode (checkmarked).
        public var isSelected: Bool
        /// Accessibility identifier resolved app-side for UI tests.
        public var accessibilityIdentifier: String

        /// Creates a theme-mode row from values resolved app-side.
        public init(
            id: String,
            displayName: String,
            isSelected: Bool,
            accessibilityIdentifier: String
        ) {
            self.id = id
            self.displayName = displayName
            self.isSelected = isSelected
            self.accessibilityIdentifier = accessibilityIdentifier
        }
    }

    /// Theme-mode rows in display order.
    public var options: [Option]

    /// Creates the theme popover snapshot from values already resolved app-side.
    public init(options: [Option]) {
        self.options = options
    }
}
