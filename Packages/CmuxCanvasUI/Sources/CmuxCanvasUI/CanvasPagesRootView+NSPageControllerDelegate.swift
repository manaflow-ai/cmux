public import AppKit

extension CanvasPagesRootView: NSPageControllerDelegate {
    /// Returns the stable page-controller identifier for a page object.
    public func pageController(
        _ pageController: NSPageController,
        identifierFor object: Any
    ) -> NSPageController.ObjectIdentifier {
        guard let page = object as? CanvasPageObject else {
            return NSPageController.ObjectIdentifier("canvas.page")
        }
        return identifier(for: page)
    }

    /// Creates the reusable controller that hosts one native Pages surface.
    public func pageController(
        _ pageController: NSPageController,
        viewControllerForIdentifier identifier: NSPageController.ObjectIdentifier
    ) -> NSViewController {
        CanvasPageViewController()
    }

    /// Updates a reused page controller with the pane content for the supplied page object.
    public func pageController(
        _ pageController: NSPageController,
        prepare viewController: NSViewController,
        with object: Any?
    ) {
        guard let controller = viewController as? CanvasPageViewController else { return }
        let page = object as? CanvasPageObject
        register(controller, for: page)
        controller.prepare(page: page, owner: self)
        scheduleRenderingUpdate()
    }

    /// Commits focus and viewport callbacks after a page transition selects a new object.
    public func pageController(
        _ pageController: NSPageController,
        didTransitionTo object: Any
    ) {
        guard let page = object as? CanvasPageObject else { return }
        finishSelection(of: page)
    }

    /// Finalizes AppKit's live transition and refreshes rendered page state.
    public func pageControllerDidEndLiveTransition(_ pageController: NSPageController) {
        pageController.completeTransition()
        isApplyingSyncSelection = false
        refreshPreparedControllers()
        updateControllerRendering()
    }
}
