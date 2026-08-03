#if os(iOS)
import UIKit

/// Owns one native controller per path and commits only completed page transitions.
@MainActor
final class ChatArtifactPageViewControllerCoordinator: NSObject,
    UIPageViewControllerDataSource,
    UIPageViewControllerDelegate
{
    private weak var pageController: UIPageViewController?
    private var state = ChatArtifactPageControllerState(paths: [], selectedPath: "")
    private var pagesByPath: [String: ChatArtifactViewerPageDescriptor] = [:]
    private var controllersByPath: [String: ChatArtifactViewerPageController] = [:]
    private var onSelectionChanged: (@MainActor (String) -> Void)?
    private var isTransitioning = false
    private var needsDataSourceReload = false

    func attach(_ controller: UIPageViewController) {
        pageController = controller
    }

    func update(
        pages: [ChatArtifactViewerPageDescriptor],
        selectedPath: String,
        onSelectionChanged: @escaping @MainActor (String) -> Void,
        isPagingEnabled: Bool
    ) {
        self.onSelectionChanged = onSelectionChanged
        pagesByPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) })
        for page in pages {
            controllersByPath[page.path]?.update(descriptor: page)
        }
        needsDataSourceReload = state.update(
            paths: pages.map(\.path),
            selectedPath: selectedPath
        ) || needsDataSourceReload
        configurePaging(isEnabled: isPagingEnabled)
        guard !isTransitioning else { return }
        removeUnusedControllers()
        reloadDataSourceIfNeeded()
        synchronizeDisplayedPage()
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerBefore viewController: UIViewController
    ) -> UIViewController? {
        guard let path = path(for: viewController),
              let previousPath = state.path(before: path) else {
            return nil
        }
        return controller(for: previousPath)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let path = path(for: viewController),
              let nextPath = state.path(after: path) else {
            return nil
        }
        return controller(for: nextPath)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        willTransitionTo pendingViewControllers: [UIViewController]
    ) {
        isTransitioning = true
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        didFinishAnimating finished: Bool,
        previousViewControllers: [UIViewController],
        transitionCompleted completed: Bool
    ) {
        isTransitioning = false
        if completed,
           let displayed = pageViewController.viewControllers?.first,
           let path = path(for: displayed),
           state.completeTransition(to: path) {
            onSelectionChanged?(path)
        }
        removeUnusedControllers()
        reloadDataSourceIfNeeded()
        synchronizeDisplayedPage()
    }

    private func synchronizeDisplayedPage() {
        guard let pageController,
              let destination = controller(for: state.selectedPath) else {
            return
        }
        let current = pageController.viewControllers?.first
        guard current !== destination else { return }
        let direction: UIPageViewController.NavigationDirection = state.isForwardTransition(
            from: current.flatMap(path(for:)),
            to: state.selectedPath
        ) ? .forward : .reverse
        pageController.setViewControllers(
            [destination],
            direction: direction,
            animated: false
        )
    }

    private func controller(for path: String) -> ChatArtifactViewerPageController? {
        if let controller = controllersByPath[path] {
            return controller
        }
        guard let page = pagesByPath[path] else { return nil }
        let controller = ChatArtifactViewerPageController(descriptor: page)
        controllersByPath[path] = controller
        return controller
    }

    private func path(for viewController: UIViewController) -> String? {
        (viewController as? ChatArtifactViewerPageController)?.path
    }

    private func removeUnusedControllers() {
        let retainedPaths = Set(state.paths)
        controllersByPath = controllersByPath.filter { retainedPaths.contains($0.key) }
    }

    private func reloadDataSourceIfNeeded() {
        guard needsDataSourceReload, let pageController else { return }
        pageController.dataSource = nil
        pageController.dataSource = self
        needsDataSourceReload = false
    }

    private func configurePaging(isEnabled: Bool) {
        guard let pageController else { return }
        for case let scrollView as UIScrollView in pageController.view.subviews {
            scrollView.isScrollEnabled = isEnabled
            scrollView.clipsToBounds = true
        }
    }
}
#endif
