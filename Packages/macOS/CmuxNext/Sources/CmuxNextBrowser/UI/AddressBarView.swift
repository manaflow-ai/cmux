public import AppKit
import CmuxNextDesign

/// The omnibar, drawn after Helium's location bar (`OmnibarStyle`): a gray
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
        didSet { controller.send(.searchEngineChanged) }
    }

    private let pill = OmnibarPillView()
    private let backdrop = OmnibarCardTopView()
    private let chip = PageInfoChipButton()
    let field = AddressField()
    private let machineBadgeView = MachineBadgeView()
    private var fieldToEdge: NSLayoutConstraint!
    private var fieldToBadge: NSLayoutConstraint!
    private let panel = OmniboxSuggestionPanel()
    private let density = DensityBinding()

    private var reportedURL: URL?
    /// Set by `focus()` for the responder change it causes.
    var pendingFocusSource: OmnibarInput.FocusSource?
    private var security: BrowserSecurityState = .none
    private(set) var controller: OmnibarController!

    /// Chromium tabs also load `chrome://` and `chrome-extension://` pages
    /// (Chromium's own WebUI and extension pages, which WebKit cannot show).
    public var allowsChromiumSchemes = false

    private var resolver: OmniboxResolver {
        var resolver = suggestionEngine.resolver
        resolver.urlResolver.allowsChromiumSchemes = allowsChromiumSchemes
        return resolver
    }

    public init(suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine()) {
        self.suggestionEngine = suggestionEngine
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        controller = OmnibarController(
            field: field,
            popup: self,
            resolver: { [unowned self] in resolver },
            suggest: { [weak self] text in await self?.suggestionEngine.suggestions(for: text) ?? [] }
        )
        controller.onEffect = { [weak self] effect in self?.perform(effect) }
        controller.onStep = { [weak self] in self?.updateChrome() }

        field.setPlaceholder(Strings.omnibarPlaceholder)
        field.delegate = self
        field.sink = self
        field.onFocus = { [weak self] in self?.fieldDidFocus() }
        field.onPasteAndGo = { [weak self] in self?.pasteAndGo() }
        field.pasteAndGoTitle = { [weak self] in self?.pasteAndGoTitle() }
        field.setAccessibilityLabel(Strings.omnibarPlaceholder)
        // A long URL truncates; it never widens the toolbar or the pane
        // (BrowserToolbarLayout decides the omnibar's width).
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)

        for view in [backdrop, pill, chip, field] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        backdrop.isHidden = true
        addSubview(backdrop)
        addSubview(pill)
        addSubview(chip)
        addSubview(field)
        machineBadgeView.isHidden = true
        addSubview(machineBadgeView)
        fieldToEdge = field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OmnibarStyle.trailingPadding)
        fieldToBadge = field.trailingAnchor.constraint(equalTo: machineBadgeView.leadingAnchor, constant: -OmnibarStyle.textLeading)
        NSLayoutConstraint.activate([
            density.bind(heightAnchor.constraint(equalToConstant: 0)) { OmnibarStyle.barHeight },
            pill.leadingAnchor.constraint(equalTo: leadingAnchor),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor),
            pill.topAnchor.constraint(equalTo: topAnchor),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor),

            backdrop.leadingAnchor.constraint(equalTo: leadingAnchor, constant: -OmnibarStyle.cardSideOutset),
            backdrop.trailingAnchor.constraint(equalTo: trailingAnchor, constant: OmnibarStyle.cardSideOutset),
            backdrop.topAnchor.constraint(equalTo: topAnchor, constant: -OmnibarStyle.cardTopOutset),
            backdrop.bottomAnchor.constraint(equalTo: bottomAnchor),

            chip.leadingAnchor.constraint(equalTo: leadingAnchor, constant: OmnibarStyle.chipLeading),
            chip.centerYAnchor.constraint(equalTo: centerYAnchor),
            density.bind(chip.widthAnchor.constraint(greaterThanOrEqualToConstant: 0)) { OmnibarStyle.chipSize },
            density.bind(chip.heightAnchor.constraint(equalToConstant: 0)) { OmnibarStyle.chipSize },

            field.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: OmnibarStyle.textLeading),
            fieldToEdge,
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            machineBadgeView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OmnibarStyle.chipLeading - 2),
            machineBadgeView.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        panel.onPick = { [weak self] row, flags in
            self?.commitMarkedText()
            self?.controller.send(.rowClick(row: row, .init(flags)))
        }
        panel.onHover = { [weak self] row, pointer in self?.controller.send(.rowHover(row: row, pointer: pointer)) }
        density.update { [unowned self] in
            field.font = OmnibarStyle.font
            field.setPlaceholder(Strings.omnibarPlaceholder)
            field.write(controller.state.fieldText, style: OmnibarPresentation(controller.state).style)
            updateChrome()
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public

    /// True from focus until commit, cancel, or blur.
    public var isEditing: Bool { controller.state.hasFocus }

    var state: OmnibarState { controller.state }

    /// The machine whose localhost this tab sees, as a subtle chip; nil
    /// hides it (plans/cmux-next/remote-localhost.md section 6).
    public func setMachineBadge(_ text: String?, help: String?) {
        if let text {
            machineBadgeView.show(text: text, help: help ?? text)
        }
        let visible = text != nil
        guard machineBadgeView.isHidden == visible else { return }
        machineBadgeView.isHidden = !visible
        fieldToEdge.isActive = !visible
        fieldToBadge.isActive = visible
    }

    /// Shows the page's URL. While editing, typed text never changes.
    public func update(url: URL?, security: BrowserSecurityState) {
        if url != reportedURL {
            reportedURL = url
            controller.send(.pageURLChanged(url))
        }
        if security != self.security {
            self.security = security
            updateChrome()
        }
    }

    /// The focus coordinator's way in (Cmd-L, a new browser tab): focuses
    /// the field with the full URL selected (Chrome `SetFocus(true)`).
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

    /// The search engine inside `suggestionEngine` changed.
    public func searchEngineDidChange() {
        controller.send(.searchEngineChanged)
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

    var fieldEditor: OmnibarFieldEditor? { field.editor }
    var suggestionPanel: OmniboxSuggestionPanel { panel }

    // MARK: Events in

    private func fieldDidFocus() {
        controller.send(.focusGained(pendingFocusSource ?? (isMouseDownInField(NSApp.currentEvent) ? .mouse : .programmatic)))
    }

    /// A press in the field itself focused it (not a click elsewhere, such
    /// as a new-tab button, that moved focus here).
    private func isMouseDownInField(_ event: NSEvent?) -> Bool {
        guard let event, [.leftMouseDown, .rightMouseDown].contains(event.type), event.window === window else { return false }
        return field.bounds.contains(field.convert(event.locationInWindow, from: nil))
    }

    /// Reports what the field editor holds now. The applier's own writes
    /// are echoes and are dropped.
    private func observeField(kind: OmnibarState.EditKind?) {
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
        case .began: onEvent?(.didBeginEditing)
        case .ended(let reason): onEvent?(.didEndEditing(reason))
        case .beep: NSSound.beep()
        case .deleteSuggestion(let url): suggestionEngine.deleteSuggestion(url)
        case .query, .cancelQuery: break
        }
    }

    // MARK: Paste and Go

    private func pastedText() -> String? {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func pasteAndGoTitle() -> String? {
        guard let text = pastedText(), let destination = resolver.destination(for: text) else { return nil }
        if case .search = destination { return Strings.pasteAndSearch }
        return Strings.pasteAndGo
    }

    private func pasteAndGo() {
        guard let text = pastedText() else { return }
        commitMarkedText()
        controller.send(.pasteAndGo(text))
    }

    // MARK: Appearance

    private func updateChrome() {
        let state = controller.state
        pill.state = state.isPopupOpen ? .card : (state.hasFocus ? .editing : .idle)
        backdrop.isHidden = !state.isPopupOpen
        let site = PageInfoSite(url: state.pageURL, security: security)
        chip.indicator = PageInfoIndicator.resolve(site: site, chip: OmnibarPresentation(state).chip)
    }

    public override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil { panel.dismiss() }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if !field.isFieldEditorActive {
            field.write(controller.state.fieldText, style: OmnibarPresentation(controller.state).style)
        }
    }
}

extension AddressBarView: OmnibarPopupSurface {
    func showRows(_ rows: [BrowserSuggestion], highlighted: Int?) {
        guard let window else { return }
        panel.show(rows, highlighted: highlighted, below: self, in: window)
    }

    func highlightRow(_ row: Int?) { panel.highlight(row) }

    func dismissRows() { panel.dismiss() }
}

extension AddressBarView: OmnibarFieldEditorSink {
    func fieldEditorDidChange(kind: OmnibarState.EditKind?) { observeField(kind: kind) }

    func fieldEditorKey(_ key: OmnibarInput.Key) -> Bool { controller.send(.key(key)) }

    func fieldEditorMouseDown(clickCount: Int, button: OmnibarInput.MouseButton, word: NSRange?) {
        controller.send(.fieldMouseDown(clickCount: clickCount, button: button, word: word))
    }

    func fieldEditorMouseUp() { controller.send(.fieldMouseUp) }

    var copyContent: OmnibarCopy? { OmnibarReducer.copyContent(of: controller.state, resolver: resolver) }

    var canUndo: Bool { controller.state.hasFocus && !controller.state.undo.isEmpty }
    var canRedo: Bool { controller.state.hasFocus && !controller.state.redo.isEmpty }
}

extension AddressBarView: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        observeField(kind: field.editor?.lastEditKind ?? .insert)
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        controller.send(.focusLost)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)): controller.send(.key(.down))
        case #selector(NSResponder.moveUp(_:)): controller.send(.key(.up))
        case #selector(NSResponder.insertTab(_:)): controller.send(.key(.tab))
        case #selector(NSResponder.insertBacktab(_:)): controller.send(.key(.backTab))
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            controller.send(.key(.enter(.init(NSApp.currentEvent?.modifierFlags ?? []))))
        case #selector(NSResponder.cancelOperation(_:)): controller.send(.key(.escape))
        case #selector(NSResponder.selectAll(_:)): controller.send(.key(.selectAll))
        // The Home key (Shift-Home extends); Cmd-Left is a caret move.
        case #selector(NSResponder.scrollToBeginningOfDocument(_:)): controller.send(.key(.home(extend: false)))
        case #selector(NSResponder.moveToBeginningOfDocumentAndModifySelection(_:)): controller.send(.key(.home(extend: true)))
        default: false
        }
    }
}
