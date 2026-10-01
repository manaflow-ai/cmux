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
