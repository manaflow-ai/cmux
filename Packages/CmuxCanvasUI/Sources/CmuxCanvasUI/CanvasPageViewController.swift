import AppKit
import CmuxCanvas

/// View controller reused by `NSPageController` for native Pages surfaces.
@MainActor
final class CanvasPageViewController: NSViewController {
    private let contentView = CanvasPageContentView()
    weak var owner: CanvasPagesRootView?
    private var page: CanvasPageObject?
    private var mountedPaneID: CanvasPaneID?
    private var mountedPanelId: UUID?
    private var mount: (any CanvasPaneContentMounting)?

    var currentPageObject: CanvasPageObject? {
        page
    }

    func isRendered(in viewport: NSView, requiresWindow: Bool = true) -> Bool {
        guard isViewLoaded,
              view.superview != nil,
              !view.isHiddenOrHasHiddenAncestor,
              view.bounds.width > 1,
              view.bounds.height > 1,
              viewport.bounds.width > 1,
              viewport.bounds.height > 1 else {
            return false
        }
        if requiresWindow {
            guard let window = view.window,
                  window === viewport.window else {
                return false
            }
        }
        return view.convert(view.bounds, to: viewport).intersects(viewport.bounds)
    }

    override func loadView() {
        view = contentView
    }

    func prepare(page: CanvasPageObject?, owner: CanvasPagesRootView) {
        self.owner = owner
        guard let page else {
            teardown()
            return
        }

        self.page = page
        let paneView = contentView.configure(
            paneID: page.paneID,
            paneBackground: owner.currentTheme.paneBackground,
            delegate: self
        )
        paneView.updateChrome(owner.chrome(for: page.pane))
        reconcileMount(for: page.pane, in: paneView, owner: owner)
        mount?.setRendering(owner.isRendering(self))
    }

    func teardown() {
        mount?.unmount()
        mount = nil
        mountedPaneID = nil
        mountedPanelId = nil
        page = nil
        contentView.clear()
    }

    func setRendering(_ rendering: Bool) {
        mount?.setRendering(rendering)
    }

    private func reconcileMount(
        for pane: CanvasPane,
        in paneView: CanvasPaneView,
        owner: CanvasPagesRootView
    ) {
        let selected = pane.selectedPanelId.rawValue
        guard mountedPaneID != pane.id || mountedPanelId != selected else { return }
        mount?.unmount()
        mount = nil

        guard let descriptor = owner.descriptor(for: selected) else { return }
        mount = descriptor.makeMount(paneView.contentContainer)
        mountedPaneID = pane.id
        mountedPanelId = selected
    }
}
