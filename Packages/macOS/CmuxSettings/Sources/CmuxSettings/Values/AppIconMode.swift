import Foundation

/// Dock icon variant. `automatic` follows the system appearance.
public enum AppIconMode: String, CaseIterable, Sendable, SettingCodable {
    case automatic, light, dark
}
