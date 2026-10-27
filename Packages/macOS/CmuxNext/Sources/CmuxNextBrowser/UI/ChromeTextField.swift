import AppKit
import CmuxNextDesign

/// Plain single-line field with no bezel, no focus ring, and a gray
/// selection instead of the accent-colored one.
class ChromeTextField: NSTextField {
    private let density = DensityBinding()
    private var placeholderText = ""
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        isBezeled = false
        drawsBackground = false
        focusRingType = .none
        usesSingleLineMode = true
        lineBreakMode = .byTruncatingTail
        cell?.isScrollable = true
        cell?.wraps = false
        density.update { [weak self] in
            guard let self else { return }
            font = BrowserMetrics.bodyFont
            applyPlaceholder()
        }
        density.start(in: self)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func setPlaceholder(_ text: String) {
        placeholderText = text
        applyPlaceholder()
    }

    // visibility-walk-allow: a text color, the placeholder and the open editor's colors in the theme scope, no layout; cheaper than a deferral
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
    }

    private func applyColors() {
        performWithTheme { textColor = Palette.textPrimary }
        applyPlaceholder()
        applyEditorColors()
    }

    private func applyPlaceholder() {
        guard !placeholderText.isEmpty else { return }
        performWithTheme {
            setPlaceholderKeepingEdit(NSAttributedString(string: placeholderText, attributes: [
                .foregroundColor: Palette.textSecondary,
                .font: font ?? BrowserMetrics.bodyFont,
            ]))
        }
    }

    private func applyEditorColors() {
        guard let editor = currentEditor() as? NSTextView else { return }
        performWithTheme {
            editor.insertionPointColor = Palette.caret
            editor.selectedTextAttributes = [.backgroundColor: Palette.textSelection]
        }
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { applyEditorColors() }
        return accepted
    }
}
