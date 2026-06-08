public import CMUXMobileCore

/// A best-effort lookup of fresher attach routes for a paired Mac from the
/// team-scoped device registry.
///
/// The registry is a rendezvous layer, not an authority: it lets a re-launched
/// phone discover the current routes for the Mac it last paired with (e.g. when
/// the Mac moved networks or restarted on a different port). It is deliberately
/// fallible — a `nil` result means "registry unavailable, use what you have," so
/// reconnect always falls back to the locally persisted paired-Mac routes and
/// pairing survives the cloud registry being down.
///
/// The pure reconnect route-selection policy lives on ``DeviceRegistryService``
/// (`selectReconnectRoutes` / `shouldApplyRegistryRefresh`).
public protocol DeviceRegistryRefreshing: Sendable {
    /// Fetch the registry's current routes for the given Mac device id, scoped to
    /// the signed-in user's team.
    ///
    /// - Returns: The registry's routes for that Mac, or `nil` when the registry
    ///   is unreachable, the call is unauthorized, or the Mac is not registered.
    ///   `nil` and `[]` are both treated as "no fresher routes" by
    ///   ``DeviceRegistryService/selectReconnectRoutes(local:registry:)``.
    func freshRoutes(forMacDeviceID macDeviceID: String) async -> [CmxAttachRoute]?
}
