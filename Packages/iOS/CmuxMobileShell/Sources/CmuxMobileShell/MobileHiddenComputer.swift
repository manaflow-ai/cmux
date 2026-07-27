/// One computer hidden on this iPhone.
///
/// Hidden entries retain their paired-Mac row and can be restored offline.
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

    /// Creates an immutable hidden-computer presentation value.
    public init(
        id: String,
        macDeviceID: String,
        instanceTag: String?,
        displayName: String,
        customColor: String?,
        customIcon: String?
    ) {
        self.id = id
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.displayName = displayName
        self.customColor = customColor
        self.customIcon = customIcon
    }
}
