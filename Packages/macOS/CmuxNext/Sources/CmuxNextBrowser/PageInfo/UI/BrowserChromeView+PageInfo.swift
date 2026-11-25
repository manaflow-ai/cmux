import AppKit

extension BrowserChromeView {
    /// Page Info, made when it first opens: a new pane's first frame has no use for it (#32909).
    public var pageInfo: PageInfoController {
        if let pageInfoIfMade { return pageInfoIfMade }
        let controller = makePageInfoController()
        controller.commandRouter = pageInfoCommandRouter
        pageInfoIfMade = controller
        return controller
    }

    /// The page info bubble for the omnibar's leading button, made by its first use (`pageInfo`);
    /// the chrome wires the button at init.
    func makePageInfoController() -> PageInfoController {
        let controller = PageInfoController(tab: { [weak self] in self?.tab }, anchor: { [weak self] in self?.addressBar.pageInfoAnchor })
        controller.onReturnFocus = { [weak self] in self?.returnFocusToPage() }
        return controller
    }

    /// The page is closing: its popup panels (Page Info, the Extensions bubble) close for good.
    /// Both are kept between opens and only ordered out, so without this they stay in the app's
    /// window list for as long as anything still holds this chrome.
    public func closePopupPanels() {
        pageInfoIfMade?.closePanel()
        extensionToolbar.closeMenuPanel()
    }
}
