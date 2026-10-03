#if os(iOS)
import UIKit

/// The terminal contracts into its card on entry and expands from it on exit.
/// UIKit's standard zoom presents the detail; here the detail is already open.
@MainActor
final class TerminalTabOverviewZoomTransition: NSObject, UIViewControllerAnimatedTransitioning {
    private let isOpening: Bool
    private var animator: UIViewPropertyAnimator?

    init(isOpening: Bool) { self.isOpening = isOpening }

    func transitionDuration(using transitionContext: (any UIViewControllerContextTransitioning)?) -> TimeInterval {
        UIAccessibility.isReduceMotionEnabled ? 0.2 : 0.46
    }

    func animateTransition(using transitionContext: any UIViewControllerContextTransitioning) {
        interruptibleAnimator(using: transitionContext).startAnimation()
    }

    func interruptibleAnimator(using context: any UIViewControllerContextTransitioning) -> any UIViewImplicitlyAnimating {
        if let animator { return animator }
        let container = context.containerView
        let overview = context.viewController(forKey: isOpening ? .to : .from) as? TerminalTabOverviewViewController
        let terminal = context.viewController(forKey: isOpening ? .from : .to)
        guard let overview, let terminal else {
            let animator = UIViewPropertyAnimator(duration: 0, curve: .linear)
            animator.addCompletion { _ in context.completeTransition(false) }
            self.animator = animator
            return animator
        }
        if isOpening {
            overview.view.frame = context.finalFrame(for: overview)
            container.addSubview(overview.view)
        }
        overview.view.layoutIfNeeded()
        terminal.view.layoutIfNeeded()
        let card = overview.transitionCard()
        let preview = card?.transitionPreview
        let fullFrame = terminal.view.convert(terminal.view.bounds, to: container)
        let cardFrame = preview.map { $0.convert($0.bounds, to: container) }
        let snapshot = UIAccessibility.isReduceMotionEnabled ? nil : terminal.view.snapshotView(afterScreenUpdates: !isOpening)
        let surface = UIView()
        surface.clipsToBounds = true
        surface.layer.cornerCurve = .continuous
        surface.isUserInteractionEnabled = false
        let canZoom = snapshot != nil && cardFrame != nil && fullFrame.width > 0
        let terminalWasHidden = terminal.view.isHidden
        if canZoom, let snapshot, let cardFrame {
            snapshot.bounds = CGRect(origin: .zero, size: fullFrame.size)
            snapshot.layer.anchorPoint = .zero
            snapshot.layer.position = .zero
            surface.addSubview(snapshot)
            surface.frame = isOpening ? fullFrame : cardFrame
            let scale = cardFrame.width / fullFrame.width
            snapshot.transform = isOpening ? .identity : CGAffineTransform(scaleX: scale, y: scale)
            surface.layer.cornerRadius = isOpening ? 0 : 12
            container.addSubview(surface)
            preview?.isHidden = true
            terminal.view.isHidden = true
        }
        if canZoom {
            overview.setZoomChromeAlpha(isOpening ? 0 : 1)
        } else {
            overview.view.alpha = isOpening ? 0 : 1
        }
        let animator = UIViewPropertyAnimator(
            duration: transitionDuration(using: context),
            dampingRatio: 1
        )
        animator.addAnimations {
            if canZoom {
                overview.setZoomChromeAlpha(self.isOpening ? 1 : 0)
            } else {
                overview.view.alpha = self.isOpening ? 1 : 0
            }
            if canZoom, let snapshot, let cardFrame {
                surface.frame = self.isOpening ? cardFrame : fullFrame
                let scale = self.isOpening ? cardFrame.width / fullFrame.width : 1
                snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
                surface.layer.cornerRadius = self.isOpening ? 12 : 0
            }
        }
        animator.addCompletion { _ in
            let completed = !context.transitionWasCancelled
            preview?.isHidden = false
            if completed, self.isOpening, canZoom, let snapshot {
                card?.setTerminalSnapshot(snapshot)
            }
            surface.removeFromSuperview()
            terminal.view.isHidden = terminalWasHidden
            overview.setZoomChromeAlpha(1)
            overview.view.alpha = 1
            context.completeTransition(completed)
        }
        self.animator = animator
        return animator
    }

    func animationEnded(_ transitionCompleted: Bool) { animator = nil }
}
#endif
