/// Supplies live, authenticated same-account Mac candidates for automatic
/// connection.
///
/// Implementations must never return cached bindings. A cached route may enrich
/// a previously authenticated pairing, but cannot authorize a first pairing.
@MainActor
public protocol MobileRemoteMacDiscovering: Sendable {
    /// Refreshes broker state and returns the current live Mac candidates.
    func discoverLiveMacs() async -> [MobileDiscoveredMac]

    /// Invalidates reusable transport discovery state for one Mac.
    ///
    /// Called when a presence route push proves the Mac's endpoint state
    /// changed (relaunch, re-registration): any discovery snapshot captured
    /// before the push is stale, so the next dial to that Mac must rebuild
    /// its plan from a fresh broker fetch instead of reusing it.
    func invalidateDiscovery(forMacDeviceID deviceID: String) async
}

/// Source compatibility for integrations that still use the retired name.
@available(*, deprecated, renamed: "MobileRemoteMacDiscovering")
public typealias MobileIrohMacDiscovering = MobileRemoteMacDiscovering
