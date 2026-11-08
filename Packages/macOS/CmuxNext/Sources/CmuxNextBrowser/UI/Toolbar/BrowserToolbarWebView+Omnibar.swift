public import AppKit
import Observation

// The omnibar's API (focus, commit, the page's address) and the effects the page's state machine
// asks the host to run: queries, editing boundaries, beeps, history notes.
extension BrowserToolbarWebView {
    // MARK: Reading the omnibar

    /// True from focus until commit, cancel or blur (and from `focus()` until the page reports it).
    public var isEditing: Bool { status.isEditing || focusPending }

    /// The suggestion list is open (Ctrl-N/P/J/K move its selection).
    public var isShowingSuggestions: Bool { status.isPopupOpen }

    /// The text the bar shows now (the compact URL at rest, the full address or the typed text
    /// while editing), as the page reported it last.
    public var displayedText: String { status.text }

    /// The page-info chip, for anchoring the bubble (the bar when the chip is not laid out yet).
    public var pageInfoAnchor: NSView { anchor("chip") ?? anchor("omnibar") ?? self }

    // MARK: Focus

    /// The focus coordinator's way in (Cmd-L, a new browser tab): focuses the field with the full
    /// URL selected (Chromium `SetFocus(true)`); again while focused selects everything again.
    public func focus() { giveKeys(source: "keyboard") }

    /// The focus coordinator's return to a tab left from its address bar: focuses the field with
    /// the selection it had when focus left.
    public func restoreFocus() {
        // Nothing to restore only while the field edits with the keys here: the page's status can
        // lag a blur the host just sent (another tab's field took the keys), so the responder decides.
        if isEditing, let content, window?.firstResponder === content.focusView { return }
        giveKeys(source: "programmatic")
    }

    /// Gives the web view the keys and tells the page where the focus came from.
    /// A file dropped from Finder (`AddressBarView+Drop`: `.fileURL` on the pasteboard, as its URL
    /// string, Chromium's `CONVERT_FILENAMES`): the field takes the keys and the text, all selected;
    /// nothing loads until Enter. The page's own drops (text, links) never reach here.
    func acceptFileDrop(_ url: URL) {
        guard !isReadOnly, url.isFileURL else { return }
        giveKeys(source: "programmatic")
        send(BrowserToolbarHostEvent.dropped(url.absoluteString))
    }

    func giveKeys(source: String) {
        allowsKeys = true
        focusPending = !status.isEditing
        if let content, let window, window.firstResponder !== content.focusView {
            window.makeFirstResponder(content.focusView)
        }
        send(BrowserToolbarHostEvent.focus(source))
        if pendingSearch {
            pendingSearch = false
            send(BrowserToolbarHostEvent.searchWithDefaultEngine)
        }
    }

    /// The web view resigned first responder (a click on the page, another pane): editing ends
    /// (`controlTextDidEndEditing`).
    func keysResigned() {
        focusPending = false
        guard allowsKeys || status.isEditing else { return }
        allowsKeys = false
        send(BrowserToolbarHostEvent.blur)
    }

    /// Opt-Cmd-F (Chrome's Search the Web): a search with the default engine in the focused field.
    /// A focus that lands later (a Chromium page window giving key back) starts it then.
    public func beginSearch() {
        guard isEditing else { return pendingSearch = true }
        send(BrowserToolbarHostEvent.searchWithDefaultEngine)
    }

    /// Return with a disposition while the field is editing (the `omnibar.openIn…Tab` actions):
    /// commits the highlighted row or the typed text to `disposition`. False when not editing.
    @discardableResult
    public func commit(_ disposition: OmnibarDisposition) -> Bool {
        guard isEditing, !isReadOnly else { return false }
        send(BrowserToolbarHostEvent.enter(disposition))
        return true
    }

    // MARK: The page's address

    /// Shows the page's URL. While editing, typed text never changes (the page keeps it).
    public func update(url: URL?, security: BrowserSecurityState) {
        if url != reportedURL {
            reportedURL = url
            onPageURLChange?(url)
        }
        self.security = security
    }

    /// Shows the page's URL again after a commit that loaded nothing in this tab.
    public func showPageURL() { send(BrowserToolbarHostEvent.showPageURL) }

    /// Verification hook (`debug.omnibar_type`): focuses the field, types `text` through the page's
    /// input and (with `commit`) presses Return there. False when the row has no page yet.
    @discardableResult
    public func debugTypeAndCommit(_ text: String, commit: Bool = true) -> Bool {
        guard content != nil else { return false }
        focus()
        send(BrowserToolbarHostEvent.debugType(text, commit: commit))
        return true
    }

    // MARK: Effects

    func perform(_ effect: OmnibarPageEffect) {
        switch effect {
        case .query(let generation, let text): runQuery(generation: generation, text: text)
        case .keywordInput(let extensionID, let text, let generation): runKeywordQuery(extensionID, text: text, generation: generation)
        case .cancelQuery:
            queryTask?.cancel()
            queryTask = nil
        case .began: onEvent?(.didBeginEditing)
        case .ended(let reason):
            allowsKeys = false
            focusPending = false
            status.isEditing = false
            // A read-only row (a sign-in window) never navigates, whatever the page reports.
            onEvent?(.didEndEditing(isReadOnly && reason.navigates ? .cancel : reason))
        case .beep: NSSound.beep()
        case .deleteSuggestion(let url): suggestionEngine.deleteSuggestion(url)
        case .typedNavigation(let url): suggestionEngine.noteTyped(url)
        case .hostTypoFixed(let host):
            suggestionEngine.resolver.hostTypoMemory.recordFix(of: host)
            setNeedsPush()
        case .typedHTTPSUpgrade(let url): onTypedHTTPSUpgrade?(url)
        case .copyAnswer(let answer):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
        case .keywordStarted, .keywordEnded: onKeywordSession?(effect)
        }
    }

    /// Rows for typed text as the engine makes them, relayed to the page. A typed key costs one
    /// engine request (the engine's own work is bounded; nothing here walks the open tabs).
    private func runQuery(generation: UInt64, text: String) {
        queryTask?.cancel()
        gate.begin(generation)
        guard !isReadOnly else { return }
        var request = OmniboxRequest(text: text, generation: generation, gate: gate, tabKey: tabKey)
        request.allowsChromiumSchemes = allowsChromiumSchemes
        let deliveries = suggestionEngine.deliveries(for: request)
        queryTask = Task { [weak self] in
            for await delivery in deliveries {
                guard !Task.isCancelled, let self else { return }
                switch delivery {
                case .local(let rows): self.send(BrowserToolbarHostEvent.suggestions(generation, rows))
                case .more(let rows, let capacity): self.send(BrowserToolbarHostEvent.moreSuggestions(generation, rows, capacity: capacity))
                }
            }
        }
    }

    private func runKeywordQuery(_ extensionID: String, text: String, generation: UInt64) {
        queryTask?.cancel()
        gate.begin(generation)
        let suggest = keywordSuggest
        queryTask = Task { [weak self] in
            let rows = await suggest(extensionID, text)
            guard !Task.isCancelled else { return }
            self?.send(BrowserToolbarHostEvent.suggestions(generation, rows))
        }
    }

    // MARK: The resolver's settings

    /// What the page's resolver and reducer need (`OmnibarConfig`).
    var omnibarConfig: [String: Any] {
        let resolver = suggestionEngine.resolver
        // Extension keywords first (an extension's own keyword wins), then the search engines'.
        let keywords = keywordSource() + OmnibarKeyword.searchEngines(default: resolver.searchEngine)
        return [
            "readOnly": isReadOnly,
            "allowsChromiumSchemes": allowsChromiumSchemes,
            "home": NSHomeDirectory(),
            "showFullURLs": suggestionEngine.display.showsFullURLs,
            "searchEngine": resolver.searchEngine.wire,
            "keywords": keywords.map(\.wire),
            "intranetHosts": resolver.intranetHosts.all,
            "fixedTypoHosts": resolver.hostTypoMemory.all,
            "upward": toolbarOpensUpward,
            "searchKeywordFormat": Strings.searchKeyword(engine: "%@"),
        ]
    }

    /// Follows `suggestionEngine.display.showsFullURLs`, the engine's settings (its search engine),
    /// and the bar's look (cmux.json
    /// `browser.omnibar`: material, opacity, radius, tint, shadow; OmnibarViews followed it live)
    /// into the page and its glass, now and on every change (one loop per engine; a new engine
    /// replaces it). A push of an unchanged state is skipped.
    func followDisplay() {
        displayLoop?.cancel()
        displayLoop = ObservationLoop { [weak self] in
            guard let self else { return }
            _ = suggestionEngine.display.showsFullURLs
            _ = suggestionEngine.display.configurationRevision
            _ = OmnibarGlassAppearance.current.look
            setNeedsPush()
            updateBarGlass()
            // An open card takes the new look and density too.
            followLayout()
        }
    }

    // MARK: The field's context menu

    /// The page's menu for the field, with the bar's own items: Paste and Go (or Paste and
    /// Search), Always Show Full URLs and Manage Search Engines.
    func editContextMenu(_ menu: NSMenu) {
        // A right-click on a resting field focuses it first (all selected), as AddressField did, so
        // its menu offers Paste and Go: the page's own focus request arrives after this menu.
        // The focus given here counts at once (`focusPending`): this first menu is built before the
        // page reports it editing, and must not wait for that report.
        let focusedNow = !isEditing && !isReadOnly && menuEventIsOnField()
        if focusedNow { giveKeys(source: "mouse") }
        if let title = pasteAndGoTitle(editing: isEditing || focusedNow) {
            let item = NSMenuItem(title: title, action: #selector(pasteAndGo(_:)), keyEquivalent: "")
            item.target = self
            let paste = menu.items.firstIndex { $0.action == #selector(NSText.paste(_:)) }
            menu.insertItem(item, at: paste.map { $0 + 1 } ?? 0)
        }
        let display = suggestionEngine.display
        var extra: [NSMenuItem] = []
        if display.setShowsFullURLs != nil {
            let item = NSMenuItem(title: Strings.alwaysShowFullURLs, action: #selector(toggleFullURLs(_:)), keyEquivalent: "")
            item.target = self
            item.state = display.showsFullURLs ? .on : .off
            extra.append(item)
        }
        if display.manageSearchEngines != nil {
            let item = NSMenuItem(title: Strings.manageSearchEngines, action: #selector(manageSearchEngines(_:)), keyEquivalent: "")
            item.target = self
            extra.append(item)
        }
        guard !extra.isEmpty else { return }
        if !menu.items.isEmpty { menu.addItem(.separator()) }
        extra.forEach(menu.addItem)
    }

    /// The event opening the menu is over the field's text area (the page's `text` rect).
    private func menuEventIsOnField() -> Bool {
        guard let event = NSApp.currentEvent, event.window === window, let field = anchor("text") else { return false }
        return field.bounds.contains(field.convert(event.locationInWindow, from: nil))
    }

    private func pastedText() -> String? {
        let text = pasteboard.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    /// "Paste and Go" or "Paste and Search" for the pasteboard's text, while the field edits (the
    /// menu is the field editor's, as AddressField's was); nil otherwise.
    func pasteAndGoTitle(editing: Bool) -> String? {
        guard !isReadOnly, editing, let text = pastedText(), let destination = suggestionEngine.resolver.destination(for: text) else { return nil }
        if case .search = destination { return Strings.pasteAndSearch }
        return Strings.pasteAndGo
    }

    @objc private func pasteAndGo(_ sender: Any?) {
        guard !isReadOnly, let text = pastedText() else { return }
        send(BrowserToolbarHostEvent.pasteAndGo(text))
    }

    @objc private func toggleFullURLs(_ sender: Any?) {
        let display = suggestionEngine.display
        display.setShowsFullURLs?(!display.showsFullURLs)
    }

    @objc private func manageSearchEngines(_ sender: Any?) {
        suggestionEngine.display.manageSearchEngines?()
    }
}

// Extension keyword sessions (`chrome.omnibox`) between the omnibar and its page, the same for a
// browser tab's toolbar and a popup window (`OmnibarTabBinding`). Only Chromium pages provide
// keywords; Enter reaches the page through `OmnibarEvent` `.keyword`.
extension BrowserToolbarWebView {
    /// Offers `tab`'s extension keywords and tells its extensions when a session starts and ends.
    ///
    /// - Parameter tab: The page whose profile's extensions answer.
    public func bindKeywords(of tab: any BrowserTab) {
        let provider = tab as? any BrowserOmniboxKeywordProviding
        keywordSource = { [weak provider] in provider?.omniboxKeywords() ?? [] }
        keywordSuggest = { [weak provider] extensionID, text in
            await provider?.omniboxKeywordSuggestions(extensionID, text: text) ?? []
        }
        onKeywordSession = { [weak provider] effect in
            switch effect {
            case .keywordStarted(let extensionID): provider?.omniboxKeywordStarted(extensionID)
            case .keywordEnded(let extensionID): provider?.omniboxKeywordEnded(extensionID)
            default: break
            }
        }
    }
}
