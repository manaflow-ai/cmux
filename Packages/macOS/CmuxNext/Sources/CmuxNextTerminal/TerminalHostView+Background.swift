public import AppKit
import CmuxNextDesign
import CmuxNextWakeups

/// The host's background: its theme's, the config's, or clear over a see-through window, repainted
/// when the scope around it changes and, while its tab shows, when the appearance does.
extension TerminalHostView {
    /// A light/dark switch repaints a hidden terminal once, when its tab shows (recipe R-appear): the
    /// paint resolves the backdrop and the theme, more than a layer color.
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        deferUntilVisible(key: AppearanceRepaint()) { [weak self] in self?.paintBackground() }
    }

    /// The key of the deferred appearance repaint on ``node``.
    private struct AppearanceRepaint: Hashable {}

    /// Runs `work` now while ``node`` is visible, else once when it shows (``VisibilityNode/deferUntilVisible(key:_:)``).
    /// A host with no tab node runs it now.
    private func deferUntilVisible(key: some Hashable, _ work: @escaping @MainActor () -> Void) {
        guard let node else { return work() }
        node.deferUntilVisible(key: key, work)
    }

    /// An opaque window paints the terminal's theme background, like
    /// `GhosttyRuntime.backgroundColor`. Where the window is see-through
    /// (translucent, glass, or over art) the window root paints the one
    /// sheet and the host stays clear, as the panes around it do, unless the
    /// terminal's theme differs from theirs: its background then lies over
    /// the glass at the window's tint (`WindowBackdrop.tintOpacity`). The user's terminal
    /// background (`appearance.surfaces.terminal`) replaces all of these;
    /// the surfaces then draw a transparent default background.
    func paintBackground() {
        let (scope, tokens) = (themeScope, themeTokens)
        // The window root's backdrop (`WindowRootView.backdrop`): the scope's art and its own tint.
        let backdrop = WindowBackdrop(tokens, reduceTransparency: ReduceTransparency.shared.isEnabled,
                                      selection: scope.backdropSelection, tintOpacity: scope.backdropTintOpacity)
        GhosttyRuntime.setSeeThrough(superview != nil && !backdrop.panesPaintBackground, host: self, on: mainWork)
        let fill = performWithTheme { Palette.surfaceOverride(.terminal) }
        if let fill {
            layer?.backgroundColor = fill.cgColor
            return
        }
        guard !backdrop.panesPaintBackground else {
            guard let rgb = theme?.colors?.background else {
                layer?.backgroundColor = GhosttyRuntime.shared.backgroundColor.cgColor
                return
            }
            layer?.backgroundColor = CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
            return
        }
        let around = superview?.themeTokens.surfaceBackground.withAlpha(1)
        let own = tokens.surfaceBackground.withAlpha(1)
        layer?.backgroundColor = theme == nil || own == around ? nil : own.withAlpha(backdrop.tintOpacity).cgColor
    }
}

/// Repaints a host when the scope around it changes its colors or its art.
@MainActor
final class TerminalHostThemeListener: ThemeResponsive {
    weak var host: TerminalHostView?

    func themeDidChange() { host?.paintBackground() }
}
