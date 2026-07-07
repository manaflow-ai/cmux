import SwiftUI
#if os(iOS)
@preconcurrency import UIKit

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

/// Re-enables the interactive swipe-from-edge back gesture, which UIKit disables
/// whenever a custom leading bar button replaces the system back button.
struct InteractiveSwipeBackEnabler: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController { GestureHostController() }
    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    private final class GestureHostController: UIViewController, UIGestureRecognizerDelegate {
        private let policy = InteractiveSwipeBackGesturePolicy()

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            navigationController?.interactivePopGestureRecognizer?.delegate = self
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            policy.shouldBegin(navigationController: navigationController)
        }

        // The pushed workspace detail hosts terminal/browser scroll gestures.
        // Taking over the navigation controller's pop gesture delegate drops
        // UIKit's built-in coexistence rule, so restore simultaneous recognition.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            policy.shouldRecognizeSimultaneously(
                gestureRecognizer: gestureRecognizer,
                navigationController: navigationController
            )
        }
    }
}
#endif
