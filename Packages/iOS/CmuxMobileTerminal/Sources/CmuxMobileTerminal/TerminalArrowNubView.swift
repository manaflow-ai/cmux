#if canImport(UIKit)
import CmuxMobileTerminalKit
import UIKit

// MARK: - Arrow Nub (draggable directional pad)

final class TerminalArrowNubView: UIView {
    var onArrowKey: ((TerminalInputAccessoryAction) -> Void)?

    // Locked to the size the docked bar actually pins the nub to, so the circular
    // background (cornerRadius = nubSize/2) and the drag clamp track the real frame.
    private let nubSize: CGFloat = TerminalInputTextView.dockedNubSize
    private let deadZone: CGFloat = 8
    private let repeatInterval: Duration = .milliseconds(80)
    private let innerDot = UIView()
    private var dragOrigin: CGPoint = .zero
    /// Drives the immediate + interval arrow repeats off an injected `Clock`
    /// (replacing the run-loop `Timer`); cancellation is wired to the gesture.
    private let arrowRepeatService = TerminalArrowRepeatService()
    /// The in-flight repeat stream consumer. Cancelled on direction change /
    /// gesture end, which terminates the service stream's cadence.
    private var repeatTask: Task<Void, Never>?
    private var lastDirection: Direction?
    private let feedbackGenerator = UIImpactFeedbackGenerator(style: .light)

    private enum Direction {
        case up, down, left, right

        var repeatDirection: TerminalArrowRepeatService.Direction {
            switch self {
            case .up:    return .upArrow
            case .down:  return .downArrow
            case .right: return .rightArrow
            case .left:  return .leftArrow
            }
        }

        var accessoryAction: TerminalInputAccessoryAction {
            switch self {
            case .up:    return .upArrow
            case .down:  return .downArrow
            case .right: return .rightArrow
            case .left:  return .leftArrow
            }
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(white: 0.25, alpha: 0.85)
        layer.cornerRadius = nubSize / 2

        innerDot.backgroundColor = UIColor(white: 0.85, alpha: 1)
        innerDot.layer.cornerRadius = 6
        innerDot.frame = CGRect(x: 0, y: 0, width: 12, height: 12)
        innerDot.layer.shadowColor = UIColor.white.cgColor
        innerDot.layer.shadowOpacity = 0.3
        innerDot.layer.shadowRadius = 3
        innerDot.layer.shadowOffset = .zero
        addSubview(innerDot)

        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        addGestureRecognizer(pan)

        feedbackGenerator.prepare()
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        if repeatTask == nil {
            innerDot.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    override var intrinsicContentSize: CGSize {
        CGSize(width: nubSize, height: nubSize)
    }

    @objc private func handlePan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: self)
        switch gesture.state {
        case .began:
            dragOrigin = innerDot.center
            feedbackGenerator.prepare()
        case .changed:
            let maxOffset: CGFloat = nubSize / 2 - 8
            let clampedX = max(-maxOffset, min(maxOffset, translation.x))
            let clampedY = max(-maxOffset, min(maxOffset, translation.y))
            innerDot.center = CGPoint(x: dragOrigin.x + clampedX, y: dragOrigin.y + clampedY)

            let direction = directionFrom(dx: translation.x, dy: translation.y)
            if direction != lastDirection {
                lastDirection = direction
                stopRepeat()
                if let direction {
                    startRepeat(direction)
                }
            }
        case .ended, .cancelled:
            stopRepeat()
            lastDirection = nil
            UIView.animate(withDuration: 0.15) {
                self.innerDot.center = CGPoint(x: self.bounds.midX, y: self.bounds.midY)
            }
        default:
            break
        }
    }

    private func directionFrom(dx: CGFloat, dy: CGFloat) -> Direction? {
        let dist = sqrt(dx * dx + dy * dy)
        guard dist > deadZone else { return nil }
        if abs(dx) > abs(dy) {
            return dx > 0 ? .right : .left
        } else {
            return dy > 0 ? .down : .up
        }
    }

    /// Consume the service's repeat stream for `direction`: it emits the first
    /// arrow immediately and one per interval. Each emission fires haptics and
    /// forwards the bytes on the main actor. Cancelled by ``stopRepeat()``.
    private func startRepeat(_ direction: Direction) {
        let stream = arrowRepeatService.repeats(
            of: direction.repeatDirection,
            every: repeatInterval,
            clock: ContinuousClock()
        )
        repeatTask = Task { @MainActor [weak self] in
            for await _ in stream {
                guard let self else { return }
                self.feedbackGenerator.impactOccurred()
                self.onArrowKey?(direction.accessoryAction)
            }
        }
    }

    private func stopRepeat() {
        repeatTask?.cancel()
        repeatTask = nil
    }
}
#endif
