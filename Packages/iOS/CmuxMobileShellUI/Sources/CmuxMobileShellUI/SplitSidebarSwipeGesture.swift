#if os(iOS)
import CmuxMobileWorkspace
import SwiftUI
import UIKit

/// Opens and closes the phone split sidebar with a horizontal swipe: right
/// from the leading screen edge to show it, left across its divider to hide
/// it. The recognizer lives on the window and only receives touches that
/// start in those strips, so the list, its row actions and the terminal keep
/// every other touch.
struct SplitSidebarSwipeGesture: UIViewRepresentable {
    let sidebarShown: Bool
    let sidebarWidth: CGFloat
    let setSidebarShown: (Bool) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> InstallerView {
        let view = InstallerView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: InstallerView, context: Context) {
        context.coordinator.sidebarShown = sidebarShown
        context.coordinator.sidebarWidth = sidebarWidth
        context.coordinator.setSidebarShown = setSidebarShown
    }

    static func dismantleUIView(_ view: InstallerView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class InstallerView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            coordinator?.install(on: window)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var sidebarShown = false
        var sidebarWidth: CGFloat = 0
        var setSidebarShown: (Bool) -> Void = { _ in }
        private var candidate: MobileWorkspaceShellLayoutPolicy.SplitSidebarSwipe?
        private lazy var recognizer: UIPanGestureRecognizer = {
            let recognizer = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            recognizer.delegate = self
            recognizer.maximumNumberOfTouches = 1
            return recognizer
        }()

        func install(on window: UIWindow?) {
            guard recognizer.view !== window else { return }
            recognizer.view?.removeGestureRecognizer(recognizer)
            window?.addGestureRecognizer(recognizer)
        }

        func uninstall() {
            recognizer.view?.removeGestureRecognizer(recognizer)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            candidate = MobileWorkspaceShellLayoutPolicy.splitSidebarSwipeCandidate(
                sidebarShown: sidebarShown,
                startX: touch.location(in: gestureRecognizer.view).x,
                sidebarWidth: sidebarWidth
            )
            return candidate != nil
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let candidate, let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            guard abs(velocity.x) > abs(velocity.y) else { return false }
            switch candidate {
            case .show: return velocity.x > 0
            case .hide: return velocity.x < 0
            }
        }

        // A touch that starts in a swipe strip belongs to the sidebar swipe
        // first; content gestures there wait for it to fail.
        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldBeRequiredToFailBy otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            candidate != nil
        }

        @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
            guard pan.state == .ended, let candidate else { return }
            let translationX = pan.translation(in: pan.view).x
            guard MobileWorkspaceShellLayoutPolicy.splitSidebarSwipeCompletes(
                candidate,
                translationX: translationX
            ) else { return }
            setSidebarShown(candidate == .show)
        }
    }
}
#endif
