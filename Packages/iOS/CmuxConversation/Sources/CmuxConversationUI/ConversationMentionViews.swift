#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

extension NSAttributedString.Key {
    /// The mentioned participant's id on a mention's characters.
    static let conversationMention = NSAttributedString.Key("cmuxConversationMention")
}

/// How mentions draw. Messages sets a mention in bold in the bubble's text
/// color, and a mention of me in the accent color so it stands out in an
/// incoming bubble; the composer shows a picked mention bold and blue and a
/// name that could become one in gray.
enum ConversationMentionStyle {
    static let accent = UIColor.systemBlue
    static let candidate = UIColor.secondaryLabel

    static func boldFont(_ font: UIFont) -> UIFont {
        font.fontDescriptor.withSymbolicTraits(.traitBold).map { UIFont(descriptor: $0, size: font.pointSize) }
            ?? .systemFont(ofSize: font.pointSize, weight: .bold)
    }

    /// `font` is the fallback where the text has none; formatted mentions
    /// keep their style and size and gain bold.
    static func apply(to text: NSMutableAttributedString, mentions: [ConversationMention], meID: String?, outgoing: Bool, font: UIFont) {
        for mention in ConversationMentionEditing.normalized(mentions, textLength: text.length) {
            embolden(text, range: mention.nsRange, fallback: font)
            text.addAttribute(.conversationMention, value: mention.participantID, range: mention.nsRange)
            if !outgoing, mention.participantID == meID {
                paint(text, range: mention.nsRange, color: accent)
            }
        }
    }

    static func embolden(_ text: NSMutableAttributedString, range: NSRange, fallback: UIFont) {
        text.enumerateAttribute(.font, in: range) { value, subrange, _ in
            text.addAttribute(.font, value: boldFont(value as? UIFont ?? fallback), range: subrange)
        }
    }

    /// Text-effect glyphs draw clear and take their color from the effect ink.
    static func paint(_ text: NSMutableAttributedString, range: NSRange, color: UIColor) {
        text.enumerateAttribute(.conversationTextEffect, in: range) { effect, subrange, _ in
            text.addAttribute(effect == nil ? .foregroundColor : .conversationEffectInk, value: color, range: subrange)
        }
    }
}

/// Mention editing for the composer's text view: tracks mention ranges
/// through edits, grays a name that can become a mention, offers the
/// matching participants, and deletes a mention as one token.
@MainActor
final class ComposerMentionController: NSObject, UIGestureRecognizerDelegate, NSTextStorageDelegate {
    private weak var textView: ComposerTextView?
    private(set) var mentions: [ConversationMention] = []
    private(set) var query: ConversationMentionQuery?
    /// Who can be mentioned; empty outside group conversations.
    var participants: () -> [ConversationParticipant] = { [] }
    var onQueryChange: ((ConversationMentionQuery?) -> Void)?
    let suggestions = ConversationMentionSuggestionsView()
    /// The candidate the last restyle drew gray.
    private var decoratedQuery: ConversationMentionQuery?

    init(textView: ComposerTextView) {
        self.textView = textView
        super.init()
        textView.deleteBackwardHandler = { [weak self] in self?.deleteBackward() ?? false }
        textView.decorateStorage = { [weak self] storage in self?.decorate(storage) }
        // Every character edit, whatever its source (keyboard, paste,
        // dictation, programmatic insertText), shifts mentions here.
        textView.textStorage.delegate = self
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.cancelsTouchesInView = false
        tap.delegate = self
        textView.addGestureRecognizer(tap)
        suggestions.onPick = { [weak self] participant in self?.commit(participant) }
    }

    var draft: ConversationMentionDraft {
        ConversationMentionDraft(text: textView?.text ?? "", mentions: mentions)
    }

    /// Called from `textView(_:shouldChangeTextIn:replacementText:)`. A
    /// deletion that reaches into a mention removes the whole token instead.
    func shouldChange(_ range: NSRange, replacement: String) -> Bool {
        guard let textView, !mentions.isEmpty, textView.markedTextRange == nil else { return true }
        let result = ConversationMentionEditing.apply(range, replacement: replacement, to: draft)
        guard result.range != range else { return true }
        replace(result.range, with: result.replacement, mentions: result.draft.mentions, caret: result.caret)
        return false
    }

    nonisolated func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorage.EditActions, range editedRange: NSRange, changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        MainActor.assumeIsolated {
            guard !isApplying, !mentions.isEmpty else { return }
            let original = NSRange(location: editedRange.location, length: editedRange.length - delta)
            mentions = ConversationMentionEditing.adjusted(mentions, forEdit: original, replacementLength: editedRange.length)
        }
    }

    /// Set while `replace` edits, which assigns the resulting mentions itself.
    private var isApplying = false

    /// Delete with the caret just after, or a selection touching, a mention
    /// removes the whole mention.
    func deleteBackward() -> Bool {
        guard let textView, !mentions.isEmpty, textView.markedTextRange == nil else { return false }
        var range = textView.selectedRange
        if range.length == 0 {
            guard range.location > 0 else { return false }
            range = (textView.text as NSString).rangeOfComposedCharacterSequence(at: range.location - 1)
        }
        // Only a deletion that reaches into a mention is handled here; any
        // other one goes through UIKit, which reports it to shouldChange.
        let result = ConversationMentionEditing.apply(range, replacement: "", to: draft)
        guard result.range != range else { return false }
        replace(result.range, with: "", mentions: result.draft.mentions, caret: result.caret)
        return true
    }

    func textDidChange() {
        guard let textView else { return }
        // Drop any mention whose text no longer names its participant
        // (autocorrect, dictation and paste can bypass shouldChange).
        let ns = textView.text as NSString? ?? ""
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
        refresh(restyle: true)
    }

    func commit(_ participant: ConversationParticipant) {
        guard let query else { return }
        let result = ConversationMentionEditing.commit(query, participant: participant, in: draft)
        guard let textView else { return }
        UIView.transition(with: textView, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction]) {
            self.replace(result.range, with: result.replacement, mentions: result.draft.mentions, caret: result.caret)
        }
    }

    private func replace(_ range: NSRange, with replacement: String, mentions: [ConversationMention], caret: Int) {
        guard let textView else { return }
        isApplying = true
        textView.textStorage.replaceCharacters(in: range, with: replacement)
        isApplying = false
        self.mentions = mentions
        textView.selectedRange = NSRange(location: caret, length: 0)
        // Programmatic edits do not reach the delegate; the composer grows,
        // shows its send button and restyles through the normal path.
        textView.delegate?.textViewDidChange?(textView)
    }

    private func refresh(restyle force: Bool) {
        guard let textView else { return }
        let caret = textView.selectedRange.length == 0 ? textView.selectedRange.location : -1
        let next = caret >= 0 ? ConversationMentionEditing.query(in: draft, caret: caret, participants: participants()) : nil
        if force || next != query { restyle(query: next) }
        if next != query {
            query = next
            onQueryChange?(next)
        }
    }

    /// Recolors the whole draft through the composer's formatting restyle:
    /// base color, mentions bold blue, a candidate gray. Formatting (bold,
    /// italic, effects) lives in the storage's semantic keys and survives.
    private func restyle(query: ConversationMentionQuery?) {
        guard let textView, textView.markedTextRange == nil else { return }
        decoratedQuery = query
        textView.restyle()
        textView.clearTypingDecorations()
    }

    /// Called inside the text view's restyle, after formatting fonts are derived.
    private func decorate(_ storage: NSTextStorage) {
        let base = textView?.baseTypingAttributes[.foregroundColor] as? UIColor ?? .label
        ConversationMentionStyle.paint(storage, range: NSRange(location: 0, length: storage.length), color: base)
        for mention in ConversationMentionEditing.normalized(mentions, textLength: storage.length) {
            ConversationMentionStyle.embolden(storage, range: mention.nsRange, fallback: ConversationTheme.bodyFont)
            ConversationMentionStyle.paint(storage, range: mention.nsRange, color: ConversationMentionStyle.accent)
        }
        if let query = decoratedQuery, NSMaxRange(query.nsRange) <= storage.length {
            ConversationMentionStyle.paint(storage, range: query.nsRange, color: ConversationMentionStyle.candidate)
        }
    }

    // MARK: Tapping the gray name

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func tapped(_ tap: UITapGestureRecognizer) {
        guard let textView, let query, query.matches.count == 1 else { return }
        let point = tap.location(in: textView)
        guard let position = textView.closestPosition(to: point) else { return }
        let index = textView.offset(from: textView.beginningOfDocument, to: position)
        guard index >= query.location, index <= query.location + query.length else { return }
        commit(query.matches[0])
    }
}

/// The participants matching a mention query, in a glass panel above the
/// composer (Messages lists them in the keyboard's suggestion bar, which an
/// app cannot fill).
final class ConversationMentionSuggestionsView: UIView {
    var onPick: ((ConversationParticipant) -> Void)?
    private let glass = makeGlassView(cornerRadius: 22, interactive: false)
    private var rows: [UIButton] = []
    private(set) var matches: [ConversationParticipant] = []
    static let rowHeight: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(glass)
        isHidden = true
        accessibilityIdentifier = "conversation.mentions.suggestions"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    var preferredHeight: CGFloat { CGFloat(min(matches.count, 4)) * Self.rowHeight + 8 }

    func configure(matches: [ConversationParticipant]) {
        self.matches = matches
        rows.forEach { $0.removeFromSuperview() }
        rows = matches.prefix(4).map { participant in
            var config = UIButton.Configuration.plain()
            config.title = participant.name
            config.baseForegroundColor = .label
            config.imagePadding = 10
            config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 12, bottom: 0, trailing: 12)
            config.image = Self.avatarImage(participant)
            let button = UIButton(configuration: config)
            button.contentHorizontalAlignment = .leading
            button.accessibilityIdentifier = "conversation.mentions.suggestion.\(participant.id)"
            button.addAction(UIAction { [weak self] _ in self?.onPick?(participant) }, for: .touchUpInside)
            glass.contentView.addSubview(button)
            return button
        }
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        glass.frame = bounds
        for (index, row) in rows.enumerated() {
            row.frame = CGRect(x: 0, y: 4 + CGFloat(index) * Self.rowHeight, width: bounds.width, height: Self.rowHeight)
        }
    }

    private static func avatarImage(_ participant: ConversationParticipant) -> UIImage {
        let avatar = ConversationAvatarView(frame: CGRect(x: 0, y: 0, width: 28, height: 28))
        avatar.configure(initials: participant.initials, colorHex: participant.colorHex)
        avatar.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: avatar.bounds).image { context in
            avatar.layer.render(in: context.cgContext)
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// A compact contact card shown when a mention is tapped.
final class ConversationMentionCardViewController: UIViewController {
    private let participant: ConversationParticipant

    init(participant: ConversationParticipant) {
        self.participant = participant
        super.init(nibName: nil, bundle: nil)
        preferredContentSize = CGSize(width: 220, height: 132)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        let avatar = ConversationAvatarView(frame: CGRect(x: 0, y: 0, width: 60, height: 60))
        avatar.configure(initials: participant.initials, colorHex: participant.colorHex)
        let name = UILabel()
        name.text = participant.name
        name.font = .systemFont(ofSize: 17, weight: .semibold)
        name.textAlignment = .center
        view.addSubview(avatar)
        view.addSubview(name)
        view.accessibilityIdentifier = "conversation.mentions.card"
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let bounds = view.safeAreaLayoutGuide.layoutFrame
        view.subviews.first?.frame = CGRect(x: bounds.midX - 30, y: bounds.minY + 16, width: 60, height: 60)
        view.subviews.last?.frame = CGRect(x: bounds.minX + 12, y: bounds.minY + 84, width: bounds.width - 24, height: 24)
    }
}
#endif

#if canImport(UIKit)
extension ConversationComposerView {
    func textView(_ textView: UITextView, shouldChangeTextIn range: NSRange, replacementText text: String) -> Bool {
        mentionController.shouldChange(range, replacement: text)
    }

    /// The draft's mentions, captured before the composer clears on send.
    var mentions: [ConversationMention] { mentionController.mentions }
}
#endif
