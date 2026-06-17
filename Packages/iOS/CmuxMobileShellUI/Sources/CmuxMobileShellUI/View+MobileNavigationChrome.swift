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
    /// Keep the system bar background **visible** so it always renders the
    /// platform material — Liquid Glass on iOS 26 (the real refractive glass,
    /// which blurs/refracts the pane behind it), the translucent system bar on
    /// iOS 18 — instead of the transparent "scroll edge" state the bar falls into
    /// over the non-scrolling terminal. We deliberately do NOT pass a custom
    /// `ShapeStyle` (e.g. a `Material`): that would replace Liquid Glass with a
    /// flat frosted blur. The pane backgrounds are extended under the bar
    /// (terminal bg ignores the top safe area; chat/browser scroll content insets
    /// under it automatically) so the glass has dark content to refract. Keep the
    /// dark color scheme so the title and toolbar buttons stay light and legible.
    @ViewBuilder
    func mobileTerminalNavigationChrome() -> some View {
        #if os(iOS)
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}
