#if os(iOS)
import UIKit

/// Decides when the custom workspace back gesture may begin or coexist.
@MainActor
struct InteractiveSwipeBackGesturePolicy {
    func shouldBegin(navigationController: UINavigationController?) -> Bool {
        (navigationController?.viewControllers.count ?? 0) > 1
    }

    func shouldRecognizeSimultaneously(
        gestureRecognizer: UIGestureRecognizer,
        navigationController: UINavigationController?
    ) -> Bool {
        gestureRecognizer == navigationController?.interactivePopGestureRecognizer
    }
}
#endif
