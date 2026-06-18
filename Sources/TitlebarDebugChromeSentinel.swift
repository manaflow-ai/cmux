import SwiftUI

/// Owns the titlebar debug-inset subscriptions on a leaf and reapplies window
/// decorations when they actually change. The keys contain dots
/// (`titlebarDebug.…`), which breaks `@AppStorage`'s per-key KVO — SwiftUI
/// falls back to invalidating the holder on every `UserDefaults` write — so
/// the window-root `ContentView` must not hold them itself
/// (https://github.com/manaflow-ai/cmux/issues/5732).
struct TitlebarDebugChromeSentinel: View {
    let onDebugChromeChange: () -> Void

    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsLeadingInsetKey)
    private var leftControlsLeadingInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsLeadingInset
    @AppStorage(MinimalModeTitlebarDebugSettings.leftControlsTopInsetKey)
    private var leftControlsTopInset = MinimalModeTitlebarDebugSettings.defaultLeftControlsTopInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTabBarInsetKey)
    private var trafficLightTabBarInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTabBarInset
    @AppStorage(MinimalModeTitlebarDebugSettings.trafficLightTitlebarLeadingInsetKey)
    private var trafficLightTitlebarLeadingInset = MinimalModeTitlebarDebugSettings.defaultTrafficLightTitlebarLeadingInset

    private var snapshot: MinimalModeTitlebarDebugSnapshot {
        MinimalModeTitlebarDebugSnapshot(
            leftControlsLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                leftControlsLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            leftControlsTopInset: MinimalModeTitlebarDebugSettings.clamped(
                leftControlsTopInset,
                range: MinimalModeTitlebarDebugSettings.topInsetRange
            ),
            trafficLightTabBarLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                trafficLightTabBarInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            ),
            trafficLightTitlebarLeadingInset: MinimalModeTitlebarDebugSettings.clamped(
                trafficLightTitlebarLeadingInset,
                range: MinimalModeTitlebarDebugSettings.horizontalInsetRange
            )
        )
    }

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
            .onChange(of: snapshot) { _, _ in
                onDebugChromeChange()
            }
    }
}
