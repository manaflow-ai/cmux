import AppKit
import SwiftUI

struct SidebarAgentActivityIndicator: View {
    let count: Int
    let spinnerColor: NSColor
    let foregroundColor: Color
    let backgroundColor: Color
    let fontScale: CGFloat

    var body: some View {
        HStack(spacing: max(3, 3 * fontScale)) {
            CoreAnimationSpinner(color: spinnerColor)
                .frame(width: max(9, 9 * fontScale), height: max(9, 9 * fontScale))
            Text("\(count)")
                .font(.system(size: max(8, 8.5 * fontScale), weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundColor(foregroundColor)
                .lineLimit(1)
        }
        .padding(.horizontal, max(5, 5 * fontScale))
        .frame(height: max(16, 16 * fontScale))
        .background(
            Capsule(style: .continuous)
                .fill(backgroundColor)
        )
        .fixedSize(horizontal: true, vertical: true)
    }
}

private struct CoreAnimationSpinner: NSViewRepresentable {
    let color: NSColor

    func makeNSView(context: Context) -> CoreAnimationSpinnerNSView {
        let view = CoreAnimationSpinnerNSView(frame: .zero)
        view.color = color
        return view
    }

    func updateNSView(_ view: CoreAnimationSpinnerNSView, context: Context) {
        view.color = color
    }
}

private final class CoreAnimationSpinnerNSView: NSView {
    private static let animationKey = "cmux.agentActivity.rotation"
    private let shapeLayer = CAShapeLayer()

    var color: NSColor = .secondaryLabelColor {
        didSet {
            shapeLayer.strokeColor = Self.resolvedCGColor(color)
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        shapeLayer.fillColor = NSColor.clear.cgColor
        shapeLayer.lineCap = .round
        shapeLayer.strokeStart = 0.08
        shapeLayer.strokeEnd = 0.78
        shapeLayer.strokeColor = Self.resolvedCGColor(color)
        layer?.addSublayer(shapeLayer)
        startAnimating()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        updatePath()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            shapeLayer.removeAnimation(forKey: Self.animationKey)
        } else {
            startAnimating()
        }
    }

    private func updatePath() {
        let side = min(bounds.width, bounds.height)
        guard side > 0 else { return }
        shapeLayer.frame = CGRect(x: 0, y: 0, width: side, height: side)
        shapeLayer.position = CGPoint(x: bounds.midX, y: bounds.midY)
        shapeLayer.lineWidth = max(1.4, side * 0.16)
        let inset = shapeLayer.lineWidth / 2
        shapeLayer.path = CGPath(
            ellipseIn: CGRect(x: inset, y: inset, width: side - inset * 2, height: side - inset * 2),
            transform: nil
        )
    }

    private func startAnimating() {
        guard shapeLayer.animation(forKey: Self.animationKey) == nil else { return }
        let animation = CABasicAnimation(keyPath: "transform.rotation.z")
        animation.fromValue = 0
        animation.toValue = CGFloat.pi * 2
        animation.duration = 0.9
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .linear)
        animation.isRemovedOnCompletion = false
        shapeLayer.add(animation, forKey: Self.animationKey)
    }

    private static func resolvedCGColor(_ color: NSColor) -> CGColor {
        color.usingColorSpace(.deviceRGB)?.cgColor
            ?? NSColor.secondaryLabelColor.usingColorSpace(.deviceRGB)?.cgColor
            ?? CGColor(gray: 0.6, alpha: 1)
    }
}
