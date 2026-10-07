public import AppKit

public extension WindowBackdrop {
    /// The backdrop a pane or page decides its own painting from: the app's art selection with
    /// `tokens` (stub: art ignored).
    @MainActor static func current(_ tokens: ThemeTokens, reduceTransparency: Bool = false) -> WindowBackdrop {
        WindowBackdrop(tokens, reduceTransparency: reduceTransparency)
    }
}
