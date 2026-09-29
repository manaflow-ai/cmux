import AppKit
import CmuxNextDesign
import QuartzCore

/// Small agent-activity indicator: spinner (running), amber dot (needs
/// input), red dot (error).
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
        if let window { isWindowVisible = window.occlusionState.contains(.visible) }
        updateAnimations()
    }

    private func updateAnimations() {
        let wanted = Self.animation(for: activity, inWindow: window != nil, windowVisible: isWindowVisible, reduceMotion: Motion.reduceMotion)
        guard wanted != runningAnimation else { return }
        shape.removeAllAnimations()
        switch wanted {
        case .spin?:
            let spin = CABasicAnimation(keyPath: "transform.rotation.z")
            spin.fromValue = 0
            spin.toValue = -2 * Double.pi
            spin.duration = 0.9
            spin.repeatCount = .infinity
            shape.add(spin, forKey: "spin")
        case .pulse?:
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1
            pulse.toValue = 0.35
            pulse.duration = 0.9
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            shape.add(pulse, forKey: "pulse")
        case nil:
            break
        }
    }
}
