/// The narrow settings reads the window-background policy needs.
///
/// The window-glass decision in ``WindowBackgroundPolicy`` depends on two
/// persisted user settings (`sidebarBlendMode` and `bgGlassEnabled`). Rather
/// than reach into `UserDefaults.standard` from inside the policy package, the
/// app composition root conforms a `UserDefaults`-backed value to this seam and
/// injects it, so the policy stays pure and testable. The default values here
/// match the legacy god-file reads byte-for-byte: `sidebarBlendMode` defaults
/// to `"withinWindow"` and `bgGlassEnabled` defaults to `false`.
public protocol WindowBackgroundSettingsReading: Sendable {
    /// The raw `sidebarBlendMode` value (default `"behindWindow"`).
    var sidebarBlendModeRawValue: String { get }

    /// Whether the background-glass effect is enabled (default `true`).
    var isBackgroundGlassEnabled: Bool { get }
}
