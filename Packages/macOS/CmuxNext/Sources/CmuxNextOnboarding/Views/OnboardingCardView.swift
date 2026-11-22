import AppKit
import CmuxNextDesign

/// A rounded card for a row in the Computer Use window and its drag panel:
/// the theme's card tint (`ThemeTokens.cardFill`, a translucent fill over
/// whatever is behind it, never opaque) and a thin light rim one device
/// pixel wide (the primary text at `CardSurfaceView.lightEdgeShare`), so the
/// card reads in light and dark. The window keeps its own backdrop; only
/// the card draws. It takes no clicks.
final class OnboardingCardView: NSView {
    private var loop: RenderLoop?

    init(cornerRadius: CGFloat) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = cornerRadius
        setAccessibilityElement(false)
        loop = RenderLoop { [weak self] in
            _ = ThemeScope.app.store.input
            self?.applyColors()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyColors()
    }

    private func applyColors() {
        performWithTheme {
            layer?.backgroundColor = themeTokens.cardFill.nsColor.cgColor
            layer?.borderColor = Palette.textPrimary.withAlphaComponent(CardSurfaceView.lightEdgeShare).cgColor
            layer?.borderWidth = Metrics.lineWidth(1 / max(window?.backingScaleFactor ?? 2, 1))
        }
    }
}
