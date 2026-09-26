import AppKit
import QuartzCore
import SwiftUI

final class GPUSpinnerNSView: NSView {
    static let animationKey = "cmux.gpuSpinner.rotation"
    private static let spokeCount = 8
    private static let cycleDuration: CFTimeInterval = 0.8
    private static let arcDuration: CFTimeInterval = 0.9

    let contentLayer = CALayer()
    private var spokeLayers: [CALayer] = []
    private let arcLayer = CAShapeLayer()

    /// Sidebar rows hide an idle spinner instead of removing it, so hiding
    /// must also stop the endless animation.
    override var isHidden: Bool {
        didSet {
            guard isHidden != oldValue else { return }
            updateAnimationState()
        }
    }

    var isPresentationActive = true {
        didSet {
            guard isPresentationActive != oldValue else { return }
            updateAnimationState()
        }
    }

    var style: GPUSpinnerStyle = .macOSSpokes {
        didSet {
            guard style != oldValue else { return }
            rebuildLayers()
        }
    }

    var color: NSColor = .secondaryLabelColor {
        didSet { applyColor() }
    }

    /// Concrete cmux scheme used to resolve semantic spinner colors.
    var colorScheme: ColorScheme = .light {
        didSet {
            guard colorScheme != oldValue else { return }
            applyColor()
        }
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
        cg = Self.resolvedCGColor(
            SidebarAppearanceColorResolver().resolvedColor(color, for: colorScheme),
            colorScheme: colorScheme
        )
        switch style {
        case .macOSSpokes:
            for spoke in spokeLayers {
                spoke.backgroundColor = cg
            }
        case .arc:
            arcLayer.strokeColor = cg
        }
    }

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

    private var shouldAnimate: Bool {
        guard isPresentationActive else { return false }
        guard !isHiddenOrHasHiddenAncestor else { return false }
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

    /// Anchors `beginTime` to the shared Core Animation media clock so all
    /// spinners of the same duration stay phase-locked, even when their layer
    /// hierarchies have different local time bases.
    private func syncedBeginTime(duration: CFTimeInterval) -> CFTimeInterval {
        let globalNow = CACurrentMediaTime()
        let layerNow = contentLayer.convertTime(globalNow, from: nil)
        let sharedPhase = globalNow.truncatingRemainder(dividingBy: duration)
        return layerNow - sharedPhase
    }

    private func installAnimationIfNeeded() {
        guard contentLayer.animation(forKey: Self.animationKey) == nil else { return }
        let duration = style == .macOSSpokes ? Self.cycleDuration : Self.arcDuration
        contentLayer.add(
            Self.makeRotationAnimation(style: style, beginTime: syncedBeginTime(duration: duration)),
            forKey: Self.animationKey
        )
    }

    /// Builds the endless rotation for `style`.
    ///
    /// Core Animation runs these animations in WindowServer, which otherwise
    /// may recomposite an animating layer at the display's full refresh rate
    /// (160 Hz on some external displays), and a translucent or glass window
    /// makes each of those frames more expensive. The spokes only change ten
    /// times a second, so they ask for 10-20 Hz; the continuous arc asks for
    /// at most 60 Hz.
    static func makeRotationAnimation(style: GPUSpinnerStyle, beginTime: CFTimeInterval) -> CAAnimation {
        switch style {
        case .macOSSpokes:
            // Discrete one-spoke steps, clockwise, matching the native cadence.
            let animation = CAKeyframeAnimation(keyPath: "transform.rotation.z")
            let count = spokeCount
            animation.values = (0...count).map { -CGFloat($0) / CGFloat(count) * .pi * 2 }
            animation.keyTimes = (0...count).map { NSNumber(value: Double($0) / Double(count)) }
            animation.calculationMode = .discrete
            animation.duration = cycleDuration
            animation.repeatCount = .infinity
            animation.isRemovedOnCompletion = false
            animation.beginTime = beginTime
            let stepsPerSecond = Float(Double(count) / cycleDuration)
            animation.preferredFrameRateRange = CAFrameRateRange(
                minimum: stepsPerSecond,
                maximum: stepsPerSecond * 2,
                preferred: stepsPerSecond * 2
            )
            return animation
        case .arc:
            let animation = CABasicAnimation(keyPath: "transform.rotation.z")
            animation.fromValue = 0
            animation.toValue = CGFloat.pi * 2
            animation.duration = arcDuration
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .linear)
            animation.isRemovedOnCompletion = false
            animation.beginTime = beginTime
            animation.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
            return animation
        }
    }

    private static func resolvedCGColor(_ color: NSColor, colorScheme: ColorScheme) -> CGColor {
        color.usingColorSpace(.deviceRGB)?.cgColor
            ?? SidebarAppearanceColorResolver()
                .resolvedColor(.secondaryLabelColor, for: colorScheme)
                .usingColorSpace(.deviceRGB)?.cgColor
            ?? CGColor(gray: 0.6, alpha: 1)
    }
}
