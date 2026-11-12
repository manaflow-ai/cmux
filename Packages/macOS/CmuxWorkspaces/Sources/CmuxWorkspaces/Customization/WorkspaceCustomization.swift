/// One independently persisted workspace customization field.
///
/// `absent` means the recovery journal has never observed a mutation for the
/// field, while `cleared` is an explicit tombstone that prevents a stale
/// session snapshot from resurrecting an older value.
public enum WorkspaceCustomizationField: Codable, Equatable, Sendable {
    /// The field has no recovery-journal entry, so the session snapshot wins.
    case absent
    /// The most recent mutation assigned the associated value.
    case value(String)
    /// The most recent mutation explicitly cleared the field.
    case cleared
}

/// Workspace identity persisted independently of session autosave.
///
/// Records are keyed by `Workspace.stableId`. Title and color are independent
/// so mutating one field never makes the other field authoritative.
public struct WorkspaceCustomization: Codable, Equatable, Sendable {
    /// Provenance of a title write observed by the recovery journal.
    public enum TitleSource: String, Codable, Sendable {
        /// An explicit user rename or clear.
        case user
        /// An automatic workspace name.
        case auto
        /// An authoritative remote workspace name.
        case remote
    }

    /// Recovery state for the workspace title.
    public let customTitle: WorkspaceCustomizationField

    /// Missing in legacy journals, which only observed user title writes.
    public let customTitleSource: TitleSource?

    /// Recovery state for the user-owned workspace accent color.
    public let customColor: WorkspaceCustomizationField

    /// Creates a workspace customization recovery record.
    ///
    /// - Parameters:
    ///   - customTitle: Recovery state for the workspace title.
    ///   - customTitleSource: The source of the latest title write.
    ///   - customColor: Recovery state for the workspace accent color.
    public init(
        customTitle: WorkspaceCustomizationField = .absent,
        customTitleSource: TitleSource? = .user,
        customColor: WorkspaceCustomizationField = .absent
    ) {
        self.customTitle = customTitle
        self.customTitleSource = customTitle == .absent ? nil : customTitleSource
        self.customColor = customColor
    }
}
