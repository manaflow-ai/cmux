
public extension WindowBackdrop {
    /// The backdrop a pane or page decides its own painting from: `tokens` with the active
    /// scope's art selection (the app's outside a scope), so over art the panes stay clear glass
    /// and the art reads through the window's one legible tint.
    @MainActor static func current(_ tokens: ThemeTokens, reduceTransparency: Bool = false) -> WindowBackdrop {
        WindowBackdrop(tokens, reduceTransparency: reduceTransparency, selection: ThemeContext.activeBackdropSelection)
    }
}
