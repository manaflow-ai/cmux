public import AppKit

/// A toast: the message, the action button and a close button on the shared
/// neutral Liquid Glass (``FloatingGlassStyle/toast``: gray glass, a top-lit
/// rim, 12 pt continuous corners; user 2026-10-20, after Rex), opaque under
/// Reduce Transparency, with the popups' shadow. VoiceOver reads the message; the buttons are reachable with
/// VoiceOver and by click. The pointer on it holds it (`onHover`).
@MainActor
public final class CmuxToastView: NSView {
    public let toast: CmuxToast
    public private(set) var actionButton: CmuxToastButton?
    public let closeButton = CmuxToastButton(style: .close, title: CmuxToastStrings.dismiss, target: nil, action: nil)
    var onAction: (() -> Void)?
    var onClose: (() -> Void)?
    /// The pointer came onto or left the toast, or the toast moved or went
    /// under a still pointer (`PointerHover`, cx-3wu5).
    var onHover: ((Bool) -> Void)?
    private var pointerHover: PointerHover?
    /// Whether the pointer is on the toast now (as of the last refresh).
    public var isHovered: Bool { pointerHover?.isHovering ?? false }

    private let reduceTransparency: ReduceTransparency

    /// `reduceTransparency` decides glass or the opaque surface (tests pass their own).
    public init(toast: CmuxToast, reduceTransparency: ReduceTransparency = .shared) {
        self.toast = toast
        self.reduceTransparency = reduceTransparency
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build()
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(toast.message)
        setAccessibilityIdentifier("cmux.toast.\(toast.id)")
        pointerHover = PointerHover(self) { [weak self] hovering in self?.onHover?(hovering) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func build() {
        let label = ChromeLabel(wrappingLabelWithString: toast.message)
        label.font = Typography.body
        label.maximumNumberOfLines = 3
        label.preferredMaxLayoutWidth = 360
        // A wrapping label resists compression at only `.defaultLow`, the same as the stack's
        // hugging, so the toast's fitting size squeezed the message to 4 pt and drew only the
        // buttons. The message keeps its width (up to 360 pt, then it wraps).
        label.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        performWithTheme { label.textColor = Palette.textPrimary }
        let row = NSStackView(views: [label])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = Metrics.space2
        // Room around the message; the buttons' hover fills stop one step short of the edge,
        // so the toast reads as one surface with text in it.
        row.edgeInsets = NSEdgeInsets(top: Metrics.space4, left: Metrics.space5,
                                      bottom: Metrics.space4, right: Metrics.space4)
        row.translatesAutoresizingMaskIntoConstraints = false
        if let action = toast.action {
            let button = CmuxToastButton(style: .action, title: action.title, target: self, action: #selector(runAction))
            actionButton = button
            row.addArrangedSubview(button)
            row.setCustomSpacing(Metrics.space5, after: label)
        }
        closeButton.target = self
        closeButton.action = #selector(close)
        row.addArrangedSubview(closeButton)

        let content = NSView()
        content.addSubview(row)
        // The shared neutral glass; the material follows this Mac (opaque under Reduce Transparency).
        let surface = OverlaySurfaceView(interactive: true, cornerRadius: Self.cornerRadius,
                                         reduceTransparency: reduceTransparency, tone: .neutralGlass(.toast))
        surface.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = true
        content.autoresizingMask = [.width, .height]
        content.frame = surface.contentView.bounds
        surface.contentView.addSubview(content)
        addSubview(surface)
        castShadow()
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            row.topAnchor.constraint(equalTo: content.topAnchor),
            row.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalTo: row.widthAnchor),
            heightAnchor.constraint(equalTo: row.heightAnchor),
        ])
    }

    /// The shared toast glass radius, never a capsule.
    static let cornerRadius = FloatingGlassStyle.toast.cornerRadius

    /// The popups' one subtle shadow, on this view's layer behind the surface
    /// (the surface clips to its corners, so it cannot cast its own).
    private func castShadow() {
        wantsLayer = true
        let elevation = PopupStyle.elevation2
        layer?.masksToBounds = false
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = Float(elevation.alpha)
        layer?.shadowRadius = elevation.layerRadius
        layer?.shadowOffset = elevation.layerOffset()
    }

    public override func layout() {
        super.layout()
        // CoreGraphics refuses a corner wider than half the rect.
        let radius = min(Self.cornerRadius, min(bounds.width, bounds.height) / 2)
        layer?.shadowPath = CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    @objc private func runAction() { onAction?() }
    @objc private func close() { onClose?() }
}
