#if os(iOS)
import UIKit

/// Bridges the workspace navigation controller's pop gesture delegate to policy.
final class InteractiveSwipeBackGestureHostController: UIViewController, UIGestureRecognizerDelegate {
    private let policy = InteractiveSwipeBackGesturePolicy()
    private weak var installedGestureRecognizer: UIGestureRecognizer?
    private weak var previousGestureDelegate: UIGestureRecognizerDelegate?

    override func willMove(toParent parent: UIViewController?) {
        if parent == nil {
            restoreGestureDelegate()
        }
        super.willMove(toParent: parent)
    }

    override func didMove(toParent parent: UIViewController?) {
        super.didMove(toParent: parent)
        guard parent != nil,
              let gestureRecognizer = navigationController?.interactivePopGestureRecognizer
        else { return }
        if gestureRecognizer.delegate !== self {
            previousGestureDelegate = gestureRecognizer.delegate
            installedGestureRecognizer = gestureRecognizer
            gestureRecognizer.delegate = self
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if navigationController == nil {
            restoreGestureDelegate()
        }
    }

    private func restoreGestureDelegate() {
        guard let installedGestureRecognizer else { return }
        if installedGestureRecognizer.delegate === self {
            installedGestureRecognizer.delegate = previousGestureDelegate
        }
        self.installedGestureRecognizer = nil
        previousGestureDelegate = nil
    }

    func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if previousGestureDelegate?.gestureRecognizerShouldBegin?(gestureRecognizer) == false {
            return false
        }
        return policy.shouldBegin(
            navigationController: navigationController,
            isTransitionInProgress: navigationController?.transitionCoordinator != nil
        )
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
