import AppKit
import QuartzCore
import SwiftUI

enum GPUSpinnerStyle {
    /// The native macOS indeterminate look: static fading spokes, rotating ring.
    case macOSSpokes
    /// A single rotating arc.
    case arc
}

/// A GPU-driven indeterminate spinner: the only animated property is the layer
/// transform (render-server interpolated, zero per-frame CPU), and the
/// animation is removed while off-window, occluded, or under Reduce Motion.
struct GPUSpinner: NSViewRepresentable {
    let style: GPUSpinnerStyle
    let color: NSColor

    func makeNSView(context: Context) -> GPUSpinnerNSView {
        let view = GPUSpinnerNSView(frame: .zero)
        view.style = style
        view.color = color
        return view
    }

    func updateNSView(_ view: GPUSpinnerNSView, context: Context) {
        view.style = style
        view.color = color
    }
}

final class GPUSpinnerNSView: NSView {
    private static let animationKey = "cmux.gpuSpinner.rotation"
    private static let spokeCount = 8
    private static let cycleDuration: CFTimeInterval = 0.8
    private static let arcDuration: CFTimeInterval = 0.9

    private let contentLayer = CALayer()
    private var spokeLayers: [CALayer] = []
    private let arcLayer = CAShapeLayer()

    var style: GPUSpinnerStyle = .macOSSpokes {
        didSet {
            guard style != oldValue else { return }
            rebuildLayers()
        }
    }

    var color: NSColor = .secondaryLabelColor {
        didSet { applyColor() }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        contentLayer.masksToBounds = false
        layer?.addSublayer(contentLayer)
        rebuildLayers()
        observeReduceMotion()
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        contentLayer.frame = bounds
        layoutContent()
        updateAnimationState()
    }

    private func layoutContent() {
        switch style {
        case .macOSSpokes:
            layoutSpokes()
        case .arc:
            layoutArc()
        }
    }

    private func layoutSpokes() {
        let side = min(bounds.width, bounds.height)
        guard side > 0, spokeLayers.count == Self.spokeCount else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        // Native macOS proportions: outer ring with a clear center gap.
        let outerRadius = side * 0.40
        let innerRadius = side * 0.18
        let thickness = max(1, side * 0.10)
        let length = max(1, outerRadius - innerRadius)
        let radius = (outerRadius + innerRadius) / 2
        for (index, spoke) in spokeLayers.enumerated() {
            let angle = CGFloat(index) / CGFloat(Self.spokeCount) * .pi * 2
            spoke.bounds = CGRect(x: 0, y: 0, width: thickness, height: length)
            spoke.cornerRadius = thickness / 2
            spoke.position = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            spoke.transform = CATransform3DMakeRotation(angle - .pi / 2, 0, 0, 1)
        }
        contentLayer.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        contentLayer.frame = bounds
    }

    private func layoutArc() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        arcLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        arcLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        arcLayer.lineWidth = max(1, side * 0.10)
        let inset = arcLayer.lineWidth / 2
        arcLayer.path = CGPath(
            ellipseIn: CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2),
            transform: nil
        )
    }

    // MARK: Layer construction

    private func rebuildLayers() {
        contentLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        spokeLayers.removeAll()
        arcLayer.removeFromSuperlayer()
        contentLayer.removeAnimation(forKey: Self.animationKey)

        switch style {
        case .macOSSpokes:
            for index in 0..<Self.spokeCount {
                let spoke = CALayer()
                // Static opacity ramp; only the ring rotates.
                let t = Float(index) / Float(Self.spokeCount - 1)
                spoke.opacity = 0.35 + 0.65 * t
                contentLayer.addSublayer(spoke)
                spokeLayers.append(spoke)
            }
        case .arc:
            arcLayer.fillColor = NSColor.clear.cgColor
            arcLayer.lineCap = .round
            arcLayer.strokeStart = 0.08
            arcLayer.strokeEnd = 0.78
            contentLayer.addSublayer(arcLayer)
        }
        applyColor()
        layoutContent()
        updateAnimationState()
    }

    private func applyColor() {
        var cg = CGColor(gray: 0.6, alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            cg = Self.resolvedCGColor(color)
        }
        switch style {
        case .macOSSpokes:
            for spoke in spokeLayers {
                spoke.backgroundColor = cg
            }
        case .arc:
            arcLayer.strokeColor = cg
        }
    }

    // MARK: Visibility-driven animation

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observeWindowOcclusion()
        updateAnimationState()
    }

    private func observeWindowOcclusion() {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didChangeOcclusionStateNotification, object: nil)
        guard let window else { return }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(visibilityChanged),
            name: NSWindow.didChangeOcclusionStateNotification,
            object: window
        )
    }

    private func observeReduceMotion() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(visibilityChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil
        )
    }

    @objc private func visibilityChanged() {
        layoutContent()
        updateAnimationState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        // Re-resolve snapshotted semantic colors on light/dark switches.
        applyColor()
    }

    private var shouldAnimate: Bool {
        guard let window else { return false }
        guard window.occlusionState.contains(.visible) else { return false }
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { return false }
        return min(bounds.width, bounds.height) > 0
    }

    private func updateAnimationState() {
        if shouldAnimate {
            installAnimationIfNeeded()
        } else {
            contentLayer.removeAnimation(forKey: Self.animationKey)
        }
    }

    /// Anchors `beginTime` to a multiple of `duration` in layer time so all
    /// spinners of the same duration stay phase-locked.
    private func syncedBeginTime(duration: CFTimeInterval) -> CFTimeInterval {
        let now = contentLayer.convertTime(CACurrentMediaTime(), from: nil)
        return now - now.truncatingRemainder(dividingBy: duration)
    }

    private func installAnimationIfNeeded() {
        guard contentLayer.animation(forKey: Self.animationKey) == nil else { return }
        switch style {
        case .macOSSpokes:
            // Discrete one-spoke steps, clockwise, matching the native cadence.
            let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let count = Self.spokeCount
            animation.values = (0...count).map { -CGFloat($0) / CGFloat(count) * .pi * 2 }
            animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
            animation.calculationMode = .discrete
            animation.duration = Self.cycleDuration
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.beginTime = syncedBeginTime(duration: Self.cycleDuration)
            contentLayer.add(animation, forKey: Self.animationKey)
        case .arc:
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = CGFloat.pi * 2
            animation.duration = Self.arcDuration
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.isRemovedOnCompletion = false
            animation.beginTime = syncedBeginTime(duration: Self.arcDuration)
            contentLayer.add(animation, forKey: Self.animationKey)
        }
    }

    private static func resolvedCGColor(_ color: NSColor) -> CGColor {
        color.usingColorSpace(.deviceRGB)?.cgColor
            ?? NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB)?.cgColor
            ?? CGColor(gray: 0.6, alpha: 1)
    }
}
