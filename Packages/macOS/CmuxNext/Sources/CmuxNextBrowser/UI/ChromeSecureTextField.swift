import AppKit
import CmuxNextDesign

/// The password field of the HTTP authentication prompt: `ChromeTextField`'s
/// look on a secure field (its characters never reach the screen or the
/// pasteboard).
final class ChromeSecureTextField: NSSecureTextField {
    private let density = DensityBinding()
    private var placeholderText = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        density.update { [weak self] in
            guard let self else { return }
            font = BrowserMetrics.bodyFont
            applyColors()
        }
        density.start(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setPlaceholder(_ text: String) {
        placeholderText = text
        applyColors()
    }

    // visibility-walk-allow: a text color and the placeholder in the theme scope, no layout; cheaper than a deferral
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            textColor = Palette.textPrimary
            setPlaceholderKeepingEdit(NSAttributedString(string: placeholderText, attributes: [
                .foregroundColor: Palette.textSecondary, .font: font ?? BrowserMetrics.bodyFont,
            ]))
        }
    }
}
