#if os(iOS)
import UIKit

@MainActor
final class ChatScrollEdgeCoordinator {
    private var bottomInteraction: UIInteraction?
    private weak var bottomInteractionTableView: ChatTranscriptUITableView?
    private weak var topContentScrollViewController: UIViewController?

    func configure(
        tableView: ChatTranscriptUITableView?,
        owner: UIViewController,
        composerView: UIView
    ) {
        configureEdgeEffect(for: tableView)
        configureContentScrollView(tableView, owner: owner)
        configureBottomInteraction(tableView, composerView: composerView)
    }

    func reset() {
        resetBottomInteraction()
        clearTopContentScrollViewController()
    }

    private func configureEdgeEffect(for tableView: ChatTranscriptUITableView?) {
        #if compiler(>=6.3)
        guard let tableView else { return }
        if #available(iOS 26.0, *) {
            tableView.topEdgeEffect.style = .soft
            tableView.bottomEdgeEffect.style = .soft
        }
        #endif
    }

    private func configureContentScrollView(
        _ tableView: ChatTranscriptUITableView?,
        owner: UIViewController
    ) {
        #if compiler(>=6.3)
        if #available(iOS 26.0, *) {
            let topController = tableView == nil
                ? nil
                : nearestNavigationContentViewController(from: owner) ?? owner
            if topContentScrollViewController !== topController {
                clearTopContentScrollViewController()
                topContentScrollViewController = topController
            }
            topController?.setContentScrollView(tableView, for: .top)
        }
        #endif
    }

    private func configureBottomInteraction(
        _ tableView: ChatTranscriptUITableView?,
        composerView: UIView
    ) {
        #if compiler(>=6.3)
        if #available(iOS 26.0, *) {
            guard let tableView else {
                resetBottomInteraction()
                return
            }

            let interaction: UIScrollEdgeElementContainerInteraction
            if let existing = bottomInteraction as? UIScrollEdgeElementContainerInteraction {
                interaction = existing
            } else {
                interaction = UIScrollEdgeElementContainerInteraction()
                interaction.edge = .bottom
                composerView.addInteraction(interaction)
                bottomInteraction = interaction
            }

            if bottomInteractionTableView !== tableView {
                interaction.scrollView = tableView
                bottomInteractionTableView = tableView
            }
        }
        #endif
    }

    private func resetBottomInteraction() {
        if let interaction = bottomInteraction {
            interaction.view?.removeInteraction(interaction)
        }
        bottomInteraction = nil
        bottomInteractionTableView = nil
    }

    private func clearTopContentScrollViewController() {
        #if compiler(>=6.3)
        if #available(iOS 26.0, *) {
            topContentScrollViewController?.setContentScrollView(nil, for: .top)
        }
        #endif
        topContentScrollViewController = nil
    }

    private func nearestNavigationContentViewController(
        from owner: UIViewController
    ) -> UIViewController? {
        var current = owner.parent
        var lastBeforeNavigation: UIViewController?
        while let controller = current {
            if controller is UINavigationController {
                return lastBeforeNavigation
            }
            lastBeforeNavigation = controller
            current = controller.parent
        }
        // No navigation controller in the parent chain: there is no nav-bar
        // owner to register the top content scroll view with. Returning the
        // topmost parent here would install scroll-edge state on an unrelated
        // controller, so report "none" and let the caller fall back to `owner`.
        return nil
    }
}
#endif
