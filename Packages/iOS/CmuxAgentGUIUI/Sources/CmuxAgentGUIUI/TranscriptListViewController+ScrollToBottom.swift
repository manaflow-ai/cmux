#if os(iOS)
import UIKit

extension TranscriptListViewController {
    func performScrollToBottom(animated: Bool) {
        if keyboardIsDocked {
            setKeyboardPinsTranscriptToLayoutGuide(true, preservingVisualPosition: false)
        }
        let distance = distanceFromBottom
        guard animated, distance > 0.5 else {
            collectionView.setContentOffset(bottomRestOffset, animated: false)
            updateUnreadCountFromVisibility()
            updatePillVisibility()
            return
        }
        if distance < collectionView.bounds.height * 1.75 {
            animateRealScrollToBottom(duration: 0.45)
            return
        }
        collectionView.layoutIfNeeded()
        guard let oldSnapshot = collectionMotionView.snapshotView(afterScreenUpdates: false) else {
            animateRealScrollToBottom(duration: 0.4)
            return
        }
        let travel = max(1, collectionViewportView.bounds.height)
        oldSnapshot.frame = collectionViewportView.bounds
        oldSnapshot.isUserInteractionEnabled = false
        collectionViewportView.addSubview(oldSnapshot)
        jumpSnapshotView = oldSnapshot
        UIView.performWithoutAnimation {
            self.collectionView.setContentOffset(self.bottomRestOffset, animated: false)
            self.collectionView.layoutIfNeeded()
            self.collectionMotionView.transform = CGAffineTransform(translationX: 0, y: travel)
        }
        let animator = UIViewPropertyAnimator(duration: 0.4, curve: .easeOut) { [weak self, weak oldSnapshot] in
            self?.collectionMotionView.transform = .identity
            oldSnapshot?.transform = CGAffineTransform(translationX: 0, y: -travel)
        }
        scrollAnimator = animator
        animator.addCompletion { [weak self, weak animator, weak oldSnapshot] _ in
            oldSnapshot?.removeFromSuperview()
            guard let self, self.scrollAnimator === animator else { return }
            self.collectionMotionView.transform = .identity
            self.jumpSnapshotView = nil
            self.scrollAnimator = nil
            self.updateUnreadCountFromVisibility()
            self.updatePillVisibility()
        }
        animator.startAnimation()
    }

    func animateRealScrollToBottom(duration: TimeInterval) {
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut) { [weak self] in
            guard let self else { return }
            self.collectionView.setContentOffset(self.bottomRestOffset, animated: false)
        }
        scrollAnimator = animator
        animator.addCompletion { [weak self, weak animator] position in
            guard let self, self.scrollAnimator === animator else { return }
            self.scrollAnimator = nil
            guard position == .end else { return }
            self.collectionView.setContentOffset(self.bottomRestOffset, animated: false)
            self.updateUnreadCountFromVisibility()
            self.updatePillVisibility()
        }
        animator.startAnimation()
    }

    var keyboardIsDocked: Bool {
        let baseBottomSafeArea = view.window?.safeAreaInsets.bottom ?? 0
        let keyboardObstruction = view.bounds.maxY - view.keyboardLayoutGuide.layoutFrame.minY
        return keyboardObstruction > baseBottomSafeArea + 0.5
    }

    func updateKeyboardPinningForCurrentScrollPosition() {
        guard !isUpdatingKeyboardPinning else { return }
        let shouldPin = distanceFromBottom <= 0.5
        let preservesHistory = keyboardIsDocked
            && keyboardPinsTranscriptToLayoutGuide
            && !shouldPin
        setKeyboardPinsTranscriptToLayoutGuide(
            shouldPin,
            preservingVisualPosition: preservesHistory
        )
    }

    func setKeyboardPinsTranscriptToLayoutGuide(
        _ pinsToKeyboard: Bool,
        preservingVisualPosition: Bool
    ) {
        guard keyboardPinsTranscriptToLayoutGuide != pinsToKeyboard,
              !isUpdatingKeyboardPinning
        else {
            return
        }
        isUpdatingKeyboardPinning = true
        defer { isUpdatingKeyboardPinning = false }
        let screenCoordinateView = view.window ?? view
        let oldViewportOriginY = preservingVisualPosition
            ? collectionViewportView.convert(.zero, to: screenCoordinateView).y
            : 0
        UIView.performWithoutAnimation {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.keyboardPinsTranscriptToLayoutGuide = pinsToKeyboard
            self.collectionViewportBottomConstraint.isActive = false
            self.collectionViewportRootBottomConstraint.isActive = false
            if pinsToKeyboard {
                self.collectionViewportBottomConstraint.isActive = true
            } else {
                self.collectionViewportRootBottomConstraint.isActive = true
            }
            if preservingVisualPosition {
                self.view.layoutIfNeeded()
                let newViewportOriginY = self.collectionViewportView.convert(
                    .zero,
                    to: screenCoordinateView
                ).y
                let targetY = self.collectionView.contentOffset.y
                    + newViewportOriginY
                    - oldViewportOriginY
                let boundedY = min(
                    max(targetY, -self.collectionView.contentInset.top),
                    self.bottomRestOffset.y
                )
                self.collectionView.setContentOffset(
                    CGPoint(x: self.collectionView.contentOffset.x, y: boundedY),
                    animated: false
                )
            } else if pinsToKeyboard {
                self.view.layoutIfNeeded()
            } else {
                self.view.setNeedsLayout()
            }
            CATransaction.commit()
        }
    }
}
#endif
