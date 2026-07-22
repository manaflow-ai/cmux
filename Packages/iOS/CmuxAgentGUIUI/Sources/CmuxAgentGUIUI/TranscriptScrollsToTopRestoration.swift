#if os(iOS)
import UIKit

/// Weakly records one scroll view's status-bar routing state for live-mode restoration.
@MainActor final class TranscriptScrollsToTopRestoration {
    weak var scrollView: UIScrollView?
    let originalValue: Bool

    init(scrollView: UIScrollView, originalValue: Bool) {
        self.scrollView = scrollView
        self.originalValue = originalValue
    }
}
#endif
