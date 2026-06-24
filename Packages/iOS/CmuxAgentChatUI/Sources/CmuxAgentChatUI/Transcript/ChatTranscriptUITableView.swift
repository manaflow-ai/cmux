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
    private var lastBoundsSize: CGSize = .zero
    private var lastContentSize: CGSize = .zero
    private var lastViewport: MobileScrollViewportSnapshot?

    override func layoutSubviews() {
        let oldBoundsSize = lastBoundsSize
        let oldContentSize = lastContentSize
        let oldViewport = lastViewport
        super.layoutSubviews()
        lastBoundsSize = bounds.size
        lastContentSize = contentSize
        lastViewport = MobileScrollViewportSnapshot(
            contentOffsetY: contentOffset.y,
            boundsHeight: bounds.height,
            adjustedBottomInset: adjustedContentInset.bottom,
            contentHeight: contentSize.height,
            atBottomThreshold: chatTranscriptAtBottomThreshold
        )
        #if DEBUG
        updateDebugAccessibilityValue()
        #endif
        afterLayout?(oldBoundsSize, oldContentSize, oldViewport)
    }

    #if DEBUG
    func updateDebugAccessibilityValue() {
        let frameInWindow = window.map { convert(bounds, to: $0) } ?? frame
        let visibleBottomY = contentOffset.y + bounds.height - adjustedContentInset.bottom
        let distanceFromBottom = max(0, contentSize.height - visibleBottomY)
        accessibilityValue = String(
            format: "frameMinY=%.2f;frameMaxY=%.2f;frameHeight=%.2f;boundsHeight=%.2f;offsetY=%.2f;visibleBottomY=%.2f;contentHeight=%.2f;distanceFromBottom=%.2f",
            locale: Locale(identifier: "en_US_POSIX"),
            frameInWindow.minY,
            frameInWindow.maxY,
            frameInWindow.height,
            bounds.height,
            contentOffset.y,
            visibleBottomY,
            contentSize.height,
            distanceFromBottom
        )
    }
    #endif
}
#endif
