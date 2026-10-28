import CmuxNextCompat
import Foundation

/// The shape of a tool's settings file the detector reads one key from.
nonisolated enum ScreenshotSettingsFileFormat: Sendable {
    /// `key=value` lines (Qt's ini, Flameshot).
    case ini
    /// A JSON object (electron-store, Kap).
    case json

    /// The string value of `key` in `text`, nil when absent.
    func value(of key: String, in text: String) -> String? {
        switch self {
        case .ini:
            for line in text.split(whereSeparator: \.isNewline) {
                let parts = line.split(separator: "=", maxSplits: 1)
                guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == key else { continue }
                let value = parts[1].trimmingCharacters(in: .whitespaces)
                return value.isEmpty ? nil : value
            }
            return nil
        case .json:
            guard let data = text.data(using: .utf8),
                  let object = try? JSONSerialization.blockingJSONObject(with: data) as? [String: Any] else { return nil }
            return object[key] as? String
        }
    }
}
