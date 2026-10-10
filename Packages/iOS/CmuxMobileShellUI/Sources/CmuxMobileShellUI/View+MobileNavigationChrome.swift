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
    ///
    /// `scrollEdgeGlass` selects the iOS 26 scroll-edge treatment: the bar
    /// keeps its system glass (no opaque fill) so the terminal's scroll-edge
    /// band — live scrollback rows rendered under the bar — shows through
    /// the scroll edge effect's progressive blur. Glyph contrast still
    /// follows the terminal theme. Callers pass `false` for non-terminal
    /// surfaces and on OS versions without scroll edge effects, keeping the
    /// opaque themed bar.
    @ViewBuilder
    func mobileTerminalNavigationChrome(
        theme: TerminalTheme? = nil,
        scrollEdgeGlass: Bool = false
    ) -> some View {
        #if os(iOS)
        let colorScheme = theme.map { $0.terminalColorScheme } ?? .dark
        if scrollEdgeGlass {
            // No explicit bar background: the system glass stays, and the
            // scroll edge effect provides legibility over the band.
            self
                .navigationBarTitleDisplayMode(.inline)
                .toolbarColorScheme(colorScheme, for: .navigationBar)
        } else if let theme {
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

}
