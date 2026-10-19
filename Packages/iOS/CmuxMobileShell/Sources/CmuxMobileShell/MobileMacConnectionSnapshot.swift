internal import CmuxMobilePairedMac
public import CMUXMobileCore

/// Read-only status for one live connection in the iOS per-Mac pool.
public struct MobileMacConnectionSnapshot: Identifiable, Equatable, Sendable {
    /// Stable identity of the Mac APP INSTANCE: sibling builds on one physical
    /// Mac are distinct pool entries, so identity must carry the tag.
    public var id: String {
        CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        ).id
    }

    /// The authenticated Mac device identifier.
    public let macDeviceID: String
    /// The current user-facing Mac name.
    public let displayName: String
    /// The authenticated tagged-build instance, when present.
    public let instanceTag: String?
    /// The control or focused role owned by this connection.
    public let role: MobileMacConnectionRole
    /// The transport this connection's client actually dialed. Per-connection
    /// because each Mac connects with its own configured method.
    public let routeKind: CmxAttachTransportKind?

    /// Creates one immutable connection status snapshot.
    public init(
        macDeviceID: String,
        displayName: String,
        instanceTag: String?,
        role: MobileMacConnectionRole,
        routeKind: CmxAttachTransportKind? = nil
    ) {
        let identity = CmxMacAppInstanceIdentity(
            macDeviceID: macDeviceID,
            instanceTag: instanceTag
        )
        self.macDeviceID = identity.macDeviceID
        self.displayName = displayName
        self.instanceTag = identity.instanceTag
        self.role = role
        self.routeKind = routeKind
    }
}
