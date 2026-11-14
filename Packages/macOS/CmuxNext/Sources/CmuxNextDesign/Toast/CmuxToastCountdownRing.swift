public import AppKit

/// The ring around a toast's close button that empties over the toast's time (``CmuxToastStyle/progressRing``):
/// how long the toast has left, at a glance. The pointer on the toast holds it full, as it holds the toast;
/// leaving starts it again in full, as the toast's time does (``CmuxToastCenter/setHovered(_:_:)``).
///
/// The ring runs only in a window; its stroke follows the overlays' timed curve. Under Reduce Motion it
/// stays full and still.
@MainActor
public final class CmuxToastCountdownRing: NSView {
    /// The ring's side, a little wider than the close button it circles.
    static let side: CGFloat = 24
    private let ring = CAShapeLayer()
    private let track = CAShapeLayer()
    /// How long the ring takes to empty: the toast's shown time.
    public let duration: Duration
    /// Whether the ring is emptying now (tests, the playground).
    public private(set) var isRunning = false

    /// - Parameter duration: The toast's shown time (``CmuxToastTuning/shownDuration(of:)``).
    public init(duration: Duration) {
        self.duration = duration
        super.init(frame: NSRect(x: 0, y: 0, width: Self.side, height: Self.side))
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        for shape in [track, ring] {
            shape.fillColor = nil
            shape.lineWidth = 1.5
            shape.lineCap = .round
            layer?.addSublayer(shape)
        }
        ring.strokeEnd = 1
        setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: Self.side),
            heightAnchor.constraint(equalToConstant: Self.side),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// It never takes a click: the close button under it does.
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }

    public override func layout() {
        super.layout()
        let inset = ring.lineWidth / 2
        // From twelve o'clock, emptying counterclockwise toward it.
        let path = CGMutablePath()
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - inset
        path.addArc(center: center, radius: radius, startAngle: .pi / 2, endAngle: .pi / 2 - 2 * .pi, clockwise: true)
        ring.frame = bounds
        track.frame = bounds
        ring.path = path
        track.path = path
        applyColors()
    }

    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyColors()
        if window == nil { stop() } else if !isRunning { start() }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    /// The pointer on the toast: the ring holds full; off it, the ring empties again from full.
    func hold(_ held: Bool) {
        if held { stop() } else if window != nil { start() }
    }

    private func start() {
        stop()
        guard Motion.canAnimate(in: self), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let seconds = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        guard seconds > 0 else { return }
        Motion.overlays.set(ring, "strokeEnd", to: CGFloat(0), duration: seconds, from: CGFloat(1))
        isRunning = true
    }

    private func stop() {
        ring.removeAnimation(forKey: "strokeEnd")
        Motion.setModel(ring, "strokeEnd", CGFloat(1))
        isRunning = false
    }

    private func applyColors() {
        performWithTheme {
            ring.strokeColor = Palette.toastText(.secondary).cgColor
            track.strokeColor = Palette.toastText(.tertiary).withAlphaComponent(0.25).cgColor
        }
    }
}
