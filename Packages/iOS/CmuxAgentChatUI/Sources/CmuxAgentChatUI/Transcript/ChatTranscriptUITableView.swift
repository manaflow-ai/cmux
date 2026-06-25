#if os(iOS)
import CmuxMobileSupport
import Foundation
import UIKit

final class ChatTranscriptUITableView: UITableView {
    var afterLayout: ((
        _ oldBoundsSize: CGSize,
        _ oldContentSize: CGSize,
        _ oldViewport: MobileScrollViewportSnapshot?
    ) -> Void)?
    #if DEBUG
    var keyboardDebugEventCount = 0
    var keyboardDebugOverlap: CGFloat = 0
    var keyboardDebugGuideOverlap: CGFloat = 0
    var keyboardDebugBottomConstraint: CGFloat = 0
    var keyboardDebugComposerMinY: CGFloat = 0
    var keyboardDebugComposerPresentationMinY: CGFloat = 0
    var keyboardDebugAnimationID = 0
    var keyboardDebugAnimationActive = false
    var keyboardDebugAnimationProgress: CGFloat = 1
    var keyboardDebugTransitionDuration: TimeInterval = 0
    #endif
    private var lastBoundsSize: CGSize = .zero
    private var lastContentSize: CGSize = .zero
    private var lastViewport: MobileScrollViewportSnapshot?
    #if DEBUG
    private var recordedKeyboardAnimationID = 0
    private var keyboardDebugMaxAnimationPresentationGap: CGFloat = 0
    private var keyboardDebugAnimationSampleCount = 0
    #endif

    override func layoutSubviews() {
        let oldBoundsSize = lastBoundsSize
        let oldContentSize = lastContentSize
        let oldViewport = lastViewport
        super.layoutSubviews()
        lastBoundsSize = bounds.size
        lastContentSize = contentSize
        recordViewport()
        #if DEBUG
        updateDebugAccessibilityValue()
        #endif
        afterLayout?(oldBoundsSize, oldContentSize, oldViewport)
    }

    func keyboardViewportSnapshot() -> MobileScrollViewportSnapshot {
        MobileScrollViewportSnapshot(
            contentOffsetY: contentOffset.y,
            boundsHeight: bounds.height,
            adjustedBottomInset: adjustedContentInset.bottom,
            contentHeight: contentSize.height,
            atBottomThreshold: chatTranscriptAtBottomThreshold
        )
    }

    func restoreKeyboardViewport(_ snapshot: MobileScrollViewportSnapshot) {
        let targetY = snapshot.restoredOffsetY(
            contentHeight: contentSize.height,
            boundsHeight: bounds.height,
            adjustedTopInset: adjustedContentInset.top,
            adjustedBottomInset: adjustedContentInset.bottom
        )
        setContentOffset(CGPoint(x: contentOffset.x, y: targetY), animated: false)
        recordViewport()
        #if DEBUG
        updateDebugAccessibilityValue()
        #endif
    }

    private func recordViewport() {
        lastViewport = MobileScrollViewportSnapshot(
            contentOffsetY: contentOffset.y,
            boundsHeight: bounds.height,
            adjustedBottomInset: adjustedContentInset.bottom,
            contentHeight: contentSize.height,
            atBottomThreshold: chatTranscriptAtBottomThreshold
        )
    }

    #if DEBUG
    func updateDebugAccessibilityValue() {
        let frameInWindow = window.map { convert(bounds, to: $0) } ?? frame
        let presentationFrameInWindow = presentationFrameInWindow() ?? frameInWindow
        let visibleBottomY = contentOffset.y + bounds.height - adjustedContentInset.bottom
        let distanceFromBottom = max(0, contentSize.height - visibleBottomY)
        let presentationGap = keyboardDebugComposerPresentationMinY - presentationFrameInWindow.maxY
        recordKeyboardAnimationGap(presentationGap)
        accessibilityValue = String(
            format: "frameMinY=%.2f;frameMaxY=%.2f;frameHeight=%.2f;presentationFrameMaxY=%.2f;boundsHeight=%.2f;offsetY=%.2f;visibleBottomY=%.2f;contentHeight=%.2f;distanceFromBottom=%.2f;keyboardEvents=%d;keyboardOverlap=%.2f;keyboardGuideOverlap=%.2f;keyboardBottomConstraint=%.2f;composerMinY=%.2f;composerPresentationMinY=%.2f;presentationGap=%.2f;keyboardAnimationActive=%d;keyboardAnimationProgress=%.2f;keyboardTransitionDuration=%.3f;maxAnimationPresentationGap=%.2f;keyboardAnimationSamples=%d",
            locale: Locale(identifier: "en_US_POSIX"),
            frameInWindow.minY,
            frameInWindow.maxY,
            frameInWindow.height,
            presentationFrameInWindow.maxY,
            bounds.height,
            contentOffset.y,
            visibleBottomY,
            contentSize.height,
            distanceFromBottom,
            keyboardDebugEventCount,
            keyboardDebugOverlap,
            keyboardDebugGuideOverlap,
            keyboardDebugBottomConstraint,
            keyboardDebugComposerMinY,
            keyboardDebugComposerPresentationMinY,
            presentationGap,
            keyboardDebugAnimationActive ? 1 : 0,
            keyboardDebugAnimationProgress,
            keyboardDebugTransitionDuration,
            keyboardDebugMaxAnimationPresentationGap,
            keyboardDebugAnimationSampleCount
        )
    }

    private func recordKeyboardAnimationGap(_ presentationGap: CGFloat) {
        if recordedKeyboardAnimationID != keyboardDebugAnimationID {
            recordedKeyboardAnimationID = keyboardDebugAnimationID
            keyboardDebugMaxAnimationPresentationGap = 0
            keyboardDebugAnimationSampleCount = 0
        }
        guard keyboardDebugAnimationActive else { return }
        keyboardDebugAnimationSampleCount += 1
        keyboardDebugMaxAnimationPresentationGap = max(
            keyboardDebugMaxAnimationPresentationGap,
            max(0, presentationGap)
        )
    }

    private func presentationFrameInWindow() -> CGRect? {
        guard let window,
              let superview,
              let presentationLayer = layer.presentation()
        else { return nil }
        return superview.layer.convert(presentationLayer.frame, to: window.layer)
    }
    #endif
}
#endif
