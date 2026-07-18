public import Foundation

/// The phone's live presence state: every known app instance keyed by
/// `(deviceId, tag)`, built from one ``PresenceUpdate/snapshot(_:)`` plus the
/// transition events that follow. Pure value type so the reduction is unit
/// testable without a socket; the shell store owns one and mutates it on the
/// main actor as stream frames arrive.
public struct PresenceMap: Equatable, Sendable {
    /// Per-device rollup for UI rows: a device is online when any of its
    /// instances is online; `lastSeenAt` is the freshest heartbeat across them.
    public struct DeviceSummary: Equatable, Sendable {
        public var online: Bool
        public var lastSeenAt: Date
        /// The host's build-channel label (`"DEV · tag"`, `"Nightly"`, `"Stable"`,
        /// …), derived from its reported bundle id + tag. `nil` when not
        /// identifiable (older host). See ``MacBuildChannel``.
        public var buildLabel: String?

        /// Create one device-level presence rollup.
        public init(online: Bool, lastSeenAt: Date, buildLabel: String? = nil) {
            self.online = online
            self.lastSeenAt = lastSeenAt
            self.buildLabel = buildLabel
        }
    }

    /// Instances grouped by device id, then keyed by tag, so a device-row
    /// rollup only ever touches that device's own instances. The device tree
    /// recomputes every visible row's summary whenever a heartbeat mutates
    /// the map, so the rollup must stay O(instances of one device), never
    /// O(all instances on the team).
    private var instancesByDevice: [String: [String: PresenceInstance]] = [:]

    public init() {}

    /// Whether any presence data has been received yet. The device tree only
    /// overrides its registry-derived "last seen" hints once a snapshot exists.
    public var isEmpty: Bool { instancesByDevice.isEmpty }

    /// Apply one stream frame. A snapshot replaces the whole map (the protocol
    /// is snapshot-first on every (re)subscribe, which is also how a dropped
    /// frame heals); transition events upsert single instances.
    public mutating func apply(_ update: PresenceUpdate) {
        switch update {
        case .snapshot(let snapshot):
            var next: [String: [String: PresenceInstance]] = [:]
            for device in snapshot.devices {
                for instance in device.instances {
                    next[instance.deviceId, default: [:]][instance.tag] = instance
                }
            }
            instancesByDevice = next
        case .online(let instance), .routes(let instance), .offline(let instance, _):
            instancesByDevice[instance.deviceId, default: [:]][instance.tag] = instance
        case .seen(let deviceId, let tag, let lastSeenAt):
            guard var instance = instancesByDevice[deviceId]?[tag] else { return }
            instance.lastSeenAt = lastSeenAt
            instancesByDevice[deviceId]?[tag] = instance
        }
    }

    /// The live presence record for one app instance, if known.
    public func instance(deviceId: String, tag: String) -> PresenceInstance? {
        instancesByDevice[deviceId]?[tag]
    }

    /// The device's single online route-advertising instance, or `nil` when
    /// zero or 2+ online instances advertise routes. The paired-Mac store is
    /// device-level (no tag), so persisted reconnect routes may only be
    /// substituted when it is unambiguous which build they belong to; this is
    /// the live-presence mirror of the registry refresh's multi-instance guard
    /// (``DeviceRegistryService/routes(forMacDeviceID:in:)``).
    public func soleRouteAdvertisingInstance(deviceId: String) -> PresenceInstance? {
        guard let instances = instancesByDevice[deviceId] else { return nil }
        let candidates = instances.values.filter { $0.online && !($0.routes ?? []).isEmpty }
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Roll the device's instances up for a device row, or `nil` when the
    /// presence service has never seen this device (the row then falls back to
    /// its registry "last seen" hint).
    public func deviceSummary(deviceId: String) -> DeviceSummary? {
        guard let instances = instancesByDevice[deviceId], !instances.isEmpty else { return nil }
        var online = false
        var lastSeenMs = -Double.infinity
        // Pick the instance to label the build from: prefer an online one (the
        // build actually running), then the freshest. A device usually has one.
        var labelInstance: PresenceInstance?
        for instance in instances.values {
            online = online || instance.online
            lastSeenMs = max(lastSeenMs, instance.lastSeenAt)
            if let current = labelInstance {
                let better = (instance.online && !current.online)
                    || (instance.online == current.online && instance.lastSeenAt > current.lastSeenAt)
                if better { labelInstance = instance }
            } else {
                labelInstance = instance
            }
        }
        return DeviceSummary(
            online: online,
            lastSeenAt: Date(timeIntervalSince1970: lastSeenMs / 1000),
            buildLabel: MacBuildChannel().label(bundleID: labelInstance?.bundleId, tag: labelInstance?.tag)
        )
    }
}
