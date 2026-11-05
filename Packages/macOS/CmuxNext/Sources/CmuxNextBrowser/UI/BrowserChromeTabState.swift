public import AppKit

/// What one browser tab shows in its pane's chrome, kept with the tab while another tab of the pane shows
/// (Chrome's model: one `BrowserView` and `ToolbarView` per window, and per tab only the state the toolbar
/// shows for it, `OmniboxView::SaveStateToTab`, `FindBarController::ChangeWebContents`). The pane's chrome
/// binds to the selected tab's state (`BrowserChromeView.bind(_:state:)`); a new tab in a pane that has a
/// chrome builds no chrome view.
///
/// The host writes a tab's hooks and per-tab presentation here, never on a chrome it does not show: each write
/// reaches the chrome while it shows this tab (`chrome`), and the chrome takes all of them when it binds the tab.
@MainActor
public final class BrowserChromeTabState: Sendable {
    /// The chrome showing this tab now; nil while the tab does not show (its pane shows another tab, or none).
    public internal(set) weak var chrome: BrowserChromeView?
    /// Design mode and the forced color scheme (the toolbar's buttons read them).
    public let modes = BrowserPageModes()

    // MARK: The chrome's per-tab hooks (`BrowserChromeView`'s properties of the same names)

    /// The tab's loads, followed while it lives, shown or not (`BrowserPageLoads`); history and finished pages go here.
    let loads = BrowserPageLoads()
    public var onPageFinished: ((URL) -> Void)? {
        get { loads.onPageFinished }
        set { loads.onPageFinished = newValue }
    }
    public var loadOverride: ((URL) -> Bool)? { didSet { chrome?.loadOverride = loadOverride } }
    public var onOpenURL: ((URL, OmnibarDisposition) -> Void)? { didSet { chrome?.onOpenURL = onOpenURL } }
    public var onTypedCommit: (() -> Void)? { didSet { chrome?.onTypedCommit = onTypedCommit } }
    public var onReturnFocusToPage: (() -> Void)? { didSet { chrome?.onReturnFocusToPage = onReturnFocusToPage } }
    public var onContentFullscreenChange: ((Bool) -> Void)? { didSet { chrome?.onContentFullscreenChange = onContentFullscreenChange } }
    public var machineBadge: ((URL?) -> (text: String, help: String)?)? { didSet { chrome?.machineBadge = machineBadge } }
    public var certificateWarningRouter: ((CertificateWarningCommand) -> Bool)? {
        didSet { chrome?.certificateWarningRouter = certificateWarningRouter }
    }
    public var pageInfoCommandRouter: ((PageInfoCommand) -> Bool)? { didSet { chrome?.pageInfoCommandRouter = pageInfoCommandRouter } }
    public var extensionMenuHandler: (any ExtensionMenuHandling)? { didSet { chrome?.extensionMenuHandler = extensionMenuHandler } }
    public var onFocusModeBadgePress: (() -> Void)? { didSet { chrome?.onFocusModeBadgePress = onFocusModeBadgePress } }
    public var history: (any BrowserHistoryStore)? {
        get { loads.history }
        set { loads.history = newValue }
    }

    // MARK: The omnibar's per-tab parts

    public var suggestionEngine: OmniboxSuggestionEngine? {
        didSet { if let suggestionEngine { chrome?.addressBar.suggestionEngine = suggestionEngine } }
    }
    public var tabKey: String? { didSet { chrome?.addressBar.tabKey = tabKey } }
    public var profileBadge: BrowserProfileBadge? { didSet { chrome?.addressBar.setProfileBadge(profileBadge) } }
    public var profileBadgeMenu: (() -> NSMenu?)? { didSet { chrome?.addressBar.profileBadgeMenu = profileBadgeMenu } }
    public var machineBadgeMenu: (() -> NSMenu?)? { didSet { chrome?.addressBar.machineBadgeMenu = machineBadgeMenu } }
    public var bookmarkStar: BookmarkStarState = .hidden { didSet { chrome?.addressBar.setBookmarkStar(bookmarkStar) } }
    public var onBookmarkStar: ((NSView) -> Void)? { didSet { chrome?.addressBar.onBookmarkStar = onBookmarkStar } }
    public var onPageURLChange: ((URL?) -> Void)? { didSet { chrome?.addressBar.onPageURLChange = onPageURLChange } }
    public var rowFavicon: ((URL) async -> NSImage?)? { didSet { chrome?.addressBar.rowFavicon = rowFavicon } }

    // MARK: The toolbar's per-tab parts

    public var profileName: String? { didSet { chrome?.toolbarButtons.profileName = profileName } }
    public var onToolbarPress: ((BrowserToolbarButton) -> Void)? { didSet { chrome?.toolbarButtons.onPress = onToolbarPress } }
    /// The toolbar's other per-tab sources (shortcut hints, the tab's downloads, media, pins), set on each bind.
    public var configureToolbar: ((BrowserToolbarButtonsView) -> Void)? {
        didSet {
            guard let buttons = chrome?.toolbarButtons else { return }
            buttons.batchSources { configureToolbar?(buttons) }
        }
    }

    // MARK: Per-tab presentation

    public var showsFocusModeIndicator = false { didSet { chrome?.showsFocusModeIndicator = showsFocusModeIndicator } }
    public var focusModeExitArmed = false { didSet { chrome?.focusModeExitArmed = focusModeExitArmed } }
    /// The bar under the toolbar (the bookmarks bar) and its height.
    public var accessory: (view: NSView, height: CGFloat)? {
        didSet { chrome?.setAccessoryView(accessory?.view, height: accessory?.height ?? 0) }
    }
    /// A notice asked for while the tab did not show: it shows when the tab next shows.
    var pendingNotice: (text: String, action: (title: String, run: () -> Void)?)?

    /// Shows `text` over the tab's page now, or when the tab next shows.
    public func showNotice(_ text: String, action: (title: String, run: () -> Void)? = nil) {
        if let chrome { chrome.showNotice(text, action: action) } else { pendingNotice = (text, action) }
    }

    /// The notice over the tab's page, shown or waiting (diagnostics, the import offer's check).
    public var noticeText: String? { chrome?.noticeText ?? pendingNotice?.text }
    /// The omnibar as the tab left it: its address, or the text typed and left there, with its selection.
    var omnibar: OmnibarState?
    /// The find pill showed, with this query and match-case setting.
    var find: (query: String, matchCase: Bool)?
    var isOmnibarHidden = false
    var wakingAddress: BrowserTabState?
    /// The chrome a cookie import offer waits in, hidden, for this tab (`BrowserCookieImportCard.heldFor`).
    weak var cookieOfferHolder: BrowserChromeView?

    public init() {}
}

extension BrowserChromeView {
    /// Shows `tab` with its own toolbar state `state` (`BrowserChromeTabSwitch`): a tab switch in a pane whose tabs share this chrome.
    public func bind(_ tab: any BrowserTab, state: BrowserChromeTabState) { BrowserChromeTabSwitch(chrome: self).bind(tab, state) }
}

/// A tab switch in a shared chrome (`BrowserChromeView.bind(_:state:)`). The tab that leaves keeps its state and its
/// page, hidden in the page area (no window move on the way back; a Chromium page conceals itself when hidden). The
/// same state with another page is that tab's page replaced (a woken hibernated page): the old page leaves, as with `tab =`.
@MainActor
struct BrowserChromeTabSwitch {
    let chrome: BrowserChromeView

    func bind(_ tab: any BrowserTab, _ state: BrowserChromeTabState) {
        state.loads.follow(tab)
        guard state !== chrome.boundState else {
            if tab !== chrome.tab { chrome.tab = tab }
            return
        }
        let leaving = chrome.tab, parks = chrome.boundState != nil
        if let previous = chrome.boundState {
            save(into: previous)
            previous.chrome = nil
        }
        // The tab moved here from another pane: that chrome hands over what it shows for it (a cookie import offer it
        // holds for the tab comes along), then lets it go.
        let other = state.chrome
        if let other { BrowserChromeTabSwitch(chrome: other).save(into: state) }
        let movedOffer = state.cookieOfferHolder.flatMap { $0 === chrome ? nil : $0.takeHeldCookieOffer(for: state) }
        if let other { BrowserChromeTabSwitch(chrome: other).release(state) }
        state.chrome = chrome
        chrome.boundState = state
        restore(from: state)
        BrowserChromeTabHooks(chrome: chrome, state: state).apply()
        // Before the page binds: the toolbar's modes become this tab's, and the leaving tab's stay as they were.
        chrome.toolbarButtons.bind(tab, modes: state.modes)
        if tab === leaving {
            chrome.attach(tab, replacing: tab)
        } else {
            // A chrome that let its tab go shows an empty page (`release`): it leaves; a tab's page stays, hidden.
            if !parks { BrowserPageArea(container: chrome.contentContainer).leave(leaving.contentView, parks: false) }
            chrome.parksLeavingPage = true
            chrome.tab = tab
            chrome.parksLeavingPage = false
        }
        restoreFind(state)
        restoreCookieOffer(state, moved: movedOffer)
    }

    /// The cookie import offer the tab left (it shows once per launch): shown again; one held for a tab that closed goes.
    private func restoreCookieOffer(_ state: BrowserChromeTabState, moved: BrowserCookieImportCard?) {
        state.cookieOfferHolder = nil
        if let moved { chrome.showCookieImportOffer(moved.offer) { moved.onChoice?($0) } }
        guard let card = chrome.currentCookieImportCard, card.isHidden else { return }
        if card.heldFor === state {
            card.heldFor = nil
            card.isHidden = false
            chrome.syncPageOverlays()
        } else if card.heldFor == nil {
            chrome.hideCookieImportOffer()
        }
    }

    /// The tab that leaves: what its toolbar shows goes into its state.
    func save(into state: BrowserChromeTabState) {
        let bar = chrome.addressBar
        if bar.field.currentEditor() != nil, let window = chrome.window { window.makeFirstResponder(nil) }
        if bar.controller.state.hasFocus { bar.controller.send(.focusLost) }
        state.omnibar = bar.controller.state
        if let shown = chrome.shownFindBar {
            state.find = (shown.pill.query, shown.pill.matchCase)
            shown.isHidden = true
        } else {
            state.find = nil
        }
        if let notice = chrome.currentNotice, !notice.isDismissing {
            state.pendingNotice = (notice.text, notice.action)
            chrome.pageOverlays.remove(notice)
        }
        // The cookie import offer waits, hidden, for its tab (it shows once per launch).
        if let card = chrome.currentCookieImportCard, !card.isHidden {
            card.heldFor = state
            state.cookieOfferHolder = chrome
            card.isHidden = true
            chrome.syncPageOverlays()
        }
        state.isOmnibarHidden = chrome.isOmnibarHidden
        state.wakingAddress = chrome.wakingAddress
    }

    /// The tab that shows: its own toolbar state, before the page binds and renders.
    private func restore(from state: BrowserChromeTabState) {
        chrome.addressBar.restore(state.omnibar ?? OmnibarState())
        chrome.isOmnibarHidden = state.isOmnibarHidden
        chrome.wakingAddress = state.wakingAddress
        chrome.loads = state.loads
    }

    /// The tab's find pill, as it left it: shown with its query, not focused (the page keeps the keyboard).
    private func restoreFind(_ state: BrowserChromeTabState) {
        guard let find = state.find else { return }
        let bar = chrome.findBar
        bar.pill.query = find.query
        bar.pill.matchCase = find.matchCase
        bar.alphaValue = 1
        bar.isHidden = false
        chrome.needsLayout = true
    }
}

extension AddressBarView {
    /// Puts back the resting omnibar a tab left; the reported address becomes that tab's, so the next page render
    /// compares with the tab's own address, not the other tab's (which would clear the text it left).
    func restore(_ resting: OmnibarState) {
        reportedURL = resting.pageURL
        controller.restore(resting)
    }
}
