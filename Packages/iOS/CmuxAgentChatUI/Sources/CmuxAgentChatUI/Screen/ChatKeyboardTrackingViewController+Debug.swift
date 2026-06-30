#if os(iOS) && DEBUG
import SwiftUI
import UIKit

extension ChatKeyboardTrackingViewController {
    func updateKeyboardDebugValues(overlap: CGFloat) {
        let visibleOverlap = currentVisibleKeyboardOverlap()
        let guideOverlap = keyboardLayoutGuideOverlap()
        let composerFrame = frameInWindow(for: composerHostingController.view)
        let composerPresentationFrame = presentationAdjustedFrameInWindow(for: composerHostingController.view)
            ?? composerFrame
        let animationProgress = clampedKeyboardAnimationProgress(overlap: overlap)
        for tableView in trackedTranscriptTables(in: transcriptHostingController.view) {
            let tableFrame = frameInWindow(for: tableView)
            tableView.keyboardDebugPresentationFrameMaxYProvider = { [weak self, weak tableView] in
                guard let self,
                      tableView != nil
                else { return nil }
                return self.presentationAdjustedFrameInWindow(for: self.transcriptClipView)?.maxY
            }
            tableView.keyboardDebugComposerPresentationMinYProvider = { [weak self] in
                guard let self else { return nil }
                return self.presentationAdjustedFrameInWindow(for: self.composerHostingController.view)?.minY
            }
            tableView.keyboardDebugEventCount = keyboardDebugEventCount
            tableView.keyboardDebugOverlap = visibleOverlap
            tableView.keyboardDebugTargetOverlap = overlap
            tableView.keyboardDebugGuideOverlap = guideOverlap
            tableView.keyboardDebugBottomConstraint = -overlap
            tableView.keyboardDebugComposerMinY = composerFrame?.minY ?? 0
            tableView.keyboardDebugComposerPresentationMinY = composerPresentationFrame?.minY ?? 0
            tableView.keyboardDebugPresentationFrameMaxY = tableFrame?.maxY ?? 0
            tableView.keyboardDebugAnimationID = keyboardTransitionID
            tableView.keyboardDebugAnimationActive = isKeyboardAnimationActive
            tableView.keyboardDebugAnimationProgress = animationProgress
            tableView.keyboardDebugTransitionDuration = keyboardDebugTransitionDuration
            tableView.updateDebugAccessibilityValue()
        }
    }

    private func clampedKeyboardAnimationProgress(overlap: CGFloat) -> CGFloat {
        guard keyboardDebugTransitionDuration > 0, isKeyboardAnimationActive else {
            return currentVisibleKeyboardOverlap() > 0 ? 1 : 0
        }
        let delta = keyboardAnimationTargetOverlap - keyboardAnimationStartOverlap
        guard abs(delta) > 0.5 else { return 1 }
        return min(max((currentVisibleKeyboardOverlap() - keyboardAnimationStartOverlap) / delta, 0), 1)
    }

    private func keyboardLayoutGuideOverlap() -> CGFloat {
        let guideFrame = view.keyboardLayoutGuide.layoutFrame
        guard !guideFrame.isNull, !guideFrame.isEmpty else { return 0 }
        return max(0, view.bounds.maxY - guideFrame.minY)
    }

    private func frameInWindow(for targetView: UIView) -> CGRect? {
        guard let window = targetView.window else { return nil }
        return targetView.convert(targetView.bounds, to: window)
    }

    private func presentationAdjustedFrameInWindow(for targetView: UIView?) -> CGRect? {
        guard let targetView,
              let window = targetView.window
        else {
            return targetView.flatMap { frameInWindow(for: $0) }
        }
        let sourceLayer = targetView.layer.presentation() ?? targetView.layer
        let targetLayer = window.layer.presentation() ?? window.layer
        return sourceLayer.convert(targetView.bounds, to: targetLayer)
    }
}
#endif
