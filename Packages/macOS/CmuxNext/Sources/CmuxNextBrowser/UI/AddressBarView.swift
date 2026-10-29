public import AppKit
import CmuxNextDesign
import CmuxNextInput
public import CmuxNextWakeups

/// The omnibar, drawn by `OmnibarStyle`: a gray
/// 8 pt pill with a page-info chip, the compact URL with the host at full
/// strength, and on focus the full URL, all selected. While suggestions show,
/// the bar turns into the top of a white card that continues as the dropdown.
/// Behavior is one state machine (`OmnibarReducer`, run by
/// `OmnibarController`); this view only turns AppKit events into
/// `OmnibarInput` and draws the bar and chip from the state.
public final class AddressBarView: NSView {
    /// Editing began or ended. The chrome loads a committed URL; the App
    /// decides where focus goes.
    public var onEvent: ((OmnibarEvent) -> Void)?

    /// The page-info button was pressed (click, Space or Return on it).
    /// The chrome opens or closes the page info bubble, anchored at
    /// `pageInfoAnchor`.
    public var onPageInfo: (() -> Void)? {
        get { chip.onPress }
        set { chip.onPress = newValue }
    }

    /// The page-info button, for anchoring the bubble.
    public var pageInfoAnchor: NSView { chip }

    public var suggestionEngine: OmniboxSuggestionEngine {
        didSet {
            controller.send(.searchEngineChanged)
            if suggestionEngine !== oldValue { followDisplay() }
        }
    }

    let pill = OmnibarPillView()
    let backdrop = OmnibarCardTopView()
    let chip = PageInfoChipButton()
    let field = AddressField()
    private let machineBadgeView = MachineBadgeView()
    private let profileBadgeView = ProfileBadgeView()
    let starButton = BookmarkStarButton()
    /// The trailing badges (browser focus mode, browser profile, machine, bookmark star); hidden ones take no room.
    let focusModeBadgeView = FocusModeBadgeView()
    private var focusModeBadgeWanted = false
    private(set) lazy var badges = NSStackView(views: [focusModeBadgeView, profileBadgeView, machineBadgeView, starButton])
    /// The bar's token sizes (read in the density binding, so a change lays out again).
    private(set) var barHeight: CGFloat = 0, chipSide: CGFloat = 0
    let panel = OmniboxSuggestionPanel()
    let density = DensityBinding()
    /// The app's one main-thread scheduler: the bar's setting follows apply on it.
    let mainWork: MainWorkScheduler
    /// The node the bar's repaints wait on (R-appear): its tab's, set by the chrome, or a root that stays
    /// visible for a bar in no tab (a popup's toolbar, the Markdown bar), whose repaints run at once.
    var visibilityNode = VisibilityNode(root: "browser.omnibar.standalone", own: .visible) {
        didSet {
            pill.visibilityNode = visibilityNode
            field.visibilityNode = visibilityNode
        }
    }
    /// The suggestion engine's "Always show full URLs" (``followDisplay()``).
    var displayWatch: FrameObservation<Bool>?

    private var reportedURL: URL?
    /// Whether the field's cursor rects were last built for editing.
    private var cursorRectsEditing = false
    /// The page's title, for a drag of the address out of the bar.
    public var pageTitle: (() -> String?)?
    /// The site icon of a page suggestion row, fetched as the tab fetches
    /// favicons (the App names the site's icon address). Nil: kind glyphs.
    public var rowFavicon: ((URL) async -> NSImage?)? {
        get { panel.faviconSource }
        set { panel.faviconSource = newValue }
    }
    /// Enter loads typed text over https that may fall back to http
    /// (`HTTPSUpgradeFallback`); the chrome watches the load.
    public var onTypedHTTPSUpgrade: ((URL) -> Void)?
    /// The page's URL changed (the host refreshes the bookmark star).
    public var onPageURLChange: ((URL?) -> Void)?
    /// Bench marks (`debug.omnibar_bench`): the press path's stages, nil
    /// outside a bench run.
    public var benchProbe: ((String) -> Void)? {
        didSet {
            field.probe = benchProbe
            controller.probe = benchProbe
        }
    }
    /// Set by `focus()` for the responder change it causes.
    var pendingFocusSource: OmnibarInput.FocusSource?
    /// `beginSearch()` ran before the field had focus: the next focus starts the search.
    private var pendingSearch = false
    private var security: BrowserSecurityState = .none
    /// Built in init, where `onEffect` is set (no IUO; lazy because its closures capture self).
    private(set) lazy var controller = OmnibarController(
        field: field,
        popup: self,
        // Once the view is gone (a controller that outlives it): the engine's plain
        // resolver, as `suggest` answers `finished`.
        resolver: { [weak self, suggestionEngine] in self?.resolver ?? suggestionEngine.resolver },
        suggest: { [weak self] request in
            guard let self, !isReadOnly else { return OmniboxDelivery.finished }
            var request = request
            request.tabKey = tabKey
            request.allowsChromiumSchemes = allowsChromiumSchemes
            return suggestionEngine.deliveries(for: request)
        },
        mainWork: mainWork
    )

    /// A bar that shows the page's address but never edits it: a system
    /// sign-in window (`WebAuthSessionWindow`), where navigating away would
    /// lose the sign-in. The same view, chip, URL styling, selection, copy
    /// and keys as an editable bar; typing, paste, Return, Paste and Go and
    /// suggestions do nothing. False for browser tabs and page popups.
    public var isReadOnly = false {
        didSet {
            field.isEditable = !isReadOnly
            field.isSelectable = true
            // The omnibar shows focus through its own capsule, never AppKit's ring.
            field.focusRingType = .none
        }
    }

    /// The text the bar shows now (the compact URL at rest, the full address
    /// or the typed text while editing).
    public var displayedText: String { field.currentText }

    /// Whether `key` reaches the state machine. A read-only bar keeps the
    /// keys that select or leave (Cmd-A, Cmd-L, Home, Escape).
    func admits(_ key: OmnibarInput.Key) -> Bool {
        guard isReadOnly else { return true }
        switch key {
        case .escape, .selectAll, .focusLocation, .home: return true
        default: return false
        }
    }

    /// Chromium tabs also load `chrome://` and `chrome-extension://` pages
    /// (Chromium's own WebUI and extension pages, which WebKit cannot show).
    public var allowsChromiumSchemes = false

    /// Extension omnibox keywords of the tab (`chrome.omnibox`), read on
    /// every reducer step (the tab caches them).
    public var keywordSource: () -> [OmnibarKeyword] = { [] }

    /// Suggestions of an extension keyword session, from the tab.
    public var keywordSuggest: (_ extensionID: String, _ text: String) async -> [BrowserSuggestion] {
        get { controller.keywordSuggest }
        set { controller.keywordSuggest = newValue }
    }

    /// Keyword session boundaries (`keywordStarted`, `keywordEnded`), for
    /// the tab's extension.
    public var onKeywordSession: ((OmnibarEffect) -> Void)?

    /// The tab this omnibar belongs to: never offered as its own Switch to Tab row.
    public var tabKey: String?

    var resolver: OmniboxResolver {
        var resolver = suggestionEngine.resolver
        resolver.urlResolver.allowsChromiumSchemes = allowsChromiumSchemes
        // Extension keywords first (an extension's own keyword wins), then
        // the search engines' (Chrome's tab to search).
        resolver.keywords = keywordSource() + OmnibarKeyword.searchEngines(default: resolver.searchEngine)
        return resolver
    }

    public init(suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine(), mainWork: MainWorkScheduler) {
        self.suggestionEngine = suggestionEngine
        self.mainWork = mainWork
        super.init(frame: .zero)
        controller.onEffect = { [weak self] effect in self?.perform(effect) }
        controller.onStep = { [weak self] in self?.updateChrome() }

        // The page drags out of the location icon while the field shows it.
        chip.dragItem = { [weak self] in
            guard let self, !controller.state.hasFocus, let url = controller.state.pageURL,
                  !BrowserNewTabPage.isNewTabPage(url) else { return nil }
            return BrowserURLDragItem(url: url, title: pageTitle?())
        }
        field.setPlaceholder(Strings.omnibarPlaceholder)
        field.delegate = self
        field.sink = self
        field.onFocus = { [weak self] in self?.fieldDidFocus() }
        field.onPasteAndGo = { [weak self] in self?.pasteAndGo() }
        field.pasteAndGoTitle = { [weak self] in self?.pasteAndGoTitle() }
        field.extraMenuItems = { [weak self] in self?.omnibarMenuItems() ?? [] }
        field.setAccessibilityLabel(Strings.omnibarPlaceholder)
        // A long URL truncates; it never widens the toolbar or the pane: the bar
        // frames the field (`AddressBarLayout`), BrowserToolbarLayout decides the omnibar's width.
        backdrop.isHidden = true
        addSubview(backdrop)
        addSubview(pill)
        addSubview(chip)
        addSubview(field)
        machineBadgeView.isHidden = true
        focusModeBadgeView.isHidden = true
        profileBadgeView.isHidden = true
        starButton.isHidden = true
        badges.orientation = .horizontal
        badges.spacing = 4
        addSubview(badges)
        panel.onPick = { [weak self] row, flags in
            self?.commitMarkedText()
            self?.controller.send(.rowClick(row: row, .init(flags)))
        }
        panel.onHover = { [weak self] row, pointer in self?.controller.send(.rowHover(row: row, pointer: pointer)) }
        density.update { [weak self] in
            guard let self else { return }
            let bar = OmnibarStyle.barHeight, chipSize = OmnibarStyle.chipSize
            if bar != barHeight { barHeight = bar; invalidateIntrinsicContentSize() }
            chipSide = chipSize
            // invalidate: a token changed (the binding runs once per change): the chip, the field's font.
            needsLayout = true
            field.font = OmnibarStyle.font
            field.setPlaceholder(Strings.omnibarPlaceholder)
            field.restyle(controller.state.fieldText, style: OmnibarPresentation(controller.state).style)
            updateChrome()
        }
        density.start(in: self)
        pill.followLook(on: mainWork)
        followDisplay()
        addCursorUpdateArea()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public

    /// True from focus until commit, cancel, or blur.
    public var isEditing: Bool { controller.state.hasFocus }

    /// The suggestion list is open (Ctrl-N/P/J/K move its selection).
    public var isShowingSuggestions: Bool { controller.state.isPopupOpen }

    var state: OmnibarState { controller.state }

    /// The machine whose localhost this tab sees, as a subtle chip; nil
    /// hides it (plans/cmux-next/remote-localhost.md section 6).
    public func setMachineBadge(_ text: String?, help: String?) {
        // Called on every render of the chrome; the same badge shows nothing new and moves no layout.
        if let shown = shownMachineBadge, shown.text == text, shown.help == help { return }
        shownMachineBadge = (text, help)
        if let text {
            machineBadgeView.show(text: text, help: help ?? text)
        }
        machineBadgeView.isHidden = text == nil
        updateBadgeSpace()
    }

    /// The machine badge last applied (`setMachineBadge`), so an unchanged one returns at once.
    private var shownMachineBadge: (text: String?, help: String?)?

    /// The tab's browser profile as a small avatar; nil hides it (one
    /// profile, or an incognito tab).
    public func setProfileBadge(_ badge: BrowserProfileBadge?) {
        if let badge { profileBadgeView.show(badge) }
        // The avatar has one size: only showing or hiding it moves the field.
        guard profileBadgeView.isHidden != (badge == nil) else { return }
        profileBadgeView.isHidden = badge == nil
        updateBadgeSpace()
    }

    /// The machine chip's menu (the host's machine actions, cx-2cob).
    public var machineBadgeMenu: (() -> NSMenu?)? {
        get { machineBadgeView.makeMenu }
        set { machineBadgeView.makeMenu = newValue }
    }

    /// The browser profile badge's menu (the host's profile actions).
    public var profileBadgeMenu: (() -> NSMenu?)? {
        get { profileBadgeView.makeMenu }
        set { profileBadgeView.makeMenu = newValue }
    }

    /// The badge shown now, for diagnostics (`debug.browser`).
    public var profileBadgeName: String? { profileBadgeView.isHidden ? nil : profileBadgeView.themedToolTip }

    /// Browser focus mode's badge: nil hides it, else "Focus Mode" or, once
    /// the first Escape armed the exit, "Esc again to exit". It fades in and
    /// out (at once with fades off in the motion settings; Reduce Motion keeps a short fade).
    public func setFocusModeBadge(armed: Bool?) {
        let text = focusModeBadgeView.shownText
        if let armed { focusModeBadgeView.show(armed: armed) }
        // The shown badge's new text has another width.
        if focusModeBadgeWanted, focusModeBadgeView.shownText != text { updateBadgeSpace() }
        let shown = armed != nil
        guard focusModeBadgeWanted != shown else { return }
        focusModeBadgeWanted = shown
        // Fades off (the motion switches; Reduce Motion keeps a short fade): the badge appears and goes at once (no animator
        // proxy, whose zero-length group can leave the old alpha until the next commit).
        guard Motion.feedback.animatesFades, Motion.canAnimate(in: focusModeBadgeView) else {
            focusModeBadgeView.alphaValue = shown ? 1 : 0
            focusModeBadgeView.isHidden = !shown
            return updateBadgeSpace()
        }
        if !shown {
            Motion.feedback.animate(.fadeOut, in: focusModeBadgeView, { focusModeBadgeView.animator().alphaValue = 0 }) { [weak self] in
                // Shown again while fading out: stay visible.
                guard let self, !focusModeBadgeWanted else { return }
                focusModeBadgeView.isHidden = true
                updateBadgeSpace()
            }
        } else {
            focusModeBadgeView.alphaValue = 0
            focusModeBadgeView.isHidden = false
            updateBadgeSpace()
            Motion.feedback.animate(.fadeIn, in: focusModeBadgeView) { focusModeBadgeView.animator().alphaValue = 1 }
        }
    }

    /// Whether the focus mode badge shows (or is fading in); tests, diagnostics.
    public var showsFocusModeBadge: Bool { focusModeBadgeWanted }
    /// The focus mode badge's text (tests, diagnostics).
    public var focusModeBadgeText: String? { showsFocusModeBadge ? focusModeBadgeView.shownText : nil }

    /// A badge showed, hid or changed its text: the badges and the field get new frames.
    func updateBadgeSpace() {
        // invalidate: called only on a badge change (each caller skips an unchanged badge).
        needsLayout = true
    }

    /// Shows the page's URL again after a commit that loaded nothing in
    /// this tab (`chrome://settings` opened Settings instead).
    public func showPageURL() { controller.send(.pageURLChanged(reportedURL)) }

    /// Shows the page's URL. While editing, typed text never changes.
    public func update(url: URL?, security: BrowserSecurityState) {
        if url != reportedURL {
            reportedURL = url
            controller.send(.pageURLChanged(url))
            onPageURLChange?(url)
        }
        if security != self.security {
            self.security = security
            updateChrome()
        }
    }

    /// The focus coordinator's way in (Cmd-L, a new browser tab): focuses
    /// the field with the full URL selected (Chromium `SetFocus(true)`).
    /// Focusing again while focused selects everything again. This is the
    /// only place the omnibar moves the first responder, and only on the
    /// coordinator's behalf (`FocusEffectApplier`).
    public func focus() {
        guard field.currentEditor() == nil else {
            controller.send(controller.state.hasFocus ? .key(.focusLocation) : .focusGained(.keyboard))
            return
        }
        pendingFocusSource = .keyboard
        defer { pendingFocusSource = nil }
        window?.makeFirstResponder(field)
    }

    /// Opt-Cmd-F (Chrome's Search the Web): a search with the default
    /// engine in the focused field ("Search Google" in the chip, empty text).
    /// Called after the focus coordinator focused the field; a focus that
    /// lands later (a Chromium page window giving key back) starts it then.
    public func beginSearch() {
        guard controller.state.hasFocus else {
            pendingSearch = true
            return
        }
        controller.send(.key(.searchWithDefaultEngine))
    }

    /// Return with a disposition while the field is editing (the
    /// `omnibar.openIn…Tab` actions, Cmd-Return): commits the highlighted
    /// row or the typed text to `disposition`, as the field's own Return
    /// does. Returns false when the field is not editing.
    @discardableResult
    public func commit(_ disposition: OmnibarDisposition) -> Bool {
        guard admits(.enter(disposition)) else { return false }
        return controller.send(.key(.enter(disposition)))
    }

    /// Verification hook (`BrowserDebugWindow`, tests): focuses the field
    /// and types `text` one character at a time through the field editor,
    /// as keystrokes do.
    func debugType(_ text: String) {
        focus()
        for character in text {
            guard let editor = field.currentEditor() as? NSTextView else { return }
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
    }

    /// Verification hook (`debug.omnibar_type`): types `text` as `debugType`
    /// does, then (with `commit`) gives the field editor a Return key-down,
    /// so the commit takes the path a real Return takes once the key reaches
    /// the field (`OmnibarFieldEditor.keyDown`, then the omnibar reducer).
    /// The window need not be key. Returns false when the field did not
    /// start editing.
    @discardableResult
    public func debugTypeAndCommit(_ text: String, commit: Bool = true) -> Bool {
        debugType(text)
        guard let editor = field.currentEditor() as? NSTextView else { return false }
        guard commit else { return true }
        guard let enter = NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window?.windowNumber ?? 0, context: nil, characters: "\r",
            charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36
        ) else { return false }
        editor.keyDown(with: enter)
        return true
    }

    var fieldEditor: OmnibarFieldEditor? { field.editor }

    // MARK: Events in

    private func fieldDidFocus() {
        let pressed = isMouseDownInField((window as? InputTapHosting)?.inputTap?.lastDispatched)
        controller.send(.focusGained(pendingFocusSource ?? (pressed ? .mouse : .programmatic)))
        if pendingSearch {
            pendingSearch = false
            controller.send(.key(.searchWithDefaultEngine))
        }
    }

    /// A press in the bar focused it (not a click elsewhere, such as a
    /// new-tab button, that moved focus here). The bar around the text
    /// forwards its presses to the field (`mouseDown(with:)`).
    /// `event`: the tap's last dispatched event, the press whose dispatch moves the focus here.
    private func isMouseDownInField(_ event: InputEventRecord?) -> Bool {
        guard let event, event.type == .leftMouseDown || event.type == .rightMouseDown,
              let window, event.windowNumber == window.windowNumber else { return false }
        return bounds.contains(convert(NSPoint(x: event.location.x, y: event.location.y), from: nil))
    }

    /// Reports what the field editor holds now. The applier's own writes
    /// are echoes and are dropped.
    func observeField(kind: OmnibarState.EditKind?) {
        guard !controller.isApplying, let editor = field.currentEditor() as? NSTextView else { return }
        let marked = editor.hasMarkedText() ? editor.markedRange() : nil
        controller.send(.fieldChanged(.init(text: editor.string, selection: editor.selectedRange(), marked: marked), kind))
    }

    /// A click on a row or Paste and Go ends an IME composition first, as a
    /// click elsewhere does; the commit reaches the state machine as an edit.
    private func commitMarkedText() {
        guard let editor = field.editor, editor.hasMarkedText() else { return }
        editor.unmarkText()
        editor.inputContext?.discardMarkedText()
    }

    // MARK: Effects out

    private func perform(_ effect: OmnibarEffect) {
        switch effect {
        case .began:
            benchProbe?("began")
            onEvent?(.didBeginEditing)
            benchProbe?("began.done")
        case .ended(let reason): onEvent?(.didEndEditing(reason))
        case .beep: NSSound.beep()
        case .deleteSuggestion(let url): suggestionEngine.deleteSuggestion(url)
        case .typedNavigation(let url): suggestionEngine.noteTyped(url)
        case .hostTypoFixed(let host): suggestionEngine.resolver.hostTypoMemory.recordFix(of: host)
        case .typedHTTPSUpgrade(let url): onTypedHTTPSUpgrade?(url)
        case .copyAnswer(let answer):
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(answer, forType: .string)
        case .keywordStarted, .keywordEnded: onKeywordSession?(effect)
        case .query, .cancelQuery, .keywordInput: break
        }
    }

    // MARK: Paste and Go

    private func pastedText() -> String? {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func pasteAndGoTitle() -> String? {
        guard !isReadOnly, let text = pastedText(), let destination = resolver.destination(for: text) else { return nil }
        if case .search = destination { return Strings.pasteAndSearch }
        return Strings.pasteAndGo
    }

    private func pasteAndGo() {
        guard !isReadOnly, let text = pastedText() else { return }
        commitMarkedText()
        controller.send(.pasteAndGo(text))
    }

    // MARK: The bar around the text

    /// One rectangle, in bar coordinates, for the I-beam and for the press
    /// that focuses the field (`OmnibarPointer`): from the page-info chip to
    /// the first shown trailing badge (or the bar's end), the bar's full
    /// height. The chip, badges and star keep the arrow and their presses.
    var textArea: NSRect {
        let leading = chip.isHidden ? bounds.minX : chip.frame.maxX
        let trailing = badges.arrangedSubviews.contains { !$0.isHidden } ? badges.frame.minX : bounds.maxX
        return NSRect(x: leading, y: bounds.minY, width: max(0, trailing - leading), height: bounds.height)
    }

    /// A press in the text area around the text (above and below the line,
    /// past its end) is a press in the field, as in every browser: the first
    /// one focuses and selects the whole address, a later one places the
    /// caret at the nearest character.
    public override func mouseDown(with event: NSEvent) {
        guard isBarHit(event) else { return super.mouseDown(with: event) }
        benchProbe?("bar.mouseDown")
        // While editing the field editor tracks the press (it reports it to
        // the state machine itself).
        if controller.state.hasFocus, let editor = field.editor { return editor.mouseDown(with: event) }
        // At rest the bar focuses the field itself, as the first click on the
        // text does: forwarding a press outside the field's frame to
        // NSTextField left focus and selection to AppKit's text tracking,
        // which sometimes ended with a caret and no select-all (nxdog96 N4).
        controller.send(.fieldMouseDown(clickCount: event.clickCount, button: .left, word: nil))
        if let editor = field.editor, window?.firstResponder === editor {
            // The field still edits (the state machine had let go): focus it
            // in place, as `focus()` does, without an end-editing round trip.
            controller.send(.focusGained(.mouse))
        } else {
            pendingFocusSource = .mouse
            window?.makeFirstResponder(field)
            pendingFocusSource = nil
        }
        controller.send(.fieldMouseUp)
    }

    public override func rightMouseDown(with event: NSEvent) {
        guard isBarHit(event) else { return super.rightMouseDown(with: event) }
        field.rightMouseDown(with: event)
    }

    public override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        field.acceptsFirstMouse(for: event)
    }

    /// The I-beam over the text area, the arrow beside the chip and the
    /// badges (`OmnibarPointer`), read from the text area when the pointer
    /// enters the bar (its `.cursorUpdate` area). A move
    /// across the text area's edge is the row's (`ArrowCursorView`'s move
    /// tracker sets the same rule on every move), so a resize of the bar, as
    /// on every frame of a divider drag beside a browser pane, rebuilds none
    /// of the window's cursor rects (Chrome: the view under the pointer names
    /// its cursor, `ui/views/widget/root_view.cc` `RootView::UpdateCursor`).
    public override func cursorUpdate(with event: NSEvent) {
        let region: OmnibarPointer.Region = textArea.contains(convert(event.locationInWindow, from: nil)) ? .bar : .barEdge
        OmnibarPointer.cursor(region).cursor.set()
    }

    public override func layout() {
        super.layout()
        applyBarLayout()
    }

    // MARK: Appearance

    private func updateChrome() {
        benchProbe?("chrome.update")
        let state = controller.state
        if state.hasFocus != cursorRectsEditing {
            // The field's cursor follows editing (`AddressField.resetCursorRects`).
            cursorRectsEditing = state.hasFocus
            window?.invalidateCursorRects(for: field)
        }
        pill.state = state.isPopupOpen ? .card : (state.hasFocus ? .editing : .idle)
        backdrop.isHidden = !state.isPopupOpen
        if state.isPopupOpen { backdrop.opensUpward = toolbarOpensUpward }
        let site = PageInfoSite(url: state.pageURL, security: security)
        let indicator = PageInfoIndicator.resolve(site: site, chip: OmnibarPresentation(state).chip)
        if indicator != chip.indicator {
            chip.indicator = indicator
            needsLayout = true // the chip's label ("Search Google", "Not Secure") sets its width
        }
        updateStarVisibility()
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { panel.dismiss() }
    }

    /// The URL's styled text is written again in the new look once the bar shows: a hidden tab's bar
    /// measures and lays out no text (R-appear).
    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        visibilityNode.deferAppearance(owner: Self.appearanceKey) { [weak self] in self?.restyleField() }
    }

    /// The ``visibilityNode`` key of the bar's deferred repaint.
    static let appearanceKey = "AddressBarView.appearance"

    private func restyleField() {
        guard !field.isFieldEditorActive else { return }
        field.write(controller.state.fieldText, style: OmnibarPresentation(controller.state).style)
    }
}
