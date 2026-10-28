public import AppKit
public import CmuxNextWakeups

/// Ties the omnibar (`AddressBarView`) to one page shown outside a browser
/// pane: a popup window (`window.open`, OAuth, extension and sign-in windows).
/// The bar follows the page's URL and security, its chip opens page info, a
/// committed address loads in the page (falling back to http when a typed
/// host refuses https), and the page's extension keywords work, as in a
/// browser tab's toolbar (`BrowserChromeView`). There is one omnibar view; this only connects it
/// (`scripts/cmux-next/check-single-omnibar.py`).
public final class OmnibarTabBinding {
    /// The bar this binding drives.
    public let addressBar: AddressBarView
    private let tab: any BrowserTab
    private let mainWork: MainWorkScheduler
    private var observation: ObservationLoop?
    /// The typed-address http fallback (`HTTPSUpgradeFallback`), as a tab's toolbar has.
    private var httpsFallback = HTTPSUpgradeFallback()
    private lazy var pageInfo: PageInfoController = {
        let controller = PageInfoController(tab: { [weak self] in self?.tab }, anchor: { [weak self] in self?.addressBar.pageInfoAnchor },
                                            mainWork: self.mainWork)
        controller.onReturnFocus = { [weak self] in self?.tab.setFocused(true) }
        return controller
    }()

    /// Binds `addressBar` to `tab` until `stop()`.
    ///
    /// - Parameters:
    ///   - addressBar: The omnibar to drive (usually an `OmnibarToolbarView`'s bar).
    ///   - tab: The page whose URL the bar shows and loads.
    ///   - mainWork: The app's one main-thread scheduler; the bar follows the page on it.
    public init(addressBar: AddressBarView, tab: any BrowserTab, mainWork: MainWorkScheduler) {
        self.addressBar = addressBar
        self.tab = tab
        self.mainWork = mainWork
        addressBar.allowsChromiumSchemes = tab.engineKind == .cef
        addressBar.onPageInfo = { [weak self] in self?.pageInfo.toggle() }
        addressBar.onEvent = { [weak self] event in self?.handle(event) }
        addressBar.onTypedHTTPSUpgrade = { [weak self] url in
            guard let self else { return }
            httpsFallback.expect(url, current: tab.state.loadError)
        }
        addressBar.bindKeywords(of: tab)
        // node-free: the popup window's own bar, in no tab; the window's occlusion stops its frames
        observation = ObservationLoop(owner: "browser.popup.omnibar", delivery: .visible(nil), on: mainWork) { [weak self] in self?.render() }
    }

    /// Stops following the page and closes its page info bubble.
    public func stop() {
        observation?.cancel()
        observation = nil
        pageInfo.tabDidChange()
    }

    private func render() {
        let state = tab.state
        if let http = httpsFallback.observe(state) {
            // One load, after this render (never a load inside the observed render): the rest of the person's
            // typed navigation, as BrowserChromeView's fallback.
            mainWork.post(.userBlocking, owner: "browser.popup.httpsFallback") { [weak self] in self?.tab.load(http) }
        }
        addressBar.update(url: BrowserChromeView.omnibarURL(for: state), security: PageInfoSite.omnibarSecurity(for: state))
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
            httpsFallback.committed(url)
            tab.load(url)
            tab.setFocused(true)
        case .didEndEditing(.open(let url, let disposition)):
            // Cmd-Return, Shift-Return, a modified row click: a new tab or
            // window, asked of the page's host as a link's new tab is (a
            // popup's host opens it beside the opener's tab).
            tab.delegate?.browserTab(tab, didRequest: .openURL(url, Self.newTabDisposition(disposition)))
        case .didEndEditing(.switchToTab(let key)):
            addressBar.suggestionEngine.revealTab(key)
        case .didEndEditing(.keyword(let extensionID, let text, let disposition)):
            // Enter in an extension keyword session: the text goes to the extension.
            (tab as? any BrowserOmniboxKeywordProviding)?.omniboxKeywordEntered(extensionID, text: text, disposition: disposition)
            tab.setFocused(true)
        case .didEndEditing(.cancel):
            tab.setFocused(true)
        case .didBeginEditing, .didEndEditing(.blur):
            break
        }
    }
}
