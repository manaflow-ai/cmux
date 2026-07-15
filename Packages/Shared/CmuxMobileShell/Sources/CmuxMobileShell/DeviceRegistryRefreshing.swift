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
    func freshRoutes(
        forMacDeviceID macDeviceID: String,
        instanceTag: String?
    ) async -> [CmxAttachRoute]?

    /// List the team's registered devices and their running cmux app instances,
    /// for the device tree (device → tags → workspaces).
    ///
    /// The same team-scoped `GET /api/devices` response that backs
    /// ``freshRoutes(forMacDeviceID:)``, decoded into the full two-level model
    /// rather than narrowed to one Mac's routes. Returns a three-way outcome so
    /// the caller can tell a transient failure (keep the current tree) from an
    /// auth/scope rejection (clear it). The registry is team-scoped, so a 401/403
    /// after the token/scope changed must NOT keep the previous scope's
    /// team-device data visible.
    func listDevices() async -> DeviceRegistryListOutcome
}

/// The outcome of a device-list registry read, distinguishing the cases that
/// must clear the cached team-device data from those that must keep it.
public enum DeviceRegistryListOutcome: Sendable {
    /// A successful read; the decoded device list (possibly empty).
    case ok([RegistryDevice])
    /// The registry rejected the call on authorization/scope grounds (a non-2xx
    /// 401/403). The cached, possibly other-scope, device data must be cleared so
    /// it cannot leak into the new auth context; the UI falls back to local
    /// paired Macs.
    case authRejected
    /// A transient failure (network error, timeout, malformed body, or any other
    /// non-auth non-2xx). The current device list should be kept so a blip never
    /// blanks a populated tree.
    case transientFailure
}
