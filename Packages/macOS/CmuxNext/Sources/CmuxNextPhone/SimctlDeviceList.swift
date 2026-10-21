public import Foundation

/// Parses `xcrun simctl list devices -j` into phones (iPhone and iPad
/// simulators on iOS runtimes; watch, TV and vision runtimes are skipped).
public struct SimctlDeviceList: Sendable {
    public init() {}

    private struct Listing: Decodable {
        let devices: [String: [Entry]]
    }

    private struct Entry: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
        let availabilityError: String?
        let deviceTypeIdentifier: String?
    }

    /// The phones in `json`, booted first, then newest runtime first, then by name.
    public func parse(_ json: Data) throws -> [PhoneDevice] {
        let listing = try JSONDecoder().decode(Listing.self, from: json)
        var phones: [(device: PhoneDevice, runtime: [Int])] = []
        for (runtimeID, entries) in listing.devices {
            guard let runtime = Self.iosRuntime(runtimeID) else { continue }
            for entry in entries {
                let state: PhoneDeviceState = if entry.isAvailable == false {
                    .unavailable(reason: entry.availabilityError ?? "unavailable")
                } else {
                    switch entry.state {
                    case "Booted": .ready
                    case "Booting": .booting
                    default: .shutdown
                    }
                }
                let device = PhoneDevice(
                    id: PhoneDeviceID(mode: .simulator, raw: entry.udid), name: entry.name,
                    model: Self.model(typeID: entry.deviceTypeIdentifier, fallback: entry.name),
                    osVersion: "iOS " + runtime.map(String.init).joined(separator: "."), state: state)
                phones.append((device, runtime))
            }
        }
        phones.sort { lhs, rhs in
            if lhs.device.state.isReady != rhs.device.state.isReady { return lhs.device.state.isReady }
            if lhs.runtime != rhs.runtime { return lhs.runtime.lexicographicallyPrecedes(rhs.runtime) == false }
            return lhs.device.name.localizedStandardCompare(rhs.device.name) == .orderedAscending
        }
        return phones.map(\.device)
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` -> [27, 0]; nil for other platforms.
    static func iosRuntime(_ id: String) -> [Int]? {
        let prefix = "com.apple.CoreSimulator.SimRuntime.iOS-"
        guard id.hasPrefix(prefix) else { return nil }
        let parts = id.dropFirst(prefix.count).split(separator: "-").compactMap { Int($0) }
        return parts.isEmpty ? nil : parts
    }

    /// `...SimDeviceType.iPhone-18-Pro-Max` -> "iPhone 18 Pro Max". The type
    /// id, not the user's name, so a renamed simulator still finds its frame.
    static func model(typeID: String?, fallback: String) -> String {
        let prefix = "com.apple.CoreSimulator.SimDeviceType."
        guard let typeID, typeID.hasPrefix(prefix) else { return fallback }
        let words = typeID.dropFirst(prefix.count).split(separator: "-").map(String.init)
        guard words.first == "iPhone" || words.first == "iPad" else { return fallback }
        return words.joined(separator: " ")
    }
}
