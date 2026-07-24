public import Foundation

/// The user-owned identity that cmux reapplies when a directory becomes a workspace again.
public struct WorkspaceDirectoryCustomization: Codable, Equatable, Sendable {
    /// The explicit user-owned workspace label.
    public let customTitle: String?

    /// The explicit user-owned workspace accent color.
    public let customColor: String?

    /// Creates a directory customization.
    ///
    /// - Parameters:
    ///   - customTitle: The explicit workspace label, or `nil` when unset.
    ///   - customColor: The explicit workspace color, or `nil` when unset.
    public init(customTitle: String?, customColor: String?) {
        self.customTitle = customTitle
        self.customColor = customColor
    }

    /// Whether neither user-owned field is set.
    public var isEmpty: Bool {
        customTitle == nil && customColor == nil
    }
}
