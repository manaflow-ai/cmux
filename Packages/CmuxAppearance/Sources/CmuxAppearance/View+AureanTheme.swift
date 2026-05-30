import SwiftUI

extension View {
    /// Injects an ``AureanTheme`` owner and its resolved palette into this view's environment.
    ///
    /// Apply once near the app root. Children read colors with
    /// `@Environment(\.aureanPalette)` and reach the owner (to switch temperature) with
    /// `@Environment(AureanTheme.self)`. Because the palette is read from the observable
    /// ``AureanTheme`` here, flipping ``AureanTheme/variant`` re-skins the whole subtree.
    ///
    /// ```swift
    /// ContentView().aureanTheme(theme)
    /// ```
    ///
    /// - Parameter theme: The theme owner, typically created once at the app root.
    /// - Returns: A view whose environment carries both the theme and its current palette.
    @MainActor
    public func aureanTheme(_ theme: AureanTheme) -> some View {
        environment(theme)
            .environment(\.aureanPalette, theme.palette)
    }
}
