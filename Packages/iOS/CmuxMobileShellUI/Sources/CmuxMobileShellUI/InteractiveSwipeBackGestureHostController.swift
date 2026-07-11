#if os(iOS)
import UIKit

/// Bridges the workspace navigation controller's pop gesture delegate to policy.
final class InteractiveSwipeBackGestureHostController: UIViewController, UIGestureRecognizerDelegate {
    private let policy = InteractiveSwipeBackGesturePolicy()

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        navigationController?.interactivePopGestureRecognizer?.delegate = self
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        policy.shouldBegin(navigationController: navigationController)
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
        // Terminal and browser surfaces have their own scroll recognizers, so
        // restore UIKit's simultaneous edge-pop recognition after replacing
        // the system back button.
        policy.shouldRecognizeSimultaneously(
            gestureRecognizer: gestureRecognizer,
            navigationController: navigationController
        )
    }
}
#endif
