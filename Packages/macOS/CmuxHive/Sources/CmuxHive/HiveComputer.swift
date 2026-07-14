public import CMUXMobileCore
public import Foundation

/// One computer on the signed-in account, merged from the device registry,
/// the local paired-computer store, and the live presence map.
///
/// This is the row model for the macOS **Settings › Computers** pane and the
/// device picker of the remote-Mac viewer. It is a pure value snapshot: the
/// merge lives in ``HiveComputerDirectory``, rows never observe stores.
public struct HiveComputer: Equatable, Sendable, Identifiable {
    /// Stable cross-platform cmux device UUID (matches the registry's
    /// `deviceId` and `CmxAttachTicket.macDeviceID`).
    public var deviceID: String
    /// Best-known human label: the local custom name override, else the
    /// registry/pairing display name, else the short device id.
    public var displayName: String
    /// Registry platform string (`"mac"`, `"ios"`, `"linux"`, `"windows"`),
    /// or `nil` when the computer is known only from a local pairing.
    public var platform: String?
    /// Whether this row is the computer the app is running on.
    public var isThisComputer: Bool
    /// Whether a local pairing record exists for this computer.
    public var isPaired: Bool
    /// Live presence for the computer, or the best registry-derived hint.
    public var presence: HiveComputerPresence
    /// Build-channel label (`"Stable"`, `"DEV · tag"`, …) reported by the
    /// live presence service, when identifiable.
    public var buildLabel: String?
    /// The computer's registered cmux app instances, freshest first.
    public var instances: [HiveComputerInstance]

    public var id: String { deviceID }

    /// Creates a merged computer row.
    public init(
        deviceID: String,
        displayName: String,
        platform: String?,
        isThisComputer: Bool,
        isPaired: Bool,
        presence: HiveComputerPresence,
        buildLabel: String? = nil,
        instances: [HiveComputerInstance] = []
    ) {
        self.deviceID = deviceID
        self.displayName = displayName
        self.platform = platform
        self.isThisComputer = isThisComputer
        self.isPaired = isPaired
        self.presence = presence
        self.buildLabel = buildLabel
        self.instances = instances
    }

    /// Whether this computer is a host another cmux can attach to (a route
    /// -advertising platform, not a phone) and is not this computer itself.
    public var isPairableHost: Bool {
        guard !isThisComputer else { return false }
        switch (platform ?? "mac").lowercased() {
        case "mac", "linux", "windows":
            return true
        default:
            return false
        }
    }

    /// The attach routes to persist when pairing this computer: the freshest
    /// online instance's routes, else the freshest instance advertising any.
    public var bestPairingRoutes: (routes: [CmxAttachRoute], instanceTag: String?)? {
        let candidates = instances.filter { !$0.routes.isEmpty }
        guard !candidates.isEmpty else { return nil }
        let ordered = candidates.sorted { lhs, rhs in
            if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
            return lhs.lastSeenAt > rhs.lastSeenAt
        }
        guard let best = ordered.first else { return nil }
        return (best.routes, best.tag)
    }
}
