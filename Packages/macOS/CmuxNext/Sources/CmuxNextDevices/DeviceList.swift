public import Foundation

/// The hub's records as physical devices, as Rust decides (`cloud_identity_device_list`,
/// cmux-cloud-config `device_list`): each cmux build (NIGHTLY, DEV, tagged DEV) and each identity
/// renewal registers its own hub record, so one Mac can hold several. This device's other builds
/// are not remotes; every other device lists once, as the record a connect should reach.
public struct DeviceList: Sendable, Equatable {
    /// One physical device other than this one.
    public struct Machine: Sendable, Equatable, Decodable {
        /// The record to show and connect to.
        public var id: String
        /// Every record of the device, `id` first.
        public var ids: [String]
    }

    /// Every record of this device: its own id first, then its other builds'.
    public var thisDevice: [String]
    public var others: [Machine]

    /// Rust's listing of `devices` for this device (`thisID`, registering as `thisName`). Without an
    /// answer from Rust: every record but this one, each its own device (the list before the rule).
    public static func make(thisID: String, thisName: String, platform: DevicePlatform,
                            devices: [HubDevice]) -> DeviceList {
        struct This: Encodable { var id: String, name: String, platform: String }
        struct Record: Encodable {
            var id: String, name: String, platform: String?, online: Bool, macScreenShared: Bool
            var lastSeenAt: Double?, createdAt: Double?
        }
        struct Request: Encodable { var this: This, devices: [Record] }
        struct Reply: Decodable { var thisDevice: [String], others: [Machine] }
        let request = Request(this: This(id: thisID, name: thisName, platform: platform.rawValue), devices: devices.map {
            Record(id: $0.id, name: $0.name, platform: $0.platform?.rawValue, online: $0.online,
                   macScreenShared: $0.macScreenShared, lastSeenAt: $0.lastSeenAt?.timeIntervalSince1970,
                   createdAt: $0.createdAt?.timeIntervalSince1970)
        })
        if let data = try? JSONEncoder().encode(request), let answer = AppRules.call("cloud_identity_device_list", data),
           let reply = try? JSONDecoder().decode(Reply.self, from: answer) {
            return DeviceList(thisDevice: reply.thisDevice, others: reply.others)
        }
        return DeviceList(thisDevice: [thisID],
                          others: devices.filter { $0.id != thisID }.map { Machine(id: $0.id, ids: [$0.id]) })
    }
}
