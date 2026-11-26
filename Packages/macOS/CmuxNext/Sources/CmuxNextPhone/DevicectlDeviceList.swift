public import Foundation

/// Parses `xcrun devicectl list devices --json-output -` into real iPhones
/// and iPads. Simulated entries are skipped (``SimctlDeviceList`` owns them),
/// as are other platforms. The rules are `cmux-phone-core`'s (op `devicectl_devices`).
public struct DevicectlDeviceList: Sendable {
    public init() {}

    public func parse(_ json: Data) throws -> [PhoneDevice] {
        try PhoneRules.decode([PhoneDeviceReply].self, "devices", "devicectl_devices", ["output": PhoneRules.text(json)],
                              what: "the device list").map(\.device)
    }
}
