/// One paired Mac to warm before the task composer opens.
public struct MobileTaskModelPrefetchTarget: Equatable, Sendable {
    public let macDeviceID: String
    public let instanceTag: String?
    /// Changes when a live host connection is replaced. `nil` keeps backend
    /// catalogs warm for an offline Mac and is replaced when that Mac connects.
    public let connectionIdentity: String?

    public init(macDeviceID: String, instanceTag: String?, connectionIdentity: String? = nil) {
        self.macDeviceID = macDeviceID
        self.instanceTag = instanceTag
        self.connectionIdentity = connectionIdentity
    }
}
