import AppKit

// Chrome commands (key equivalents the chrome handles itself) and the
// trailing toolbar buttons' share of the width-driven toolbar collapse.
extension BrowserChromeView {
    public func perform(_ command: BrowserChromeCommand) {
        switch command {
        case .focusAddressBar: addressBar.focus()
        case .findInPage: showFindBar()
        case .findNext: findBar.isHidden ? showFindBar() : findBar.findNext()
        case .findPrevious: findBar.isHidden ? showFindBar() : findBar.findPrevious()
        case .reload: tab.reload()
        case .stop: tab.stop()
        case .goBack: tab.goBack()
        case .goForward: tab.goForward()
        case .zoomIn: tab.zoomIn(); siteZoom.userDidZoom()
        case .zoomOut: tab.zoomOut(); siteZoom.userDidZoom()
        case .resetZoom: tab.resetZoom(); siteZoom.userDidZoom()
        case .showDevTools: tab.showDevTools()
        }
    }

    /// The width the extension layout may use: the pane minus the trailing
    /// buttons. Buttons collapse into More, design mode and DevTools first,
    /// while the omnibar would drop below its minimum with Forward shown and
    /// no extension button.
    func widthLeftByToolbarButtons() -> CGFloat {
        let metrics = Self.toolbarMetrics
        let gap = BrowserMetrics.buttonSpacing
        let roomy = BrowserToolbarLayout(visiblePinned: 0, showsForward: true)
        let level = (0...2).first { candidate in
            let width = bounds.width - toolbarButtons.width(collapse: candidate) - gap
            let address = BrowserToolbarLayout.addressWidth(width: width, layout: roomy, showsExtensions: extensionToolbar.isShowingExtensions,
                                                            metrics: metrics)
            return address >= metrics.minimumAddress
        } ?? 2
        toolbarButtons.setCollapse(level)
        return bounds.width - toolbarButtons.width(collapse: level) - gap
    }
}
