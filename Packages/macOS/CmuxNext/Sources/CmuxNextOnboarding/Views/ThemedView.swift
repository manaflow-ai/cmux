import AppKit
import CmuxNextDesign

/// A layer-backed view whose colors come from closures, re-resolved when
/// the theme (appearance) changes. Base class for small chrome pieces.
class ThemedView: NSView {
    var fill: () -> NSColor? = { nil } { didSet { applyColors() } }
    var border: () -> NSColor? = { nil } { didSet { applyColors() } }
    var borderWidth: CGFloat = 1 { didSet { applyColors() } }
    var cornerRadius: CGFloat = 0 { didSet { layer?.cornerRadius = cornerRadius } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() { applyColors() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    func applyColors() {
        layer?.backgroundColor = fill()?.cgColor
        let stroke = border()
        layer?.borderColor = stroke?.cgColor
        layer?.borderWidth = stroke == nil ? 0 : borderWidth
    }
}
