public import QuartzCore

/// The spinner's drawing: a thin arc (``arcLength`` of the circle, round caps) that turns clockwise
/// once per ``period``, as a Core Animation rotation the render server runs (no per-frame work in
/// the app). Its phase is Unix time mod the period, so every spinner in the process, and the Mac
/// app's (CmuxNextDesign `SpinnerClock`), sits at the same angle at the same moment.
public final class CmuxSpinnerLayer: CALayer {
    /// Share of the circle the arc covers (CmuxNextDesign `StatusIndicatorTunables.arcLength`).
    public static let arcLength: CGFloat = 0.72
    /// The key of the turning animation.
    public static let turnKey = "cmux.spinner.turn"

    /// The arc's ink.
    public var tint: CGColor? {
        didSet { arc.strokeColor = tint }
    }

    /// One turn's length; the shared period unless a test passes its own.
    public var period = CmuxSpinnerPeriod() {
        didSet { if isTurning { turn(true) } }
    }

    /// Whether the arc is turning (false while stopped or under Reduce Motion).
    public var isTurning: Bool { animation(forKey: Self.turnKey) != nil }

    private let arc = CAShapeLayer()

    override public init() {
        super.init()
        arc.fillColor = nil
        arc.lineCap = .round
        arc.strokeStart = 0
        arc.strokeEnd = Self.arcLength
        addSublayer(arc)
    }

    /// A copy Core Animation makes (a presentation layer): it draws nothing of its own.
    override public init(layer: Any) {
        super.init(layer: layer)
        if let other = layer as? CmuxSpinnerLayer { tint = other.tint; period = other.period }
    }

    @available(*, unavailable)
    public required init?(coder: NSCoder) { nil }

    override public func layoutSublayers() {
        super.layoutSublayers()
        let side = min(bounds.width, bounds.height)
        let line = Self.lineWidth(side: side)
        // No implicit animation of the path or frame when the host resizes.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arc.frame = CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
        arc.lineWidth = line
        arc.path = CGPath(ellipseIn: arc.bounds.insetBy(dx: line / 2, dy: line / 2), transform: nil)
        CATransaction.commit()
    }

    /// Starts or stops the turn. A host passes false under Reduce Motion: the arc then holds still.
    public func turn(_ on: Bool) {
        arc.removeAnimation(forKey: Self.turnKey)
        removeAnimation(forKey: Self.turnKey)
        guard on else { return }
        let spin = Self.turnAnimation(period: period)
        spin.beginTime = convertTime(Self.beginTime(period: period, mediaTime: CACurrentMediaTime()), from: nil)
        add(spin, forKey: Self.turnKey)
    }

    /// The stroke width at a side: CmuxNextDesign's 1.5 pt at its 12 pt marks, thicker as it grows.
    static func lineWidth(side: CGFloat) -> CGFloat { max(1.5, side / 8) }

    /// One clockwise turn per `period`, repeating. iOS layers run y-down, macOS layers y-up, so the
    /// same on-screen direction is a positive angle on one and a negative one on the other.
    static func turnAnimation(period: CmuxSpinnerPeriod) -> CABasicAnimation {
        // motion: allow the hosts pass `turn(false)` under Reduce Motion; a spinner is a loop, not a transition
        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = 0
        #if os(macOS)
        spin.toValue = -2 * CGFloat.pi
        #else
        spin.toValue = 2 * CGFloat.pi
        #endif
        spin.duration = period.seconds
        spin.repeatCount = .infinity
        spin.isRemovedOnCompletion = false
        return spin
    }

    /// Unix time minus media time, read once per process: the media clock stops while the device
    /// sleeps and Unix time does not, so one offset keeps every spinner of the process in one phase.
    private static let processEpoch: TimeInterval = Date().timeIntervalSince1970 - CACurrentMediaTime()

    /// The media time a turn of `period` must begin at for its phase now to be Unix time mod `period`.
    static func beginTime(period: CmuxSpinnerPeriod, mediaTime: CFTimeInterval,
                          unixTime: TimeInterval? = nil) -> CFTimeInterval {
        let cycle = period.seconds
        guard cycle > 0 else { return mediaTime }
        let into = (unixTime ?? mediaTime + processEpoch).truncatingRemainder(dividingBy: cycle)
        return mediaTime - (into < 0 ? into + cycle : into)
    }
}
