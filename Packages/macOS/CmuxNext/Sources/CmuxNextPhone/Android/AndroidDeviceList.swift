import Foundation

/// Parses `adb devices -l`.
struct AndroidDeviceList {
    struct Entry: Sendable, Hashable {
        var serial: String
        /// "device", "offline", "unauthorized".
        var state: String
        /// The `model:` field ("Pixel_7"), when adb reports it.
        var model: String?

        var isEmulator: Bool { serial.hasPrefix("emulator-") }
    }

    func parse(_ output: Data) -> [Entry] {
        String(decoding: output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
            let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)) }
            return Entry(serial: fields[0], state: fields[1], model: model)
        }
    }
}
