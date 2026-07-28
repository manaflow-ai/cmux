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

/// How a freshly-created workspace participates in directory customization.
public enum WorkspaceDirectoryCustomizationCreationMode: Equatable, Sendable {
    /// Do not associate the workspace with a directory customization record.
    case disabled
    /// Track the workspace directory so later user title/color changes persist.
    case trackDirectory
}
