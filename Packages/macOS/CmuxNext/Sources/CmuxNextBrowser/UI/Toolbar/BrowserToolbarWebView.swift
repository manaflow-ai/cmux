public import AppKit
import CmuxNextCompat
public import CmuxNextDesign
import CmuxNextPages

/// The browser toolbar row, drawn by a React page (webviews/src/pages/browser-toolbar, wire in
/// webviews/src/browser-chrome/toolbar/wire.ts): Back, Forward and Reload, the omnibar (page-info
/// chip, field, badges, bookmark star), the pinned extension actions and the Extensions button, the
/// trailing buttons and More. One page per row: a browser pane (all its tabs), a popup window, the
/// Markdown tab's bar.
///
/// The page owns the omnibar's state machine (../omnibox reduce) with one resting state per tab
/// slot (`tabSlot`), and the field (a real `<input>`, so IME, selection and undo are the engine's).
/// This view pushes the page's state once per run-loop pass at most, runs the effects the page
/// sends (queries, commits, beeps), relays the suggestion card (`OmniboxPopupPanel`), and lays an
/// invisible anchor view over each control the page reported (`ToolbarAnchorView`), so menus and
/// bubbles open where they did. It keeps the `AddressBarView` API the App and the chrome use.
///
/// Keys: the web view takes first responder only while the field edits (`acceptsKeyFocus`), so a
/// press on a toolbar button leaves the keys on the browser page. A press on the field asks for
/// them (`requestFocus`); Cmd-L and a new tab give them (`focus()`).
public final class BrowserToolbarWebView: NSView {
    // MARK: The omnibar's hooks (AddressBarView's API)

    /// Editing began or ended. The chrome loads a committed URL; the App decides where focus goes.
    public var onEvent: ((OmnibarEvent) -> Void)?
    /// The page-info chip was pressed: the owner opens or closes Page Info at `pageInfoAnchor`.
    public var onPageInfo: (() -> Void)?
    /// The row's other controls (navigation, trailing buttons, extensions): the owner runs them.
    var onCommand: ((BrowserToolbarPageCommand) -> Void)?
    /// The page laid its controls out again (the chrome follows the collapse and Forward).
    var onLayout: ((BrowserToolbarLayoutReport) -> Void)?
    /// The omnibar's status changed (editing, the card).
    var onStatusChange: (() -> Void)?

    /// Pushes again when the engine's display settings change (`followDisplay`).
    var displayLoop: ObservationLoop?

    public var suggestionEngine: OmniboxSuggestionEngine {
        didSet {
            if suggestionEngine !== oldValue { followDisplay() }
            setNeedsPush()
        }
    }

    /// The tab this omnibar belongs to: never offered as its own Switch to Tab row.
    public var tabKey: String?
    /// A bar that shows the page's address but never edits it (a system sign-in window).
    public var isReadOnly = false { didSet { if isReadOnly != oldValue { setNeedsPush() } } }
    /// Chromium tabs also load `chrome://` and `chrome-extension://` pages.
    public var allowsChromiumSchemes = false { didSet { if allowsChromiumSchemes != oldValue { setNeedsPush() } } }
    /// Extension omnibox keywords of the tab (`chrome.omnibox`), read on every push.
    public var keywordSource: () -> [OmnibarKeyword] = { [] } { didSet { setNeedsPush() } }
    /// Suggestions of an extension keyword session, from the tab.
    public var keywordSuggest: (_ extensionID: String, _ text: String) async -> [BrowserSuggestion] = { _, _ in [] }
    /// Keyword session boundaries (`keywordStarted`, `keywordEnded`), for the tab's extension.
    public var onKeywordSession: ((OmnibarPageEffect) -> Void)?
    /// The page's title, for a drag of the address out of the chip.
    public var pageTitle: (() -> String?)?
    /// The site icon of a page suggestion row (the App names the site's icon address). Nil: kind glyphs.
    public var rowFavicon: ((URL) async -> NSImage?)? { didSet { popup.faviconSource = rowFavicon } }
    /// Enter loads typed text over https that may fall back to http (`HTTPSUpgradeFallback`).
    public var onTypedHTTPSUpgrade: ((URL) -> Void)?
    /// The page's URL changed (the host refreshes the bookmark star).
    public var onPageURLChange: ((URL?) -> Void)?
    /// The bookmark star was pressed; the argument is the anchor for the edit bubble.
    public var onBookmarkStar: ((NSView) -> Void)?
    /// A press on the focus mode badge: the host leaves focus mode.
    public var onFocusModeBadgePress: (() -> Void)?
    /// The machine chip's menu and the browser profile badge's menu.
    public var machineBadgeMenu: (() -> NSMenu?)?
    public var profileBadgeMenu: (() -> NSMenu?)?

    // MARK: What the row shows (the owner sets it; each change pushes once per pass)

    /// The tab slot shown now: each keeps its own omnibar (`BrowserChromeTabState.slot`).
    var tabSlot = "default" { didSet { if tabSlot != oldValue { setNeedsPush() } } }
    /// The draft the shown tab brought from another pane (`BrowserChromeTabState.omnibarDraft`); the
    /// page rests on it when it has no slot of its own for the tab.
    var tabDraft: OmnibarDraft? { didSet { if tabDraft != oldValue { setNeedsPush() } } }
    /// Back, Forward, Reload and the trailing buttons (false: the omnibar alone, a popup window).
    var showsButtons: Bool { didSet { if showsButtons != oldValue { setNeedsPush() } } }
    var navigation = ToolbarNavigation() { didSet { if navigation != oldValue { setNeedsPush() } } }
    /// The trailing buttons as the page draws them (`BrowserToolbarButtons.wire`).
    var buttonsWire: [[String: Any]] = [] { didSet { setNeedsPush() } }
    /// The pinned extension actions and the Extensions button (`ExtensionActions.wire`).
    var extensionsWire: [String: Any] = ["shows": false, "pinned": [Any]()] { didSet { setNeedsPush() } }
    /// Page Info is open (the chip draws pressed).
    var pageInfoOpen = false { didSet { if pageInfoOpen != oldValue { setNeedsPush() } } }
    var bookmarkStar = BookmarkStarState.hidden { didSet { if bookmarkStar != oldValue { setNeedsPush() } } }
    var focusModeBadge: String? { didSet { if focusModeBadge != oldValue { setNeedsPush() } } }
    var shownProfileBadge: BrowserProfileBadge?
    var shownMachineBadge: (text: String, help: String)?

    // MARK: The page

    /// Makes the row's React page; tests pass their own.
    var makeWebContent: @MainActor () -> (any BrowserChromeWebContent)? = { BrowserChromeWebHost(.browserToolbar) }
    private(set) var content: (any BrowserChromeWebContent)?
    /// The suggestion card, made when it first opens.
    private(set) lazy var popup: OmniboxPopupPanel = {
        let popup = OmniboxPopupPanel()
        popup.onHover = { [weak self] row, pointer in self?.send(BrowserToolbarHostEvent.rowHover(row, pointer: pointer)) }
        popup.onPick = { [weak self] row, meta, shift, alt in
            self?.send(BrowserToolbarHostEvent.rowClick(row, meta: meta, shift: shift, alt: alt))
        }
        popup.faviconSource = rowFavicon
        return popup
    }()
    /// The omnibar as the page reported it last.
    public internal(set) var status = OmnibarStatus()
    /// Where the page drew its controls last.
    private(set) var layoutReport = BrowserToolbarLayoutReport()
    private var anchors: [String: ToolbarAnchorView] = [:]
    /// The page shows `reportedURL` (and its lock) at rest.
    var reportedURL: URL? { didSet { if reportedURL != oldValue { setNeedsPush() } } }
    var security: BrowserSecurityState = .none { didSet { if security != oldValue { setNeedsPush() } } }

    // MARK: Pushes and events

    private var revision = 0
    private var pushScheduled = false
    private var lastPushed: NSDictionary?
    /// Host requests the page has not acked, oldest first (`ToolbarHostEvent`), each with the binding
    /// it was queued under: the page drops a tab-scoped one of an older binding.
    private var events: [(seq: Int, binding: Int, event: [String: Any])] = []
    private var nextSeq = 0
    /// The tab binding: it moves on every tab shown (`showTab`) and let go (`release`), and rides in
    /// the state. The page stamps each command with the binding of the state it applied last, and a
    /// tab-scoped command of another binding is dropped before it runs (`admits`): a commit typed in
    /// the tab that left never navigates the tab that came.
    private(set) var binding = 0
    /// SF Symbol profile icons drawn for the page (`badgesWire`).
    let profileSymbols = PageSymbolImages()

    // MARK: Keys and queries

    /// The web view may take first responder: the field edits, or a focus is on its way.
    var allowsKeys = false
    /// A focus was given and the page has not reported editing yet (`isEditing` answers true).
    var focusPending = false
    /// `beginSearch()` ran before the field had focus: the next focus starts the search.
    var pendingSearch = false
    /// The newest query generation: work for an older one stops delivering.
    let gate = OmniboxGenerationGate()
    var queryTask: Task<Void, Never>?

    public init(suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine(), showsButtons: Bool = true) {
        self.suggestionEngine = suggestionEngine
        self.showsButtons = showsButtons
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        setAccessibilityElement(true)
        setAccessibilityRole(.toolbar)
        followDisplay()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    nonisolated public override var isFlipped: Bool { true }

    // MARK: The page's lifetime

    /// The page is made when the row first joins a window (a chrome made off screen costs no web view).
    public override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil {
            makeContentIfNeeded()
        } else {
            popup.dismiss()
        }
    }

    private func makeContentIfNeeded() {
        guard content == nil, let made = makeWebContent() else { return }
        made.onMessage = { [weak self] kind, params in self?.received(kind, params) }
        made.acceptsKeyFocus = { [weak self] in self?.allowsKeys ?? false }
        made.onResignedKeys = { [weak self] in self?.keysResigned() }
        made.contextMenuEditor = { [weak self] menu in self?.editContextMenu(menu) }
        let view = made.view
        view.translatesAutoresizingMaskIntoConstraints = true
        view.autoresizingMask = [.width, .height]
        view.frame = bounds
        addSubview(view, positioned: .below, relativeTo: nil)
        content = made
        lastPushed = nil
        setNeedsPush()
    }

    /// The row is going away for good (its pane or window closed): the page closes.
    public func close() {
        queryTask?.cancel()
        queryTask = nil
        displayLoop?.cancel()
        displayLoop = nil
        popup.close()
        content?.close()
        content = nil
    }

    // MARK: Pushing state

    /// Pushes the page's state on the next run-loop pass: several changes in one turn (a tab switch
    /// sets a dozen properties) reach the page as one state.
    func setNeedsPush() {
        guard !pushScheduled else { return }
        pushScheduled = true
        MainRunLoopBlock.perform { [weak self] in self?.pushNow() }
    }

    // perf-hot: 1ms browser-toolbar-push
    /// Pushes now when anything changed since the last push.
    func pushNow() {
        pushScheduled = false
        guard let content else { return }
        let state = wireState()
        let compared = NSDictionary(dictionary: state)
        if let lastPushed, lastPushed.isEqual(compared) { return }
        lastPushed = compared
        revision += 1
        var pushed = state
        pushed["revision"] = revision
        content.push(pushed)
    }

    /// Queues a one-shot request for the page; it rides in every state until the page acks it.
    func send(_ event: [String: Any]) {
        nextSeq += 1
        events.append((nextSeq, binding, event))
        setNeedsPush()
    }

    /// Another tab binds (or the shown one is let go): what the page sends from here on under an older
    /// binding is the old tab's and is dropped; its running query and its card go.
    func beginBinding() {
        binding += 1
        queryTask?.cancel()
        queryTask = nil
        popup.dismiss()
        setNeedsPush()
    }

    /// The state the next push sends (`cmux.browser-toolbar.state`).
    func wireState() -> [String: Any] {
        let site = PageInfoSite(url: reportedURL, security: security)
        let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        let look = OmnibarGlassLook.current
        // The bar's coverage raised to the text's legibility floor, which needs the window's own
        // opacity: only the host knows it (`AddressBarSurface.resolvedCoverage`).
        let coverage: Double = performWithTheme { Palette.addressBar.resolvedCoverage(look.backgroundOpacity) }
        return [
            "tab": tabSlot,
            "draft": tabDraft?.wire ?? NSNull(),
            "url": reportedURL?.absoluteString ?? NSNull(),
            "site": site.isEmpty ? NSNull() : site.wire,
            "title": pageTitle?() ?? NSNull(),
            "navigation": ["canGoBack": navigation.canGoBack, "canGoForward": navigation.canGoForward, "loading": navigation.loading],
            "showsButtons": showsButtons,
            "bookmark": bookmarkStar.wire,
            "pageInfoOpen": pageInfoOpen,
            "badges": badgesWire,
            "extensions": extensionsWire,
            "buttons": buttonsWire,
            "omnibar": omnibarConfig,
            "look": ["material": look.material.rawValue, "backgroundOpacity": look.backgroundOpacity, "coverage": coverage],
            "metrics": ToolbarRowMetrics.wire(scale: scale, withButtons: showsButtons, barTop: barTop(scale: scale)),
            "binding": binding,
            "events": events.map { ["seq": $0.seq, "binding": $0.binding, "event": $0.event] as [String: Any] },
        ]
    }

    /// The bar's top in the row: under the top padding, or, with the toolbar at the bottom of its
    /// pane, the same distance above the row's bottom.
    private func barTop(scale: CGFloat) -> CGFloat {
        let top = ToolbarRowMetrics.barTop(scale: scale, withButtons: showsButtons)
        guard toolbarOpensUpward, bounds.height > 0 else { return top }
        return bounds.height - top - ToolbarRowMetrics.barHeight
    }

    /// The badges part of the state: focus mode text, profile monogram and color, machine name.
    var badgesWire: [String: Any] {
        var badges: [String: Any] = [:]
        badges["focusMode"] = focusModeBadge.map { ["text": $0] } ?? NSNull()
        if let badge = shownProfileBadge {
            let color: Any = badge.color.map { color in performWithTheme { GlassBackdropPayload.css(color.fill.cgColor) } } ?? NSNull()
            // A profile icon is an emoji, a letter, or an SF Symbol name, which the page cannot draw:
            // the symbol goes as a template image (`PageSymbolImages`, as the agent pane draws harness symbols).
            let symbol: Any = profileSymbols.dataURL(badge.monogram) ?? NSNull()
            badges["profile"] = ["monogram": badge.monogram, "symbol": symbol, "color": color, "name": badge.name]
        } else {
            badges["profile"] = NSNull()
        }
        badges["machine"] = shownMachineBadge.map { ["text": $0.text, "help": $0.help] } ?? NSNull()
        return badges
    }

    // MARK: The page's messages

    func received(_ kind: String, _ params: [String: Any]) {
        guard kind == "command", let command = BrowserToolbarPageCommand(wire: params),
              admits(command, stamp: BrowserToolbarPageCommand.int(params["binding"])) else { return }
        handle(command)
    }

    /// Whether `command`, made under binding `stamp`, may run: a tab-independent one always; one
    /// that acts on the shown tab only when it was made for the binding shown now.
    func admits(_ command: BrowserToolbarPageCommand, stamp: Int?) -> Bool {
        command.isTabIndependent || stamp == binding
    }

    func handle(_ command: BrowserToolbarPageCommand) {
        switch command {
        case .requestFocus: giveKeys(source: "mouse")
        case .effect(let effect): perform(effect)
        case .status(let next): statusChanged(next)
        case .popup(let rows, let highlighted, let upward): showPopup(rows, highlighted: highlighted, upward: upward)
        case .layout(let report): applyLayout(report)
        case .ack(let seq): events.removeAll { $0.seq <= seq }
        case .pageInfo: onPageInfo?()
        case .bookmark: onBookmarkStar?(anchor("star") ?? self)
        case .focusModeBadge: onFocusModeBadgePress?()
        case .profileBadge: popUp(profileBadgeMenu?(), at: "badge:profile")
        case .machineBadge: popUp(machineBadgeMenu?(), at: "badge:machine")
        default: onCommand?(command)
        }
    }

    private func statusChanged(_ next: OmnibarStatus) {
        let wasEditing = status.isEditing
        status = next
        if next.isEditing { focusPending = false }
        if !next.isEditing, wasEditing { allowsKeys = false }
        if next.isEditing, pendingSearch {
            pendingSearch = false
            send(BrowserToolbarHostEvent.searchWithDefaultEngine)
        }
        onStatusChange?()
    }

    // MARK: Anchors

    /// The view over the control the page reported as `key` (nil while it is hidden).
    func anchor(_ key: String) -> NSView? {
        guard let view = anchors[key], view.superview != nil else { return nil }
        return view
    }

    private func applyLayout(_ report: BrowserToolbarLayoutReport) {
        layoutReport = report
        for (key, view) in anchors where report.rects[key] == nil {
            view.removeFromSuperview()
            anchors[key] = nil
        }
        for (key, rect) in report.rects {
            let view = anchors[key] ?? ToolbarAnchorView(key: key)
            anchors[key] = view
            if view.superview !== self { addSubview(view) }
            if view.frame != rect { view.frame = rect }
        }
        if status.isPopupOpen { popup.follow(bar: omnibarRectInScreen) }
        onLayout?(report)
    }

    /// The omnibar's rect on screen (the card hangs under it).
    var omnibarRectInScreen: NSRect? {
        guard let window, let bar = anchor("omnibar") else { return nil }
        return window.convertToScreen(bar.convert(bar.bounds, to: nil))
    }

    /// Opens `menu` under the control `key` (a badge's menu).
    func popUp(_ menu: NSMenu?, at key: String) {
        guard let menu, let view = anchor(key) ?? anchor("omnibar"), view.window != nil else { return }
        menu.popUp(positioning: nil, at: CmuxPopoverAnchor.menuPoint(for: menu, in: view, gap: 4), in: view)
    }

    // MARK: The suggestion card

    private func showPopup(_ rows: [BrowserSuggestion], highlighted: Int?, upward: Bool) {
        guard !rows.isEmpty, let window, let bar = omnibarRectInScreen else { return popup.dismiss() }
        popup.show(rows, highlighted: highlighted, upward: upward, bar: bar, in: window, themeOf: self)
    }

    public override func layout() {
        super.layout()
        // The bar's top depends on the row's height at the bottom of a pane.
        if toolbarOpensUpward { setNeedsPush() }
    }

    public override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        setNeedsPush()
    }
}

extension PageInfoSite {
    /// An empty or blank page: the chip shows nothing.
    var isEmpty: Bool {
        if case .empty = kind { return true }
        return false
    }
}

/// Back, Forward and Reload as the row draws them.
struct ToolbarNavigation: Equatable {
    var canGoBack = false
    var canGoForward = false
    /// Reload shows Stop.
    var loading = false
}

extension BookmarkStarState {
    var wire: String {
        switch self {
        case .hidden: "hidden"
        case .off: "off"
        case .on: "on"
        }
    }
}
