#if os(iOS)
import UIKit

extension TranscriptListViewController {
    func configureKeyboardObservation() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardWillChangeFrameNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleKeyboardFrameChange(_:)),
            name: UIResponder.keyboardWillHideNotification,
            object: nil
        )
    }

    @objc
    private func handleKeyboardFrameChange(_ notification: Notification) {
        view.layoutIfNeeded()
        let guideObstruction = max(0, view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY)
        let restingObstruction = view.safeAreaInsets.bottom
        // While the keyboard obstructs beyond the resting guide, any strip
        // declared via additionalSafeAreaInsets.bottom is pinned to the guide
        // and rides above the keyboard, so its height stacks on top of the
        // keyboard obstruction instead of being absorbed by it.
        let inset: CGFloat = if guideObstruction > restingObstruction + 0.5 {
            guideObstruction + additionalSafeAreaInsets.bottom - restingObstruction
        } else {
            0
        }
        let delta = inset - currentKeyboardInset
        currentKeyboardInset = inset
        updateVisualEdgeInsets(preservingBottomPosition: false)
        keyboardAnimator?.stopAnimation(true)
        guard !collectionView.isTracking,
              !collectionView.isDragging,
              !collectionView.isDecelerating,
              abs(delta) > 0.5
        else {
            return
        }

        let duration = (notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? NSNumber)?.doubleValue ?? 0.25
        let curveRaw = (notification.userInfo?[UIResponder.keyboardAnimationCurveUserInfoKey] as? NSNumber)?.intValue
            ?? UIView.AnimationCurve.easeInOut.rawValue
        let curve = UIView.AnimationCurve(rawValue: curveRaw) ?? .easeInOut
        let animator = UIViewPropertyAnimator(duration: duration, curve: curve) { [weak self] in
            guard let self else { return }
            self.collectionView.contentOffset.y -= delta
        }
        keyboardAnimator = animator
        animator.startAnimation()
    }
}
#endif
