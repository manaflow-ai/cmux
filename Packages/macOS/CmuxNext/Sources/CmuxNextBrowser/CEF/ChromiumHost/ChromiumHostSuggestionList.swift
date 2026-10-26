import AppKit

/// Where a page view's suggestion list sends its answers: the shim's suggestion action in the app
/// (`CEFPaneSuggestionWire`), a recorder in tests.
protocol ChromiumHostSuggestionWire: AnyObject {
    /// The browser whose page the view shows now; nil while it shows none that takes suggestions.
    var suggestionBrowser: Int32? { get }
    /// One action for the rows of `token`, one-way: Chromium answers with the next SHOW or HIDE.
    func send(_ action: ChromiumHostSuggestionAction, token: Int64, row: Int, browser: Int32)
}

/// What draws a suggestion list (``ChromiumHostSuggestionPopup``, a stand-in in tests). It reports
/// the pointer and clicks and draws the one highlight the list gives it.
protocol ChromiumHostSuggestionPresenting: AnyObject {
    /// The pointer moved onto a row (nil: off every row).
    var onHover: ((Int?) -> Void)? { get set }
    /// A row was clicked.
    var onPick: ((Int) -> Void)? { get set }
    /// A row's delete button was clicked.
    var onRemove: ((Int) -> Void)? { get set }
    /// The list closed by a dismiss rule (a click outside it, the window moved or closed).
    var onDismiss: (() -> Void)? { get set }
    /// Shows `suggestions`, or replaces the shown rows, next to `field` (screen) over `window`.
    /// False when it cannot show (the window is not on screen).
    func present(_ suggestions: ChromiumHostSuggestions, highlighted: Int?, field: CGRect, in window: NSWindow) -> Bool
    func highlight(_ row: Int?)
    /// Closes the list; no ``onDismiss``.
    func hide()
    /// The list's frame on the screen, nil while it is not on screen.
    var shownFrame: CGRect? { get }
}

/// A hosted page view's autofill, password and `<datalist>` suggestions (task 061 of
/// plans/cmux-next/chrome-parity/p01-process.md, feature `chromiumHostSuggestions`).
///
/// In the Chromium Host Chrome's Views popup (`PopupViewViews`,
/// chrome/browser/ui/views/autofill/popup/popup_view_views.cc) would open a window in the
/// off-screen browser process, so the fork makes the embedder its controller's view (task 172), as
/// Android's `AutofillPopupViewAndroid` is a view that is not Views. Chrome's split stays: the
/// controller in Chromium owns the rows, the selection and the keys (the focused field keeps
/// them: arrows and Page Up and Down select, Return and Tab accept, Shift+Delete removes, Escape
/// dismisses); this list only draws the rows Chromium sends, follows the selection Chromium moves,
/// and reports the pointer as `PopupViewViews` reports it to its controller: the row under it
/// (Chrome previews the row's values), a click, a delete button, a click outside. It never takes
/// the keys, so the field keeps the caret and typing.
final class ChromiumHostSuggestionList {
    /// The rows on screen and the browser they belong to.
    struct Shown: Equatable {
        let browser: Int32
        var suggestions: ChromiumHostSuggestions
        var highlighted: Int?
    }

    private(set) var shown: Shown?
    private let presenter: any ChromiumHostSuggestionPresenting
    /// The page view the rows' field is in.
    private weak var view: NSView?
    /// The pane's wire, from its latest event.
    private var wire: (any ChromiumHostSuggestionWire)?

    /// `view`: the page view (its rows anchor to its field's rect); `presenter` draws them (nil: the
    /// cmux popup, ``ChromiumHostSuggestionPopup``).
    init(view: NSView, presenter: (any ChromiumHostSuggestionPresenting)? = nil) {
        self.view = view
        self.presenter = presenter ?? ChromiumHostSuggestionPopup()
        self.presenter.onHover = { [weak self] row in self?.hovered(row) }
        self.presenter.onPick = { [weak self] row in self?.picked(row) }
        self.presenter.onRemove = { [weak self] row in self?.removed(row) }
        self.presenter.onDismiss = { [weak self] in self?.dismissed() }
    }

    /// SUGGESTIONS of `browser`, one of the pane's, which answers through `wire`.
    func handle(_ event: ChromiumHostSuggestionEvent, browser: Int32, wire: any ChromiumHostSuggestionWire) {
        self.wire = wire
        switch event {
        case .show(let suggestions):
            show(suggestions, browser: browser, wire: wire)
        case .select(let token, let row):
            guard var shown, shown.browser == browser, shown.suggestions.token == token else { return }
            shown.highlighted = row
            self.shown = shown
            presenter.highlight(row)
        case .hide(let token):
            guard let shown, shown.browser == browser, shown.suggestions.token == token else { return }
            close()
        case .announce(let text):
            announce(text)
        }
    }

    /// The list on the screen, nil while it is not on screen.
    var shownFrame: CGRect? { presenter.shownFrame }

    /// The shown rows' field on the screen, nil with none shown or the page view in no window.
    var fieldOnScreen: CGRect? {
        guard let shown, let view else { return nil }
        return Self.screenRect(of: shown.suggestions.field, in: view)
    }

    /// The page view shows `browser` now (nil: none). Rows of another browser close, as Chrome's popup
    /// hides when its tab hides or leaves the view (`AutofillPopupHideHelper`,
    /// chrome/browser/ui/autofill/autofill_popup_hide_helper.cc); Chromium hears a dismiss while
    /// `isAlive` says the rows' browser lives.
    func shownBrowserChanged(to browser: Int32?, isAlive: (Int32) -> Bool) {
        guard let shown, shown.browser != browser else { return }
        close()
        if isAlive(shown.browser) { wire?.send(.dismiss, token: shown.suggestions.token, row: 0, browser: shown.browser) }
    }

    /// The Chromium Host ended: its rows went with it, and nothing is answered.
    func hostEnded() {
        guard shown != nil else { return }
        close()
    }

    /// Shows the rows while their browser is the page view's, below the field (above it when there is
    /// no room below), and tells Chromium they are on screen. Rows of a tab not shown, or of a page
    /// view out of its window, are dismissed at once, as Chrome hides a popup whose tab hides.
    private func show(_ suggestions: ChromiumHostSuggestions, browser: Int32, wire: any ChromiumHostSuggestionWire) {
        guard wire.suggestionBrowser == browser, let view, let window = view.window,
              let field = Self.screenRect(of: suggestions.field, in: view),
              presenter.present(suggestions, highlighted: suggestions.selected, field: field, in: window) else {
            if shown?.browser == browser { close() }
            wire.send(.dismiss, token: suggestions.token, row: 0, browser: browser)
            return
        }
        shown = Shown(browser: browser, suggestions: suggestions, highlighted: suggestions.selected)
        wire.send(.shown, token: suggestions.token, row: 0, browser: browser)
    }

    private func close() {
        shown = nil
        presenter.hide()
    }

    // MARK: The person's choices

    private func hovered(_ row: Int?) {
        guard var shown, let wire else { return }
        let target = row.flatMap { shown.suggestions.rows.indices.contains($0) && shown.suggestions.rows[$0].selectable ? $0 : nil }
        guard target != shown.highlighted else { return }
        shown.highlighted = target
        self.shown = shown
        presenter.highlight(target)
        wire.send(.select, token: shown.suggestions.token, row: target ?? -1, browser: shown.browser)
    }

    /// A click: Chromium fills the field and hides the rows, or ignores a click within 500 ms of
    /// SHOWN, as Chrome's popup does (`kIgnoreEarlyClicksOnSuggestionsDuration`).
    private func picked(_ row: Int) {
        guard let shown, let wire, shown.suggestions.rows.indices.contains(row), shown.suggestions.rows[row].acceptable else { return }
        wire.send(.accept, token: shown.suggestions.token, row: row, browser: shown.browser)
    }

    /// The delete button: Chromium removes the entry and shows the rows left (a new SHOW) or hides.
    private func removed(_ row: Int) {
        guard let shown, let wire, shown.suggestions.rows.indices.contains(row), shown.suggestions.rows[row].removable else { return }
        wire.send(.remove, token: shown.suggestions.token, row: row, browser: shown.browser)
    }

    private func dismissed() {
        guard let shown, let wire else { return }
        self.shown = nil
        wire.send(.dismiss, token: shown.suggestions.token, row: 0, browser: shown.browser)
    }

    /// Chrome's popup announces an accepted row ("Address filled"); VoiceOver reads it in the window.
    private func announce(_ text: String) {
        guard !text.isEmpty, let element = view?.window ?? view else { return }
        NSAccessibility.post(element: element, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// `field` (the page view's DIP from its top left; the page view's points) on the screen, nil
    /// while the view is in no window.
    static func screenRect(of field: CGRect, in view: NSView) -> CGRect? {
        guard let window = view.window else { return nil }
        let local = view.isFlipped ? field : CGRect(x: field.minX, y: view.bounds.height - field.maxY, width: field.width, height: field.height)
        return window.convertToScreen(view.convert(local, to: nil))
    }
}
