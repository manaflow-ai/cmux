public import CmuxMobileWire
public import Foundation

/// Parses `xcrun simctl list devices -j` into `SimulatorInfo`s (iOS runtimes
/// only, available devices only). The app runs the command; parsing is pure.
public struct SimctlSimulatorList: Sendable {
    public init() {}

    public func parse(_ json: Data) throws -> [SimulatorInfo] {
        guard let root = try JSONSerialization.jsonObject(with: json) as? [String: Any],
              let devices = root["devices"] as? [String: Any] else { return [] }
        var result: [SimulatorInfo] = []
        for (runtimeID, value) in devices.sorted(by: { $0.key > $1.key }) {
            guard let runtime = Self.runtimeName(runtimeID), let list = value as? [[String: Any]] else { continue }
            for device in list {
                guard device["isAvailable"] as? Bool ?? true, let udid = device["udid"] as? String,
                      let name = device["name"] as? String else { continue }
                let state: SimulatorInfo.State = (device["state"] as? String) == "Booted" ? .booted : .shutdown
                result.append(SimulatorInfo(udid: udid, name: name, runtime: runtime, state: state))
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
