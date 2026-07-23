/// Supplies live, authenticated same-account Mac candidates for zero-touch
/// Iroh connection.
///
/// Implementations must never return cached bindings. A cached route may enrich
/// a previously authenticated pairing, but cannot authorize a first pairing.
@MainActor
public protocol MobileIrohMacDiscovering: Sendable {
    /// Refreshes broker state and returns the current live Mac candidates.
    func discoverLiveMacs() async -> [MobileDiscoveredIrohMac]
}
