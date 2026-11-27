#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// Swipe right on a bubble to reply, as `CKBalloonSwipeController` does it:
/// the bubble follows the finger 1:1 to 40 pt and logarithmically past it,
/// uncovering the arrow parked behind it; crossing 40 pt while moving right
/// commits (pulse plus a soft haptic), dragging back under it while moving
/// left un-commits (haptic only). On release the arrow fades over 0.4 s and
/// the bubble eases home over 0.25 s; a committed swipe opens the reply and
/// its arrow vanishes with the row on the next frame, as Messages does.
extension ConversationViewController {
    /// The bubble cell a reply swipe at `point` would drag, if any.
    func replySwipeCell(at point: CGPoint, velocity: CGPoint) -> MessageCell? {
        guard ConversationReplyMotion.isSwipeAngle(velocity: velocity),
              let indexPath = collectionView.indexPathForItem(at: point),
              let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
              let model = cell.model, model.message.seq != nil,
              let balloon = cell.cellLayout.map({ $0.bubbleFrame ?? $0.linkCardFrame ?? $0.imageFrames.first ?? $0.contentFrame }) else { return nil }
        let area = ConversationReplyMotion.swipeArea(bubble: balloon, isOutgoing: model.isOutgoing)
        return area.contains(cell.convert(point, from: collectionView)) ? cell : nil
    }

    func updateReplySwipe(rowID: String, translation: CGFloat, velocity: CGFloat) {
        let offset = ConversationReplyMotion.bubbleOffset(forTranslation: translation)
        replyDragOffset = offset
        guard let indexPath = indexPath(for: rowID), let cell = collectionView.cellForItem(at: indexPath) as? MessageCell,
              let model = cell.model else { return }
        cell.replyDrag = offset
        let threshold = ConversationReplyMotion.confirmThreshold
        if !replyHapticFired {
            cell.replyIndicator.update(progress: ConversationReplyMotion.indicatorProgress(forOffset: offset), isOutgoing: model.isOutgoing)
        }
        if offset > threshold, velocity > 0, !replyHapticFired {
            replyHapticFired = true
            cell.replyIndicator.pulse(isOutgoing: model.isOutgoing) {
                UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            }
        } else if replyHapticFired, offset < threshold, velocity < 0 {
            UIImpactFeedbackGenerator(style: .soft).impactOccurred()
            replyHapticFired = false
        }
    }

    func endReplySwipe(rowID: String, ended: Bool) {
        let commit = replyHapticFired && ended
        let releasedAt = replyDragOffset
        let cell = indexPath(for: rowID).flatMap { collectionView.cellForItem(at: $0) as? MessageCell }
        if commit {
            cell?.replyIndicator.reset()
        } else {
            cell?.replyIndicator.settle()
        }
        replyDragRowID = nil
        replyDragOffset = 0
        replyHapticFired = false
        if commit, case let .message(model)? = row(for: rowID) {
            enterReplyMode(for: model.message, dragOffset: releasedAt)
        }
        UIView.animate(withDuration: ConversationReplyMotion.bubbleResetDuration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction]) {
            cell?.replyDrag = 0
        }
    }
}
#endif
