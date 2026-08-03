import AppKit
import CmuxFoundation
import QuartzCore

/// Native one-time discovery hint for Command-scroll canvas panning.
@MainActor
final class CanvasCommandScrollHint: NSVisualEffectView {
    private let contentStack = NSStackView()
    private let borderLayer = CAShapeLayer()
    private var hasAnimatedIn = false

    init(text: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.18
        layer?.shadowRadius = 12
        layer?.shadowOffset = CGSize(width: 0, height: -4)

        contentStack.orientation = .horizontal
        contentStack.alignment = .centerY
        contentStack.spacing = 8
        contentStack.translatesAutoresizingMaskIntoConstraints = false
        contentStack.addArrangedSubview(CanvasKeycapView(text: "⌘"))
        contentStack.addArrangedSubview(symbolView(name: "plus", pointSize: 9, weight: .bold, color: .secondaryLabelColor))
        contentStack.addArrangedSubview(CanvasKeycapView(symbolName: "arrow.up.and.down.and.arrow.left.and.right"))

        let label = NSTextField(labelWithString: text)
        label.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        contentStack.addArrangedSubview(label)
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -9),
        ])

        borderLayer.fillColor = NSColor.clear.cgColor
        borderLayer.lineWidth = 1
        layer?.addSublayer(borderLayer)
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityLabel(text)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let fitting = contentStack.fittingSize
        return NSSize(width: ceil(fitting.width + 28), height: ceil(fitting.height + 18))
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: bounds.height / 2, cornerHeight: bounds.height / 2, transform: nil)
        borderLayer.frame = bounds
        borderLayer.path = CGPath(
            roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
            cornerWidth: max(0, bounds.height / 2 - 0.5),
            cornerHeight: max(0, bounds.height / 2 - 0.5),
            transform: nil
        )
        effectiveAppearance.performAsCurrentDrawingAppearance {
            borderLayer.strokeColor = NSColor.labelColor.withAlphaComponent(0.08)
                .usingColorSpace(.deviceRGB)?.cgColor
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasAnimatedIn else { return }
        hasAnimatedIn = true
        alphaValue = 0
        let scale = CABasicAnimation(keyPath: "transform.scale")
        scale.fromValue = 0.9
        scale.toValue = 1
        scale.duration = 0.34
        scale.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.32, 1)
        layer?.add(scale, forKey: "cmux.canvasHint.scaleIn")
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            animator().alphaValue = 1
        }
    }

    private func symbolView(
        name: String,
        pointSize: CGFloat,
        weight: NSFont.Weight,
        color: NSColor
    ) -> NSImageView {
        let view = NSImageView()
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: GlobalFontMagnification.scaled(pointSize),
                weight: weight
            ))
        view.image = image
        view.contentTintColor = color
        return view
    }
}

@MainActor
private final class CanvasKeycapView: NSView {
    private let contentView: NSView

    init(text: String) {
        let label = NSTextField(labelWithString: text)
        label.font = GlobalFontMagnification.systemFont(ofSize: 12, weight: .semibold)
        label.textColor = .labelColor
        contentView = label
        super.init(frame: .zero)
        setup()
    }

    init(symbolName: String) {
        let image = NSImageView()
        image.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(
                pointSize: GlobalFontMagnification.scaled(12),
                weight: .semibold
            ))
        image.contentTintColor = .labelColor
        contentView = image
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        let fitting = contentView.fittingSize
        return NSSize(width: ceil(max(18, fitting.width) + 8), height: ceil(max(18, fitting.height)))
    }

    override func layout() {
        super.layout()
        contentView.frame = CGRect(
            x: (bounds.width - contentView.fittingSize.width) / 2,
            y: (bounds.height - contentView.fittingSize.height) / 2,
            width: contentView.fittingSize.width,
            height: contentView.fittingSize.height
        )
        layer?.cornerRadius = 5
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.10)
                .usingColorSpace(.deviceRGB)?.cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.12)
                .usingColorSpace(.deviceRGB)?.cgColor
        }
    }

    private func setup() {
        wantsLayer = true
        layer?.borderWidth = 1
        addSubview(contentView)
    }
}
