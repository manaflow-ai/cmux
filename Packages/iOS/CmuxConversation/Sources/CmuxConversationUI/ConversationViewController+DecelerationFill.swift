#if canImport(UIKit)
import CmuxConversationGeometry
import UIKit

/// Draws the frame UIKit skips when a fling starts (iOS 26; see
/// `ConversationDecelerationFill`): the transcript's rows are drawn where
/// that frame's step would have taken them until the offset catches up.
///
/// It runs in the update cycle after the display links, where UIKit's
/// deceleration has (or has not) moved the offset for the frame, and stays
/// passive except for the first frames of a fling, which it keeps coming so
/// the skipped one is still drawn.
@MainActor
final class ConversationDecelerationFillDriver {
    private weak var collectionView: TranscriptCollectionView?
    private var link: AnyObject?
    private var fill = ConversationDecelerationFill()
    private var lastModelTime: Double?
    /// Updates still requested after a lift.
    private var heldUpdates = 0

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
        guard #available(iOS 18.0, *), let link = link as? UIUpdateLink else { return }
        heldUpdates = 3
        link.requiresContinuousUpdates = true
    }

    private func update(modelTime: Double) {
        guard let collectionView else { return }
        let elapsed = lastModelTime.map { modelTime - $0 } ?? 0
        lastModelTime = modelTime
        // A first update after a pause starts over (no frame length).
        let duration = elapsed > 0 && elapsed < 0.05 ? elapsed : 0
        collectionView.drawingLead = fill.update(
            offset: collectionView.contentOffset.y, duration: duration, decelerating: collectionView.isDecelerating
        )
        guard heldUpdates > 0 else { return }
        heldUpdates -= 1
        if heldUpdates == 0, #available(iOS 18.0, *), let link = link as? UIUpdateLink {
            link.requiresContinuousUpdates = false
        }
    }
}
#endif
