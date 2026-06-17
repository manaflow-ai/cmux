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
    /// We intentionally do NOT set a *visible* opaque toolbar background and do
    /// NOT hide the background either: the system bar's own material IS the
    /// glass, and the panes are extended under it (`ignoresSafeArea(.top)` on the
    /// terminal, automatic scroll-content inset for chat/browser) so content
    /// renders behind it. Keep the dark color scheme so the title and toolbar
    /// buttons stay light and legible over the dark panes.
    @ViewBuilder
    func mobileTerminalNavigationChrome() -> some View {
        #if os(iOS)
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}
