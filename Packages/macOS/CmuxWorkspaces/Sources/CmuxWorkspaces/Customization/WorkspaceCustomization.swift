/// One independently persisted workspace customization field.
///
/// `absent` means the recovery journal has never observed a mutation for the
/// field, while `cleared` is an explicit tombstone that prevents a stale
/// session snapshot from resurrecting an older value.
public enum WorkspaceCustomizationField: Codable, Equatable, Sendable {
    /// The field has no recovery-journal entry, so the session snapshot wins.
    case absent
    /// The most recent user mutation assigned the associated value.
    case value(String)
    /// The most recent user mutation explicitly cleared the field.
    case cleared
}

/// User-owned workspace identity persisted independently of session autosave.
///
/// Records are keyed by `Workspace.stableId`. Title and color are independent
/// so mutating one field never makes the other field authoritative.
public struct WorkspaceCustomization: Codable, Equatable, Sendable {
    /// Recovery state for the user-owned workspace title.
    public let customTitle: WorkspaceCustomizationField

    /// Recovery state for the user-owned workspace accent color.
    public let customColor: WorkspaceCustomizationField

    /// Creates a workspace customization recovery record.
    ///
    /// - Parameters:
    ///   - customTitle: Recovery state for the workspace title.
    ///   - customColor: Recovery state for the workspace accent color.
    public init(
        customTitle: WorkspaceCustomizationField = .absent,
        customColor: WorkspaceCustomizationField = .absent
    ) {
        self.customTitle = customTitle
        self.customColor = customColor
    }
}
