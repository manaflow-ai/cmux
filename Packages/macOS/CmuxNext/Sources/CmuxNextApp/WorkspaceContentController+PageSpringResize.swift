import CmuxNextBrowser
import CmuxNextDesign
import CmuxNextFeatures
import CmuxNextLayout

extension WorkspaceContentController {
    /// `LayoutPaneContentProvider`: with the `pageSpringResizeOnce` feature, a page in a springing pane resizes
    /// as `browserResize.springPageResize` says, inside the window's one fence per turn (p03-rendering-036).
    /// Read once per pane host, as it is made.
    var pageSpringResizing: PageSpringResizing? {
        guard services.features.isEnabled(.pageSpringResizeOnce) else { return nil }
        return PageSpringResizing(mode: { BrowserResizeTunables.springPageResize.value }, fence: state.pageResizeFence)
    }
}
