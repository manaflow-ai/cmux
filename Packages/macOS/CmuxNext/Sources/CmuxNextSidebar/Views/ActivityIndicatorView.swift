import AppKit
import CmuxNextDesign
import QuartzCore

/// Small agent-activity indicator: spinner (running), the theme's yellow
/// dot (needs input) or red dot (error).
final class ActivityIndicatorView: NSView {
    let shape = CAShapeLayer()
    private(set) var activity: AgentActivity = .idle
    /// Whether the window is on screen and not fully covered. The list sets
    /// this from the window's occlusion state; a hidden window runs no
    /// animation, so an occluded sidebar costs no frames.
    var isWindowVisible = true {
        didSet { if isWindowVisible != oldValue { updateAnimations() } }
    }

    /// The looping animation an indicator runs, if any.
    enum Animation: Equatable { case spin, pulse }

    /// Pure decision: which animation runs for `activity`. None while not in
    /// a window, while the window is occluded, or under Reduce Motion.
    static func animation(for activity: AgentActivity, inWindow: Bool, windowVisible: Bool, reduceMotion: Bool) -> Animation? {
        guard inWindow, windowVisible, !reduceMotion else { return nil }
        switch activity {
        case .running: return .spin
        case .needsInput: return .pulse
        case .error, .idle: return nil
        }
    }

    /// The animation currently attached to the layer (tests, diagnostics).
    var runningAnimation: Animation? {
        if shape.animation(forKey: "spin") != nil { return .spin }
        if shape.animation(forKey: "pulse") != nil { return .pulse }
        return nil
    }

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

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }

    override func layout() {
        super.layout()
        // A sublayer the view did not create keeps contentsScale 1 unless set;
        // a 1x shape layer is magnified (blurry) on Retina.
        shape.contentsScale = window?.backingScaleFactor ?? 2
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
        performWithTheme {
            switch activity {
            case .running:
                shape.strokeColor = Palette.textSecondary.cgColor
                shape.fillColor = nil
            case .needsInput:
                shape.strokeColor = nil
                shape.fillColor = Palette.attention.cgColor
            case .error:
                shape.strokeColor = nil
                shape.fillColor = Palette.danger.cgColor
            case .idle:
                break
            }
        }
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { isWindowVisible = window.occlusionState.contains(.visible) }
        updateAnimations()
    }

    private func updateAnimations() {
        let wanted = Self.animation(for: activity, inWindow: window != nil, windowVisible: isWindowVisible, reduceMotion: !Motion.animatesLoops)
        guard wanted != runningAnimation else { return }
        shape.removeAllAnimations()
        switch wanted {
        case .spin?:
            if let spin = Motion.spinAnimation() { shape.add(spin, forKey: "spin") }
        case .pulse?:
            if let pulse = Motion.pulseAnimation(low: 0.35) { shape.add(pulse, forKey: "pulse") }
        case nil:
            break
        }
    }
}
