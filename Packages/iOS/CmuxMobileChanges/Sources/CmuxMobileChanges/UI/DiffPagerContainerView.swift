#if os(iOS)
public import SwiftUI
internal import UIKit

/// UIKit-owned horizontal diff pager.
///
/// `UIPageViewController` owns the pan gesture and page lifecycle
/// exclusively. `updateUIViewController` is a guarded no-op unless the file
/// snapshot itself changed, so a SwiftUI re-render (a diff load landing, a
/// cache touch, a toolbar update) can never rebuild the container while a
/// swipe is in flight. Page content changes are confined to each page's own
/// hosting controller.
struct DiffPagerContainerView: UIViewControllerRepresentable {
    let files: [ChangedFileItem]
    let initialSelectedIndex: Int
    let makePage: @MainActor (Int, ChangedFileItem) -> AnyView
    let onSelectionChanged: @MainActor (Int) -> Void

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pager = UIPageViewController(
            transitionStyle: .scroll,
            navigationOrientation: .horizontal
        )
        pager.dataSource = context.coordinator
        pager.delegate = context.coordinator
        context.coordinator.install(
            files: files,
            makePage: makePage,
            onSelectionChanged: onSelectionChanged
        )
        if let initial = context.coordinator.pageController(at: initialSelectedIndex) {
            pager.setViewControllers([initial], direction: .forward, animated: false)
            context.coordinator.currentIndex = initialSelectedIndex
        }
        return pager
    }

    func updateUIViewController(_ pager: UIPageViewController, context: Context) {
        context.coordinator.install(
            files: files,
            makePage: makePage,
            onSelectionChanged: onSelectionChanged
        )
        // Only a genuine snapshot change may touch the page hierarchy, and
        // never while UIKit is mid-transition; an interrupted interactive
        // swipe is exactly the takeover this container exists to prevent.
        guard context.coordinator.needsReset else { return }
        guard !context.coordinator.isTransitioning else { return }
        context.coordinator.resetPages(on: pager)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    /// Hosting controller carrying its page index for settle attribution.
    @MainActor
    final class PageHostingController: UIHostingController<AnyView> {
        let pageIndex: Int

        init(pageIndex: Int, rootView: AnyView) {
            self.pageIndex = pageIndex
            super.init(rootView: rootView)
        }

        @available(*, unavailable)
        required dynamic init?(coder aDecoder: NSCoder) {
            fatalError("init(coder:) is not supported")
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        private var files: [ChangedFileItem] = []
        private var makePage: (@MainActor (Int, ChangedFileItem) -> AnyView)?
        private var onSelectionChanged: (@MainActor (Int) -> Void)?
        private var pagesByIndex: [Int: PageHostingController] = [:]
        var currentIndex = 0
        var isTransitioning = false
        var needsReset = false

        func install(
            files: [ChangedFileItem],
            makePage: @escaping @MainActor (Int, ChangedFileItem) -> AnyView,
            onSelectionChanged: @escaping @MainActor (Int) -> Void
        ) {
            self.makePage = makePage
            self.onSelectionChanged = onSelectionChanged
            let paths = files.map(\.path)
            if paths != self.files.map(\.path) {
                needsReset = !self.files.isEmpty
                self.files = files
            }
        }

        /// Rebuilds the page hierarchy after the changed-file snapshot itself
        /// changed (a refresh while pushed), clamping to the nearest page.
        func resetPages(on pager: UIPageViewController) {
            needsReset = false
            pagesByIndex = [:]
            guard !files.isEmpty else { return }
            currentIndex = min(max(currentIndex, 0), files.count - 1)
            if let page = pageController(at: currentIndex) {
                pager.setViewControllers([page], direction: .forward, animated: false)
            }
        }

        func pageController(at index: Int) -> PageHostingController? {
            guard files.indices.contains(index), let makePage else { return nil }
            if let existing = pagesByIndex[index] { return existing }
            let controller = PageHostingController(
                pageIndex: index,
                rootView: makePage(index, files[index])
            )
            pagesByIndex[index] = controller
            return controller
        }

        /// Drops retained controllers outside the current page and its
        /// immediate neighbors; UIKit re-requests them from the data source
        /// on the next swipe, and their state rehydrates from the store.
        private func prunePages() {
            pagesByIndex = pagesByIndex.filter { abs($0.key - currentIndex) <= 1 }
        }

        // MARK: UIPageViewControllerDataSource

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerBefore viewController: UIViewController
        ) -> UIViewController? {
            guard let page = viewController as? PageHostingController else { return nil }
            return pageController(at: page.pageIndex - 1)
        }

        func pageViewController(
            _ pageViewController: UIPageViewController,
            viewControllerAfter viewController: UIViewController
        ) -> UIViewController? {
            guard let page = viewController as? PageHostingController else { return nil }
            return pageController(at: page.pageIndex + 1)
        }

        // MARK: UIPageViewControllerDelegate

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
            guard completed,
                  let visible = pageViewController.viewControllers?.first as? PageHostingController,
                  visible.pageIndex != currentIndex
            else { return }
            currentIndex = visible.pageIndex
            prunePages()
            onSelectionChanged?(visible.pageIndex)
        }
    }
}
#endif
