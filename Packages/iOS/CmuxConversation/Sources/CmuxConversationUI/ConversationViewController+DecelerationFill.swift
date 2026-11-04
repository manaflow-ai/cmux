#if canImport(UIKit)
import CmuxConversationGeometry
import UIKit

/// Draws the frame UIKit skips when a fling starts (iOS 26; see
/// `ConversationDecelerationFill`): the transcript's rows are drawn where
/// that frame's step would have taken them until the offset catches up.
///
/// DEBUG lab only (`CMUX_UITEST_CONVERSATION_FILL=1`) until a device run
/// shows UIKit's skipped frame on the phone: drawing ahead is a guess, and
/// a wrong one (a finger catching the fling) flickered there.
///
/// It runs in the update cycle after the display links, where UIKit's
/// deceleration has (or has not) moved the offset for the frame. It stays
/// passive: asking for updates at the lift moves UIKit's deceleration start
/// itself (on iOS 27 that request alone made the frame after the lift
/// stall), and the skipped frame already gets an update of its own.
@MainActor
final class ConversationDecelerationFillDriver {
    private weak var collectionView: TranscriptCollectionView?
    private var link: AnyObject?
    private var fill = ConversationDecelerationFill()
    private var lastModelTime: Double?

    init(collectionView: TranscriptCollectionView) {
        self.collectionView = collectionView
    }

    func start() {
        guard link == nil, let collectionView, #available(iOS 18.0, *) else { return }
        let link = UIUpdateLink(view: collectionView)
        link.addAction(to: .afterCADisplayLinkDispatch) { [weak self] _, info in
            self?.update(modelTime: info.modelTime)
        }
        link.isEnabled = true
        self.link = link
    }

    /// The finger lifted into a fling.
    func flingBegan() {
        fill.expectSkippedFrame()
    }

    /// The offset moved by `delta` to keep the rows in place.
    func contentShifted(by delta: CGFloat) {
        guard delta != 0 else { return }
        fill.shift(by: delta)
    }

    private func update(modelTime: Double) {
        guard let collectionView else { return }
        let elapsed = lastModelTime.map { modelTime - $0 } ?? 0
        lastModelTime = modelTime
        // A first update after a pause starts over (no frame length).
        let duration = elapsed > 0 && elapsed < 0.05 ? elapsed : 0
        // Where the content can rest; UIKit bounces at either end.
        let inset = collectionView.adjustedContentInset
        let top = -inset.top
        let bottom = max(top, collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        collectionView.drawingLead = fill.update(
            offset: collectionView.contentOffset.y, duration: duration, decelerating: collectionView.isDecelerating,
            range: top...bottom
        )
    }
}
#endif
