import CMUXMobileCore
import CmuxCloud
import CmuxSurfaceCatalogModel
import Foundation

/// One running cmux app instance on a device, as the presence service reports
/// it. Mirrors `workers/presence/src/core.ts` (`PresenceInstance`) and the iOS
/// twin in `CmuxMobileShell/PresenceInstance.swift`; the identities match the
/// durable registry (`devices.device_uuid`, `device_app_instances.tag`).
struct DevicePresenceInstance: Decodable, Equatable, Sendable {
    let deviceId: String
    let tag: String
    let platform: String
    let displayName: String?
    let bundleId: String?
    let online: Bool
    /// Epoch milliseconds of the last heartbeat.
    let lastSeenAt: Double
    /// Attach routes mirrored live from the host's heartbeat. Decoded per entry
    /// so a route kind this build cannot dial never drops the whole instance.
    let routes: [CmxAttachRoute]?

    private enum CodingKeys: String, CodingKey {
        case deviceId, tag, platform, displayName, bundleId, online, lastSeenAt, routes
    }

    private struct FailableRoute: Decodable {
        let value: CmxAttachRoute?
        init(from decoder: any Decoder) {
            value = try? CmxAttachRoute(from: decoder)
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        deviceId = try container.decode(String.self, forKey: .deviceId)
        tag = try container.decodeIfPresent(String.self, forKey: .tag) ?? SurfaceDeviceInstanceID.defaultTag
        platform = try container.decodeIfPresent(String.self, forKey: .platform) ?? "mac"
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId)
        online = try container.decodeIfPresent(Bool.self, forKey: .online) ?? false
        lastSeenAt = try container.decodeIfPresent(Double.self, forKey: .lastSeenAt) ?? 0
        routes = try container.decodeIfPresent([FailableRoute].self, forKey: .routes)?.compactMap(\.value)
    }

    init(
        deviceId: String,
        tag: String,
        platform: String = "mac",
        displayName: String? = nil,
        bundleId: String? = nil,
        online: Bool,
        lastSeenAt: Double,
        routes: [CmxAttachRoute]? = nil
    ) {
        self.deviceId = deviceId
        self.tag = tag
        self.platform = platform
        self.displayName = displayName
        self.bundleId = bundleId
        self.online = online
        self.lastSeenAt = lastSeenAt
        self.routes = routes
    }

    var instanceID: SurfaceDeviceInstanceID { SurfaceDeviceInstanceID(deviceID: deviceId, tag: tag) }
}

/// The per-device rollup in a presence snapshot (`PresenceDevice` in core.ts).
struct DevicePresenceDevice: Decodable, Equatable, Sendable {
    let deviceId: String
    let instances: [DevicePresenceInstance]
}

/// The durable device-list record the worker's `devices` sync collection
/// carries (`DeviceRecord` in `workers/presence/src/syncDevices.ts`). It is the
/// only source that names the device's owner, which the directory needs before
/// it may present this account's bearer token to a host.
struct DeviceSyncDeviceRecord: Decodable, Equatable, Sendable {
    let deviceId: String
    let ownerUserId: String?

    private enum CodingKeys: String, CodingKey {
        case deviceId, ownerUserId
    }
}

/// One `sync.snapshot` / `sync.delta` record envelope (`SyncWireRecord`).
struct DeviceSyncRecord: Equatable, Sendable {
    let id: String
    let deleted: Bool
    let device: DeviceSyncDeviceRecord?
}

/// One `vms` sync record (`VmRecord` in `workers/presence/src/syncVms.ts`):
/// the same entry shape `GET /api/vm` lists, decoded by the list parser, or a
/// tombstone (`deleted`) carrying no summary.
struct VMSyncRecord: Equatable, Sendable {
    let id: String
    let deleted: Bool
    let summary: VMSummary?
}

/// One message from the presence subscribe socket. Presence frames mirror
/// `PresenceEvent` in core.ts; sync frames mirror `sync.ts`. Anything this
/// build does not understand parses as `.ignored`, so a newer worker never
/// breaks an older Mac.
enum DevicePresenceFrame: Equatable, Sendable {
    case snapshot(devices: [DevicePresenceDevice])
    case online(DevicePresenceInstance)
    case offline(DevicePresenceInstance)
    case seen(deviceId: String, tag: String, lastSeenAt: Double)
    case routes(DevicePresenceInstance)
    /// A page of the `devices` collection; `complete` ends the page set.
    case syncSnapshot(records: [DeviceSyncRecord], complete: Bool)
    case syncDelta(records: [DeviceSyncRecord])
    /// A page of the `vms` collection. `backfilled` false means the worker has
    /// never held a full list (only rows written since the collection
    /// shipped), so the consumer applies the page set upsert-only. On the
    /// `complete` page `snapshotRev` and `epoch` become the reconnect cursor.
    case vmsSnapshot(records: [VMSyncRecord], complete: Bool, backfilled: Bool, snapshotRev: Int, epoch: Int)
    /// Changed `vms` records; `rev` is the head this frame brings the cursor to.
    case vmsDelta(records: [VMSyncRecord], rev: Int)
    case ignored

    static let devicesCollection = "devices"
    static let vmsCollection = "vms"

    /// One collection a `sync.hello` asks for, with the cursor and epoch the
    /// client already holds (0/0 for a fresh snapshot).
    struct SyncCollection: Equatable, Sendable {
        let name: String
        let cursor: Int
        let epoch: Int

        init(name: String, cursor: Int = 0, epoch: Int = 0) {
            self.name = name
            self.cursor = cursor
            self.epoch = epoch
        }

        /// The device directory's subscription: always a fresh snapshot.
        static let devices = SyncCollection(name: DevicePresenceFrame.devicesCollection)
    }

    /// Parse one socket message. Throws only for non-JSON payloads.
    static func parse(_ data: Data) throws -> DevicePresenceFrame {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return .ignored
        }
        switch type {
        case "snapshot":
            guard let rawDevices = object["devices"] as? [Any] else { return .ignored }
            let devices = rawDevices.compactMap { raw -> DevicePresenceDevice? in
                guard let data = try? JSONSerialization.data(withJSONObject: raw) else { return nil }
                return try? JSONDecoder().decode(DevicePresenceDevice.self, from: data)
            }
            return .snapshot(devices: devices)
        case "online", "offline", "routes":
            guard let raw = object["instance"],
                  let data = try? JSONSerialization.data(withJSONObject: raw),
                  let instance = try? JSONDecoder().decode(DevicePresenceInstance.self, from: data) else {
                return .ignored
            }
            switch type {
            case "online": return .online(instance)
            case "offline": return .offline(instance)
            default: return .routes(instance)
            }
        case "seen":
            guard let deviceId = object["deviceId"] as? String,
                  let tag = object["tag"] as? String,
                  let lastSeenAt = (object["lastSeenAt"] as? NSNumber)?.doubleValue else {
                return .ignored
            }
            return .seen(deviceId: deviceId, tag: tag, lastSeenAt: lastSeenAt)
        case "sync.snapshot", "sync.delta":
            let rawRecords = (object["records"] as? [Any]) ?? []
            switch object["collection"] as? String {
            case devicesCollection:
                let records = rawRecords.compactMap(Self.syncRecord)
                if type == "sync.snapshot" {
                    return .syncSnapshot(records: records, complete: (object["complete"] as? Bool) ?? false)
                }
                return .syncDelta(records: records)
            case vmsCollection:
                let records = rawRecords.enumerated().compactMap { Self.vmSyncRecord($0.element, index: $0.offset) }
                if type == "sync.snapshot" {
                    return .vmsSnapshot(
                        records: records,
                        complete: (object["complete"] as? Bool) ?? false,
                        backfilled: (object["backfilled"] as? Bool) ?? false,
                        snapshotRev: Self.revision(object["snapshotRev"]),
                        epoch: Self.revision(object["epoch"])
                    )
                }
                return .vmsDelta(records: records, rev: Self.revision(object["rev"]))
            default:
                return .ignored
            }
        default:
            return .ignored
        }
    }

    /// The `sync.hello` a client sends after connect to receive `collections`
    /// (snapshot first, deltas after) on the same socket. The default asks for
    /// `devices` from cursor 0 in epoch 0: the directory keeps no durable
    /// cursor, so every connect starts from a fresh snapshot, which is also the
    /// protocol's supported resync path. The `vms` consumer passes the cursor
    /// it last applied so a reconnect catches up with deltas.
    static func syncHello(collections: [SyncCollection] = [.devices]) -> Data {
        let payload: [String: Any] = [
            "type": "sync.hello",
            "protocol": "sync/v1",
            "collections": collections.map { ["name": $0.name, "cursor": $0.cursor, "epoch": $0.epoch] },
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    /// A non-negative integer cursor; anything else reads as 0 (fresh).
    private static func revision(_ raw: Any?) -> Int {
        guard let number = raw as? NSNumber, number.doubleValue.isFinite, number.doubleValue >= 0 else { return 0 }
        return number.intValue
    }

    /// A live record whose payload the list parser rejects is dropped (never
    /// a tombstone), so one malformed machine cannot delete a row.
    private static func vmSyncRecord(_ raw: Any, index: Int) -> VMSyncRecord? {
        guard let object = raw as? [String: Any], let id = object["id"] as? String, !id.isEmpty else { return nil }
        let deleted = (object["deleted"] as? Bool) ?? false
        if deleted { return VMSyncRecord(id: id, deleted: true, summary: nil) }
        guard let payload = object["payload"] as? [String: Any],
              let summary = try? VMClient.decodeListItem(payload, index: index),
              summary.id == id else { return nil }
        return VMSyncRecord(id: id, deleted: false, summary: summary)
    }

    private static func syncRecord(_ raw: Any) -> DeviceSyncRecord? {
        guard let object = raw as? [String: Any], let id = object["id"] as? String else { return nil }
        let deleted = (object["deleted"] as? Bool) ?? false
        var device: DeviceSyncDeviceRecord?
        if !deleted, let payload = object["payload"],
           let data = try? JSONSerialization.data(withJSONObject: payload) {
            device = try? JSONDecoder().decode(DeviceSyncDeviceRecord.self, from: data)
        }
        return DeviceSyncRecord(id: id, deleted: deleted, device: device)
    }
}
