import AppKit

/// What one browser tab shows in its pane's chrome, kept with the tab while another tab of the pane shows
/// (Chrome's model: one `BrowserView` and `ToolbarView` per window, and per tab only the state the toolbar
/// shows for it, `OmniboxView::SaveStateToTab`, `FindBarController::ChangeWebContents`). The pane's chrome
/// binds to the selected tab's state (`BrowserChromeView.bind(_:state:)`); a new tab in a pane that has a
/// chrome builds no chrome view.
///
/// The host writes a tab's hooks and per-tab presentation here, never on a chrome it does not show: each write
/// reaches the chrome while it shows this tab (`chrome`), and the chrome takes all of them when it binds the tab.
@MainActor
public final class BrowserChromeTabState {
    /// The chrome showing this tab now; nil while the tab does not show (its pane shows another tab, or none).
    public internal(set) weak var chrome: BrowserChromeView?
    /// Design mode and the forced color scheme (the toolbar's buttons read them).
    public let modes = BrowserPageModes()

    // MARK: The chrome's per-tab hooks (`BrowserChromeView`'s properties of the same names)

    public var onPageFinished: ((URL) -> Void)?
    public var loadOverride: ((URL) -> Bool)?
    public var onOpenURL: ((URL, OmnibarDisposition) -> Void)?
    public var onTypedCommit: (() -> Void)?
    public var onReturnFocusToPage: (() -> Void)?
    public var onContentFullscreenChange: ((Bool) -> Void)?
    public var machineBadge: ((URL?) -> (text: String, help: String)?)?
    public var certificateWarningRouter: ((CertificateWarningCommand) -> Bool)?
    public var pageInfoCommandRouter: ((PageInfoCommand) -> Bool)?
    public var extensionMenuHandler: (any ExtensionMenuHandling)?
    public var onFocusModeBadgePress: (() -> Void)?
    public var history: (any BrowserHistoryStore)?

    // MARK: The omnibar's per-tab parts

    public var suggestionEngine: OmniboxSuggestionEngine?
    public var tabKey: String?
    public var profileBadge: BrowserProfileBadge?
    public var profileBadgeMenu: (() -> NSMenu?)?
    public var machineBadgeMenu: (() -> NSMenu?)?
    public var bookmarkStar: BookmarkStarState = .hidden
    public var onBookmarkStar: ((NSView) -> Void)?
    public var onPageURLChange: ((URL?) -> Void)?
    public var rowFavicon: ((URL) async -> NSImage?)?

    // MARK: The toolbar's per-tab parts

    public var profileName: String?
    public var onToolbarPress: ((BrowserToolbarButton) -> Void)?

    // MARK: Per-tab presentation

    public var showsFocusModeIndicator = false
    public var focusModeExitArmed = false
    /// The bar under the toolbar (the bookmarks bar) and its height.
    public var accessory: (view: NSView, height: CGFloat)?
    /// A notice asked for while the tab did not show: it shows when the tab next shows.
    var pendingNotice: (text: String, action: (title: String, run: () -> Void)?)?

    /// Shows `text` over the tab's page now, or when the tab next shows.
    public func showNotice(_ text: String, action: (title: String, run: () -> Void)? = nil) {
        pendingNotice = (text, action)
    }

    /// The notice over the tab's page, shown or waiting (diagnostics, the import offer's check).
    public var noticeText: String? { chrome?.noticeText ?? pendingNotice?.text }
    /// The omnibar as the tab left it: its address, or the text typed and left there, with its selection.
    var omnibar: OmnibarState?
    /// The find pill showed, with this query and match-case setting.
    var find: (query: String, matchCase: Bool)?
    var isOmnibarHidden = false
    var wakingAddress: BrowserTabState?
    var httpsFallback = HTTPSUpgradeFallback()
    var recordedURL: URL?
    var recordedTitle: String?
    var finishedURL: URL?

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
        guard state !== chrome.boundState else {
            if tab !== chrome.tab { chrome.tab = tab }
            return
        }
        let leaving = chrome.tab
        if let previous = chrome.boundState {
            save(into: previous)
            previous.chrome = nil
        }
        state.chrome?.boundState = nil  // the tab moved here from another pane's chrome
        state.chrome = chrome
        chrome.boundState = state
        restore(from: state)
        // Before the page binds: the toolbar's modes become this tab's, and the leaving tab's stay as they were.
        chrome.toolbarButtons.bind(tab, modes: state.modes)
        if tab === leaving {
            chrome.reattach()
        } else {
            chrome.parksLeavingPage = true
            chrome.tab = tab
            chrome.parksLeavingPage = false
        }
        restoreFind(state)
    }

    /// The tab that leaves: what its toolbar shows goes into its state.
    private func save(into state: BrowserChromeTabState) {
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
        state.isOmnibarHidden = chrome.isOmnibarHidden
        state.wakingAddress = chrome.wakingAddress
        state.httpsFallback = chrome.httpsFallback
        state.recordedURL = chrome.recordedURL
        state.recordedTitle = chrome.recordedTitle
        state.finishedURL = chrome.finishedURL
    }

    /// The tab that shows: its own toolbar state, before the page binds and renders.
    private func restore(from state: BrowserChromeTabState) {
        chrome.addressBar.controller.restore(state.omnibar ?? OmnibarState())
        chrome.isOmnibarHidden = state.isOmnibarHidden
        chrome.wakingAddress = state.wakingAddress
        chrome.httpsFallback = state.httpsFallback
        chrome.recordedURL = state.recordedURL
        chrome.recordedTitle = state.recordedTitle
        chrome.finishedURL = state.finishedURL
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
