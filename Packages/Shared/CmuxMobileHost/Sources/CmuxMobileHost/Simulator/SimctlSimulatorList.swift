public import CmuxMobileWire
public import Foundation

/// Parses `xcrun simctl list devices -j` into `SimulatorInfo`s (iOS runtimes
/// only, available devices only). The app runs the command; parsing is pure.
public struct SimctlSimulatorList: Sendable {
    struct Listing: Decodable {
        let devices: [String: [Device]]
    }

    struct Device: Decodable {
        let udid: String
        let name: String
        let state: String
        let isAvailable: Bool?
    }

    public init() {}

    public func parse(_ json: Data) throws -> [SimulatorInfo] {
        let listing = try JSONDecoder().decode(Listing.self, from: json)
        var result: [SimulatorInfo] = []
        for (runtimeID, devices) in listing.devices.sorted(by: { $0.key > $1.key }) {
            guard let runtime = Self.runtimeName(runtimeID) else { continue }
            for device in devices where device.isAvailable ?? true {
                result.append(SimulatorInfo(udid: device.udid, name: device.name, runtime: runtime,
                                            state: device.state == "Booted" ? .booted : .shutdown))
            }
        }
        return result
    }

    /// `com.apple.CoreSimulator.SimRuntime.iOS-27-0` -> `iOS 27.0`; nil for other platforms.
    static func runtimeName(_ id: String) -> String? {
        guard let suffix = id.split(separator: ".").last, suffix.hasPrefix("iOS-") else { return nil }
        let version = suffix.dropFirst(4).split(separator: "-").joined(separator: ".")
        return "iOS \(version)"
    }
}
