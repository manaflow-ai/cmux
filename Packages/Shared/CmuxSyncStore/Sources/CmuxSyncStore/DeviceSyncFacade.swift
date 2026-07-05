public import CMUXMobileCore
public import CmuxMobileShellModel
import Foundation

/// The `devices` collection name. Must match `DEVICES_COLLECTION` in the worker.
public let devicesSyncCollection = "devices"

/// Decodes and discards one arbitrary JSON value, used to advance an unkeyed
/// container past an element that failed strict decoding (so a single bad route
/// does not abort the whole array). It accepts any JSON shape.
private struct AnyDecodableSkip: Decodable {
    init(from decoder: any Decoder) throws {
        // A single-value container accepts any JSON scalar; for objects/arrays we
        // fall back to an empty keyed/unkeyed read. Either way the element is
        // consumed so the parent unkeyed cursor advances by one.
        if let single = try? decoder.singleValueContainer(), !single.decodeNil() {
            // Try the common scalar shapes; ignore the value.
            if (try? single.decode(Bool.self)) != nil { return }
            if (try? single.decode(Double.self)) != nil { return }
            if (try? single.decode(String.self)) != nil { return }
        }
        // Object or array element: read it as a keyed/unkeyed container to consume.
        if (try? decoder.container(keyedBy: SkipKey.self)) != nil { return }
        _ = try? decoder.unkeyedContainer()
    }
    private struct SkipKey: CodingKey {
        var stringValue: String; var intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; self.intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }
}

/// The durable device-list record the iOS tree renders. The Swift mirror of the
/// worker's `DeviceRecord` (workers/presence/src/syncDevices.ts). Carries the
/// LIST-SHAPE only: identity, owner, routes, and the per-tag instance set. Live
/// online/offline and per-tick freshness ride the presence overlay, not this
/// record (DESIGN.md §4.2).
public struct SyncedDeviceRecord: Codable, Equatable, Sendable {
    public var deviceId: String
    public var platform: String
    public var displayName: String?
    public var ownerUserId: String?
    /// Epoch ms AS OF this rev (not live freshness). Seeds "last seen ~N ago"
    /// when there is no live presence link.
    public var lastSeenAtAtRev: Double
    public var instances: [InstanceRecord]

    public struct InstanceRecord: Codable, Equatable, Sendable {
        public var tag: String
        public var routes: [CmxAttachRoute]
        public var lastSeenAtAtRev: Double

        private enum CodingKeys: String, CodingKey {
            case tag, routes, lastSeenAtAtRev
        }

        public init(tag: String, routes: [CmxAttachRoute], lastSeenAtAtRev: Double) {
            self.tag = tag
            self.routes = routes
            self.lastSeenAtAtRev = lastSeenAtAtRev
        }

        /// Decode routes FAILABLY per entry: a future route kind or one malformed
        /// route must not drop the whole device row (which would hide a device the
        /// registry/presence paths still render). Bad routes are skipped; the rest
        /// of the instance decodes normally. Mirrors the registry/presence
        /// per-route decode contract (DESIGN.md §13 resilience).
        public init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.tag = try container.decode(String.self, forKey: .tag)
            self.lastSeenAtAtRev = try container.decode(Double.self, forKey: .lastSeenAtAtRev)
            self.routes = Self.decodeRoutesFailably(container)
        }

        public func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(tag, forKey: .tag)
            try container.encode(routes, forKey: .routes)
            try container.encode(lastSeenAtAtRev, forKey: .lastSeenAtAtRev)
        }

        private static func decodeRoutesFailably(
            _ container: KeyedDecodingContainer<CodingKeys>
        ) -> [CmxAttachRoute] {
            // The routes array is itself optional/absent-tolerant; an absent or
            // non-array field yields no routes (the device still renders, just
            // without an attach candidate).
            guard var unkeyed = try? container.nestedUnkeyedContainer(forKey: .routes) else {
                return []
            }
            var routes: [CmxAttachRoute] = []
            while !unkeyed.isAtEnd {
                // Decode each element independently. A failed element is skipped,
                // but we must still advance the cursor past it, so decode into a
                // throwaway `AnyDecodableSkip` on failure.
                if let route = try? unkeyed.decode(CmxAttachRoute.self) {
                    routes.append(route)
                } else {
                    _ = try? unkeyed.decode(AnyDecodableSkip.self)
                }
            }
            return routes
        }
    }

    public init(deviceId: String, platform: String, displayName: String?, ownerUserId: String?, lastSeenAtAtRev: Double, instances: [InstanceRecord]) {
        self.deviceId = deviceId
        self.platform = platform
        self.displayName = displayName
        self.ownerUserId = ownerUserId
        self.lastSeenAtAtRev = lastSeenAtAtRev
        self.instances = instances
    }
}

/// Typed read facade over the generic store for the `devices` collection. It is
/// the only code that knows the `devices` payload schema; the store and
/// transport stay generic (DESIGN.md §4.2). A row that fails to decode is
/// dropped (a tombstone, or a record from a future schema this build cannot
/// read), never crashing the list.
public struct DeviceSyncFacade: Sendable {
    private let store: any CmuxSyncStoring

    public init(store: any CmuxSyncStoring) {
        self.store = store
    }

    /// The instant launch read: live device records for a team, decoded and in
    /// render order (newest-seen first, the store's `sort_key DESC`). No network
    /// (DESIGN.md §3.3 t0). Undecodable rows are skipped.
    public func devices(teamID: String) async throws -> [SyncedDeviceRecord] {
        let rows = try await store.liveRecords(teamID: teamID, collection: devicesSyncCollection)
        let decoder = JSONDecoder()
        return rows.compactMap { row in
            try? decoder.decode(SyncedDeviceRecord.self, from: row.payloadJSON)
        }
    }

    /// The launch read mapped to the UI's existing `RegistryDevice` shape, so the
    /// shell's `loadRegistryDevices` local-first branch is a one-line swap with
    /// no new UI model (DESIGN.md §4.2: "No new UI model. The facade ... produc[es]
    /// the existing two-level RegistryDevice/RegistryAppInstance shape").
    public func registryDevices(teamID: String) async throws -> [RegistryDevice] {
        try await devices(teamID: teamID).map(Self.registryDevice(from:))
    }

    /// Map one synced record to the UI model. `lastSeenAtAtRev` is epoch ms (the
    /// as-of-rev value); `RegistryDevice.lastSeenAt`/`RegistryAppInstance.lastSeenAt`
    /// are `Date`s. The live liveness dot is still overlaid from presence on top
    /// of this, exactly as the registry path is overlaid today (DESIGN.md §4.2).
    public static func registryDevice(from record: SyncedDeviceRecord) -> RegistryDevice {
        RegistryDevice(
            deviceId: record.deviceId,
            platform: record.platform,
            displayName: record.displayName,
            lastSeenAt: Date(timeIntervalSince1970: record.lastSeenAtAtRev / 1000.0),
            instances: record.instances.map { inst in
                RegistryAppInstance(
                    tag: inst.tag,
                    routes: inst.routes,
                    lastSeenAt: Date(timeIntervalSince1970: inst.lastSeenAtAtRev / 1000.0)
                )
            }
        )
    }

    /// The render-order hint for a device wire record: its newest instance's
    /// `lastSeenAtAtRev` (epoch ms), used as the store `sort_key`. Decoding the
    /// payload here keeps the sort rule in the facade, not the generic store.
    public static func sortKey(for record: SyncWireRecord) -> Double {
        guard let decoded = try? JSONDecoder().decode(SyncedDeviceRecord.self, from: record.payloadJSON) else {
            return 0
        }
        return decoded.lastSeenAtAtRev
    }
}
