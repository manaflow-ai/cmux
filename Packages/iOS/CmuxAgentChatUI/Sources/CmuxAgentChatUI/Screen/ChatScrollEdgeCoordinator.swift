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

    func topChromeInset(for owner: UIViewController) -> CGFloat {
        guard #available(iOS 26.0, *),
              let window = owner.view.window,
              let navigationBar = nearestNavigationBar(from: owner)
        else { return 0 }

        let viewFrame = owner.view.convert(owner.view.bounds, to: window)
        let navigationFrame = navigationBar.convert(navigationBar.bounds, to: window)
        guard viewFrame.minY <= navigationFrame.maxY,
              viewFrame.maxY >= navigationFrame.minY
        else { return 0 }
        return max(0, navigationFrame.maxY - viewFrame.minY)
    }

    private func configureEdgeEffect(for tableView: ChatTranscriptUITableView?) {
        guard let tableView else { return }
        if #available(iOS 26.0, *) {
            tableView.topEdgeEffect.style = .soft
            tableView.bottomEdgeEffect.style = .soft
        }
    }

    private func configureContentScrollView(
        _ tableView: ChatTranscriptUITableView?,
        owner: UIViewController
    ) {
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
        topContentScrollViewController?.setContentScrollView(nil, for: .top)
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
        return lastBeforeNavigation
    }

    private func nearestNavigationBar(from owner: UIViewController) -> UINavigationBar? {
        if let navigationBar = owner.navigationController?.navigationBar {
            return navigationBar
        }
        var current = owner.parent
        while let controller = current {
            if let navigationController = controller as? UINavigationController {
                return navigationController.navigationBar
            }
            if let navigationBar = controller.navigationController?.navigationBar {
                return navigationBar
            }
            current = controller.parent
        }
        return owner.view.window?.rootViewController.flatMap(firstNavigationController(in:))?.navigationBar
    }

    private func firstNavigationController(in controller: UIViewController) -> UINavigationController? {
        if let navigationController = controller as? UINavigationController {
            return navigationController
        }
        for child in controller.children {
            if let navigationController = firstNavigationController(in: child) {
                return navigationController
            }
        }
        if let presented = controller.presentedViewController,
           let navigationController = firstNavigationController(in: presented) {
            return navigationController
        }
        return nil
    }
}
#endif
