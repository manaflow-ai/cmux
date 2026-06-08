public import CMUXMobileCore
public import CmuxMobileShellModel

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

    /// List the team's registered devices and their running cmux app instances,
    /// for the device tree (device → tags → workspaces).
    ///
    /// The same team-scoped `GET /api/devices` response that backs
    /// ``freshRoutes(forMacDeviceID:)``, decoded into the full two-level model
    /// rather than narrowed to one Mac's routes. Best-effort like the rest of the
    /// registry: returns `nil` when the registry is unreachable, the call is
    /// unauthorized, or the response is malformed, so the tree falls back to the
    /// locally known paired Macs and the app keeps working with the cloud down.
    func listDevices() async -> [RegistryDevice]?
}
