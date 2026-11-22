import AppKit

/// A plain container that calls `onThemeChange` whenever its colors must be
/// resolved again: a theme change repaints its scope and calls
/// `viewDidChangeEffectiveAppearance` on every view in it. Panels host their
/// AppKit labels in one so the labels' colors follow the scope.
final class ThemeHookView: NSView {
    var onThemeChange: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onThemeChange?()
    }
}
