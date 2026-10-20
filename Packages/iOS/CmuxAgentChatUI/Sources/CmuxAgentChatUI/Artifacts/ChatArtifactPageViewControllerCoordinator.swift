#if os(iOS)
import SwiftUI
import UIKit

/// Owns one clipped hosting controller per path and commits only completed page transitions.
@MainActor
final class ChatArtifactPageViewControllerCoordinator: NSObject,
    UIPageViewControllerDataSource,
    UIPageViewControllerDelegate
{
    private weak var pageController: UIPageViewController?
    private var state = ChatArtifactPageControllerState(paths: [], selectedPath: "")
    private var pagesByPath: [String: ChatArtifactViewerHostedPage] = [:]
    private var hostsByPath: [String: UIHostingController<ChatArtifactViewerHostedPage>] = [:]
    private var selection: Binding<String>?
    private var isTransitioning = false
    private var needsDataSourceReload = false

    func attach(_ controller: UIPageViewController) {
        pageController = controller
    }

    func update(
        pages: [ChatArtifactViewerHostedPage],
        selectedPath: String,
        selection: Binding<String>,
        isPagingEnabled: Bool
    ) {
        self.selection = selection
        pagesByPath = Dictionary(uniqueKeysWithValues: pages.map { ($0.path, $0) })
        for page in pages {
            hostsByPath[page.path]?.rootView = page
        }
        needsDataSourceReload = state.update(
            paths: pages.map(\.path),
            selectedPath: selectedPath
        ) || needsDataSourceReload
        configurePaging(isEnabled: isPagingEnabled)
        guard !isTransitioning else { return }
        removeUnusedHosts()
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
        return host(for: previousPath)
    }

    func pageViewController(
        _ pageViewController: UIPageViewController,
        viewControllerAfter viewController: UIViewController
    ) -> UIViewController? {
        guard let path = path(for: viewController),
              let nextPath = state.path(after: path) else {
            return nil
        }
        return host(for: nextPath)
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
            selection?.wrappedValue = path
        }
        removeUnusedHosts()
        reloadDataSourceIfNeeded()
        synchronizeDisplayedPage()
    }

    private func synchronizeDisplayedPage() {
        guard let pageController,
              let destination = host(for: state.selectedPath) else {
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

    private func host(for path: String) -> UIHostingController<ChatArtifactViewerHostedPage>? {
        if let host = hostsByPath[path] {
            return host
        }
        guard let page = pagesByPath[path] else { return nil }
        let host = UIHostingController(rootView: page)
        host.view.backgroundColor = .systemBackground
        host.view.isOpaque = true
        host.view.clipsToBounds = true
        hostsByPath[path] = host
        return host
    }

    private func path(for viewController: UIViewController) -> String? {
        hostsByPath.first { $0.value === viewController }?.key
    }

    private func removeUnusedHosts() {
        let retainedPaths = Set(state.paths)
        hostsByPath = hostsByPath.filter { retainedPaths.contains($0.key) }
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
