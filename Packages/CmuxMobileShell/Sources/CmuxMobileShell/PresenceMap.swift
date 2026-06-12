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

        public init(online: Bool, lastSeenAt: Date) {
            self.online = online
            self.lastSeenAt = lastSeenAt
        }
    }

    /// Instances keyed by ``Self/key(deviceId:tag:)``. `deviceId` is a
    /// fixed-format UUID, so the `":"`-joined composite key is unambiguous
    /// even though tags may contain `":"`.
    private var instancesByKey: [String: PresenceInstance] = [:]

    public init() {}

    /// Whether any presence data has been received yet. The device tree only
    /// overrides its registry-derived "last seen" hints once a snapshot exists.
    public var isEmpty: Bool { instancesByKey.isEmpty }

    private static func key(deviceId: String, tag: String) -> String {
        "\(deviceId):\(tag)"
    }

    /// Apply one stream frame. A snapshot replaces the whole map (the protocol
    /// is snapshot-first on every (re)subscribe, which is also how a dropped
    /// frame heals); transition events upsert single instances.
    public mutating func apply(_ update: PresenceUpdate) {
        switch update {
        case .snapshot(let snapshot):
            var next: [String: PresenceInstance] = [:]
            for device in snapshot.devices {
                for instance in device.instances {
                    next[Self.key(deviceId: instance.deviceId, tag: instance.tag)] = instance
                }
            }
            instancesByKey = next
        case .online(let instance), .routes(let instance), .offline(let instance, _):
            instancesByKey[Self.key(deviceId: instance.deviceId, tag: instance.tag)] = instance
        case .seen(let deviceId, let tag, let lastSeenAt):
            let key = Self.key(deviceId: deviceId, tag: tag)
            guard var instance = instancesByKey[key] else { return }
            instance.lastSeenAt = lastSeenAt
            instancesByKey[key] = instance
        }
    }

    /// The live presence record for one app instance, if known.
    public func instance(deviceId: String, tag: String) -> PresenceInstance? {
        instancesByKey[Self.key(deviceId: deviceId, tag: tag)]
    }

    /// Roll the device's instances up for a device row, or `nil` when the
    /// presence service has never seen this device (the row then falls back to
    /// its registry "last seen" hint).
    public func deviceSummary(deviceId: String) -> DeviceSummary? {
        var online = false
        var lastSeenMs: Double?
        for instance in instancesByKey.values where instance.deviceId == deviceId {
            online = online || instance.online
            lastSeenMs = max(lastSeenMs ?? instance.lastSeenAt, instance.lastSeenAt)
        }
        guard let lastSeenMs else { return nil }
        return DeviceSummary(
            online: online,
            lastSeenAt: Date(timeIntervalSince1970: lastSeenMs / 1000)
        )
    }
}
