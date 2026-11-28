public import Foundation

/// Parses `xcrun simctl list devices -j` into phones (iPhone and iPad
/// simulators on iOS runtimes; watch, TV and vision runtimes are skipped),
/// booted first, then newest runtime first, then by name. The rules are
/// `cmux-phone-core`'s (op `simctl_devices`).
public struct SimctlDeviceList: Sendable {
    public init() {}

    public func parse(_ json: Data) throws -> [PhoneDevice] {
        try PhoneRules.decode([PhoneDeviceReply].self, "devices", "simctl_devices", ["output": PhoneRules.text(json)],
                              what: "the simulator list").map(\.device)
    }
}
