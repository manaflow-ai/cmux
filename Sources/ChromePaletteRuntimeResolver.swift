import AppKit
import CmuxSettings
import CmuxSettingsUI

/// Resolves the app-facing chrome palette from the settings composition root.
///
/// The resolver is intentionally a value type with injected runtime state. It
/// keeps app-target composition code from reaching into JSON or UserDefaults
/// through a second global settings path.
@MainActor
struct ChromePaletteRuntimeResolver {
    private let runtime: SettingsRuntime?

    /// Creates a resolver over an optional settings runtime.
    ///
    /// - Parameter runtime: The app's settings dependency bundle. `nil` is
    ///   accepted for previews and early lifecycle fallbacks.
    init(runtime: SettingsRuntime?) {
        self.runtime = runtime
    }

    /// Resolves the current theme, appearance variant, and validated overrides.
    func resolve() -> ChromePalette {
        guard let runtime else {
            return ChromePalette.resolve(
                theme: .default,
                appearanceMode: .system,
                effectiveSystemScheme: effectiveSystemScheme
            )
        }

        return ChromePalette.resolve(
            theme: runtime.jsonStore.snapshotValue(for: runtime.catalog.chrome.theme),
            appearanceMode: runtime.userDefaultsStore.initialValue(for: runtime.catalog.app.appearance),
            effectiveSystemScheme: effectiveSystemScheme,
            overrides: runtime.jsonStore.snapshotValue(for: runtime.catalog.chrome.overrides)
        )
    }

    /// Resolves the current macOS light/dark appearance without consulting
    /// the terminal theme.
    var effectiveSystemScheme: ChromeColorScheme {
        let fallback = AppearanceSettings.systemNSAppearance()?.cmuxPrefersDark ?? false
        // Accessing NSApp.effectiveAppearance before application launch can
        // crash on newer macOS releases. Match AppearanceSettings' launch-safe
        // policy and use the persisted system fallback until AppKit is ready.
        let prefersDark = AppIconLaunchState.isApplicationFinishedLaunching()
            ? (NSApp?.effectiveAppearance.cmuxPrefersDark ?? fallback)
            : fallback
        return prefersDark ? .dark : .light
    }
}
