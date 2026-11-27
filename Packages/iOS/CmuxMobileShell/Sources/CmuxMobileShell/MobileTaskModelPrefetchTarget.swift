/// One paired Mac to warm before the task composer opens.
public nonisolated struct MobileTaskModelPrefetchTarget: Equatable, Sendable {
    /// The physical Mac device identifier.
    public let macDeviceID: String
    /// The exact app instance paired on that Mac, when known.
    public let instanceTag: String?
    /// Changes when a live host connection is replaced. `nil` keeps backend
    /// catalogs warm for an offline Mac and is replaced when that Mac connects.
    public let connectionIdentity: String?

    /// Creates a prefetch target for one paired Mac.
    public init(macDeviceID: String, instanceTag: String?, connectionIdentity: String? = nil) {
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.connectionIdentity = connectionIdentity
    }
}
