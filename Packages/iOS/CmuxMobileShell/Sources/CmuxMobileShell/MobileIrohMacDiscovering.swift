/// Supplies live, authenticated same-account Mac candidates for zero-touch
/// Iroh connection.
///
/// Implementations must never return cached bindings. A cached route may enrich
/// a previously authenticated pairing, but cannot authorize a first pairing.
@MainActor
public protocol MobileIrohMacDiscovering: Sendable {
    /// Refreshes broker state and returns the current live Mac candidates.
    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac]

    /// Invalidates reusable transport discovery state for one Mac.
    ///
    /// Called when a presence route push proves the Mac's endpoint state
    /// changed (relaunch, re-registration): any discovery snapshot captured
    /// before the push is stale, so the next dial to that Mac must rebuild
    /// its plan from a fresh broker fetch instead of reusing it.
    func invalidateDiscovery(forMacDeviceID deviceID: String) async
}
