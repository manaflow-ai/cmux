import AppKit
import CmuxNextDesign

/// Text colors a palette label takes from its theme scope.
enum PaletteTone {
    case primary, secondary, tertiary

    /// theme-scoped: callers read it inside `performWithTheme`.
    var color: NSColor {
        switch self {
        case .primary: Palette.textPrimary
        case .secondary: Palette.textSecondary
        case .tertiary: Palette.textTertiary
        }
    }
}

/// A one-line label whose text color follows its view's theme scope: it
/// re-resolves on every theme change (`viewDidChangeEffectiveAppearance`)
/// and when its tone changes.
final class PaletteLabel: NSTextField {
    /// Nil leaves the color to the owner (attributed titles).
    var tone: PaletteTone? = .primary {
        didSet { if tone != oldValue { applyTone() } }
    }
    /// The Design style this label draws in (`PaletteText.label`).
    var fontSource: (@MainActor () -> NSFont)?

    /// Takes the current size of the label's style (a text size or density change).
    func refreshFont() {
        guard let font = fontSource?(), font != self.font else { return }
        self.font = font
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyTone()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTone()
    }

    private func applyTone() {
        guard let tone else { return }
        performWithTheme { textColor = tone.color }
    }
}

extension NSView {
    /// Every `PaletteLabel` below this view takes its style's current size.
    func refreshPaletteFonts() {
        (self as? PaletteLabel)?.refreshFont()
        subviews.forEach { $0.refreshPaletteFonts() }
    }
}
