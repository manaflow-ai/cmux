public import CMUXMobileCore
public import Foundation

/// One live, broker-verified same-account Mac that iOS may try automatically.
///
/// This value is discovery input, not a persisted pairing. The shell must still
/// complete Iroh admission and validate the authenticated host device and app
/// instance before writing it to the paired-Mac store.
public struct MobileDiscoveredIrohMac: Equatable, Sendable {
    /// Stable cmux device identifier asserted by the authenticated broker.
    public let deviceID: String
    /// Human-readable Mac name supplied by the registered binding.
    public let displayName: String?
    /// Exact running cmux app-instance tag asserted by the broker.
    public let instanceTag: String
    /// Iroh-pinned routes for this endpoint.
    public let routes: [CmxAttachRoute]
    /// Broker-observed recency used only to order otherwise equivalent candidates.
    public let lastSeenAt: Date

    /// Creates a live same-account discovery candidate.
    public init(
        deviceID: String,
        displayName: String?,
        instanceTag: String,
        routes: [CmxAttachRoute],
        lastSeenAt: Date
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.instanceTag = instanceTag
        self.routes = routes
        self.lastSeenAt = lastSeenAt
    }
}
