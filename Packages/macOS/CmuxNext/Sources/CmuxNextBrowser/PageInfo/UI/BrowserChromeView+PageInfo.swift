import AppKit

extension BrowserChromeView {
    /// The page info bubble for the omnibar's leading button. Created on the
    /// first `attach`, which also wires the button.
    func makePageInfoController() -> PageInfoController {
        let controller = PageInfoController(tab: { [weak self] in self?.tab }, anchor: { [weak self] in self?.addressBar.pageInfoAnchor })
        controller.onReturnFocus = { [weak self] in self?.returnFocusToPage() }
        addressBar.onPageInfo = { [weak controller] in controller?.toggle() }
        return controller
    }

    /// The page is closing: its popup panels (Page Info, the Extensions bubble) close for good.
    /// Both are kept between opens and only ordered out, so without this they stay in the app's
    /// window list for as long as anything still holds this chrome.
    public func closePopupPanels() {
        pageInfo.closePanel()
        extensionToolbar.closeMenuPanel()
    }
}
