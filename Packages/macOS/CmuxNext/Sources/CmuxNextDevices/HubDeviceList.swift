internal import CCmuxLayoutReducerFFI
public import Foundation

/// The hub's records as physical devices (Rust `cloud_identity_device_list`, cmux-cloud-config
/// `device_list`): every build of cmux with its own bundle id (NIGHTLY, DEV, a tagged DEV) is its
/// own identity and so its own hub record with the same Computer Name, and a renewed identity
/// leaves its old record behind. Records of one platform and one folded name are one device;
/// this device's are This Mac, never a remote (Leo's Screen Sharing page listed cosmic-gray
/// twice, Offline, while he sat on it, 2026-11-15).
public struct HubDeviceList: Equatable, Sendable {
    /// Every record of this device: its own id first, then its other builds'.
    public var thisDevice: [String]
    /// The other devices, one each: the record to show and connect to.
    public var others: [HubDevice]

    public init(thisDevice: [String], others: [HubDevice]) {
        self.thisDevice = thisDevice
        self.others = others
    }

    /// `devices` as physical devices for the device `thisID` names (`thisName` and `thisPlatform`
    /// mark it before the hub lists its record). When the rules do not answer, every other record
    /// is a device, as before.
    public static func make(thisID: String, thisName: String? = nil, thisPlatform: DevicePlatform? = nil,
                            devices: [HubDevice]) -> HubDeviceList {
        let others = devices.filter { $0.id != thisID }
        guard let answer = ask(thisID: thisID, thisName: thisName, thisPlatform: thisPlatform, devices: devices) else {
            return HubDeviceList(thisDevice: [thisID], others: others)
        }
        let byID = Dictionary(others.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return HubDeviceList(thisDevice: answer.thisDevice, others: answer.others.compactMap { byID[$0.id] })
    }

    private struct Answer: Decodable {
        struct Machine: Decodable { var id: String; var ids: [String] }
        var thisDevice: [String]
        var others: [Machine]
    }

    private static func ask(thisID: String, thisName: String?, thisPlatform: DevicePlatform?, devices: [HubDevice]) -> Answer? {
        struct This: Encodable { var id: String; var name: String?; var platform: String? }
        struct Record: Encodable {
            var id: String, name: String, platform: String?, online: Bool, macScreenShared: Bool
            var lastSeenAt: Double?, createdAt: Double?
        }
        struct Request: Encodable { var this: This; var devices: [Record] }
        let request = Request(
            this: This(id: thisID, name: thisName, platform: thisPlatform?.rawValue),
            devices: devices.map {
                Record(id: $0.id, name: $0.name, platform: $0.platform?.rawValue, online: $0.online, macScreenShared: $0.macScreenShared,
                       lastSeenAt: $0.lastSeenAt?.timeIntervalSince1970, createdAt: $0.createdAt?.timeIntervalSince1970)
            })
        guard let body = try? JSONEncoder().encode(request), let reply = call("cloud_identity_device_list", body) else { return nil }
        return try? JSONDecoder().decode(Answer.self, from: reply)
    }

    /// One JSON call of the app FFI (`cmux_layout_reducer_json`); nil when it does not answer.
    private static func call(_ operation: String, _ request: Data) -> Data? {
        var capacity = 16384
        for _ in 0..<2 {
            var output = [UInt8](repeating: 0, count: capacity)
            var length = 0
            let code: Int32 = request.withUnsafeBytes { bytes in
                operation.withCString { op in
                    output.withUnsafeMutableBytes { out in
                        cmux_layout_reducer_json(bytes.bindMemory(to: UInt8.self).baseAddress, request.count, op,
                                                 out.bindMemory(to: UInt8.self).baseAddress, out.count, &length)
                    }
                }
            }
            if code == CMUX_LAYOUT_REDUCER_ERR_BUFFER, length > capacity { capacity = length; continue }
            guard code == CMUX_LAYOUT_REDUCER_OK, length <= capacity else { return nil }
            return Data(output.prefix(length))
        }
        return nil
    }
}

extension DeviceHub {
    /// This device and the user's other devices, one per physical device (``HubDeviceList``).
    public var deviceList: HubDeviceList {
        HubDeviceList.make(thisID: identity.id, thisName: deviceName, thisPlatform: platform, devices: devices)
    }

    /// The user's other devices, one per physical device; this Mac's other builds are left out.
    public var remoteDevices: [HubDevice] { deviceList.others }
}
