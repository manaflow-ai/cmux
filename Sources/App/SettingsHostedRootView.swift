import CmuxSettingsUI
import SwiftUI

/// Hosts the Settings UI inside the cmux-owned Settings window
/// (a ``CmuxHostedWindowController``).
///
/// Observes the appearance setting via `@AppStorage` so the window re-tints
/// live when the user changes the theme, `.cmuxAppearanceColorScheme(_:)` takes
/// a one-shot value, so the live binding is reproduced here.
struct SettingsHostedRootView: View {
    let runtime: SettingsRuntime
    @AppStorage(AppearanceSettings.appearanceModeKey)
    private var appearanceMode = AppearanceSettings.defaultMode.rawValue

    var body: some View {
        SettingsWindowRoot(runtime: runtime)
            .settingsRuntime(runtime)
            .cmuxAppearanceColorScheme(appearanceMode)
    }
}
