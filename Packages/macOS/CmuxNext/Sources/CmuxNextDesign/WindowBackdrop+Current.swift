
public extension WindowBackdrop {
    /// The backdrop a pane or page decides its own painting from: `tokens` with the app's art
    /// selection, so over art the panes stay clear glass and the art reads through the window's
    /// one legible tint.
    @MainActor static func current(_ tokens: ThemeTokens, reduceTransparency: Bool = false) -> WindowBackdrop {
        WindowBackdrop(tokens, reduceTransparency: reduceTransparency, selection: ThemeScope.app.backdropSelection)
    }
}
