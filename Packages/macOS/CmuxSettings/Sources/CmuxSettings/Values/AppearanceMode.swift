import Foundation

/// User-selectable appearance for the cmux app.
///
/// Drives the SwiftUI color scheme and the Ghostty terminal theme synchronization.
/// Stored under the catalog entry ``SettingCatalog/appAppearance``.
public enum AppearanceMode: String, CaseIterable, Sendable, SettingCodable {
    /// Follow the macOS system appearance.
    case system
    /// Always use the light variant.
    case light
    /// Always use the dark variant.
    case dark
}
