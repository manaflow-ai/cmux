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

    /// Dark, terminal-colored navigation chrome for the terminal detail screen.
    @ViewBuilder
    func mobileTerminalNavigationChrome() -> some View {
        #if os(iOS)
        self
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(TerminalPalette.background, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbarColorScheme(.dark, for: .navigationBar)
        #else
        self
        #endif
    }
}
