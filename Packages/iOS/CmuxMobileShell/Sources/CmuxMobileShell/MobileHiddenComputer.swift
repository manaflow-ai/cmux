/// One computer hidden on this iPhone.
///
/// Local entries retain their paired-Mac row and can be restored offline.
/// Legacy entries have only the marker left by an older cmux version and need
/// one live same-account discovery to recreate their local row.
public struct MobileHiddenComputer: Equatable, Identifiable, Sendable {
    /// Stable pairing identity used by list diffing.
    public let id: String
    /// Physical Mac device identifier.
    public let macDeviceID: String
    /// Authenticated app-instance tag, when the hidden marker identifies one.
    public let instanceTag: String?
    /// Best available user-facing name.
    public let displayName: String
    /// User-selected color retained by a local paired-Mac row.
    public let customColor: String?
    /// User-selected icon retained by a local paired-Mac row.
    public let customIcon: String?
    /// Whether unhide requires live legacy recovery rather than a local marker change.
    public let requiresLegacyRecovery: Bool

    /// Creates an immutable hidden-computer presentation value.
    public init(
        id: String,
        macDeviceID: String,
        instanceTag: String?,
        displayName: String,
        customColor: String?,
        customIcon: String?,
        requiresLegacyRecovery: Bool
    ) {
        self.id = id
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.displayName = displayName
        self.customColor = customColor
        self.customIcon = customIcon
        self.requiresLegacyRecovery = requiresLegacyRecovery
    }
}
