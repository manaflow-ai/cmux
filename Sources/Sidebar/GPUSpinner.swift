import AppKit
import QuartzCore
import SwiftUI

/// Spinner styles drawn entirely with Core Animation layers. The rotation is a
/// `transform.rotation.z` animation run by the render server, so there is zero
/// per-frame CPU work and nothing on the main thread once the animation is
/// installed.
enum GPUSpinnerStyle {
    /// The native macOS indeterminate look: fading "spokes" (rounded bars)
    /// arranged in a ring. The bars are static; only the ring rotates.
    case macOSSpokes
    /// A single rotating arc (the original cmux sidebar spinner).
    case arc
}

/// A GPU-driven indeterminate spinner.
///
/// Energy profile: the only animated property is the layer transform, which the
/// window server interpolates off the main thread on the GPU. There is no
/// timer, no `setNeedsDisplay` per frame, and no main-thread work while it
/// spins, so it is the battery-friendly alternative to `NSProgressIndicator`
/// (which redraws every frame on the CPU). The animation is removed whenever the
/// view leaves the window, the window is occluded/minimized, or the system
/// "Reduce Motion" accessibility setting is on, so an off-screen or background
/// spinner costs nothing.
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
        let thickness = max(1, side * 0.16)
        let length = max(2, side * 0.30)
        // Distance from the center to each spoke's own center.
        let radius = side / 2 - length / 2
        for (index, spoke) in spokeLayers.enumerated() {
            let angle = CGFloat(index) / CGFloat(Self.spokeCount) * .pi * 2
            spoke.bounds = CGRect(x: 0, y: 0, width: thickness, height: length)
            spoke.cornerRadius = thickness / 2
            spoke.position = CGPoint(
                x: center.x + cos(angle) * radius,
                y: center.y + sin(angle) * radius
            )
            // Rotate so the bar's long axis points radially outward.
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
        arcLayer.lineWidth = max(1.4, side * 0.16)
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
                // Static opacity ramp: the leading spoke is brightest, trailing
                // spokes fade. Only the ring rotates, so the bright spoke chases
                // around the circle.
                let t = Float(index) / Float(Self.spokeCount - 1)
                spoke.opacity = 0.2 + 0.8 * t
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
        let cg = Self.resolvedCGColor(color)
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
        // Reduce Motion swaps between the static ring and the animated ring, so
        // rebuild the static appearance before re-evaluating the animation.
        layoutContent()
        updateAnimationState()
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

    private func installAnimationIfNeeded() {
        guard contentLayer.animation(forKey: Self.animationKey) == nil else { return }
        switch style {
        case .macOSSpokes:
            // Discrete steps, one spoke per step, to match the native macOS
            // indeterminate spinner's stepped cadence. Clockwise (negative z).
            let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let count = Self.spokeCount
            animation.values = (0...count).map { -CGFloat($0) / CGFloat(count) * .pi * 2 }
            animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
            animation.calculationMode = .discrete
            animation.duration = Self.cycleDuration
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            contentLayer.add(animation, forKey: Self.animationKey)
        case .arc:
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = CGFloat.pi * 2
            animation.duration = 0.9
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.isRemovedOnCompletion = false
            contentLayer.add(animation, forKey: Self.animationKey)
        }
    }

    private static func resolvedCGColor(_ color: NSColor) -> CGColor {
        color.usingColorSpace(.deviceRGB)?.cgColor
            ?? NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB)?.cgColor
            ?? CGColor(gray: 0.6, alpha: 1)
    }
}
