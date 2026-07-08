internal import Foundation

/// A Sendable snapshot of one sidebar status/metadata entry, in display order,
/// for the v1 `list_status` / `list_meta` / `sidebar_state` line formatting.
public struct ControlSidebarStatusEntrySnapshot: Sendable, Equatable {
    /// The entry key.
    public let key: String
    /// The entry value.
    public let value: String
    /// The optional SF Symbol/icon token.
    public let icon: String?
    /// The optional color token.
    public let color: String?
    /// The optional absolute URL string.
    public let urlAbsoluteString: String?
    /// The display priority (0 omitted from the listing line).
    public let priority: Int
    /// The render format (non-`plain` is appended to the listing line).
    public let format: ControlSidebarMetadataFormat

    /// Creates a snapshot.
    ///
    /// - Parameters:
    ///   - key: The entry key.
    ///   - value: The entry value.
    ///   - icon: The optional icon token.
    ///   - color: The optional color token.
    ///   - urlAbsoluteString: The optional absolute URL string.
    ///   - priority: The display priority.
    ///   - format: The render format.
    public init(
        key: String,
        value: String,
        icon: String?,
        color: String?,
        urlAbsoluteString: String?,
        priority: Int,
        format: ControlSidebarMetadataFormat
    ) {
        self.key = key
        self.value = value
        self.icon = icon
        self.color = color
        self.urlAbsoluteString = urlAbsoluteString
        self.priority = priority
        self.format = format
    }
}
