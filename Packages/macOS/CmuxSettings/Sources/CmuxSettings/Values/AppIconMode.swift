import Foundation

/// Dock icon variant. `system` leaves the bundle's layered icon alone so macOS
/// can apply its Dark, Tinted and Clear appearances; `automatic` follows the
/// system appearance with cmux's own light/dark bitmaps.
public enum AppIconMode: String, CaseIterable, Sendable, SettingCodable {
    case system, automatic, light, dark
}
