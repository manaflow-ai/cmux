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
    /// Use a translucent blur *material* as the bar background (rather than the
    /// system default or an opaque fill) so content behind the bar is visibly
    /// blurred — the "frosted glass" look. The pane backgrounds are extended
    /// under the bar (terminal bg ignores the top safe area; chat/browser scroll
    /// content insets under it automatically) so there is dark content for the
    /// material to blur. Keep the dark color scheme so the title and toolbar
    /// buttons stay light and legible over the dark panes.
    @ViewBuilder
    func mobileTerminalNavigationChrome() -> some View {
        #if os(iOS)
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.ultraThinMaterial, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}
