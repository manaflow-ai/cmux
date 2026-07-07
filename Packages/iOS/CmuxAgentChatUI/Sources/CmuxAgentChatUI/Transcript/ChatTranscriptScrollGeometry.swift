#if os(iOS)
import UIKit

extension UITableView {
    var chatTranscriptVisibleBottomY: CGFloat {
        contentOffset.y + bounds.height - adjustedContentInset.bottom
    }

    var chatTranscriptDistanceFromBottom: CGFloat {
        max(0, contentSize.height - chatTranscriptVisibleBottomY)
    }

    var chatTranscriptMaxOffsetY: CGFloat {
        max(
            -adjustedContentInset.top,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )
    }

    func chatTranscriptClampedOffsetY(_ offsetY: CGFloat) -> CGFloat {
        min(max(offsetY, -adjustedContentInset.top), chatTranscriptMaxOffsetY)
    }
}

#endif
