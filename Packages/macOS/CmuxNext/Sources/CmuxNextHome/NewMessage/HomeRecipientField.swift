public import AppKit
import CmuxNextDesign

/// New Message's To: field, as in Messages: "To:", one token per
/// recipient, then the text being typed, and a + button at the end. It owns
/// the draft (``HomeNewMessageDraft``) and the suggestion list under it:
/// typing suggests people, Return / comma / Tab make the text a token (the
/// highlighted suggestion when there is one), Backspace with nothing typed
/// removes the last token, Up / Down move through the suggestions. Before
/// anyone is chosen and while nothing is typed, the list offers the Chiefs
/// and the team in sections, with New Chief after the Chiefs (``idleSuggestions``,
/// ``onNewChief``, ``onInvite``), nothing highlighted until Down. Return with
/// nothing typed chooses the highlighted row, else (and Tab with
/// nothing typed) hands the keyboard to the message box.
public final class HomeRecipientField: NSView, NSTextFieldDelegate {
    /// The draft changed (a token added or removed, or the typed text).
    public var onChange: (HomeNewMessageDraft) -> Void = { _ in }
    /// Return or Tab with nothing typed: the message box takes the keyboard.
    public var onDone: () -> Void = {}
    /// Escape: the page may end the draft (Messages leaves New Message).
    public var onEscape: () -> Void = {}
    /// The people the field suggests (read on each change).
    public var contacts: () -> [HomeContact] = { [] }
    /// What the list offers before anyone is chosen or typed (the Chiefs, main first, then the team).
    public var idleSuggestions: () -> [HomeContact] = { [] }
    /// The idle list's New Chief row runs this (`home.newChief`); nil leaves the row out.
    public var onNewChief: (() -> Void)?
    /// The idle list's Invite row, shown when the Team section has nobody, runs this (`home.invite`); nil leaves it out.
    public var onInvite: (() -> Void)?

    public private(set) var draft = HomeNewMessageDraft()
    /// The suggestions under the field; the page places it (it overlaps the content).
    public let suggestions = HomeRecipientSuggestionsView()

    let toLabel = ThemedLabel(labelWithString: HomeConversationStrings.toLabel)
    let text = ThemedTextField()
    let addButton = NSButton()
    let separator = NSView()
    private(set) var chips: [HomeRecipientChip] = []
    /// The + button showed every contact (cleared by the next keystroke).
    private var browsing = false
    /// The token a click selected: Backspace removes it.
    private(set) var selectedToken: Int? {
        didSet { for (index, chip) in chips.enumerated() { chip.isSelected = index == selectedToken } }
    }

    /// One line of the field (Messages' To: bar).
    public static let lineHeight: CGFloat = 32
    static let inset: CGFloat = 14

    public override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        toLabel.font = Typography.body
        toLabel.ink = .secondary
        addSubview(toLabel)
        text.isBordered = false
        text.isBezeled = false
        text.drawsBackground = false
        text.font = Typography.body
        text.delegate = self
        text.cell?.wraps = false
        text.cell?.isScrollable = true
        text.setAccessibilityLabel(HomeConversationStrings.composeSearch)
        text.setAccessibilityIdentifier("cmux.home.newMessage.to")
        addSubview(text)
        addButton.bezelStyle = .accessoryBarAction
        addButton.isBordered = false
        addButton.image = NSImage(systemSymbolName: "plus.circle", accessibilityDescription: HomeConversationStrings.addRecipient)
        addButton.imagePosition = .imageOnly
        addButton.contentTintColor = .secondaryLabelColor
        addButton.setAccessibilityLabel(HomeConversationStrings.addRecipient)
        addButton.setAccessibilityIdentifier("cmux.home.newMessage.add")
        addButton.target = self
        addButton.action = #selector(browse)
        addSubview(addButton)
        separator.wantsLayer = true
        addSubview(separator)
        suggestions.onChoose = { [weak self] in self?.choose($0) }
        suggestions.onNewChief = { [weak self] in self?.onNewChief?() }
        suggestions.onInvite = { [weak self] in self?.onInvite?() }
        applyColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    nonisolated public override var isFlipped: Bool { true }

    /// The text field takes the keyboard (the page opens with the caret here).
    public func focus() { window?.makeFirstResponder(text) }

    /// The view that has the caret while the person picks recipients.
    public var primaryInput: NSView { text }

    // MARK: Editing

    /// Sets the draft (a draft kept while the person looked at another conversation).
    public func setDraft(_ draft: HomeNewMessageDraft) {
        self.draft = draft
        text.stringValue = draft.query
        rebuildChips()
        refreshSuggestions()
    }

    /// Adds `recipient` as a token (a suggestion chosen).
    public func choose(_ recipient: HomeRecipient) {
        draft.add(recipient)
        text.stringValue = ""
        changed()
    }

    /// The typed text becomes a token: the highlighted suggestion, else what it parses as.
    /// `pickWithNothingTyped` (Return): with nothing typed the highlighted suggestion is chosen.
    @discardableResult
    public func commit(pickWithNothingTyped: Bool = false) -> Bool {
        let typed = text.stringValue.trimmingCharacters(in: HomeNewMessageDraft.separators)
        guard !typed.isEmpty || pickWithNothingTyped else { return false }
        if let row = suggestions.highlightedRow, !suggestions.isHidden {
            suggestions.activate(row)
            return true
        }
        guard !typed.isEmpty else { return false }
        draft.query = typed
        draft.commit(contacts: contacts())
        text.stringValue = ""
        changed()
        return true
    }

    /// Backspace with nothing typed: the selected token goes, else the last one.
    @discardableResult
    public func deleteBackward() -> Bool {
        if let selected = selectedToken {
            removeToken(at: selected)
            return true
        }
        draft.query = text.stringValue
        guard draft.deleteBackward() else { return false }
        changed()
        return true
    }

    /// Removes the token at `index` (its chip was clicked away).
    public func removeToken(at index: Int) {
        selectedToken = nil
        draft.remove(at: index)
        changed()
        focus()
    }

    @objc func browse() {
        browsing = true
        let chosen = Set(draft.recipients)
        let all = contacts().map(HomeRecipient.contact).filter { !chosen.contains($0) }
        suggestions.show(all, empty: HomeConversationStrings.composeNoContacts)
        needsLayout = true
        superview?.needsLayout = true
        focus()
    }

    /// A click on a token: it is selected and the caret stays in the field.
    func selectToken(at index: Int) {
        focus()
        selectedToken = index
    }

    private func changed() {
        browsing = false
        selectedToken = nil
        rebuildChips()
        refreshSuggestions()
        onChange(draft)
    }

    /// Shows the suggestions for the typed text; before anyone is chosen or typed, the Chiefs and the team.
    public func refreshSuggestions() {
        guard !browsing else { return }
        if draft.isEmpty {
            suggestions.show(rows: idleRows(), highlightFirst: false)
        } else {
            suggestions.show(draft.suggestions(contacts: contacts()))
        }
        superview?.needsLayout = true
    }

    /// The list before anything is typed (the user, 2026-10-27): the Chiefs under "Chiefs" with New Chief
    /// after them, then everyone else under "Team" (an Invite row when the team has nobody).
    func idleRows() -> [HomeRecipientSuggestion] {
        let offered = idleSuggestions()
        let chiefs = offered.filter { $0.source == .agent }
        let team = offered.filter { $0.source != .agent }
        var rows: [HomeRecipientSuggestion] = []
        if !chiefs.isEmpty || onNewChief != nil {
            rows.append(.header(HomeConversationStrings.chiefsSection))
            rows += chiefs.map { .recipient(.contact($0)) }
            if onNewChief != nil { rows.append(.newChief) }
        }
        if !team.isEmpty || onInvite != nil {
            rows.append(.header(HomeConversationStrings.teamSection))
            rows += team.isEmpty ? [.invite] : team.map { .recipient(.contact($0)) }
        }
        return rows
    }

    public func controlTextDidChange(_ notification: Notification) {
        let value = text.stringValue
        // A comma or semicolon ends the token as Messages does.
        if let last = value.last, last == "," || last == ";" {
            text.stringValue = String(value.dropLast())
            commit()
            return
        }
        draft.query = value
        browsing = false
        selectedToken = nil
        refreshSuggestions()
        onChange(draft)
    }

    public func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        handle(selector)
    }

    /// The field's keys (also the test seam): true when handled.
    @discardableResult
    func handle(_ selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if !commit(pickWithNothingTyped: true) { onDone() }
            return true
        case #selector(NSResponder.insertTab(_:)):
            if !commit() { onDone() }
            return true
        case #selector(NSResponder.deleteBackward(_:)), #selector(NSResponder.deleteForward(_:)):
            return text.stringValue.isEmpty ? deleteBackward() : false
        case #selector(NSResponder.moveDown(_:)):
            guard !suggestions.isHidden else { return false }
            suggestions.move(1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            guard !suggestions.isHidden else { return false }
            suggestions.move(-1)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // The Chiefs offered before anything is typed stay: Escape goes to the page.
            if !suggestions.isHidden, browsing || !draft.isEmpty {
                browsing = false
                suggestions.show([])
                return true
            }
            onEscape()
            return true
        default:
            return false
        }
    }

    // MARK: Layout

    private func rebuildChips() {
        for chip in chips { chip.removeFromSuperview() }
        chips = draft.tokens.enumerated().map { index, token in
            let chip = HomeRecipientChip(token: token)
            chip.onRemove = { [weak self] in self?.removeToken(at: index) }
            chip.onSelect = { [weak self] in self?.selectToken(at: index) }
            addSubview(chip)
            return chip
        }
        let names = draft.tokens.map(\.text).joined(separator: ", ")
        text.setAccessibilityValueDescription(names.isEmpty ? nil : HomeConversationStrings.composeTo(names))
        needsLayout = true
        invalidateIntrinsicContentSize()
        superview?.needsLayout = true
    }

    /// The frames of the chips and the text field for `width`, and the height they need.
    func arrange(width: CGFloat) -> (chips: [NSRect], text: NSRect, height: CGFloat) {
        let inset = Self.inset, line = Self.lineHeight, gap: CGFloat = 4
        let labelWidth = ceil(toLabel.intrinsicContentSize.width)
        let right = width - inset - 24 - gap
        var x = inset + labelWidth + 6, y: CGFloat = 0
        var frames: [NSRect] = []
        for chip in chips {
            let w = min(chip.preferredWidth, right - inset - labelWidth - 6)
            if x + w > right, x > inset + labelWidth + 6 {
                x = inset + labelWidth + 6
                y += line
            }
            frames.append(NSRect(x: x, y: y + (line - HomeRecipientChip.height) / 2, width: w, height: HomeRecipientChip.height))
            x += w + gap
        }
        let minimumText: CGFloat = 120
        if right - x < minimumText, !chips.isEmpty {
            x = inset + labelWidth + 6
            y += line
        }
        let textHeight = ceil(text.intrinsicContentSize.height)
        let textFrame = NSRect(x: x, y: y + (line - textHeight) / 2, width: max(0, right - x), height: textHeight)
        return (frames, textFrame, y + line + 10)
    }

    public override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: arrange(width: max(bounds.width, 320)).height)
    }

    /// The height the field needs at `width` (it grows a line per wrapped row of tokens).
    public func height(forWidth width: CGFloat) -> CGFloat { arrange(width: width).height }

    public override func layout() {
        super.layout()
        let placed = arrange(width: bounds.width)
        let line = Self.lineHeight
        let labelSize = toLabel.intrinsicContentSize
        // The text box starts at the inset; the frame adds the label's padding around it.
        toLabel.frame = toLabel.frame(forAlignmentRect: NSRect(x: Self.inset, y: 5 + (line - labelSize.height) / 2,
                                                               width: ceil(labelSize.width), height: labelSize.height))
        for (chip, frame) in zip(chips, placed.chips) { chip.frame = frame.offsetBy(dx: 0, dy: 5) }
        text.frame = placed.text.offsetBy(dx: 0, dy: 5)
        addButton.frame = NSRect(x: bounds.width - Self.inset - 22, y: 5 + (line - 22) / 2, width: 22, height: 22)
        separator.frame = NSRect(x: 0, y: bounds.height - 0.5, width: bounds.width, height: 0.5)
    }

    func applyColors() {
        layer?.backgroundColor = performWithTheme { Palette.paneFill.cgColor }
        separator.layer?.backgroundColor = performWithTheme { Palette.separator.cgColor }
    }

    public override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }
}
