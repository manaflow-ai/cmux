import AppKit
import CmuxNextDesign
import QuartzCore

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
