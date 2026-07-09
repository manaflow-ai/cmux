public import Foundation

/// Pure value snapshot driving the browser-profile popover content (the list of
/// profiles with the active one checkmarked, plus the new/import/rename rows).
///
/// Every field is already resolved app-side: the profile rows (id, display name,
/// and whether each is the active profile), whether the active profile can be
/// renamed, the popover padding resolved from `BrowserProfilePopoverPaddingStore`,
/// and all `String(localized:)` titles/labels (the catalog keys bind to the app
/// bundle, so localization stays app-side and the resolved strings are passed
/// through here). Holding only `Sendable` values keeps the popover view
/// renderable in this package without reaching back into the app target.
public struct BrowserProfilePopoverSnapshot: Sendable {
    /// One selectable profile row in the popover list.
    public struct Profile: Identifiable, Sendable {
        /// Stable identifier used to key the row and report the selection.
        public let id: UUID
        /// Human-readable profile name.
        public var displayName: String
        /// Whether this row is the currently active profile (checkmarked).
        public var isSelected: Bool

        /// Creates a profile row from values resolved app-side.
        public init(id: UUID, displayName: String, isSelected: Bool) {
            self.id = id
            self.displayName = displayName
            self.isSelected = isSelected
        }
    }

    /// Section title shown above the profile list.
    public var title: String
    /// Profile rows in display order.
    public var profiles: [Profile]
    /// Whether the rename row is shown (the active profile can be renamed).
    public var canRenameActiveProfile: Bool
    /// Horizontal popover padding resolved app-side.
    public var horizontalPadding: CGFloat
    /// Vertical popover padding resolved app-side.
    public var verticalPadding: CGFloat
    /// Pre-localized label for the new-profile row.
    public var newProfileLabel: String
    /// Pre-localized label for the import-browser-data row.
    public var importLabel: String
    /// Pre-localized label for the rename-current-profile row.
    public var renameLabel: String

    /// Creates the profile popover snapshot from values already resolved app-side.
    public init(
        title: String,
        profiles: [Profile],
        canRenameActiveProfile: Bool,
        horizontalPadding: CGFloat,
        verticalPadding: CGFloat,
        newProfileLabel: String,
        importLabel: String,
        renameLabel: String
    ) {
        self.title = title
        self.profiles = profiles
        self.canRenameActiveProfile = canRenameActiveProfile
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.newProfileLabel = newProfileLabel
        self.importLabel = importLabel
        self.renameLabel = renameLabel
    }
}
