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
    /// Owning Stack user of the local paired-Mac row this entry came from.
    ///
    /// Captured so Forget deletes the exact row it was shown for. A team-less
    /// row is visible under any selected team (legacy visibility), so the live
    /// display scope is not a safe delete key.
    public let stackUserID: String?
    /// Owning Stack team of the local paired-Mac row, or `nil` for a team-less
    /// pairing. This is the row's OWN team, not the currently-selected team.
    public let teamID: String?

    /// Creates an immutable hidden-computer presentation value.
    public init(
        id: String,
        macDeviceID: String,
        instanceTag: String?,
        displayName: String,
        customColor: String?,
        customIcon: String?,
        stackUserID: String? = nil,
        teamID: String? = nil
    ) {
        self.id = id
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.displayName = displayName
        self.customColor = customColor
        self.customIcon = customIcon
        self.stackUserID = stackUserID
        self.teamID = teamID
    }
}
