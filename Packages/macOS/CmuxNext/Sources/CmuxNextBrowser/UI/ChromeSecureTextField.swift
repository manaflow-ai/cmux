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
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        density.update { [unowned self] in
            font = BrowserMetrics.bodyFont
            applyColors()
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setPlaceholder(_ text: String) {
        placeholderText = text
        applyColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            textColor = Palette.textPrimary
            placeholderAttributedString = NSAttributedString(string: placeholderText, attributes: [
                .foregroundColor: Palette.textSecondary, .font: font ?? BrowserMetrics.bodyFont,
            ])
        }
    }
}
