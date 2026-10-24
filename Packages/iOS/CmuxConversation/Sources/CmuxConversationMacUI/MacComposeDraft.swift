#if os(macOS)
import AppKit
import CmuxConversationCore

/// macOS New Message metrics. No macOS 26 reference host was available (the
/// fleet runs macOS 27 without Screen Recording), so these follow the iOS
/// sheet's measured proportions at Messages for Mac's 13 pt text size.
enum MacComposeMetrics {
    static var font: NSFont { .systemFont(ofSize: 13) }
    static let fieldInset: CGFloat = 16
    static let fieldTopGap: CGFloat = 8
    static let lineHeight: CGFloat = 24
    static let lineTop: CGFloat = 5
    static var minHeight: CGFloat { lineTop * 2 + lineHeight }
    static let toLeading: CGFloat = 12
    static let toGap: CGFloat = 6
    static let tokenHeight: CGFloat = 19
    static let tokenPadding: CGFloat = 4
    static let addSize: CGFloat = 22
    static let suggestionRowHeight: CGFloat = 44
    static let suggestionWidth: CGFloat = 300
}

/// A recipient token: the name in its service color with a trailing comma;
/// selected, a filled capsule with white text.
final class MacRecipientTokenView: MacFlippedView {
    private var text = NSAttributedString()
    private(set) var recipient: ConversationRecipient
    var isTokenSelected = false { didSet { update() } }
    var onClick: (() -> Void)?

    init(recipient: ConversationRecipient) {
        self.recipient = recipient
        super.init(frame: .zero)
        wantsLayer = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        update()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ recipient: ConversationRecipient) {
        self.recipient = recipient
        update()
    }

    static func color(for state: ConversationRecipient.State) -> NSColor {
        switch state {
        case .resolving: .secondaryLabelColor
        case .resolved(.iMessage): .systemBlue
        case .resolved(.sms): .systemGreen
        case .invalid: .systemRed
        }
    }

    private func update() {
        let tint = Self.color(for: recipient.state)
        let text = NSMutableAttributedString(string: recipient.name, attributes: [
            .font: MacComposeMetrics.font, .foregroundColor: isTokenSelected ? NSColor.white : tint,
        ])
        if !isTokenSelected {
            text.append(NSAttributedString(string: ",", attributes: [.font: MacComposeMetrics.font, .foregroundColor: NSColor.secondaryLabelColor]))
        }
        self.text = text
        layer?.backgroundColor = isTokenSelected ? resolved(tint, in: self) : nil
        setAccessibilityLabel(recipient.name)
        setAccessibilityIdentifier("conversation.compose.token.\(recipient.id)")
        setAccessibilitySelected(isTokenSelected)
        needsLayout = true
        needsDisplay = true
    }

    var preferredWidth: CGFloat { ceil(text.size().width) + 2 * MacComposeMetrics.tokenPadding }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func draw(_ dirtyRect: NSRect) {
        let size = text.size()
        text.draw(at: NSPoint(x: MacComposeMetrics.tokenPadding, y: (bounds.height - size.height) / 2))
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// The To: header of a draft conversation: "To:", wrapping tokens, the text
/// being typed, and the circular + (Add Contact).
final class MacRecipientField: MacFlippedView, NSTextFieldDelegate {
    private let background = MacFlippedView()
    private let toLabel = makeMacLabel()
    let textField = NSTextField()
    let addButton = NSButton()
    private(set) var tokens: [MacRecipientTokenView] = []
    private(set) var preferredHeight = MacComposeMetrics.minHeight
    var onText: ((String) -> Void)?
    var onReturn: (() -> Void)?
    /// Backspace in an empty field; true when a token was selected or removed.
    var onDeleteBackward: (() -> Bool)?
    var onTokenClick: ((String) -> Void)?
    var onAdd: (() -> Void)?
    var onHeightChange: (() -> Void)?
    /// Arrow keys move the autocomplete selection; true when handled.
    var onMove: ((Int) -> Bool)?
    var onCancel: (() -> Bool)?
    private var selectedTokenID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        background.wantsLayer = true
        addSubview(background)
        toLabel.stringValue = String(localized: "conversation.compose.to", defaultValue: "To:", bundle: .module)
        toLabel.font = MacComposeMetrics.font
        toLabel.textColor = .secondaryLabelColor
        addSubview(toLabel)
        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = MacComposeMetrics.font
        textField.delegate = self
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.setAccessibilityLabel(toLabel.stringValue)
        textField.setAccessibilityIdentifier("conversation.compose.to")
        addSubview(textField)
        addButton.image = NSImage(systemSymbolName: "plus", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 11, weight: .bold))
        if #available(macOS 26.0, *) {
            addButton.bezelStyle = .glass
            addButton.borderShape = .circle
        } else {
            addButton.isBordered = false
        }
        addButton.controlSize = .small
        addButton.target = self
        addButton.action = #selector(addTapped)
        addButton.setAccessibilityLabel(String(localized: "conversation.compose.addContact", defaultValue: "Add Contact", bundle: .module))
        addButton.setAccessibilityIdentifier("conversation.compose.addContact")
        addSubview(addButton)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func addTapped() { onAdd?() }

    func update(draft: ConversationRecipientDraft) {
        if draft.recipients.map(\.id) != tokens.map(\.recipient.id) {
            tokens.forEach { $0.removeFromSuperview() }
            tokens = draft.recipients.map { recipient in
                let token = MacRecipientTokenView(recipient: recipient)
                token.onClick = { [weak self] in self?.onTokenClick?(recipient.id) }
                addSubview(token, positioned: .below, relativeTo: textField)
                return token
            }
        } else {
            for (token, recipient) in zip(tokens, draft.recipients) { token.configure(recipient) }
        }
        selectedTokenID = draft.selectedID
        for token in tokens { token.isTokenSelected = token.recipient.id == draft.selectedID }
        if textField.stringValue != draft.text { textField.stringValue = draft.text }
        let height = flow(width: bounds.width)
        if height != preferredHeight {
            preferredHeight = height
            onHeightChange?()
        }
        needsLayout = true
    }

    func controlTextDidChange(_ notification: Notification) {
        onText?(textField.stringValue)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
            if textField.stringValue.trimmingCharacters(in: .whitespaces).isEmpty, selector == #selector(NSResponder.insertTab(_:)) { return false }
            onReturn?()
            return true
        case #selector(NSResponder.deleteBackward(_:)):
            guard textField.stringValue.isEmpty || selectedTokenID != nil else { return false }
            return onDeleteBackward?() ?? false
        case #selector(NSResponder.moveDown(_:)):
            return onMove?(1) ?? false
        case #selector(NSResponder.moveUp(_:)):
            return onMove?(-1) ?? false
        case #selector(NSResponder.cancelOperation(_:)):
            return onCancel?() ?? false
        default:
            return false
        }
    }

    func control(_ control: NSControl, textShouldBeginEditing fieldEditor: NSText) -> Bool { true }

    /// A comma ends a recipient, like Return.
    func controlTextDidEndEditing(_ notification: Notification) {}

    override func layout() {
        super.layout()
        background.frame = bounds
        background.layer?.cornerRadius = min(bounds.height, MacComposeMetrics.minHeight) / 2
        background.layer?.backgroundColor = resolved(NSColor(white: effectiveAppearance.isDarkMac ? 1 : 0, alpha: effectiveAppearance.isDarkMac ? 0.08 : 0.04), in: self)
        _ = flow(width: bounds.width)
    }

    @discardableResult
    private func flow(width: CGFloat) -> CGFloat {
        guard width > 0 else { return preferredHeight }
        let m = MacComposeMetrics.self
        let center = { (line: Int) in m.lineTop + CGFloat(line) * m.lineHeight + m.lineHeight / 2 }
        let toWidth = ceil(toLabel.attributedStringValue.size().width) + 4
        toLabel.frame = CGRect(x: m.toLeading, y: center(0) - 8, width: toWidth, height: 16)
        let start = m.toLeading + toWidth + m.toGap - m.tokenPadding
        let right = width - m.toLeading - m.addSize - 6
        var x = start
        var line = 0
        for token in tokens {
            let w = token.preferredWidth
            if x + w > right, x > start {
                line += 1
                x = start
            }
            token.frame = CGRect(x: x, y: center(line) - m.tokenHeight / 2, width: min(w, right - x), height: m.tokenHeight)
            x += w + 1
        }
        var textX = tokens.isEmpty ? start + m.tokenPadding : x + 2
        if right - textX < 80, !tokens.isEmpty {
            line += 1
            textX = start + m.tokenPadding
        }
        textField.frame = CGRect(x: textX, y: center(line) - 9, width: max(80, right - textX), height: 18)
        let height = max(m.minHeight, m.lineTop * 2 + CGFloat(line + 1) * m.lineHeight)
        addButton.frame = CGRect(x: width - m.toLeading - m.addSize + 4, y: height - m.lineTop - m.lineHeight / 2 - m.addSize / 2, width: m.addSize, height: m.addSize)
        return height
    }
}

/// One autocomplete row: avatar, name (typed prefix bold), address in its service color.
final class MacComposeSuggestionRow: MacFlippedView {
    private let avatar = MacAvatarView()
    private let name = makeMacLabel()
    private let detail = makeMacLabel()

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [avatar, name, detail] { addSubview(view) }
        detail.font = .systemFont(ofSize: 11)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ contact: ConversationContact, query: String) {
        avatar.initials = contact.initials
        avatar.colorHex = contact.colorHex
        let text = NSMutableAttributedString(string: contact.name, attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor])
        var offset = 0
        for word in contact.name.split(separator: " ") {
            if !query.isEmpty, word.lowercased().hasPrefix(query.lowercased()) {
                text.addAttribute(.font, value: NSFont.systemFont(ofSize: 13, weight: .semibold), range: NSRange(location: offset, length: min(query.count, word.count)))
                break
            }
            offset += word.count + 1
        }
        name.attributedStringValue = text
        let handle = contact.handles.first
        detail.stringValue = handle.map { "\($0.label) \($0.value)" } ?? ""
        detail.textColor = contact.service == .iMessage ? .systemBlue : .systemGreen
        setAccessibilityLabel(contact.name)
        setAccessibilityIdentifier("conversation.compose.suggestion.\(contact.id)")
    }

    override func layout() {
        super.layout()
        avatar.frame = CGRect(x: 10, y: (bounds.height - 28) / 2, width: 28, height: 28)
        name.frame = CGRect(x: 46, y: 6, width: bounds.width - 52, height: 17)
        detail.frame = CGRect(x: 46, y: 23, width: bounds.width - 52, height: 15)
    }
}

/// A Messages for Mac draft conversation: the To: header across the top of
/// the transcript pane, the autocomplete list under it, the service line, and
/// its own composer (the window hosts it in the bottom accessory).
@MainActor
final class MacComposeDraftController: NSViewController, NSTableViewDataSource, NSTableViewDelegate, MacComposerViewDelegate {
    let session: ConversationComposeSession
    let field = MacRecipientField()
    let composer = MacComposerView()
    private let serviceTitle = makeMacLabel()
    private let serviceSubtitle = makeMacLabel()
    private let suggestions = NSTableView()
    private let suggestionsScroll = NSScrollView()
    private let suggestionsPanel: NSView = {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView()
            glass.cornerRadius = 12
            return glass
        }
        let view = NSVisualEffectView()
        view.material = .popover
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = 12
        return view
    }()
    private var highlighted: Int?
    var onOpenConversation: ((ConversationCreation, ConversationComposeMessage) -> Void)?
    var onRecipientsChange: (() -> Void)?
    var onComposerHeightChange: (() -> Void)?

    init(directory: any ConversationDirectory) {
        session = ConversationComposeSession(directory: directory)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = MacFlippedView(frame: NSRect(x: 0, y: 0, width: 760, height: 700))
        root.setAccessibilityIdentifier("conversation.compose")
        for label in [serviceTitle, serviceSubtitle] {
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.isHidden = true
            root.addSubview(label)
        }
        serviceTitle.font = .systemFont(ofSize: 11, weight: .semibold)
        serviceTitle.setAccessibilityIdentifier("conversation.compose.service")
        let lock = NSTextAttachment()
        lock.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 8, weight: .semibold))
        lock.bounds = CGRect(x: 0, y: -0.5, width: 7, height: 9)
        let encrypted = NSMutableAttributedString(attachment: lock)
        encrypted.append(NSAttributedString(
            string: " " + String(localized: "conversation.start.encrypted", defaultValue: "Encrypted", bundle: .module),
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
        ))
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        encrypted.addAttributes([.foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: centered], range: NSRange(location: 0, length: encrypted.length))
        serviceSubtitle.attributedStringValue = encrypted

        root.addSubview(field)
        let column = NSTableColumn(identifier: .init("s"))
        suggestions.addTableColumn(column)
        suggestions.headerView = nil
        suggestions.rowHeight = MacComposeMetrics.suggestionRowHeight
        suggestions.intercellSpacing = .zero
        suggestions.backgroundColor = .clear
        suggestions.style = .plain
        suggestions.dataSource = self
        suggestions.delegate = self
        suggestions.target = self
        suggestions.action = #selector(suggestionClicked)
        suggestions.setAccessibilityIdentifier("conversation.compose.suggestions")
        suggestionsScroll.documentView = suggestions
        suggestionsScroll.drawsBackground = false
        suggestionsScroll.hasVerticalScroller = true
        suggestionsScroll.autohidesScrollers = true
        if #available(macOS 26.0, *), let glass = suggestionsPanel as? NSGlassEffectView {
            glass.contentView = suggestionsScroll
        } else {
            suggestionsPanel.addSubview(suggestionsScroll)
        }
        suggestionsPanel.isHidden = true
        root.addSubview(suggestionsPanel)
        view = root

        composer.delegate = self
        composer.placeholderText = ""
        composer.appsButton.isEnabled = false

        field.onText = { [weak self] text in self?.session.setText(text) }
        field.onReturn = { [weak self] in self?.commit() }
        field.onDeleteBackward = { [weak self] in self?.session.backspace() ?? false }
        field.onTokenClick = { [weak self] id in
            guard let self else { return }
            self.session.select(id)
            self.view.window?.makeFirstResponder(self.field.textField)
        }
        field.onAdd = { [weak self] in self?.showAllContacts() }
        field.onHeightChange = { [weak self] in self?.view.needsLayout = true }
        field.onMove = { [weak self] delta in self?.moveHighlight(delta) ?? false }
        field.onCancel = { [weak self] in
            guard let self, !self.session.suggestions.isEmpty else { return false }
            self.session.setText("")
            return true
        }
        session.onChange = { [weak self] change in self?.sessionDidChange(change) }
        sessionDidChange(.recipients)
    }

    func focusRecipients() {
        view.window?.makeFirstResponder(field.textField)
    }

    /// Prefills the first message (Forward's entrypoint): text in the
    /// composer, images as attachment cards; the To: field keeps focus.
    func setDraft(_ message: ConversationComposeMessage) {
        composer.text = message.text
        for image in message.images {
            if let nsImage = NSImage(data: image.data) {
                composer.addAttachment(MacComposerAttachment(image: nsImage, data: image.data, mimeType: image.mimeType))
            }
        }
        focusRecipients()
    }

    private func sessionDidChange(_ change: ConversationComposeSession.Change) {
        switch change {
        case .recipients:
            field.update(draft: session.draft)
            updateServiceLine()
            onRecipientsChange?()
        case .suggestions:
            highlighted = session.suggestions.isEmpty ? nil : 0
            suggestions.reloadData()
            if let highlighted { suggestions.selectRowIndexes(IndexSet(integer: highlighted), byExtendingSelection: false) }
            suggestionsPanel.isHidden = session.suggestions.isEmpty
            suggestionsPanel.alphaValue = session.suggestions.isEmpty ? 0 : 1
            updateServiceLine()
            view.needsLayout = true
        case .sending:
            break
        }
    }

    private func updateServiceLine() {
        let service = session.draft.service
        serviceTitle.stringValue = service == .sms
            ? String(localized: "conversation.compose.service.sms", defaultValue: "Text Message • SMS", bundle: .module)
            : "iMessage"
        let hidden = service == nil
        serviceTitle.isHidden = hidden
        serviceSubtitle.isHidden = hidden
    }

    /// Return: the highlighted suggestion, else the typed address.
    private func commit() {
        if let highlighted, highlighted < session.suggestions.count, !session.draft.query.isEmpty {
            session.add(session.suggestions[highlighted])
        } else {
            session.commitText()
        }
    }

    private func moveHighlight(_ delta: Int) -> Bool {
        guard !session.suggestions.isEmpty else { return false }
        let next = max(0, min(session.suggestions.count - 1, (highlighted ?? -1) + delta))
        highlighted = next
        suggestions.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        suggestions.scrollRowToVisible(next)
        return true
    }

    @objc private func suggestionClicked() {
        let row = suggestions.clickedRow
        guard row >= 0, row < session.suggestions.count else { return }
        session.add(session.suggestions[row])
        focusRecipients()
    }

    private func showAllContacts() {
        let menu = NSMenu()
        let excluding = session.draft.contactIDs
        Task { [weak self] in
            guard let self else { return }
            let contacts = (try? await self.session.directory.searchContacts("", limit: 500, excluding: excluding)) ?? []
            for contact in contacts {
                let item = NSMenuItem(title: contact.name, action: #selector(self.pickedContact(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = contact.id
                menu.addItem(item)
            }
            self.allContacts = contacts
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: self.field.addButton.bounds.height + 4), in: self.field.addButton)
        }
    }

    private var allContacts: [ConversationContact] = []

    @objc private func pickedContact(_ item: NSMenuItem) {
        guard let id = item.representedObject as? String, let contact = allContacts.first(where: { $0.id == id }) else { return }
        session.add(contact)
        focusRecipients()
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        let m = MacComposeMetrics.self
        // The pane runs under the floating sidebar; lay out in the safe area.
        let insets = view.safeAreaInsets
        let top = insets.top + m.fieldTopGap
        let left = insets.left + m.fieldInset
        let width = view.bounds.width - insets.left - insets.right - 2 * m.fieldInset
        field.frame = CGRect(x: left, y: top, width: width, height: field.preferredHeight)
        serviceTitle.frame = CGRect(x: insets.left, y: field.frame.maxY + 18, width: view.bounds.width - insets.left - insets.right, height: 14)
        serviceSubtitle.frame = CGRect(x: insets.left, y: serviceTitle.frame.maxY + 1, width: serviceTitle.frame.width, height: 14)
        let rows = CGFloat(min(session.suggestions.count, 6))
        suggestionsPanel.frame = rows > 0
            ? CGRect(x: left + 40, y: field.frame.maxY + 4, width: min(m.suggestionWidth, width - 40), height: rows * m.suggestionRowHeight + 8)
            : .zero
        suggestionsScroll.frame = suggestionsPanel.bounds.insetBy(dx: 0, dy: 4)
        suggestions.tableColumns.first?.width = suggestionsScroll.bounds.width
    }

    // MARK: Sending

    func send() {
        let images = composer.attachments.map {
            ConversationComposeImage(data: $0.data, width: Int($0.image.size.width), height: Int($0.image.size.height), mimeType: $0.mimeType)
        }
        let message = ConversationComposeMessage(text: composer.text.trimmingCharacters(in: .whitespacesAndNewlines), images: images)
        guard !message.isEmpty, !session.isSending else { return }
        if session.draft.recipients.isEmpty && session.draft.query.isEmpty {
            focusRecipients()
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                let creation = try await self.session.openConversation()
                self.composer.clearAfterSend()
                self.onOpenConversation?(creation, message)
            } catch {
                let alert = NSAlert()
                let invalid = (error as? ConversationBackendError)?.code == -32005
                alert.messageText = invalid
                    ? String(localized: "conversation.compose.invalid.title", defaultValue: "Not a Valid Address", bundle: .module)
                    : String(localized: "conversation.compose.failed.title", defaultValue: "Could Not Start Conversation", bundle: .module)
                alert.informativeText = invalid
                    ? String(localized: "conversation.compose.invalid.message", defaultValue: "Remove the red recipients and try again.", bundle: .module)
                    : String(describing: error)
                if let window = self.view.window { alert.beginSheetModal(for: window, completionHandler: nil) } else { alert.runModal() }
            }
        }
    }

    func composerDidChangeText(_ composer: MacComposerView) {}
    func composerDidChangeHeight(_ composer: MacComposerView) { onComposerHeightChange?() }
    func composerDidSubmit(_ composer: MacComposerView) { send() }
    func composerDidTapApps(_ composer: MacComposerView) {}

    // MARK: Suggestions table

    func numberOfRows(in tableView: NSTableView) -> Int { session.suggestions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let view = tableView.makeView(withIdentifier: .init("s"), owner: nil) as? MacComposeSuggestionRow ?? MacComposeSuggestionRow()
        view.identifier = .init("s")
        view.configure(session.suggestions[row], query: session.draft.query)
        return view
    }

    // MARK: Lab

    /// `to <text>`, `return`, `backspace`, `down`, `up`, `tap <i>`, `pick <i>`,
    /// `body <text>`, `draft <text>`, `send`, `state`.
    func labCommand(_ line: String) -> String {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let arg = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "to":
            focusRecipients()
            field.textField.stringValue = arg
            session.setText(arg)
        case "return": commit()
        case "backspace":
            if !session.backspace() {
                field.textField.stringValue = String(field.textField.stringValue.dropLast())
                session.setText(field.textField.stringValue)
            }
        case "down": _ = moveHighlight(1)
        case "up": _ = moveHighlight(-1)
        case "tap":
            guard let index = Int(arg), index < session.draft.recipients.count else { return "error no token" }
            session.select(session.draft.recipients[index].id)
        case "pick":
            guard let index = Int(arg), index < session.suggestions.count else { return "error no suggestion" }
            session.add(session.suggestions[index])
        case "body": composer.text = arg
        case "draft": setDraft(ConversationComposeMessage(text: arg))
        case "send": send()
        case "state": break
        default: return "error unknown"
        }
        let draft = session.draft
        let tokens = draft.recipients.map { r in "\(r.name)[\(r.state)]\(r.id == draft.selectedID ? "*" : "")" }.joined(separator: ",")
        return "tokens=\(tokens) text=\(draft.text) suggestions=\(session.suggestions.map(\.name).joined(separator: ",")) highlighted=\(highlighted.map(String.init) ?? "-") service=\(draft.service?.rawValue ?? "-")"
    }
}

/// The sidebar's draft row while composing: an empty avatar and "New
/// Message", or the recipients' names once there are any.
final class MacComposeDraftRow: MacFlippedView {
    private let avatar = MacFlippedView()
    private let glyph = NSImageView()
    private let title = makeMacLabel()
    var onClick: (() -> Void)?
    var isEmphasized = true { didSet { needsLayout = true } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        avatar.wantsLayer = true
        addSubview(avatar)
        glyph.image = NSImage(systemSymbolName: "person.fill", accessibilityDescription: nil)?.withSymbolConfiguration(.init(pointSize: 18, weight: .regular))
        glyph.contentTintColor = .white
        avatar.addSubview(glyph)
        title.font = .systemFont(ofSize: 13, weight: .bold)
        title.maximumNumberOfLines = 1
        title.lineBreakMode = .byTruncatingTail
        addSubview(title)
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityIdentifier("conversation.sidebar.draft")
        configure(names: [])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(names: [String]) {
        title.stringValue = names.isEmpty
            ? String(localized: "conversation.compose.title", defaultValue: "New Message", bundle: .module)
            : ListFormatter.localizedString(byJoining: names)
        setAccessibilityLabel(title.stringValue)
    }

    override func mouseDown(with event: NSEvent) { onClick?() }

    override func layout() {
        super.layout()
        // Same geometry as a conversation row: 40 pt avatar at 12 pt, text at 56 pt.
        let fill = bounds.insetBy(dx: 10, dy: 0)
        layer?.cornerRadius = 0
        let selection = CAShapeLayer()
        selection.path = CGPath(roundedRect: fill, cornerWidth: 10, cornerHeight: 10, transform: nil)
        selection.fillColor = isEmphasized ? resolved(.controlAccentColor, in: self) : resolved(NSColor(white: effectiveAppearance.isDarkMac ? 1 : 0, alpha: 0.07), in: self)
        layer?.sublayers?.filter { $0.name == "draftSelection" }.forEach { $0.removeFromSuperlayer() }
        selection.name = "draftSelection"
        layer?.insertSublayer(selection, at: 0)
        avatar.frame = CGRect(x: 12, y: (bounds.height - 40) / 2 - 1, width: 40, height: 40)
        avatar.layer?.cornerRadius = 20
        avatar.layer?.backgroundColor = resolved(NSColor(white: 0.62, alpha: 1), in: self)
        glyph.frame = avatar.bounds.insetBy(dx: 9, dy: 9)
        title.textColor = isEmphasized ? .white : .labelColor
        title.frame = CGRect(x: 56, y: (bounds.height - 17) / 2, width: bounds.width - 66, height: 17)
    }
}
#endif
