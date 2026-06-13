public import Foundation

/// Resolves the `mobileAutoAttach` feature flag.
///
/// Auto-attach (registry-driven "sign in → connected") is on by default in DEBUG
/// builds for dogfood and off in Release until it has been dogfooded, matching
/// the macOS beta-feature convention of a `UserDefaults`-backed boolean. The flag
/// is read once at the composition root and injected into the shell as a plain
/// `Bool`, so the shell stays testable without touching `UserDefaults`.
public enum MobileAutoAttachFlag {
    /// The `UserDefaults` key. Present-and-set overrides the build default, so a
    /// dogfood Release build can opt in (or a DEBUG build can opt out) without a
    /// rebuild.
    public static let defaultsKey = "cmux.mobile.autoAttach.enabled"

    /// The build default when the key is absent: on in DEBUG, off in Release.
    public static var buildDefault: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// Whether auto-attach is enabled, honoring an explicit `UserDefaults`
    /// override and otherwise the build default.
    public static func isEnabled(defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: defaultsKey) != nil {
            return defaults.bool(forKey: defaultsKey)
        }
        return buildDefault
    }
}
