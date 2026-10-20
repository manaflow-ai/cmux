import AppKit
import CmuxWorkspaces

/// App-side `UserDefaults`-backed conformance to the window-background settings
/// seam. The default values match the legacy god-file reads byte-for-byte:
/// `sidebarBlendMode` -> `"withinWindow"`, `bgGlassEnabled` -> `false`.
struct UserDefaultsWindowBackgroundSettings: WindowBackgroundSettingsReading {
    // `UserDefaults` accessors are documented as thread-safe; the seam requires
    // `Sendable`, so suppress the non-Sendable stored-property check here rather
    // than boxing it.
    nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var sidebarBlendModeRawValue: String {
        defaults.string(forKey: "sidebarBlendMode") ?? "withinWindow"
    }

    var isBackgroundGlassEnabled: Bool {
        defaults.object(forKey: "bgGlassEnabled") as? Bool ?? false
    }
}

/// Transitional composition point for the window-background policy and the
/// compositor-blur controller, replacing the `cmux*` free functions that lived
/// in the terminal god file. These read `UserDefaults.standard` exactly as the
/// legacy free functions did; the proper composition root will inject them
/// later, mirroring the other transitional `GhosttyApp` statics.
enum WindowBackgroundComposition {
    /// The window-background policy reading from `UserDefaults.standard`.
    static let policy = WindowBackgroundPolicy(
        settings: UserDefaultsWindowBackgroundSettings()
    )

    /// The compositor-blur controller wrapping the private CGS shims.
    static let blurController = CompositorBlurController()
}
