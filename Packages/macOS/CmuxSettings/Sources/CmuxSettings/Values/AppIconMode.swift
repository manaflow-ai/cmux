import Foundation

/// Dock icon variant. `automatic` follows the system appearance.
public enum AppIconMode: String, CaseIterable, Identifiable, Sendable, SettingCodable {
    case automatic, light, dark

    /// Stable identity for SwiftUI pickers; equals the persisted raw value.
    public var id: String { rawValue }

    /// Asset-catalog image name for the manually-pinned icon, or `nil` for
    /// ``automatic`` (the appearance observer chooses the image at runtime).
    public var imageName: String? {
        switch self {
        case .automatic: return nil
        case .light: return "AppIconLight"
        case .dark: return "AppIconDark"
        }
    }
}
