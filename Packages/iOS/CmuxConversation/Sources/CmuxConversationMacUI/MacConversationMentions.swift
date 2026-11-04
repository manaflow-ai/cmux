#if os(macOS)
import AppKit
import CmuxConversationCore
import CmuxConversationGeometry

extension NSAttributedString.Key {
    /// The mentioned participant's id on a mention's characters.
    static let macConversationMention = NSAttributedString.Key("cmuxMacConversationMention")
}

/// Mentions draw bold in the bubble's text color; a mention of me draws in
/// the accent color in an incoming bubble. In the composer a picked mention
/// is bold and blue, and a name that could become one is gray.
enum MacMentionStyle {
    static let accent = NSColor.systemBlue
    static let candidate = NSColor.secondaryLabelColor

    static func boldFont(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    /// `font` is the fallback where the text has none; formatted mentions
    /// keep their style and size and gain bold.
    static func apply(to text: NSMutableAttributedString, mentions: [ConversationMention], meID: String?, outgoing: Bool, font: NSFont) {
        for mention in ConversationMentionEditing.normalized(mentions, textLength: text.length) {
            embolden(text, range: mention.nsRange, fallback: font)
            text.addAttribute(.macConversationMention, value: mention.participantID, range: mention.nsRange)
            if !outgoing, mention.participantID == meID {
                paint(text, range: mention.nsRange, color: accent)
            }
        }
    }

    static func embolden(_ text: NSMutableAttributedString, range: NSRange, fallback: NSFont) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            text.addAttribute(.font, value: boldFont(value as? NSFont ?? fallback), range: subrange)
        }
    }

    /// Text-effect glyphs draw clear and take their color from the effect ink.
    static func paint(_ text: NSMutableAttributedString, range: NSRange, color: NSColor) {
        text.enumerateAttribute(.conversationTextEffect, in: range) { effect, subrange, _ in
            text.addAttribute(effect == nil ? .foregroundColor : .conversationEffectInk, value: color, range: subrange)
        }
    }
}

/// Mention editing for the composer's text view: tracks mention ranges
/// through edits, grays a name that can become a mention, lists matching
/// participants in a popover (arrows move, Return or Tab picks, Escape
/// dismisses), and deletes a mention as one token.
@MainActor
final class MacComposerMentionController {
    private weak var textView: MacComposerTextView?
    private(set) var mentions: [ConversationMention] = []
    private(set) var query: ConversationMentionQuery?
    /// Who can be mentioned; empty outside group conversations.
    var participants: () -> [ConversationParticipant] = { [] }
    private let suggestions = MacMentionSuggestionsController()
    private var popover: NSPopover?
    /// The query location the user dismissed with Escape.
    private var dismissedLocation: Int?
    /// The candidate the last restyle drew gray.
    private var decoratedQuery: ConversationMentionQuery?

    init(textView: MacComposerTextView) {
        self.textView = textView
        suggestions.onPick = { [weak self] participant in self?.commit(participant) }
        textView.decorateStorage = { [weak self] storage in self?.decorate(storage) }
    }

    var draft: ConversationMentionDraft {
        ConversationMentionDraft(text: textView?.string ?? "", mentions: mentions)
    }

    var isShowingSuggestions: Bool { popover?.isShown == true }

    /// Called from `textView(_:shouldChangeTextIn:replacementString:)`.
    func shouldChange(_ range: NSRange, replacement: String?) -> Bool {
        guard textView != nil, let replacement, !isApplying, !mentions.isEmpty else { return true }
        let result = ConversationMentionEditing.apply(range, replacement: replacement, to: draft)
        guard result.range != range else {
            mentions = result.draft.mentions
            return true
        }
        // A deletion reached into a mention: remove the whole token.
        replace(result.range, with: result.replacement, mentions: result.draft.mentions, caret: result.caret)
        return false
    }

    func textDidChange() {
        guard let textView, !isApplying else { return }
        let ns = textView.string as NSString
        let people = participants()
        mentions = ConversationMentionEditing.normalized(mentions, textLength: ns.length).filter { mention in
            people.first { $0.id == mention.participantID }.map { ns.substring(with: mention.nsRange) == $0.mentionName } ?? false
        }
        refresh(restyle: true)
    }

    func selectionDidChange() {
        refresh(restyle: false)
    }

    func reset() {
        mentions = []
        dismissedLocation = nil
        refresh(restyle: true)
    }

    /// Keyboard handling while suggestions show. Return picks only for an
    /// "@" query, so Return after a typed name still sends.
    func handle(_ selector: Selector) -> Bool {
        guard isShowingSuggestions, let query else { return false }
        switch selector {
        case #selector(NSResponder.moveDown(_:)):
            suggestions.moveSelection(1)
        case #selector(NSResponder.moveUp(_:)):
            suggestions.moveSelection(-1)
        case #selector(NSResponder.insertTab(_:)):
            suggestions.pickSelected()
        case #selector(NSResponder.insertNewline(_:)):
            guard query.kind == .explicit else { return false }
            suggestions.pickSelected()
        case #selector(NSResponder.cancelOperation(_:)):
            dismissedLocation = query.location
            refresh(restyle: true)
        default:
            return false
        }
        return true
    }

    func commit(_ participant: ConversationParticipant) {
        guard let query else { return }
        let result = ConversationMentionEditing.commit(query, participant: participant, in: draft)
        replace(result.range, with: result.replacement, mentions: result.draft.mentions, caret: result.caret)
    }

    private func replace(_ range: NSRange, with replacement: String, mentions: [ConversationMention], caret: Int) {
        guard let textView else { return }
        // Through the text view's own insertion so undo, the input context
        // and the composer's change handling all see a normal edit.
        isApplying = true
        textView.insertText(replacement, replacementRange: range)
        isApplying = false
        self.mentions = mentions
        textView.setSelectedRange(NSRange(location: caret, length: 0))
        refresh(restyle: true)
    }

    /// Set while `replace` edits, so the delegate hooks leave mentions alone.
    private var isApplying = false

    private func refresh(restyle force: Bool) {
        guard let textView else { return }
        let selection = textView.selectedRange()
        var next = selection.length == 0
            ? ConversationMentionEditing.query(in: draft, caret: selection.location, participants: participants())
            : nil
        if let candidate = next, candidate.location == dismissedLocation {
            next = nil
        } else if next?.location != dismissedLocation {
            dismissedLocation = nil
        }
        if force || next != query { restyle(query: next) }
        guard next != query else { return }
        query = next
        if let next, textView.window?.firstResponder === textView {
            showPopover(next)
        } else {
            closePopover()
        }
    }

    /// Recolors the draft through the composer's formatting restyle, so
    /// bold/italic/effects (semantic keys in the storage) survive.
    private func restyle(query: ConversationMentionQuery?) {
        guard let textView, !textView.hasMarkedText() else { return }
        decoratedQuery = query
        textView.restyle()
        textView.clearTypingDecorations()
    }

    /// Called inside the text view's restyle, after formatting fonts are derived.
    private func decorate(_ storage: NSTextStorage) {
        let base = textView?.baseTypingAttributes[.foregroundColor] as? NSColor ?? .labelColor
        MacMentionStyle.paint(storage, range: NSRange(location: 0, length: storage.length), color: base)
        for mention in ConversationMentionEditing.normalized(mentions, textLength: storage.length) {
            MacMentionStyle.embolden(storage, range: mention.nsRange, fallback: MacConversationTheme.composerFont)
            MacMentionStyle.paint(storage, range: mention.nsRange, color: MacMentionStyle.accent)
        }
        if let query = decoratedQuery, NSMaxRange(query.nsRange) <= storage.length {
            MacMentionStyle.paint(storage, range: query.nsRange, color: MacMentionStyle.candidate)
        }
    }

    private func showPopover(_ query: ConversationMentionQuery) {
        guard let textView, let manager = textView.layoutManager, let container = textView.textContainer else { return }
        suggestions.configure(matches: query.matches)
        let glyphs = manager.glyphRange(forCharacterRange: query.nsRange, actualCharacterRange: nil)
        var rect = manager.boundingRect(forGlyphRange: glyphs, in: container)
        rect.origin.x += textView.textContainerOrigin.x
        rect.origin.y += textView.textContainerOrigin.y
        rect.size.width = max(rect.width, 1)
        if let popover, popover.isShown {
            popover.contentSize = suggestions.preferredContentSize
            popover.positioningRect = rect
            return
        }
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.animates = true
        popover.contentViewController = suggestions
        popover.contentSize = suggestions.preferredContentSize
        // The composer sits at the window bottom: open upward.
        popover.show(relativeTo: rect, of: textView, preferredEdge: textView.isFlipped ? .minY : .maxY)
        self.popover = popover
    }

    private func closePopover() {
        popover?.close()
        popover = nil
    }
}

/// The participants matching a mention query, one row each.
@MainActor
final class MacMentionSuggestionsController: NSViewController {
    var onPick: ((ConversationParticipant) -> Void)?
    private(set) var matches: [ConversationParticipant] = []
    private(set) var selectedIndex = 0
    private var rows: [MacMentionSuggestionRow] = []
    static let rowHeight: CGFloat = 32

    override func loadView() {
        view = MacFlippedView(frame: NSRect(x: 0, y: 0, width: 220, height: Self.rowHeight + 10))
        view.setAccessibilityIdentifier("conversation.mentions.suggestions")
    }

    func configure(matches: [ConversationParticipant]) {
        _ = view
        if matches.map(\.id) != self.matches.map(\.id) { selectedIndex = 0 }
        self.matches = matches
        rows.forEach { $0.removeFromSuperview() }
        rows = matches.prefix(6).enumerated().map { index, participant in
            let row = MacMentionSuggestionRow(participant: participant)
            row.frame = NSRect(x: 5, y: 5 + CGFloat(index) * Self.rowHeight, width: 210, height: Self.rowHeight)
            row.onClick = { [weak self] in self?.onPick?(participant) }
            view.addSubview(row)
            return row
        }
        preferredContentSize = NSSize(width: 220, height: CGFloat(rows.count) * Self.rowHeight + 10)
        updateSelection()
    }

    func moveSelection(_ delta: Int) {
        guard !rows.isEmpty else { return }
        selectedIndex = (selectedIndex + delta + rows.count) % rows.count
        updateSelection()
    }

    func pickSelected() {
        guard selectedIndex < matches.count else { return }
        onPick?(matches[selectedIndex])
    }

    private func updateSelection() {
        for (index, row) in rows.enumerated() { row.isSelected = index == selectedIndex }
    }
}

final class MacMentionSuggestionRow: MacFlippedView {
    var onClick: (() -> Void)?
    var isSelected = false { didSet { updateColors() } }
    private let avatar = MacAvatarView()
    private let name = makeMacLabel()

    init(participant: ConversationParticipant) {
        super.init(frame: .zero)
        avatar.initials = participant.initials
        avatar.colorHex = participant.colorHex
        name.stringValue = participant.name
        name.font = .systemFont(ofSize: 13)
        name.maximumNumberOfLines = 1
        addSubview(avatar)
        addSubview(name)
        layer?.cornerRadius = 6
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(participant.name)
        setAccessibilityIdentifier("conversation.mentions.suggestion.\(participant.id)")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        avatar.frame = NSRect(x: 6, y: (bounds.height - 22) / 2, width: 22, height: 22)
        name.frame = NSRect(x: 36, y: (bounds.height - 17) / 2, width: bounds.width - 42, height: 17)
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        layer?.backgroundColor = isSelected ? resolved(.controlAccentColor, in: self) : nil
        name.textColor = isSelected ? .white : .labelColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?()
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// A compact contact card shown when a mention is clicked.
final class MacMentionCardController: NSViewController {
    private let participant: ConversationParticipant

    init(participant: ConversationParticipant) {
        self.participant = participant
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = MacFlippedView(frame: NSRect(x: 0, y: 0, width: 200, height: 112))
        let avatar = MacAvatarView(frame: NSRect(x: 76, y: 14, width: 48, height: 48))
        avatar.initials = participant.initials
        avatar.colorHex = participant.colorHex
        let name = makeMacLabel()
        name.stringValue = participant.name
        name.font = .systemFont(ofSize: 13, weight: .semibold)
        name.alignment = .center
        name.frame = NSRect(x: 8, y: 72, width: 184, height: 20)
        root.addSubview(avatar)
        root.addSubview(name)
        root.setAccessibilityIdentifier("conversation.mentions.card")
        view = root
        preferredContentSize = root.frame.size
    }
}

extension MacComposerView {
    func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
        mentionController.shouldChange(affectedCharRange, replacement: replacementString)
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        mentionController.selectionDidChange()
    }

    /// The draft's mentions, captured before the composer clears on send.
    var mentions: [ConversationMention] { mentionController.mentions }
}
#endif

#if os(macOS)
extension MacConversationViewController {
    /// Mentions work in group conversations only, as in Messages.
    func installMentions() {
        composer.mentionController.participants = { [weak self] in
            guard let info = self?.store.info, info.kind == .group else { return [] }
            return info.participants
        }
    }

    /// Clicking a mention shows that participant's card.
    func showMentionCard(participantID: String, at point: CGPoint, in rowView: NSView) {
        guard let participant = store.info?.participant(participantID) else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = MacMentionCardController(participant: participant)
        popover.show(relativeTo: NSRect(x: point.x - 2, y: point.y - 2, width: 4, height: 4), of: rowView, preferredEdge: .maxY)
    }
}
#endif

#if os(macOS)
extension MacConversationViewController {
    /// Lab verbs: `mention state`, `mention key <selector>`, `mention backspace`,
    /// `mention pick <id>`, `mention click <text>` (clicks that mention in the newest row showing it).
    func mentionLabCommand(_ argument: String) -> String {
        let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
        let textView = composer.textView
        let controller = composer.mentionController
        switch parts.first ?? "" {
        case "state":
            var runs: [String] = []
            if let storage = textView.textStorage {
                storage.enumerateAttributes(in: NSRange(location: 0, length: storage.length)) { attributes, range, _ in
                    let font = attributes[.font] as? NSFont
                    let bold = font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false
                    let color = (attributes[.foregroundColor] as? NSColor)?.usingColorSpace(.sRGB)
                    let rgb = color.map { String(format: "%.2f,%.2f,%.2f,%.2f", $0.redComponent, $0.greenComponent, $0.blueComponent, $0.alphaComponent) } ?? "-"
                    runs.append("[\((storage.string as NSString).substring(with: range))|\(bold ? "B" : "")|\(rgb)]")
                }
            }
            let mentions = controller.mentions.map { "\($0.participantID)@\($0.location)+\($0.length)" }.joined(separator: ",")
            let query = controller.query.map { "\($0.kind)@\($0.location)+\($0.length):\($0.matches.map(\.id).joined(separator: ","))" } ?? "-"
            return "text=\(textView.string.debugDescription) sel=\(textView.selectedRange().location) mentions=[\(mentions)] query=\(query) popover=\(controller.isShowingSuggestions) fr=\(view.window?.firstResponder.map { String(describing: type(of: $0)) } ?? "-") runs=\(runs.joined())"
        case "key":
            textView.doCommand(by: NSSelectorFromString(parts.count > 1 ? parts[1] : ""))
            return "ok"
        case "backspace":
            textView.deleteBackward(nil)
            return "ok"
        case "insert":
            // As typed on a keyboard: at the selection.
            textView.insertText(parts.count > 1 ? parts[1] : "", replacementRange: NSRange(location: NSNotFound, length: 0))
            return "ok"
        case "pick":
            guard let participant = store.info?.participant(parts.count > 1 ? parts[1] : "") else { return "error no participant" }
            controller.commit(participant)
            return "ok"
        case "click":
            let needle = parts.count > 1 ? parts[1] : ""
            for index in rows.indices.reversed() {
                guard let model = messageModel(at: index), model.message.text.contains(needle) else { continue }
                tableView.scrollRowToVisible(index)
                guard let rowView = rowView(at: index), let frame = rowView.rowLayout?.textFrame else { return "error not visible" }
                let text = layoutCache.text(model)
                let storage = NSTextStorage(attributedString: text)
                let manager = NSLayoutManager()
                let container = NSTextContainer(size: CGSize(width: frame.width, height: .greatestFiniteMagnitude))
                container.lineFragmentPadding = 0
                manager.addTextContainer(container)
                storage.addLayoutManager(manager)
                let range = (text.string as NSString).range(of: needle)
                let rect = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                let point = NSPoint(x: frame.minX + rect.midX, y: frame.minY + rect.midY)
                guard let participantID = text.attribute(.macConversationMention, at: range.location, effectiveRange: nil) as? String else {
                    return "error not a mention"
                }
                showMentionCard(participantID: participantID, at: point, in: rowView)
                return "card \(participantID)"
            }
            return "error no row"
        default:
            return "error usage mention state|key <selector>|backspace|pick <id>|click <text>"
        }
    }
}
#endif
