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

    /// Terminal-colored navigation chrome for the terminal detail screen.
    /// The selected surface's theme is explicit so both the bar fill and system
    /// glyph contrast repaint when a live render-grid theme changes.
    @ViewBuilder
    func mobileTerminalNavigationChrome(theme: TerminalTheme? = nil) -> some View {
        #if os(iOS)
        let colorScheme = theme.map { $0.terminalColorScheme } ?? .dark
        if let theme {
            self
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(theme.terminalBackgroundColor, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
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
