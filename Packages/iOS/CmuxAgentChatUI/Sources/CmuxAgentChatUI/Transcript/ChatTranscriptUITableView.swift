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
    var keyboardDebugTargetOverlap: CGFloat = 0
    var keyboardDebugGuideOverlap: CGFloat = 0
    var keyboardDebugBottomConstraint: CGFloat = 0
    var keyboardDebugComposerMinY: CGFloat = 0
    var keyboardDebugComposerPresentationMinY: CGFloat = 0
    var keyboardDebugPresentationFrameMaxY: CGFloat = 0
    var keyboardDebugPresentationFrameMaxYProvider: (() -> CGFloat?)?
    var keyboardDebugComposerPresentationMinYProvider: (() -> CGFloat?)?
    var keyboardDebugAnimationID = 0
    var keyboardDebugAnimationActive = false
    var keyboardDebugAnimationProgress: CGFloat = 1
    var keyboardDebugTransitionDuration: TimeInterval = 0
    #endif
    private var lastBoundsSize: CGSize = .zero
    private var lastContentSize: CGSize = .zero
    private var lastViewport: MobileScrollViewportSnapshot?
    private(set) var composerOverlayBottomInset: CGFloat = 0
    var isKeyboardViewportExternallyDriven = false
    #if DEBUG
    private var recordedKeyboardAnimationID = 0
    private var keyboardDebugMaxAnimationPresentationGap: CGFloat = 0
    private var keyboardDebugAnimationSampleCount = 0
    #endif

    #if DEBUG
    override var accessibilityValue: String? {
        get { debugAccessibilityValue() }
        set { super.accessibilityValue = newValue }
    }
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
        restoreKeyboardViewport(snapshot, boundsHeight: bounds.height)
    }

    func restoreKeyboardViewport(
        _ snapshot: MobileScrollViewportSnapshot,
        boundsHeight: CGFloat
    ) {
        let targetY = snapshot.restoredOffsetY(
            contentHeight: contentSize.height,
            boundsHeight: boundsHeight,
            adjustedTopInset: adjustedContentInset.top,
            adjustedBottomInset: adjustedContentInset.bottom
        )
        setContentOffset(CGPoint(x: contentOffset.x, y: targetY), animated: false)
        recordViewport()
        #if DEBUG
        updateDebugAccessibilityValue()
        #endif
    }

    func applyComposerOverlayBottomInset(_ bottomInset: CGFloat) {
        let resolvedInset = max(0, ceil(bottomInset))
        guard abs(composerOverlayBottomInset - resolvedInset) > 0.5
            || abs(contentInset.bottom - resolvedInset) > 0.5
        else {
            return
        }

        let snapshot = keyboardViewportSnapshot()
        composerOverlayBottomInset = resolvedInset
        isKeyboardViewportExternallyDriven = true
        contentInset.bottom = resolvedInset
        var indicatorInsets = verticalScrollIndicatorInsets
        indicatorInsets.bottom = resolvedInset
        verticalScrollIndicatorInsets = indicatorInsets
        restoreKeyboardViewport(snapshot)
        isKeyboardViewportExternallyDriven = false
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
        super.accessibilityValue = debugAccessibilityValue()
    }

    private func debugAccessibilityValue() -> String {
        let frameInWindow = window.map { convert(bounds, to: $0) } ?? frame
        let presentationFrameMaxY: CGFloat
        if let providedFrameMaxY = keyboardDebugPresentationFrameMaxYProvider?() {
            presentationFrameMaxY = providedFrameMaxY
        } else if keyboardDebugPresentationFrameMaxY != 0 {
            presentationFrameMaxY = keyboardDebugPresentationFrameMaxY
        } else {
            presentationFrameMaxY = (presentationFrameInWindow() ?? frameInWindow).maxY
        }
        let composerPresentationMinY = keyboardDebugComposerPresentationMinYProvider?()
            ?? keyboardDebugComposerPresentationMinY
        let visibleBottomY = contentOffset.y + bounds.height - adjustedContentInset.bottom
        let distanceFromBottom = max(0, contentSize.height - visibleBottomY)
        let presentationGap = composerPresentationMinY - presentationFrameMaxY
        let topEdgeEffectSoft: Int
        let bottomEdgeEffectSoft: Int
        if #available(iOS 26.0, *) {
            topEdgeEffectSoft = topEdgeEffect.style === UIScrollEdgeEffect.Style.soft ? 1 : 0
            bottomEdgeEffectSoft = bottomEdgeEffect.style === UIScrollEdgeEffect.Style.soft ? 1 : 0
        } else {
            topEdgeEffectSoft = 0
            bottomEdgeEffectSoft = 0
        }
        recordKeyboardAnimationGap(presentationGap)
        return String(
            format: "frameMinY=%.2f;frameMaxY=%.2f;frameHeight=%.2f;presentationFrameMaxY=%.2f;boundsHeight=%.2f;offsetY=%.2f;visibleBottomY=%.2f;contentHeight=%.2f;distanceFromBottom=%.2f;keyboardEvents=%d;keyboardOverlap=%.2f;keyboardTargetOverlap=%.2f;keyboardGuideOverlap=%.2f;keyboardBottomConstraint=%.2f;composerMinY=%.2f;composerPresentationMinY=%.2f;presentationGap=%.2f;composerOverlayBottomInset=%.2f;keyboardAnimationActive=%d;keyboardAnimationProgress=%.2f;keyboardTransitionDuration=%.3f;maxAnimationPresentationGap=%.2f;keyboardAnimationSamples=%d;topEdgeEffectSoft=%d;bottomEdgeEffectSoft=%d",
            locale: Locale(identifier: "en_US_POSIX"),
            frameInWindow.minY,
            frameInWindow.maxY,
            frameInWindow.height,
            presentationFrameMaxY,
            bounds.height,
            contentOffset.y,
            visibleBottomY,
            contentSize.height,
            distanceFromBottom,
            keyboardDebugEventCount,
            keyboardDebugOverlap,
            keyboardDebugTargetOverlap,
            keyboardDebugGuideOverlap,
            keyboardDebugBottomConstraint,
            keyboardDebugComposerMinY,
            composerPresentationMinY,
            presentationGap,
            composerOverlayBottomInset,
            keyboardDebugAnimationActive ? 1 : 0,
            keyboardDebugAnimationProgress,
            keyboardDebugTransitionDuration,
            keyboardDebugMaxAnimationPresentationGap,
            keyboardDebugAnimationSampleCount,
            topEdgeEffectSoft,
            bottomEdgeEffectSoft
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
        guard let window
        else { return nil }
        let sourceLayer = layer.presentation() ?? layer
        let targetLayer = window.layer.presentation() ?? window.layer
        return sourceLayer.convert(bounds, to: targetLayer)
    }
    #endif
}
#endif
