// SPDX-License-Identifier: GPL-3.0-or-later
import AppKit
import CmuxNextDesign

/// The first-run Computer Use page's picture: a small app window with a few controls and the blue
/// agent cursor (cmux blue, #0A84FF) visiting them, a click ring at each stop. The tour loops
/// through `Motion.cursor` (`cursorTourAnimation`); with loops off (the master switch, the cursor
/// category, animation speed off, Reduce Motion) the cursor rests on the first control and the
/// picture still says what it shows. Drawn with layers, no assets.
final class ComputerUseCursorIllustration: NSView {
    /// The agent cursor's color: cmux blue.
    static let cursorBlue = NSColor(srgbRed: 10 / 255, green: 132 / 255, blue: 1, alpha: 1)
    static let size = NSSize(width: 360, height: 168)
    static let tourKey = "cmux.onboarding.cursorTour"
    static let clickKey = "cmux.onboarding.cursorClick"

    private let card = CALayer()
    private let titlebar = CALayer()
    private var controls: [CALayer] = []
    private let cursor = CAShapeLayer()
    private let ring = CAShapeLayer()
    private var motion: MotionSubscription?

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(OnboardingStrings.computerUseWelcomeIllustration)
        guard let root = layer else { return }
        card.cornerRadius = 10
        card.borderWidth = 1
        titlebar.cornerRadius = 10
        titlebar.maskedCorners = [.layerMinXMinYCorner, .layerMaxXMinYCorner]
        root.addSublayer(card)
        card.addSublayer(titlebar)
        for _ in 0..<3 {
            let control = CALayer()
            control.cornerRadius = 6
            card.addSublayer(control)
            controls.append(control)
        }
        ring.fillColor = nil
        ring.lineWidth = 2
        ring.opacity = 0
        root.addSublayer(ring)
        cursor.path = Self.arrowPath()
        cursor.lineWidth = 1.5
        cursor.lineJoin = .round
        cursor.shadowOpacity = 0.25
        cursor.shadowRadius = 2
        cursor.shadowOffset = CGSize(width: 0, height: 1)
        root.addSublayer(cursor)
        motion = Motion.changes.subscribe { [weak self] _ in self?.updateTour() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var intrinsicContentSize: NSSize { Self.size }

    /// Where the cursor's tip rests at each stop, in the view's flipped coordinates.
    var stops: [CGPoint] {
        controls.map { CGPoint(x: $0.frame.midX + card.frame.minX, y: $0.frame.midY + card.frame.minY) }
    }

    /// The tour runs now (loops allowed and the view on screen).
    var isTouring: Bool { cursor.animation(forKey: Self.tourKey) != nil }

    override func layout() {
        super.layout()
        let inset: CGFloat = 12
        card.frame = bounds.insetBy(dx: inset, dy: inset)
        titlebar.frame = CGRect(x: 0, y: 0, width: card.bounds.width, height: 24)
        let width = (card.bounds.width - 4 * 16) / 3
        for (index, control) in controls.enumerated() {
            control.frame = CGRect(x: 16 + CGFloat(index) * (width + 16), y: 52, width: width, height: 60)
        }
        restCursor()
        updateTour()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTour()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    override func updateLayer() {
        super.updateLayer()
        paint()
    }

    override var wantsUpdateLayer: Bool { true }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            card.backgroundColor = Palette.textPrimary.withAlphaComponent(0.04).cgColor
            card.borderColor = Palette.separator.cgColor
            titlebar.backgroundColor = Palette.textPrimary.withAlphaComponent(0.06).cgColor
            for control in controls { control.backgroundColor = Palette.textPrimary.withAlphaComponent(0.08).cgColor }
            cursor.fillColor = Self.cursorBlue.cgColor
            cursor.strokeColor = NSColor.white.cgColor
            ring.strokeColor = Self.cursorBlue.cgColor
        }
    }

    /// The cursor at the first control, no animation: what a person sees with loops off.
    private func restCursor() {
        guard let first = stops.first else { return }
        Motion.cursor.withoutAnimation {
            cursor.position = first
            ring.position = first
            ring.path = CGPath(ellipseIn: CGRect(x: -14, y: -14, width: 28, height: 28), transform: nil)
        }
    }

    /// Starts the tour when loops are allowed and the view is in a window, else stops it.
    func updateTour() {
        cursor.removeAnimation(forKey: Self.tourKey)
        ring.removeAnimation(forKey: Self.tourKey)
        ring.removeAnimation(forKey: Self.clickKey)
        guard window != nil, bounds.width > 0,
              let tour = Motion.cursor.cursorTourAnimation(stops: stops),
              let click = Motion.cursor.cursorTourClickAnimation(stops: stops.count) else { return }
        cursor.add(tour, forKey: Self.tourKey)
        ring.add(tour, forKey: Self.tourKey)
        ring.add(click, forKey: Self.clickKey)
    }

    /// The pointer arrow, tip at the origin, in flipped coordinates (y down).
    private static func arrowPath() -> CGPath {
        let path = CGMutablePath()
        path.move(to: .zero)
        path.addLine(to: CGPoint(x: 0, y: 17))
        path.addLine(to: CGPoint(x: 4.5, y: 13))
        path.addLine(to: CGPoint(x: 7.5, y: 19.5))
        path.addLine(to: CGPoint(x: 10, y: 18.5))
        path.addLine(to: CGPoint(x: 7, y: 12))
        path.addLine(to: CGPoint(x: 12.5, y: 12))
        path.closeSubpath()
        return path
    }
}
