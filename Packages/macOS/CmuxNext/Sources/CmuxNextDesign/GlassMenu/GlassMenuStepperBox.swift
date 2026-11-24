import AppKit

/// The boxed − · value · + of a ``GlassMenuStepperRowView``, as the ChatGPT Atlas zoom row draws it (Lawrence
/// 2026-11-23: "let's just match these screenshots"): one rounded hairline box around the three, a hairline
/// between each, the value in the middle. The reset button sits outside it, beside the box.
@MainActor
final class GlassMenuStepperBox: NSView {
    private let dividers = [NSView(), NSView()]

    /// `minus`, `value` and `plus`, in that order, side by side in the box.
    init(minus: NSView, value: NSView, plus: NSView) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(false)
        let parts = [minus, dividers[0], value, dividers[1], plus]
        for part in parts {
            part.translatesAutoresizingMaskIntoConstraints = false
            addSubview(part)
        }
        let line = Metrics.lineWidth(1)
        var constraints = [
            heightAnchor.constraint(equalToConstant: GlassMenuStepperButton.side + line * 2),
            minus.leadingAnchor.constraint(equalTo: leadingAnchor),
            plus.trailingAnchor.constraint(equalTo: trailingAnchor),
            value.centerYAnchor.constraint(equalTo: centerYAnchor),
            minus.centerYAnchor.constraint(equalTo: centerYAnchor),
            plus.centerYAnchor.constraint(equalTo: centerYAnchor),
        ]
        for (left, right) in zip(parts, parts.dropFirst()) {
            constraints.append(right.leadingAnchor.constraint(equalTo: left.trailingAnchor))
        }
        for divider in dividers {
            divider.wantsLayer = true
            constraints += [
                divider.widthAnchor.constraint(equalToConstant: line),
                divider.topAnchor.constraint(equalTo: topAnchor, constant: Self.dividerGap),
                divider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.dividerGap),
            ]
        }
        NSLayoutConstraint.activate(constraints)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The room above and below each divider: the dividers stop short of the box's edge, as Atlas's do.
    private static let dividerGap: CGFloat = 4

    override var wantsUpdateLayer: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let line = Metrics.lineWidth(1)
        let radius = PopupStyle.standard.rowCornerRadius
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: line / 2, dy: line / 2), xRadius: radius, yRadius: radius)
        box.lineWidth = line
        performWithTheme {
            Palette.separator.setStroke()
            box.stroke()
            for divider in dividers { divider.layer?.backgroundColor = Palette.separator.cgColor }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
