import CmuxNextDesign
import CmuxNextDesignTokens
import CmuxNextTestSupport
import CoreGraphics
import Testing

/// The suites that read the curved main pane's gutter (`chrome.mainPane.gutter`): the window
/// edge, its corners and the chrome shade. They run one at a time under this parent, so a test
/// that sets the gutter (the Debug Settings flush opt-in, gutter 0) never runs beside one that
/// reads the default.
@MainActor @Suite(.closesItsWindows, .serialized) struct MainPaneGutterSuites {
    /// Runs `body` with the main pane gutter at `points` (the Debug Settings override), then
    /// removes the override.
    static func withGutter<T>(_ points: CGFloat, _ body: () throws -> T) rethrows -> T {
        let store = TunableStore.shared
        let gutter = ChromeTunables.mainPaneGutter
        store.register([gutter.descriptor])
        if !store.isActive { store.activate(file: nil) }
        store.set(gutter.key, .number(Double(points)))
        defer { store.set(gutter.key, nil) }
        return try body()
    }

    /// Runs `body` on the in-memory default chrome style, whose main pane is curved, then puts the style back. The
    /// style is process-wide: a settings load in a suite that runs alongside leaves it at the file default
    /// `flat` (no card, `ChromeStyleSetting.fallback`), so a test that reads the curved main pane pins it.
    static func onCurvedMainPane<T>(_ body: () throws -> T) rethrows -> T {
        let design = DesignSettings.shared
        let before = design.chromeStyle
        design.chromeStyle = .default
        defer { design.chromeStyle = before }
        return try body()
    }
}
