#if os(iOS)
import CmuxMobileSupport
import Foundation
import UIKit

final class ChatTranscriptUITableView: UITableView {
    var afterLayout: ((
        _ oldBoundsSize: CGSize,
        _ oldContentSize: CGSize,
        _ oldViewport: MobileScrollViewportSnapshot?,
        _ oldAnchor: ChatTranscriptTableAnchor?
    ) -> Void)?
    var anchorBeforeLayout: (() -> ChatTranscriptTableAnchor?)?
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
    private(set) var topChromeOverlayInset: CGFloat = 0
    private(set) var composerOverlayBottomInset: CGFloat = 0
    var isViewportInsetsExternallyDriven = false
    #if DEBUG
    private var recordedKeyboardAnimationID = 0
    private var keyboardDebugMaxAnimationPresentationGap: CGFloat = 0
    private var keyboardDebugAnimationSampleCount = 0
    private var debugTopEdgeEffectSoft = false
    private var debugBottomEdgeEffectSoft = false
    private var debugTopContentScrollViewRegistered = false
    private var debugBottomEdgeElementContainerRegistered = false
    #endif

    #if DEBUG
    override var accessibilityValue: String? {
        get { debugAccessibilityValue() }
        set { super.accessibilityValue = newValue }
    }
    #endif

    override var contentOffset: CGPoint {
        didSet { recordViewport() }
    }

    override func layoutSubviews() {
        let oldBoundsSize = lastBoundsSize
        let oldContentSize = lastContentSize
        let oldViewport = lastViewport
        let oldAnchor = anchorBeforeLayout?()
        super.layoutSubviews()
        lastBoundsSize = bounds.size
        lastContentSize = contentSize
        recordViewport()
        #if DEBUG
        updateDebugAccessibilityValue()
        #endif
        afterLayout?(oldBoundsSize, oldContentSize, oldViewport, oldAnchor)
    }

    func applyScrollEdgeEffects(topSoft: Bool, bottomSoft: Bool) {
        #if DEBUG
        debugTopEdgeEffectSoft = false
        debugBottomEdgeEffectSoft = false
        #endif
        if #available(iOS 26.0, *) {
            topEdgeEffect.style = topSoft ? .soft : .automatic
            bottomEdgeEffect.style = bottomSoft ? .soft : .automatic
            #if DEBUG
            debugTopEdgeEffectSoft = topSoft
            debugBottomEdgeEffectSoft = bottomSoft
            updateDebugAccessibilityValue()
            #endif
        }
    }

    #if DEBUG
    func recordTopContentScrollViewRegistration(_ isRegistered: Bool) {
        debugTopContentScrollViewRegistered = isRegistered
        updateDebugAccessibilityValue()
    }

    func recordBottomEdgeElementContainerRegistration(_ isRegistered: Bool) {
        debugBottomEdgeElementContainerRegistered = isRegistered
        updateDebugAccessibilityValue()
    }
    #endif

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

    func recordCurrentViewport() {
        recordViewport()
        #if DEBUG
        updateDebugAccessibilityValue()
        #endif
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
        recordCurrentViewport()
    }

    func applyTranscriptViewportInsets(
        topChromeInset: CGFloat,
        adjustedBottomInset: CGFloat,
        composerOverlayBottomInset: CGFloat
    ) {
        let resolvedTopInset = max(0, ceil(topChromeInset))
        let resolvedAdjustedBottomInset = max(0, ceil(adjustedBottomInset))
        // Target the final adjusted inset. UIKit may or may not add a bottom
        // safe-area contribution for this hosted table, so subtract the actual
        // current contribution instead of branching by OS version.
        let automaticBottomAdjustment = max(0, adjustedContentInset.bottom - contentInset.bottom)
        let resolvedContentBottomInset = max(0, resolvedAdjustedBottomInset - automaticBottomAdjustment)
        let resolvedOverlayBottomInset = max(0, ceil(composerOverlayBottomInset))
        let oldTopInset = adjustedContentInset.top
        let oldVisibleTopY = contentOffset.y + oldTopInset
        let topChanged = abs(topChromeOverlayInset - resolvedTopInset) > 0.5
            || abs(contentInset.top - resolvedTopInset) > 0.5
        let bottomChanged = abs(adjustedContentInset.bottom - resolvedAdjustedBottomInset) > 0.5
            || abs(contentInset.bottom - resolvedContentBottomInset) > 0.5
        let overlayChanged = abs(self.composerOverlayBottomInset - resolvedOverlayBottomInset) > 0.5
        guard topChanged || bottomChanged || overlayChanged
        else {
            return
        }

        let snapshot = keyboardViewportSnapshot()
        let wasPinnedToTop = contentOffset.y <= -oldTopInset + 1
        topChromeOverlayInset = resolvedTopInset
        self.composerOverlayBottomInset = resolvedOverlayBottomInset
        isViewportInsetsExternallyDriven = true
        contentInset.top = resolvedTopInset
        contentInset.bottom = resolvedContentBottomInset
        var indicatorInsets = verticalScrollIndicatorInsets
        indicatorInsets.top = resolvedTopInset
        indicatorInsets.bottom = resolvedOverlayBottomInset
        verticalScrollIndicatorInsets = indicatorInsets
        if wasPinnedToTop {
            // Keep the transcript pinned to the top chrome reservation — the
            // symmetric counterpart to `wasAtBottom`. Without this, a
            // composer/bottom-inset change takes the `bottomChanged` branch and
            // `restoreKeyboardViewport` preserves the old visible bottom, which
            // drifts the first row back under the toolbar.
            setClampedContentOffsetY(-adjustedContentInset.top)
        } else if snapshot.wasAtBottom || bottomChanged {
            restoreKeyboardViewport(snapshot)
        } else if topChanged {
            setClampedContentOffsetY(oldVisibleTopY - adjustedContentInset.top)
        } else {
            clampCurrentOffset()
        }
        isViewportInsetsExternallyDriven = false
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

    private func clampCurrentOffset() {
        let maxOffsetY = max(
            -adjustedContentInset.top,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )
        let targetY = min(max(contentOffset.y, -adjustedContentInset.top), maxOffsetY)
        setClampedContentOffsetY(targetY)
    }

    private func setClampedContentOffsetY(_ offsetY: CGFloat) {
        let maxOffsetY = max(
            -adjustedContentInset.top,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )
        let targetY = min(max(offsetY, -adjustedContentInset.top), maxOffsetY)
        if abs(contentOffset.y - targetY) > 0.5 {
            setContentOffset(CGPoint(x: contentOffset.x, y: targetY), animated: false)
        }
        recordViewport()
        #if DEBUG
        updateDebugAccessibilityValue()
        #endif
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
        let visibleTopY = contentOffset.y + adjustedContentInset.top
        let visibleBottomY = contentOffset.y + bounds.height - adjustedContentInset.bottom
        let distanceFromBottom = max(0, contentSize.height - visibleBottomY)
        let presentationGap = composerPresentationMinY - presentationFrameMaxY
        recordKeyboardAnimationGap(presentationGap)
        return String(
            format: "frameMinY=%.2f;frameMaxY=%.2f;frameHeight=%.2f;presentationFrameMaxY=%.2f;boundsHeight=%.2f;offsetY=%.2f;adjustedTopInset=%.2f;adjustedBottomInset=%.2f;visibleTopY=%.2f;visibleBottomY=%.2f;contentHeight=%.2f;distanceFromBottom=%.2f;keyboardEvents=%d;keyboardOverlap=%.2f;keyboardTargetOverlap=%.2f;keyboardGuideOverlap=%.2f;keyboardBottomConstraint=%.2f;composerMinY=%.2f;composerPresentationMinY=%.2f;presentationGap=%.2f;topChromeOverlayInset=%.2f;composerOverlayBottomInset=%.2f;keyboardAnimationActive=%d;keyboardAnimationProgress=%.2f;keyboardTransitionDuration=%.3f;maxAnimationPresentationGap=%.2f;keyboardAnimationSamples=%d;topEdgeEffectSoft=%d;bottomEdgeEffectSoft=%d;topContentScrollViewRegistered=%d;bottomEdgeElementContainerRegistered=%d",
            locale: Locale(identifier: "en_US_POSIX"),
            frameInWindow.minY,
            frameInWindow.maxY,
            frameInWindow.height,
            presentationFrameMaxY,
            bounds.height,
            contentOffset.y,
            adjustedContentInset.top,
            adjustedContentInset.bottom,
            visibleTopY,
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
            topChromeOverlayInset,
            composerOverlayBottomInset,
            keyboardDebugAnimationActive ? 1 : 0,
            keyboardDebugAnimationProgress,
            keyboardDebugTransitionDuration,
            keyboardDebugMaxAnimationPresentationGap,
            keyboardDebugAnimationSampleCount,
            debugTopEdgeEffectSoft ? 1 : 0,
            debugBottomEdgeEffectSoft ? 1 : 0,
            debugTopContentScrollViewRegistered ? 1 : 0,
            debugBottomEdgeElementContainerRegistered ? 1 : 0
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

struct ChatTranscriptTableAnchor {
    let id: String
    let offsetFromRowTop: CGFloat
}

#endif
