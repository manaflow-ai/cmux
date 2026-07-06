#if os(iOS)
import UIKit

extension ChatTranscriptTableView.Coordinator {
    func userVisibleFinalGlideDistance(in tableView: UITableView) -> CGFloat {
        max(600, min(1_200, tableView.bounds.height * 1.25))
    }

    func cancelUserScrollMomentumIfNeeded(in tableView: UITableView) {
        guard tableView.isTracking || tableView.isDragging || tableView.isDecelerating else { return }
        tableView.setContentOffset(tableView.contentOffset, animated: false)
    }

    func distanceFromBottom(in tableView: UITableView) -> CGFloat {
        guard tableView.bounds.height > 0 else { return 0 }
        let visibleBottom = visibleBottomY(in: tableView)
        return max(0, tableView.contentSize.height - visibleBottom)
    }

    func visibleBottomY(in tableView: UITableView) -> CGFloat {
        tableView.contentOffset.y
            + tableView.bounds.height
            - tableView.adjustedContentInset.bottom
    }

    func maxOffsetY(in tableView: UITableView) -> CGFloat {
        max(
            -tableView.adjustedContentInset.top,
            tableView.contentSize.height
                - tableView.bounds.height
                + tableView.adjustedContentInset.bottom
        )
    }

    func clampedOffsetY(_ offsetY: CGFloat, in tableView: UITableView) -> CGFloat {
        min(max(offsetY, -tableView.adjustedContentInset.top), maxOffsetY(in: tableView))
    }
}

#endif
