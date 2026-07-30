/// Read-only status for one live connection in the iOS per-Mac pool.
public struct MobileMacConnectionSnapshot: Identifiable, Equatable, Sendable {
    /// Stable identity of the Mac connection.
    public var id: String { macDeviceID }

    /// The authenticated Mac device identifier.
    public let macDeviceID: String
    /// The current user-facing Mac name.
    public let displayName: String
    /// The authenticated tagged-build instance, when present.
    public let instanceTag: String?
    /// The control or focused role owned by this connection.
    public let role: MobileMacConnectionRole

    /// Creates one immutable connection status snapshot.
    public init(
        macDeviceID: String,
        displayName: String,
        instanceTag: String?,
        role: MobileMacConnectionRole
    ) {
        self.macDeviceID = macDeviceID
        self.displayName = displayName
        self.instanceTag = instanceTag
        self.role = role
    }
}
