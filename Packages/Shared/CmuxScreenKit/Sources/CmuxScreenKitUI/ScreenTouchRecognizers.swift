#if os(iOS)
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Reports one finger's touch as it happens (down, moves, up), for trackpad
/// mode, which needs the touch-down a tap recognizer hides. A second finger
/// cancels it, so two-finger gestures and pinch take over. It never blocks
/// other recognizers or the touches themselves.
final class SingleTouchRecognizer: UIGestureRecognizer {
    enum Event {
        /// Locations are in window coordinates (they do not move when the view scrolls).
        case down(CGPoint, TimeInterval)
        case moved(CGPoint, TimeInterval)
        case up(TimeInterval)
        case cancelled
    }

    var onEvent: ((Event) -> Void)?
    private var tracked: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, touches.count == 1, let touch = touches.first else {
            abandon()
            return
        }
        tracked = touch
        state = .began
        onEvent?(.down(touch.location(in: nil), touch.timestamp))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        state = .changed
        onEvent?(.moved(tracked.location(in: nil), tracked.timestamp))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        onEvent?(.up(tracked.timestamp))
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        abandon()
    }

    /// A second finger, or the system took the touch.
    private func abandon() {
        if tracked != nil {
            onEvent?(.cancelled)
            state = .cancelled
        } else {
            state = .failed
        }
    }

    override func reset() {
        super.reset()
        tracked = nil
    }
}

/// A mouse or trackpad button on iPad (indirect pointer touches; the app
/// sets `UIApplicationSupportsIndirectInputEvents`): which button went
/// down, the pointer while it is held, and its release. A press drags at
/// once, as on a Mac.
final class PointerButtonRecognizer: UIGestureRecognizer {
    enum Event {
        case down(UITouch, secondary: Bool)
        case moved(UITouch)
        case up
    }

    var onEvent: ((Event) -> Void)?
    private var tracked: UITouch?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)]
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked == nil, let touch = touches.first else { return }
        tracked = touch
        state = .began
        onEvent?(.down(touch, secondary: event.buttonMask.contains(.secondary)))
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        state = .changed
        onEvent?(.moved(tracked))
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let tracked, touches.contains(tracked) else { return }
        onEvent?(.up)
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard tracked != nil else { return }
        onEvent?(.up)
        state = .cancelled
    }

    override func reset() {
        super.reset()
        tracked = nil
    }
}

extension ScreenViewController {
    /// The arrow drawn in trackpad mode (and under a hovering pointer) when
    /// the Mac sends no cursor shape: white with a dark outline, in
    /// framebuffer pixels, hotspot at its tip.
    static let fallbackCursor: (image: CGImage?, size: CGSize, hotspot: CGPoint) = {
        let size = CGSize(width: 28, height: 42)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let path = UIBezierPath()
            path.move(to: CGPoint(x: 2, y: 2))
            path.addLine(to: CGPoint(x: 2, y: 34))
            path.addLine(to: CGPoint(x: 10, y: 26.5))
            path.addLine(to: CGPoint(x: 15.5, y: 39))
            path.addLine(to: CGPoint(x: 21, y: 36.5))
            path.addLine(to: CGPoint(x: 15.5, y: 24.5))
            path.addLine(to: CGPoint(x: 26, y: 24.5))
            path.close()
            path.lineJoinStyle = .round
            path.lineWidth = 2
            context.cgContext.setShadow(offset: CGSize(width: 0, height: 1), blur: 2, color: UIColor.black.withAlphaComponent(0.4).cgColor)
            UIColor.white.setFill()
            path.fill()
            context.cgContext.setShadow(offset: .zero, blur: 0, color: nil)
            UIColor.black.setStroke()
            path.stroke()
        }
        return (image.cgImage, size, CGPoint(x: 2, y: 2))
    }()
}
#endif
