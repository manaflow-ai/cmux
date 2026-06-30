#if os(iOS)
import UIKit

@MainActor
final class ChatScrollEdgeCoordinator {
    private var bottomInteraction: UIInteraction?
    private weak var bottomInteractionTableView: ChatTranscriptUITableView?
    private weak var topContentScrollViewController: UIViewController?
    private weak var topContentScrollViewTableView: ChatTranscriptUITableView?

    func configure(
        tableView: ChatTranscriptUITableView?,
        owner: UIViewController,
        composerView: UIView,
        suppressTopEdgeEffect: Bool
    ) {
        configureEdgeEffect(for: tableView, suppressTopEdgeEffect: suppressTopEdgeEffect)
        configureContentScrollView(
            tableView,
            owner: owner,
            suppressTopEdgeEffect: suppressTopEdgeEffect
        )
        configureBottomInteraction(tableView, composerView: composerView)
    }

    func reset() {
        resetBottomInteraction()
        clearTopContentScrollViewController()
    }

    private func configureEdgeEffect(
        for tableView: ChatTranscriptUITableView?,
        suppressTopEdgeEffect: Bool
    ) {
        guard let tableView else { return }
        tableView.applyScrollEdgeEffects(topSoft: !suppressTopEdgeEffect, bottomSoft: true)
    }

    private func configureContentScrollView(
        _ tableView: ChatTranscriptUITableView?,
        owner: UIViewController,
        suppressTopEdgeEffect: Bool
    ) {
        if #available(iOS 26.0, *) {
            guard let tableView, !suppressTopEdgeEffect else {
                clearTopContentScrollViewController()
                #if DEBUG
                tableView?.recordTopContentScrollViewRegistration(false)
                #endif
                return
            }
            let topController = nearestNavigationContentViewController(from: owner) ?? owner
            if topContentScrollViewController !== topController {
                clearTopContentScrollViewController()
                topContentScrollViewController = topController
            }
            if topContentScrollViewTableView !== tableView {
                #if DEBUG
                topContentScrollViewTableView?.recordTopContentScrollViewRegistration(false)
                #endif
                topContentScrollViewTableView = tableView
            }
            topController.setContentScrollView(tableView, for: .top)
            #if DEBUG
            tableView.recordTopContentScrollViewRegistration(true)
            #endif
        }
    }

    private func configureBottomInteraction(
        _ tableView: ChatTranscriptUITableView?,
        composerView: UIView
    ) {
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
    }

    private func resetBottomInteraction() {
        if let interaction = bottomInteraction {
            interaction.view?.removeInteraction(interaction)
        }
        bottomInteraction = nil
        bottomInteractionTableView = nil
    }

    private func clearTopContentScrollViewController() {
        if #available(iOS 26.0, *) {
            topContentScrollViewController?.setContentScrollView(nil, for: .top)
        }
        #if DEBUG
        topContentScrollViewTableView?.recordTopContentScrollViewRegistration(false)
        #endif
        topContentScrollViewController = nil
        topContentScrollViewTableView = nil
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
