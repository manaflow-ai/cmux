import AppKit
import CmuxNextDesign
import QuartzCore

/// Workspace icon: an SF Symbol or a color swatch with a monogram.
final class SidebarIconView: NSView {
    private let imageView = NSImageView()
    private let swatch = CALayer()
    private let monogram = NSTextField(labelWithString: "")
    private var icon: WorkspaceIcon = .symbol("terminal")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        swatch.cornerCurve = .continuous
        swatch.borderWidth = 0.5
        layer?.addSublayer(swatch)
        imageView.imageScaling = .scaleProportionallyDown
        monogram.font = NSFont.systemFont(ofSize: Typography.caption.pointSize, weight: .bold)
        monogram.textColor = .white
        monogram.alignment = .center
        addSubview(imageView)
        addSubview(monogram)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func configure(icon: WorkspaceIcon, title: String) {
        self.icon = icon
        switch icon {
        case let .symbol(name, tint):
            let config = SidebarStyle.glyphConfig
            imageView.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
                ?? NSImage(systemSymbolName: "terminal", accessibilityDescription: nil)?.withSymbolConfiguration(config)
            imageView.contentTintColor = tint.map(SidebarStyle.color) ?? Palette.textSecondary
            imageView.isHidden = false
            monogram.isHidden = true
        case .swatch:
            imageView.isHidden = true
            monogram.isHidden = false
            monogram.stringValue = title.first.map { String($0).uppercased() } ?? ""
        }
        needsDisplay = true
        needsLayout = true
    }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if case let .swatch(color) = icon {
            swatch.isHidden = false
            swatch.backgroundColor = SidebarStyle.color(color).cgColor
            swatch.borderColor = NSColor(white: 1, alpha: 0.22).cgColor
        } else {
            swatch.isHidden = true
        }
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        imageView.frame = bounds
        let side = Metrics.iconSize
        let rect = CGRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2, width: side, height: side)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        swatch.frame = rect
        swatch.cornerRadius = side * 0.28
        CATransaction.commit()
        let size = monogram.intrinsicContentSize
        monogram.frame = NSRect(x: rect.minX, y: rect.midY - size.height / 2, width: rect.width, height: size.height)
        needsDisplay = true
    }
}

/// Small agent-activity indicator: spinner (running), amber dot (needs
/// input), red dot (error).
final class ActivityIndicatorView: NSView {
    private let shape = CAShapeLayer()
    private(set) var activity: AgentActivity = .idle

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(shape)
        shape.fillColor = nil
        shape.lineCap = .round
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func configure(_ activity: AgentActivity) {
        guard activity != self.activity || shape.path == nil else { return }
        self.activity = activity
        isHidden = activity == .idle
        needsDisplay = true
        needsLayout = true
    }

    override func layout() {
        super.layout()
        shape.frame = bounds
        let rect = bounds.insetBy(dx: Metrics.space1 / 2, dy: Metrics.space1 / 2)
        switch activity {
        case .running:
            shape.path = CGPath(ellipseIn: rect, transform: nil)
            shape.strokeStart = 0
            shape.strokeEnd = 0.72
            shape.lineWidth = Metrics.space1 * 0.75
        case .needsInput, .error:
            let side = SidebarStyle.dotSize
            shape.path = CGPath(ellipseIn: CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side), transform: nil)
            shape.strokeEnd = 1
            shape.lineWidth = 0
        case .idle:
            shape.path = nil
        }
        updateAnimations()
    }

    override func updateLayer() {
        switch activity {
        case .running:
            shape.strokeColor = resolvedCGColor(Palette.textSecondary)
            shape.fillColor = nil
        case .needsInput:
            shape.strokeColor = nil
            shape.fillColor = NSColor.systemOrange.cgColor
        case .error:
            shape.strokeColor = nil
            shape.fillColor = NSColor.systemRed.cgColor
        case .idle:
            break
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimations()
    }

    private func updateAnimations() {
        shape.removeAllAnimations()
        guard window != nil, !Motion.reduceMotion else { return }
        switch activity {
        case .running:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .infinity
            shape.add(spin, forKey: "spin")
        case .needsInput:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(pulse, forKey: "pulse")
        case .error, .idle:
            break
        }
    }
}

/// Unread badge: a count pill or a dot.
final class UnreadBadgeView: NSView {
    private(set) var state: UnreadState = .none
    private let label = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        label.font = SidebarStyle.badgeFont
        label.alignment = .center
        label.textColor = Palette.textPrimary
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }

    func configure(_ state: UnreadState) {
        self.state = state
        isHidden = !state.isUnread
        if case let .count(n) = state {
            label.stringValue = n > 99 ? "99+" : "\(n)"
            label.isHidden = false
        } else {
            label.isHidden = true
        }
        needsDisplay = true
        needsLayout = true
    }

    /// Width this badge wants at the given height.
    var preferredWidth: CGFloat {
        switch state {
        case .none: 0
        case .dot: SidebarStyle.dotSize
        case .count: max(SidebarStyle.badgeHeight + Metrics.space2, ceil(label.attributedStringValue.size().width) + Metrics.space4)
        }
    }

    override func updateLayer() {
        guard let layer else { return }
        switch state {
        case .dot:
            layer.backgroundColor = resolvedCGColor(Palette.textPrimary.withAlphaComponent(0.85))
        default:
            layer.backgroundColor = resolvedCGColor(SidebarStyle.badgeFill)
        }
        layer.cornerRadius = bounds.height / 2
    }

    override func layout() {
        super.layout()
        let h = label.intrinsicContentSize.height
        label.frame = NSRect(x: 0, y: (bounds.height - h) / 2, width: bounds.width, height: h)
        needsDisplay = true
    }
}

/// Small borderless icon button with a gray hover fill (no blue).
final class SidebarIconButton: NSButton {
    private var hovering = false { didSet { needsDisplay = true } }
    var onPress: (() -> Void)?

    init(symbol: String, pointSize: CGFloat = Metrics.smallIconSize, weight: NSFont.Weight = .semibold, label: String) {
        super.init(frame: .zero)
        let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: weight)
        image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)?.withSymbolConfiguration(config)
        imagePosition = .imageOnly
        isBordered = false
        contentTintColor = Palette.textSecondary
        setAccessibilityLabel(label)
        toolTip = label
        wantsLayer = true
        layer?.cornerCurve = .continuous
        target = self
        action = #selector(pressed)
        refusesFirstResponder = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func pressed() { onPress?() }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.cornerRadius = Metrics.itemCornerRadius
        layer?.backgroundColor = hovering ? resolvedCGColor(Palette.selectionFill) : nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }
}

/// Floating gray pill under the active row. One instance glides between rows.
final class SelectionPillView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
        layer?.borderWidth = 0.5
        layer?.shadowOpacity = 1
        layer?.shadowRadius = Metrics.space1
        layer?.shadowOffset = CGSize(width: 0, height: -Metrics.space1 / 2)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = resolvedCGColor(Palette.selectionFill)
        layer?.borderColor = resolvedCGColor(SidebarStyle.pillRim)
        layer?.shadowColor = NSColor(white: 0, alpha: 0.10).cgColor
    }
}

/// Placeholder drawn inside the open drag gap.
final class GapIndicatorView: NSView {
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        layer?.cornerRadius = SidebarStyle.rowCornerRadius
        layer?.borderWidth = 1
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        layer?.backgroundColor = resolvedCGColor(Palette.hoverFill)
        layer?.borderColor = resolvedCGColor(Palette.separator)
    }
}
