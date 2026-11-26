import Foundation

/// Parses `adb devices -l` (`cmux-phone-core`'s op `adb_devices`).
struct AndroidDeviceList {
    struct Entry: Sendable, Hashable, Decodable {
        var serial: String
        /// "device", "offline", "unauthorized".
        var state: String
        /// The `model:` field ("Pixel_7"), when adb reports it.
        var model: String?

        var isEmulator: Bool { serial.hasPrefix("emulator-") }
    }

    func parse(_ output: Data) -> [Entry] {
        (try? PhoneRules.decode([Entry].self, "devices", "adb_devices", ["output": PhoneRules.text(output)],
                                what: "the adb device list")) ?? []
    }
}
