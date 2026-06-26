public import CMUXMobileCore
public import Foundation

/// One tagged cmux app instance running on a registered device, as returned by
/// the team-scoped device registry (`GET /api/devices`).
///
/// Mirrors a `device_app_instances` row: a `(deviceId, tag)` pair carrying the
/// attach `routes` the phone uses to reach that specific build. The registry is
/// port-flexible, so the reachable endpoint lives in `routes` rather than a
/// fixed column.
public struct RegistryAppInstance: Equatable, Sendable, Identifiable {
    /// The cmux build tag this instance runs (`"stable"`, a dev tag, or
    /// `"default"` when the build does not distinguish tags).
    public var tag: String
    /// Attach routes advertised by this instance, ordered by priority. Decoded
    /// failably and individually upstream, so a malformed/unknown-kind route is
    /// dropped rather than failing the whole instance.
    public var routes: [CmxAttachRoute]
    /// When the registry last saw this instance register/refresh. Drives the
    /// best-effort "last seen N ago" liveness hint when no live link exists.
    public var lastSeenAt: Date
    /// The Mac-chosen mobile transport mode (cmuxRelay/ownRelay/tailscale) for a
    /// read-only badge. `nil` when unknown (the registry path does not carry it;
    /// it is populated from the presence-DO sync record).
    public var transportMode: String?

    /// The tag is unique per device, so it doubles as the per-device row id.
    public var id: String { tag }

    /// Memberwise initializer. `transportMode` defaults to `nil` for callers
    /// (the registry path) that do not carry it; the presence-DO sync facade
    /// passes the synced value through.
    public init(tag: String, routes: [CmxAttachRoute], lastSeenAt: Date, transportMode: String? = nil) {
        self.tag = tag
        self.routes = routes
        self.lastSeenAt = lastSeenAt
        self.transportMode = transportMode
    }

    /// Whether this instance advertises at least one attach route, i.e. it is a
    /// candidate the phone could connect to.
    public var hasRoutes: Bool { !routes.isEmpty }
}

/// One registered physical machine (Mac/host) in the team-scoped device
/// registry, with its running cmux app instances.
///
/// Mirrors a `devices` row plus its `device_app_instances`. This is the
/// two-level model the device tree renders: device → app instances (tags). The
/// `deviceId` here is the cmux-generated device UUID (the wire `deviceId`), not
/// the internal surrogate row id, so it matches `CmxAttachTicket.macDeviceID`
/// for correlating the live connection.
public struct RegistryDevice: Equatable, Sendable, Identifiable {
    /// Stable, cross-platform cmux device UUID (matches `MobileHostIdentity` /
    /// `CmxAttachTicket.macDeviceID`). Used as the `Identifiable` id and to
    /// correlate the active connection.
    public var deviceId: String
    /// `"mac" | "ios" | "linux" | "windows"`. Only host platforms that advertise
    /// routes (typically `"mac"`/`"linux"`) are controllable from the phone.
    public var platform: String
    /// User-renamable label (e.g. the Mac's name), if the device supplied one.
    public var displayName: String?
    /// When the registry last saw any registration/refresh for this device.
    public var lastSeenAt: Date
    /// The device's running cmux app instances (tags), newest-first.
    public var instances: [RegistryAppInstance]

    public var id: String { deviceId }

    public init(
        deviceId: String,
        platform: String,
        displayName: String?,
        lastSeenAt: Date,
        instances: [RegistryAppInstance]
    ) {
        self.deviceId = deviceId
        self.platform = platform
        self.displayName = displayName
        self.lastSeenAt = lastSeenAt
        self.instances = instances
    }

    /// A human label for the device: its display name, else the short device id.
    public var title: String {
        if let displayName, !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return displayName
        }
        return String(deviceId.prefix(8))
    }

    /// Whether this device is a host the phone can attach to. P1 does not register
    /// the phone itself, but guard anyway so an `ios` (or any non-host) row is
    /// never rendered as a tappable, connectable host.
    public var isControllableHost: Bool {
        switch platform.lowercased() {
        case "mac", "linux", "windows":
            return true
        default:
            return false
        }
    }
}
