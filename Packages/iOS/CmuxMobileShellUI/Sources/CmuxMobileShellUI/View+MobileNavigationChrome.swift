import CMUXMobileCore
import SwiftUI

extension View {
    /// Inline navigation-bar title display mode (iOS); no-op elsewhere.
    @ViewBuilder
    func mobileInlineNavigationTitle() -> some View {
        #if os(iOS)
        self.navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    /// Translucent "liquid glass" navigation chrome for the terminal detail
    /// screen: the system bar material (Liquid Glass on iOS 26+, the translucent
    /// blur bar on iOS 18) lets the terminal / chat behind it show through,
    /// instead of the previous opaque terminal-colored fill.
    ///
    /// iOS 26: clear the bar's own background so the pane shows through the whole
    /// header. The readable "liquid glass" then comes from per-element glass —
    /// toolbar buttons get it automatically, and the title is wrapped in an
    /// explicit Liquid Glass capsule (`mobileGlassNavigationTitle`) so it stays
    /// legible over busy terminal text instead of floating bare.
    ///
    /// iOS 18 has no per-element glass, so keep a translucent material bar as the
    /// backing (which also backs the title); `mobileGlassNavigationTitle` is a
    /// no-op there. The toolbar color scheme follows the terminal background so
    /// system title and button glyphs remain legible for light and dark themes.
    @ViewBuilder
    func mobileTerminalNavigationChrome(theme: TerminalTheme? = nil) -> some View {
        #if os(iOS)
        let colorScheme = theme.map { TerminalPalette.colorScheme(for: $0) } ?? .dark
        if #available(iOS 26.0, *) {
            self
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.hidden, for: .navigationBar)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
        } else {
            self
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
        }
        #else
        self
        #endif
    }

    /// Keeps the legacy chat top gap on pre-iOS 26 material bars. On iOS 26 the
    /// UIKit chat controller handles the top underlap for native scroll-edge
    /// blending, so the host should not add an extra spacer.
    @ViewBuilder
    func mobileChatTopScrollEdgeLayout(legacyTopPadding length: CGFloat) -> some View {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self
        } else {
            self.safeAreaPadding(.top, length)
        }
        #else
        self
        #endif
    }
}
