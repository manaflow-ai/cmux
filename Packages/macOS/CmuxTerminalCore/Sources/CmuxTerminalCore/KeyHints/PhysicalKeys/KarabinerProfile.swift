public import Foundation

/// The selected profile of a Karabiner-Elements `karabiner.json`: its
/// simple modifications, per-device settings, and complex modification
/// manipulators, in the order Karabiner applies them.
public struct KarabinerProfile: Sendable, Equatable {
    /// What a simple modification sends for a key.
    enum SimpleTarget: Sendable, Equatable {
        /// Another key; ``PhysicalKey/noAction`` when the key is turned off.
        case key(PhysicalKey)
        /// Something cmux doesn't model (a consumer key, a mouse button, a chord).
        case unknown
    }

    /// A `devices` entry: settings for the keyboards its identifiers pick.
    struct Device: Sendable, Equatable {
        var identifiers: KarabinerDeviceIdentifiers
        var ignore: Bool?
        var simpleModifications: [PhysicalKey: SimpleTarget]
    }

    var simpleModifications: [PhysicalKey: SimpleTarget]
    var devices: [Device]
    var manipulators: [KarabinerManipulator]

    /// No modifications: what Karabiner-Elements runs without a `karabiner.json`.
    public static let empty = KarabinerProfile()

    init(
        simpleModifications: [PhysicalKey: SimpleTarget] = [:],
        devices: [Device] = [],
        manipulators: [KarabinerManipulator] = []
    ) {
        self.simpleModifications = simpleModifications
        self.devices = devices
        self.manipulators = manipulators
    }

    /// Parses `karabiner.json` and keeps the profile marked `selected`.
    ///
    /// Rules whose `enabled` is `false` are skipped. Returns `nil` when the
    /// file isn't valid JSON or no profile is selected.
    ///
    /// - Parameter configurationData: The contents of `karabiner.json`.
    public init?(configurationData: Data) {
        guard let root = try? JSONSerialization.jsonObject(with: configurationData) as? [String: Any],
              let profiles = root["profiles"] as? [[String: Any]],
              let profile = profiles.first(where: { $0["selected"] as? Bool == true }) else { return nil }
        simpleModifications = Self.simpleModifications(profile["simple_modifications"])
        devices = (profile["devices"] as? [[String: Any]] ?? []).map { device in
            Device(
                identifiers: KarabinerDeviceIdentifiers(json: device["identifiers"] as? [String: Any] ?? [:]),
                ignore: device["ignore"] as? Bool,
                simpleModifications: Self.simpleModifications(device["simple_modifications"])
            )
        }
        var manipulators: [KarabinerManipulator] = []
        let complex = profile["complex_modifications"] as? [String: Any] ?? [:]
        for rule in complex["rules"] as? [[String: Any]] ?? [] where rule["enabled"] as? Bool != false {
            for manipulator in rule["manipulators"] as? [[String: Any]] ?? [] {
                if let parsed = KarabinerManipulator(json: manipulator) {
                    manipulators.append(parsed)
                }
            }
        }
        self.manipulators = manipulators
    }

    /// The `devices` entry that applies to `device`, preferring an entry
    /// for the keyboard alone over one for a combined keyboard and pointing
    /// device.
    ///
    /// - Returns: The entry, or `nil` for none; `certain` is false when an
    ///   entry names something cmux can't check, so it may be this device.
    func deviceSettings(for device: KeyboardDevice) -> (settings: Device?, certain: Bool) {
        var matching: [Device] = []
        for entry in devices {
            switch entry.identifiers.isEntry(for: device) {
            case true?: matching.append(entry)
            case nil: return (nil, false)
            case false?: continue
            }
        }
        return (matching.first { $0.identifiers.isPointingDevice != true } ?? matching.first, true)
    }

    private static func simpleModifications(_ value: Any?) -> [PhysicalKey: SimpleTarget] {
        var result: [PhysicalKey: SimpleTarget] = [:]
        for entry in value as? [[String: Any]] ?? [] {
            guard let from = entry["from"] as? [String: Any],
                  let name = from["key_code"] as? String,
                  let key = PhysicalKey(karabinerKeyCode: name) else { continue }
            result[key] = simpleTarget(entry["to"])
        }
        return result
    }

    /// `to` is an array of events in current files and an object in old ones.
    private static func simpleTarget(_ value: Any?) -> SimpleTarget {
        let entries: [Any]
        if let array = value as? [Any] {
            entries = array
        } else if let single = value as? [String: Any] {
            entries = [single]
        } else {
            return .unknown
        }
        if entries.isEmpty { return .key(.noAction) }
        guard entries.count == 1, let entry = entries.first as? [String: Any],
              Set(entry.keys) == ["key_code"], let name = entry["key_code"] as? String else { return .unknown }
        if name == "vk_none" { return .key(.noAction) }
        guard let key = PhysicalKey(karabinerKeyCode: name) else { return .unknown }
        return .key(key)
    }
}
