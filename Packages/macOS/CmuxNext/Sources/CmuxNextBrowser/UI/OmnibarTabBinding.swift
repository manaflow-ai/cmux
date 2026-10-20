public import AppKit

/// Ties the omnibar (`AddressBarView`) to one page shown outside a browser
/// pane: a popup window (`window.open`, OAuth, extension and sign-in windows).
/// The bar follows the page's URL and security, its chip opens page info, and
/// a committed address loads in the page, as in a browser tab's toolbar
/// (`BrowserChromeView`). There is one omnibar view; this only connects it
/// (`scripts/cmux-next/check-single-omnibar.py`).
public final class OmnibarTabBinding {
    /// The bar this binding drives.
    public let addressBar: AddressBarView
    private let tab: any BrowserTab
    private var observation: ObservationLoop?
    private lazy var pageInfo: PageInfoController = {
        let controller = PageInfoController(tab: { [weak self] in self?.tab }, anchor: { [weak self] in self?.addressBar.pageInfoAnchor })
        controller.onReturnFocus = { [weak self] in self?.tab.setFocused(true) }
        return controller
    }()

    /// Binds `addressBar` to `tab` until `stop()`.
    ///
    /// - Parameters:
    ///   - addressBar: The omnibar to drive (usually an `OmnibarToolbarView`'s bar).
    ///   - tab: The page whose URL the bar shows and loads.
    public init(addressBar: AddressBarView, tab: any BrowserTab) {
        self.addressBar = addressBar
        self.tab = tab
        addressBar.allowsChromiumSchemes = tab.engineKind == .cef
        addressBar.onPageInfo = { [weak self] in self?.pageInfo.toggle() }
        addressBar.onEvent = { [weak self] event in self?.handle(event) }
        observation = ObservationLoop { [weak self] in self?.render() }
    }

    /// Stops following the page and closes its page info bubble.
    public func stop() {
        observation?.cancel()
        observation = nil
        pageInfo.tabDidChange()
    }

    private func render() {
        let state = tab.state
        addressBar.update(url: state.url, security: PageInfoSite.omnibarSecurity(for: state))
    }

    /// The page intent for an omnibar disposition other than this page.
    static func newTabDisposition(_ disposition: OmnibarDisposition) -> BrowserNewTabDisposition {
        switch disposition {
        case .newBackgroundTab: .backgroundTab
        case .newWindow: .newWindow
        case .newForegroundTab, .currentTab: .foregroundTab
        }
    }

    /// What an omnibar boundary does, as `BrowserChromeView.performOmnibarEnd`
    /// for a tab: a commit loads here, then the page has the keyboard again.
    private func handle(_ event: OmnibarEvent) {
        switch event {
        case .didEndEditing(.commit(let url)):
            tab.load(url)
            tab.setFocused(true)
        case .didEndEditing(.open(let url, let disposition)):
            // Cmd-Return, Shift-Return, a modified row click: a new tab or
            // window, asked of the page's host as a link's new tab is (a
            // popup's host opens it beside the opener's tab).
            tab.delegate?.browserTab(tab, didRequest: .openURL(url, Self.newTabDisposition(disposition)))
        case .didEndEditing(.switchToTab(let key)):
            addressBar.suggestionEngine.revealTab(key)
        case .didEndEditing(.cancel):
            tab.setFocused(true)
        case .didBeginEditing, .didEndEditing(.blur), .didEndEditing(.keyword):
            // A popup page offers no extension keywords (`keywordSource` stays empty).
            break
        }
    }
}
