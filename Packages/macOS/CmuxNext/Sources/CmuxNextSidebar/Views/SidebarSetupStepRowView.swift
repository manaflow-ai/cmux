import AppKit
import CmuxNextDesign

/// One row of the "Finish setting up" card (``SidebarSetupCardView``): a dashed circle and the step's text, a
/// check on a dimmed row once done, a spinner while the step runs. A step that can run now is a button: the
/// hover fill (concentric with the card) under the pointer, and a click, Space, Return or VoiceOver press
/// runs it. A done, running or unavailable step takes no click; its tooltip says what it gives or why not.
final class SidebarSetupStepRowView: NSView {
    var onPress: (() -> Void)?
    private(set) var step: SidebarSetupCard.Step?
    private let label = ChromeLabel(labelWithString: "")
    /// The dashed circle (to do) or the filled circle (done).
    private let circle = CAShapeLayer()
    /// The check inside a done step's circle.
    private let check = CAShapeLayer()
    private let spinner = StatusIndicatorView.spinner()
    private var isHovered = false { didSet { if isHovered != oldValue { needsDisplay = true } } }
    private var isPressed = false { didSet { if isPressed != oldValue { needsDisplay = true } } }
    private var isKeyFocused = false { didSet { if isKeyFocused != oldValue { needsDisplay = true } } }
    private lazy var keyRepaint = KeyWindowRepaint(self)
    /// Where the row's text starts and its hover fill's corner: set by the card.
    var contentInset: CGFloat = 8 { didSet { if contentInset != oldValue { needsLayout = true } } }
    var fillCornerRadius: CGFloat = 4 { didSet { if fillCornerRadius != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        focusRingType = .none
        layer?.cornerCurve = .continuous
        label.lineBreakMode = .byTruncatingTail
        label.maximumNumberOfLines = 1
        label.setAccessibilityElement(false)
        addSubview(label)
        circle.fillColor = nil
        layer?.addSublayer(circle)
        check.fillColor = nil
        check.lineCap = .round
        check.lineJoin = .round
        layer?.addSublayer(check)
        addSubview(spinner)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    nonisolated override var isFlipped: Bool { true }
    nonisolated override var wantsUpdateLayer: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// A click runs the step now.
    var isRunnable: Bool { step.map { $0.runnable && !$0.done && !$0.busy } ?? false }

    func configure(_ step: SidebarSetupCard.Step) {
        guard step != self.step else { return }
        self.step = step
        label.stringValue = step.title
        themedToolTip = step.help
        setAccessibilityLabel(step.title)
        setAccessibilityHelp(step.help)
        setAccessibilityValue(step.done ? Strings.setupStepDone : nil)
        setAccessibilityEnabled(isRunnable)
        spinner.spin(step.busy)
        spinner.isHidden = !step.busy
        if !isRunnable { isHovered = false; isPressed = false }
        needsLayout = true
        needsDisplay = true
    }

    static var font: NSFont { Typography.body }
    /// The circle's side.
    static let mark: CGFloat = 14

    override func layout() {
        super.layout()
        layer?.cornerRadius = fillCornerRadius
        let b = bounds, mark = Self.mark
        let markRect = NSRect(x: contentInset, y: ((b.height - mark) / 2).rounded(), width: mark, height: mark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let line = Metrics.lineWidth(1.25)
        circle.frame = markRect
        circle.lineWidth = line
        circle.path = CGPath(ellipseIn: CGRect(x: line / 2, y: line / 2, width: mark - line, height: mark - line), transform: nil)
        check.frame = markRect
        check.lineWidth = Metrics.lineWidth(1.5)
        let path = CGMutablePath()
        // Flipped view, unflipped layer geometry: y grows up inside the shape layer.
        path.move(to: CGPoint(x: mark * 0.30, y: mark * 0.50))
        path.addLine(to: CGPoint(x: mark * 0.45, y: mark * 0.36))
        path.addLine(to: CGPoint(x: mark * 0.71, y: mark * 0.64))
        check.path = path
        CATransaction.commit()
        spinner.frame = markRect
        label.font = Self.font
        let h = ceil(label.intrinsicContentSize.height)
        let x = markRect.maxX + Metrics.space2
        label.frame = NSRect(x: x, y: ((b.height - h) / 2).rounded(), width: max(0, b.width - x - contentInset), height: h)
    }

    override func updateLayer() {
        let done = step?.done == true, busy = step?.busy == true
        performWithTheme {
            layer?.backgroundColor = (isRunnable && isPressed ? Palette.pressedFill : isRunnable && isHovered ? Palette.hoverFill : .clear).cgColor
            layer?.borderColor = Palette.focusRing.cgColor
            layer?.borderWidth = KeyWindowRepaint.showsFocus(self, focused: isKeyFocused) ? Metrics.lineWidth(1.5) : 0
            label.textColor = done ? Palette.textTertiary : Palette.textPrimary
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            circle.isHidden = busy
            circle.strokeColor = done ? nil : Palette.textTertiary.cgColor
            circle.fillColor = done ? Palette.accentFill.cgColor : nil
            // Twelve dashes around the circle, the reference's "not started" ring.
            let length = .pi * (Self.mark - circle.lineWidth)
            circle.lineDashPattern = done ? nil : [NSNumber(value: Double(length / 24)), NSNumber(value: Double(length / 24))]
            check.isHidden = !done
            check.strokeColor = Palette.onAccent.cgColor
            CATransaction.commit()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false; isPressed = false }
    override func mouseDown(with event: NSEvent) { if isRunnable { isPressed = true } }

    /// Runs on release inside, like a button.
    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        isPressed = false
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        press()
    }

    override func viewDidHide() {
        super.viewDidHide()
        isHovered = false
        isPressed = false
    }

    /// A press (click, key, VoiceOver): runs the step once when it can run.
    func press() {
        guard isRunnable else { return }
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        guard isRunnable else { return false }
        press()
        return true
    }

    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled && isRunnable }
    override var canBecomeKeyView: Bool { acceptsFirstResponder && !isHiddenOrHasHiddenAncestor }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        keyRepaint.track()
    }

    override func becomeFirstResponder() -> Bool {
        isKeyFocused = true
        return true
    }

    override func resignFirstResponder() -> Bool {
        isKeyFocused = false
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard SidebarUpdateToggle.isActivationKey(event) else { return super.keyDown(with: event) }
        press()
    }
}
