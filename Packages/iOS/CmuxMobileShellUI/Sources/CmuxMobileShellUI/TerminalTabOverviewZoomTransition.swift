#if os(iOS)
import CmuxMobileTerminal
import UIKit

/// The terminal contracts into its card on entry and expands from it on exit.
/// UIKit's standard zoom presents the detail; here the detail is already open.
@MainActor
final class TerminalTabOverviewZoomTransition: NSObject, UIViewControllerAnimatedTransitioning {
    private let isOpening: Bool
    private weak var contentAnchor: UIView?
    private var animator: UIViewPropertyAnimator?

    init(isOpening: Bool, contentAnchor: UIView) {
        self.isOpening = isOpening
        self.contentAnchor = contentAnchor
    }

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
        let rootFrame = terminal.view.convert(terminal.view.bounds, to: container)
        let viewport = overview.transitionTerminalID.flatMap {
            GhosttySurfaceView.terminalContentFrame(surfaceID: $0.rawValue, in: terminal.view)
        }
        let anchorFrame = contentAnchor.map { $0.convert($0.safeAreaLayoutGuide.layoutFrame, to: terminal.view) }
        let contentFrame = (viewport ?? anchorFrame ?? terminal.view.bounds).intersection(terminal.view.bounds)
        let fullFrame = terminal.view.convert(contentFrame, to: container)
        let cardFrame = preview.map { $0.convert($0.bounds, to: container) }
        let snapshot = UIAccessibility.isReduceMotionEnabled ? nil : terminal.view.resizableSnapshotView(
            from: contentFrame, afterScreenUpdates: !isOpening, withCapInsets: .zero
        )
        let chrome = snapshot == nil ? nil : terminal.view.snapshotView(afterScreenUpdates: false)
        let surface = UIView()
        surface.clipsToBounds = true
        surface.layer.cornerCurve = .continuous
        surface.isUserInteractionEnabled = false
        let canZoom = snapshot != nil && cardFrame != nil && !fullFrame.isEmpty
        let terminalWasHidden = terminal.view.isHidden
        if canZoom, let snapshot, let cardFrame {
            // Keep the surrounding native controls at their original size.
            // Only the renderer's viewport travels into the card.
            if let chrome {
                chrome.frame = rootFrame
                let path = UIBezierPath(rect: chrome.bounds)
                path.append(UIBezierPath(rect: contentFrame.offsetBy(dx: -terminal.view.bounds.minX, dy: -terminal.view.bounds.minY)))
                let mask = CAShapeLayer()
                mask.path = path.cgPath
                mask.fillRule = .evenOdd
                chrome.layer.mask = mask
                chrome.alpha = isOpening ? 1 : 0
                container.addSubview(chrome)
            }
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
                chrome?.alpha = self.isOpening ? 0 : 1
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
            chrome?.removeFromSuperview()
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
