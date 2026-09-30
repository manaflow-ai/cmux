public import AppKit
import CmuxNextDesign

/// The omnibar, drawn after Helium's location bar (`OmnibarStyle`): a gray
/// 8 pt pill with a page-info chip, the compact URL with the host at full
/// strength, and on focus the full URL, all selected. While suggestions show,
/// the bar turns into the top of a white card that continues as the dropdown.
/// Editing rules live in `OmniboxEditModel`.
public final class AddressBarView: NSView {
    /// Editing began or ended. The chrome loads a committed URL; the App
    /// decides where focus goes.
    public var onEvent: ((OmnibarEvent) -> Void)?

    public var suggestionEngine: OmniboxSuggestionEngine

    private let pill = OmnibarPillView()
    private let backdrop = OmnibarCardTopView()
    private let chip = OmnibarChipView()
    private let field = AddressField()
    private let panel = OmniboxSuggestionPanel()
    private let density = DensityBinding()

    private var url: URL?
    private var security: BrowserSecurityState = .none
    private(set) var model = OmniboxEditModel()
    private var pendingDeletion = false
    private var suggestionTask: Task<Void, Never>?
    private var isApplying = false

    public init(suggestionEngine: OmniboxSuggestionEngine = OmniboxSuggestionEngine()) {
        self.suggestionEngine = suggestionEngine
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        field.setPlaceholder(Strings.omnibarPlaceholder)
        field.delegate = self
        field.onFocus = { [weak self] in self?.beginEditing() }
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
        panel.onPick = { [weak self] index in self?.pick(index) }
        density.update { [unowned self] in
            field.font = OmnibarStyle.font
            field.setPlaceholder(Strings.omnibarPlaceholder)
            renderIdleText()
            updateChrome()
        }
        density.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Public

    /// True from focus until commit, cancel, or blur.
    public var isEditing: Bool { model.isEditing }

    /// Shows the page's URL. While editing, untouched text follows it.
    public func update(url: URL?, security: BrowserSecurityState) {
        guard url != self.url || security != self.security else { return }
        self.url = url
        self.security = security
        if model.isEditing {
            if !model.userHasEdited {
                model.pageURLChanged(url)
                apply()
            }
        } else {
            renderIdleText()
        }
        updateChrome()
    }

    /// Focuses the field with the full URL selected (Cmd-L). Focusing again
    /// while editing selects everything again, as in Chrome.
    public func focus() {
        if field.currentEditor() != nil {
            if !model.isEditing { beginEditing() } else { field.currentEditor()?.selectAll(nil) }
            return
        }
        window?.makeFirstResponder(field)
    }

    /// Verification hook (`BrowserDebugWindow`): focuses the field and types
    /// `text` one character at a time through the same path as keystrokes.
    func debugType(_ text: String) {
        focus()
        var typed = ""
        for character in text {
            typed.append(character)
            field.stringValue = typed
            textDidChange()
        }
    }

    // MARK: Editing

    private func beginEditing() {
        model.begin(url: url)
        apply()
        updateChrome()
        onEvent?(.didBeginEditing)
    }

    /// Ends editing and shows the compact URL. `reason` nil means the model
    /// already ended without an event (a commit sends its own).
    private func finishEditing(_ reason: OmnibarEndReason) {
        guard model.isEditing else { return }
        suggestionTask?.cancel()
        model.end()
        panel.dismiss()
        renderIdleText()
        updateChrome()
        onEvent?(.didEndEditing(reason))
    }

    /// Writes the model's text and selection into the field editor.
    private func apply() {
        let presentation = model.presentation
        isApplying = true
        defer { isApplying = false }
        if field.stringValue != presentation.text { field.stringValue = presentation.text }
        if let editor = field.currentEditor() {
            let length = (presentation.text as NSString).length
            let selection = NSIntersectionRange(presentation.selection, NSRange(location: 0, length: length))
            editor.selectedRange = selection.location == NSNotFound ? NSRange(location: length, length: 0) : selection
            if selection.length == 0 { editor.scrollRangeToVisible(selection) }
        }
        field.textColor = OmnibarStyle.textPrimary
    }

    /// The compact URL with the host at full strength and the rest dimmed.
    private func renderIdleText() {
        guard !model.isEditing else { return }
        let text = BrowserURLDisplay.displayText(for: url)
        let attributed = NSMutableAttributedString(string: text, attributes: [
            .font: OmnibarStyle.font,
            .foregroundColor: OmnibarStyle.textSecondary,
        ])
        let host = BrowserURLDisplay.hostRange(in: text, for: url) ?? NSRange(location: 0, length: (text as NSString).length)
        attributed.addAttribute(.foregroundColor, value: OmnibarStyle.textPrimary, range: host)
        field.attributedStringValue = attributed
    }

    private func textDidChange() {
        guard !isApplying else { return }
        if !model.isEditing { model.begin(url: url); onEvent?(.didBeginEditing) }
        let text = field.stringValue
        let deletion = pendingDeletion || text.utf16.count < model.userText.utf16.count
        pendingDeletion = false
        model.userEdited(text, isDeletion: deletion)
        if model.suggestions.isEmpty { panel.dismiss() }
        updateChrome()
        requestSuggestions(for: text)
    }

    private func requestSuggestions(for text: String) {
        suggestionTask?.cancel()
        let engine = suggestionEngine
        suggestionTask = Task { [weak self] in
            let rows = await engine.suggestions(for: text)
            guard !Task.isCancelled, let self else { return }
            guard self.model.received(rows, for: text) else { return }
            self.apply()
            self.showPanel()
            self.updateChrome()
        }
    }

    private func showPanel() {
        guard model.isPopupOpen, let window else {
            panel.dismiss()
            return
        }
        panel.show(model.suggestions, selected: model.selectedIndex, below: self, in: window)
    }

    private func move(_ delta: Int) {
        guard model.isPopupOpen else { return }
        model.move(delta)
        apply()
        panel.select(model.selectedIndex)
        updateChrome()
    }

    private func submit() {
        guard let destination = model.commitDestination(resolver: suggestionEngine.resolver) else {
            NSSound.beep()
            return
        }
        url = destination
        finishEditing(.commit(destination))
    }

    private func pick(_ index: Int) {
        model.select(index)
        submit()
    }

    private func cancel() {
        switch model.escape() {
        case .reverted:
            suggestionTask?.cancel()
            panel.dismiss()
            apply()
            updateChrome()
        case .cancel:
            finishEditing(.cancel)
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
        guard let text = pastedText(), let destination = suggestionEngine.resolver.destination(for: text)?.url else { return }
        if !model.isEditing { model.begin(url: url) }
        url = destination
        finishEditing(.commit(destination))
    }

    // MARK: Appearance

    private func updateChrome() {
        let popup = model.isEditing && model.isPopupOpen
        pill.state = popup ? .card : (model.isEditing ? .editing : .idle)
        backdrop.isHidden = !popup
        chip.symbol = chipSymbol()
        chip.setAccessibilityLabel(security == .insecure && !model.isEditing ? Strings.notSecure : nil)
        chip.toolTip = security == .insecure && !model.isEditing ? Strings.notSecure : nil
    }

    private func chipSymbol() -> String {
        if model.isEditing {
            if let index = model.selectedIndex, model.suggestions.indices.contains(index) {
                return model.suggestions[index].kind == .search ? "magnifyingglass" : "globe"
            }
            return model.userHasEdited || url == nil ? "magnifyingglass" : securitySymbol
        }
        return url == nil || BrowserURLDisplay.displayText(for: url).isEmpty ? "magnifyingglass" : securitySymbol
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
        renderIdleText()
    }
}

extension AddressBarView: NSTextFieldDelegate {
    public func controlTextDidChange(_ notification: Notification) {
        textDidChange()
    }

    public func controlTextDidEndEditing(_ notification: Notification) {
        finishEditing(.blur)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            guard model.isPopupOpen else { return false }
            move(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard model.isPopupOpen else { return false }
            move(-1)
            return true
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertLineBreak(_:)):
            submit()
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)),
             #selector(NSResponder.deleteWordBackward(_:)), #selector(NSResponder.deleteWordForward(_:)),
             #selector(NSResponder.deleteToBeginningOfLine(_:)), #selector(NSResponder.deleteToEndOfLine(_:)):
            pendingDeletion = true
            return false
        case #selector(NSResponder.moveRight(_:)), #selector(NSResponder.moveToEndOfLine(_:)),
             #selector(NSResponder.moveToEndOfDocument(_:)):
            // Right arrow at an inline completion accepts it as typed text.
            guard !model.inlineCompletion.isEmpty else { return false }
            let accepted = model.userText + model.inlineCompletion
            model.userEdited(accepted, isDeletion: true)
            apply()
            requestSuggestions(for: accepted)
            return true
        default:
            return false
        }
    }
}

/// The omnibar text field: a first click selects the whole URL (later
/// clicks place the caret), and the edit menu offers Paste and Go.
final class AddressField: ChromeTextField {
    var onFocus: (() -> Void)?
    var onPasteAndGo: (() -> Void)?
    var pasteAndGoTitle: (() -> String?)?

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            (currentEditor() as? NSTextView)?.selectedTextAttributes = [.backgroundColor: OmnibarStyle.selection]
            onFocus?()
        }
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        // Chrome: clicking an unfocused omnibox selects everything instead
        // of placing the caret where the click landed.
        guard currentEditor() == nil, event.clickCount == 1 else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
    }

    /// The field editor's context menu (the field is its delegate).
    @objc func textView(_ textView: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
        guard let title = pasteAndGoTitle?() else { return menu }
        let item = NSMenuItem(title: title, action: #selector(performPasteAndGo(_:)), keyEquivalent: "")
        item.target = self
        let paste = menu.items.firstIndex { $0.action == #selector(NSText.paste(_:)) }
        menu.insertItem(item, at: paste.map { $0 + 1 } ?? 0)
        return menu
    }

    @objc private func performPasteAndGo(_ sender: Any?) {
        onPasteAndGo?()
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
