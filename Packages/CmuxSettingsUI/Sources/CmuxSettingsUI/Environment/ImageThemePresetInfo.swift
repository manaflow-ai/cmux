import Foundation

/// Lightweight descriptor of a bundled image-theme preset, surfaced to the
/// settings UI so the package can render a preset picker without depending on
/// the host's concrete theme catalog.
///
/// The host (`SettingsHostActions.availableImageThemePresets()`) maps its own
/// preset list into these values; the Sidebar section renders a menu from them
/// and calls back with ``key`` to apply one.
public struct ImageThemePresetInfo: Identifiable, Hashable {
    /// Stable identifier persisted in settings and passed to
    /// `SettingsHostActions.applyImageThemePreset(_:)` (snake_case, e.g.
    /// `solar_flare`).
    public let key: String

    /// Human-readable name shown in the preset menu (a theme proper noun).
    public let name: String

    /// The preset's default image opacity in the range `0...1`, applied to the
    /// background image when the preset is selected.
    public let opacity: Double

    /// Creates a preset descriptor.
    /// - Parameters:
    ///   - key: Stable persisted identifier.
    ///   - name: Display name for the menu.
    ///   - opacity: Default image opacity (`0...1`).
    public init(key: String, name: String, opacity: Double) {
        self.key = key
        self.name = name
        self.opacity = opacity
    }

    /// `Identifiable` conformance; returns ``key``.
    public var id: String { key }
}
