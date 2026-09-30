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

    public var suggestionEngine: OmniboxSuggestionEngine {
        didSet { controller.send(.searchEngineChanged) }
    }

    private let pill = OmnibarPillView()
    private let backdrop = OmnibarCardTopView()
    private let chip = OmnibarChipView()
    private let field = AddressField()
    private let panel = OmniboxSuggestionPanel()
    private let density = DensityBinding()

    private var reportedURL: URL?
    private var security: BrowserSecurityState = .none
    private(set) var controller: OmnibarController!

    public init(suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine()) {
        self.suggestionEngine = suggestionEngine
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        controller = OmnibarController(
            field: field,
            popup: self,
            resolver: { [unowned self] in suggestionEngine.resolver },
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

        for view in [backdrop, pill, chip, field] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        backdrop.isHidden = true
        addSubview(backdrop)
        addSubview(pill)
        addSubview(chip)
        addSubview(field)
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
            density.bind(chip.widthAnchor.constraint(equalToConstant: 0)) { OmnibarStyle.chipSize },
            density.bind(chip.heightAnchor.constraint(equalToConstant: 0)) { OmnibarStyle.chipSize },

            field.leadingAnchor.constraint(equalTo: chip.trailingAnchor, constant: OmnibarStyle.textLeading),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -OmnibarStyle.trailingPadding),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
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
    /// the field with the full URL selected. Focusing again while focused
    /// selects everything again, as in Chrome. This is the only place the
    /// omnibar moves the first responder, and only on the coordinator's
    /// behalf (`FocusEffectApplier`).
    public func focus() {
        guard field.currentEditor() == nil else {
            controller.send(controller.state.hasFocus ? .key(.selectAll) : .focusGained(.keyboard))
            return
        }
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
        let mouse = NSApp.currentEvent.map { [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains($0.type) } ?? false
        controller.send(.focusGained(mouse ? .mouse : .programmatic))
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
        case .query, .cancelQuery: break
        }
    }

    // MARK: Paste and Go

    private func pastedText() -> String? {
        let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return text?.isEmpty == false ? text : nil
    }

    private func pasteAndGoTitle() -> String? {
        guard let text = pastedText(), let destination = suggestionEngine.resolver.destination(for: text) else { return nil }
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
        chip.symbol = chipSymbol(state)
        let insecure = security == .insecure && !state.hasFocus
        chip.setAccessibilityLabel(insecure ? Strings.notSecure : nil)
        chip.toolTip = insecure ? Strings.notSecure : nil
    }

    private func chipSymbol(_ state: OmnibarState) -> String {
        switch state.phase {
        case .editing:
            if let row = state.popup.highlighted, state.popup.rows.indices.contains(row) {
                return state.popup.rows[row].kind == .search ? "magnifyingglass" : "globe"
            }
            return "magnifyingglass"
        case .focused:
            return state.pageURL == nil ? "magnifyingglass" : securitySymbol
        case .idle, .committing:
            return state.fieldText.isEmpty || state.retainedText != nil ? "magnifyingglass" : securitySymbol
        }
    }

    private var securitySymbol: String {
        switch security {
        case .secure: "slider.horizontal.3"
        case .insecure: "exclamationmark.triangle"
        case .local: "doc"
        case .none: "info.circle"
        }
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

    func fieldEditorMouseDown(clickCount: Int) { controller.send(.fieldMouseDown(clickCount: clickCount)) }

    func fieldEditorMouseUp() { controller.send(.fieldMouseUp) }

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
        default: false
        }
    }
}
