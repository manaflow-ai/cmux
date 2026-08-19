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
        if let theme {
            let style = MobileTerminalChromeStyle(theme: theme)
            self
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(style.background, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(style.colorScheme, for: .navigationBar)
        } else {
            self
                .navigationBarTitleDisplayMode(.inline)
                .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
                .toolbarBackground(.visible, for: .navigationBar)
                .toolbarColorScheme(.dark, for: .navigationBar)
        }
        #else
        self
        #endif
    }

    /// Draws a toolbar control on an opaque terminal-owned backing. Both colors
    /// come from one theme snapshot, so private adaptive material cannot lag the
    /// foreground during a live terminal-theme change.
    @ViewBuilder
    func mobileTerminalChromeControl(theme: TerminalTheme) -> some View {
        #if os(iOS)
        let style = MobileTerminalChromeStyle(theme: theme)
        self
            .foregroundStyle(style.foreground)
            .tint(style.foreground)
            .background(style.background)
            .environment(\.colorScheme, style.colorScheme)
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

extension ToolbarContent {
    /// Removes iOS 26's shared glass effect while retaining native toolbar item
    /// layout, grouping, actions, and accessibility identity.
    @ToolbarContentBuilder
    func mobileTerminalSharedBackgroundHidden() -> some ToolbarContent {
        #if os(iOS)
        if #available(iOS 26.0, *) {
            self.sharedBackgroundVisibility(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }
}
