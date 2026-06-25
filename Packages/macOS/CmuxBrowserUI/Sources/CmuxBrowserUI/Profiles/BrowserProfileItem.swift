public import Foundation

/// A value snapshot of one selectable browser profile for the profile popover.
///
/// The popover lives in the package, but the profile model
/// (`BrowserProfileDefinition`) and the selection state (`panel.profileID`) stay
/// app-side. The app builds one `BrowserProfileItem` per profile, computing
/// `isSelected` against the panel's active profile, and hands the snapshot to
/// ``BrowserProfilePopoverView``. Keeping a value snapshot at the list boundary
/// means the row subtree holds no reference to the `BrowserProfileStore`.
public struct BrowserProfileItem: Identifiable, Sendable {
    /// Stable identity, the underlying profile's id.
    public let id: UUID

    /// The profile's display name, shown for the row.
    public let name: String

    /// Whether this profile is the panel's currently active profile (shows a
    /// checkmark).
    public let isSelected: Bool

    /// Creates a snapshot item for a single profile.
    /// - Parameters:
    ///   - id: The profile's stable id.
    ///   - name: The profile's display name.
    ///   - isSelected: Whether this profile is currently active.
    public init(id: UUID, name: String, isSelected: Bool) {
        self.id = id
        self.name = name
        self.isSelected = isSelected
    }
}
