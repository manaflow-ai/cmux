#if os(macOS)
import AppKit
import CmuxConversationCore
import CmuxConversationGeometry

// Messages polls on macOS 26: the poll card, voting by click, "Add Choice",
// Poll Details, the composer from the apps menu, and the vote-failed
// recovery. Geometry and colors are shared with iOS (PollCardGeometry).

struct MacPollVoter: Hashable {
    var name: String
    var initials: String
    var colorHex: String
    var isMe: Bool
}

struct MacPollRowModel: Hashable {
    var poll: ConversationPoll
    var meID: String?
    var voteFailed: Bool
    var interactive: Bool
    var participants: [String: MacPollVoter]

    func isMine(_ optionID: String) -> Bool {
        meID.map { poll.hasVote(participantID: $0, optionID: optionID) } ?? false
    }

    var canAddChoice: Bool { interactive && poll.options.count < ConversationPoll.maxOptions }

    @MainActor
    static func attach(to row: MacConversationRow, store: ConversationStore) -> MacConversationRow {
        guard case let .message(model) = row else { return row }
        return .message(attach(to: model, store: store))
    }

    @MainActor
    static func attach(to model: MacMessageRowModel, store: ConversationStore) -> MacMessageRowModel {
        guard let poll = model.message.poll, let info = store.info else { return model }
        var model = model
        var participants: [String: MacPollVoter] = [:]
        for participant in info.participants {
            participants[participant.id] = MacPollVoter(
                name: participant.name, initials: participant.initials, colorHex: participant.colorHex, isMe: participant.isMe
            )
        }
        model.poll = MacPollRowModel(
            poll: poll,
            meID: store.meID,
            voteFailed: store.pollVoteFailure(messageID: model.message.id) != nil,
            interactive: store.canInteractWithPoll(model.message),
            participants: participants
        )
        return model
    }
}

enum MacPollStyle {
    static let metrics = PollCardGeometry.Metrics.macOS
    nonisolated(unsafe) static let titleFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    nonisolated(unsafe) static let optionFont = NSFont.systemFont(ofSize: 13)
    nonisolated(unsafe) static let stampFont = NSFont.systemFont(ofSize: 11, weight: .semibold)

    static func color(_ pair: (light: PollCardColors.RGBA, dark: PollCardColors.RGBA)) -> NSColor {
        NSColor(name: nil) { appearance in
            let c = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? pair.dark : pair.light
            return NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
        }
    }

    static func color(_ c: PollCardColors.RGBA) -> NSColor {
        NSColor(srgbRed: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static let selectedBar = color(PollCardColors.selectedBar)
    static let deselectedBar = color(PollCardColors.deselectedBar)
    static let track = color(PollCardColors.track)
    static let accent = color(PollCardColors.accent)

    static func measure(_ text: String, font: NSFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(rect.height)
    }

    static func cardLayout(_ model: MacPollRowModel, width: CGFloat) -> PollCardGeometry.Layout {
        let poll = model.poll
        let title = poll.question.isEmpty ? nil : measure(poll.question, font: titleFont, width: width - 2 * metrics.padding)
        let lineHeight = ceil(optionFont.ascender - optionFont.descender + optionFont.leading)
        return PollCardGeometry.layout(width: width, titleHeight: title, rows: poll.options.map { option in
            let voters = poll.voteCount(for: option.id)
            let textWidth = PollCardGeometry.textWidth(cardWidth: width, voterCount: voters, metrics)
            return (max(lineHeight, measure(option.text, font: optionFont, width: textWidth)), voters, CGFloat(poll.barFraction(for: option.id)))
        }, metrics)
    }

    static func votesText(_ count: Int) -> String {
        count == 1
            ? String(localized: "conversation.poll.oneVote", defaultValue: "1 Vote", bundle: .module)
            : String(format: String(localized: "conversation.poll.votes", defaultValue: "%lld Votes", bundle: .module), Int64(count))
    }
}

struct MacPollCellLayout {
    var cardFrame: CGRect
    var card: PollCardGeometry.Layout
    var addChoiceFrame: CGRect?
    var failedFrame: CGRect?
}

extension MacMessageLayout {
    static func computePoll(_ model: MacMessageRowModel, width: CGFloat) -> MacMessageLayout {
        let t = MacConversationTheme.self
        let pollModel = model.poll!
        let margin = t.sideMargin
        let avatarColumn = model.isGroup ? t.avatarSize + t.avatarGap : 0
        let cardWidth = PollCardGeometry.cardWidth(available: floor((width - avatarColumn) * t.maxBubbleWidthFraction), MacPollStyle.metrics)
        var y: CGFloat = 0
        var senderNameFrame: CGRect?
        if model.showsSenderName, model.senderName != nil {
            senderNameFrame = CGRect(x: margin + avatarColumn + t.senderNameInset, y: y, width: cardWidth, height: 13)
            y += 14
        }
        if !model.reactionKinds.isEmpty { y += 14 }
        let card = MacPollStyle.cardLayout(pollModel, width: cardWidth)
        let cardX = model.isOutgoing ? width - t.outgoingMargin - cardWidth : margin + avatarColumn
        let cardFrame = CGRect(x: cardX, y: y, width: cardWidth, height: card.size.height)
        y = cardFrame.maxY + (model.showsTail ? t.tailDrop : 0)
        func sideRect(_ y: CGFloat, height: CGFloat) -> CGRect {
            model.isOutgoing
                ? CGRect(x: margin, y: y, width: cardFrame.maxX - 5 - margin, height: height)
                : CGRect(x: cardFrame.minX + 5, y: y, width: width - cardFrame.minX - 5 - margin, height: height)
        }
        var addChoiceFrame: CGRect?
        if pollModel.canAddChoice {
            addChoiceFrame = sideRect(y + 2, height: MacPollStyle.metrics.stampHeight)
            y += 2 + MacPollStyle.metrics.stampHeight
        }
        var failedFrame: CGRect?
        if pollModel.voteFailed {
            failedFrame = sideRect(y + 2, height: 14)
            y += 2 + 14
        }
        var footerFrame: CGRect?
        if model.footer != .none {
            footerFrame = sideRect(y + 2, height: 14)
            y += 2 + 14
        }
        let tailBottom = cardFrame.maxY + (model.showsTail ? t.tailDrop : 0)
        return MacMessageLayout(
            height: ceil(y),
            senderNameFrame: senderNameFrame,
            quoteFrame: nil,
            quoteTextFrame: nil,
            quoteAvatarFrame: nil,
            quoteThumbFrame: nil,
            threadPath: nil,
            imageFrames: [],
            bubbleFrame: nil,
            textFrame: nil,
            emojiFrame: nil,
            avatarFrame: model.showsAvatar ? CGRect(x: margin, y: tailBottom - t.avatarSize, width: t.avatarSize, height: t.avatarSize) : nil,
            reactionAnchor: model.reactionKinds.isEmpty ? nil : (model.isOutgoing ? CGPoint(x: cardFrame.minX, y: cardFrame.minY) : CGPoint(x: cardFrame.maxX, y: cardFrame.minY)),
            editedFrame: nil,
            repliesFrame: nil,
            footerFrame: footerFrame,
            failedBadgeFrame: nil,
            contentFrame: cardFrame,
            poll: MacPollCellLayout(cardFrame: cardFrame, card: card, addChoiceFrame: addChoiceFrame, failedFrame: failedFrame)
        )
    }
}

// MARK: - Views

final class MacPollOptionRowView: MacFlippedView {
    private let bar = CALayer()
    private let ring = CAShapeLayer()
    private let check = NSImageView()
    let label = makeMacLabel()
    private var avatars: [MacAvatarView] = []
    private(set) var optionID = ""
    private var mine = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.cornerRadius = MacPollStyle.metrics.rowCornerRadius
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        layer?.addSublayer(bar)
        layer?.addSublayer(ring)
        ring.lineWidth = PollCardColors.emptyCircleStrokeWidth
        check.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: nil)
        check.symbolConfiguration = .init(pointSize: 9, weight: .bold)
        check.contentTintColor = MacPollStyle.color(PollCardColors.selectedGlyph)
        addSubview(check)
        label.font = MacPollStyle.optionFont
        label.textColor = .labelColor
        addSubview(label)
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(option: ConversationPollOption, row: PollCardGeometry.Row, model: MacPollRowModel, animated: Bool) {
        optionID = option.id
        let origin = row.frame.origin
        frame = row.frame
        mine = model.isMine(option.id)
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.3)
        bar.frame = row.barFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        CATransaction.commit()
        let circle = row.circleFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        ring.frame = circle
        ring.path = CGPath(ellipseIn: CGRect(origin: .zero, size: circle.size).insetBy(dx: 0.75, dy: 0.75), transform: nil)
        check.frame = circle
        check.isHidden = !mine
        label.stringValue = option.text
        // NSTextField insets its text ~2 pt per side.
        label.frame = row.textFrame.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: -2, dy: 0)
        let voterIDs = model.poll.voterIDs(for: option.id)
        while avatars.count < row.avatarFrames.count {
            let avatar = MacAvatarView()
            avatar.layer?.borderWidth = 1
            addSubview(avatar)
            avatars.append(avatar)
        }
        for (index, avatar) in avatars.enumerated() {
            guard index < row.avatarFrames.count, index < voterIDs.count else {
                avatar.isHidden = true
                continue
            }
            avatar.isHidden = false
            avatar.frame = row.avatarFrames[index].offsetBy(dx: -origin.x, dy: -origin.y)
            let voter = model.participants[voterIDs[index]]
            avatar.initials = voter?.initials ?? ""
            avatar.colorHex = voter?.colorHex
        }
        updateColors()
        setAccessibilityLabel(option.text)
        setAccessibilityValue(MacPollStyle.votesText(voterIDs.count))
        setAccessibilityIdentifier("conversation.poll.option.\(option.id)")
    }

    private func updateColors() {
        layer?.backgroundColor = resolved(MacPollStyle.track, in: self)
        bar.backgroundColor = resolved(mine ? MacPollStyle.selectedBar : MacPollStyle.deselectedBar, in: self)
        ring.strokeColor = resolved(mine ? MacPollStyle.selectedBar : MacPollStyle.accent, in: self)
        ring.fillColor = mine ? resolved(MacPollStyle.selectedBar, in: self) : nil
        for avatar in avatars { avatar.layer?.borderColor = resolved(MacConversationTheme.incomingBubble, in: self) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }
}

final class MacPollCardView: MacFlippedView {
    private let background = MacBubbleLayer()
    let titleLabel = makeMacLabel()
    private(set) var rows: [MacPollOptionRowView] = []
    private var messageID: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        layer?.addSublayer(background)
        titleLabel.font = MacPollStyle.titleFont
        titleLabel.textColor = .labelColor
        addSubview(titleLabel)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityIdentifier("conversation.poll")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func configure(messageID: String, model: MacPollRowModel, layout: PollCardGeometry.Layout, outgoing: Bool, tail: Bool) {
        let animated = self.messageID == messageID
        self.messageID = messageID
        background.update(rect: bounds, side: outgoing ? .trailing : .leading, tail: tail)
        background.fillColor = resolved(MacConversationTheme.incomingBubble, in: self)
        titleLabel.isHidden = layout.titleFrame == nil
        titleLabel.stringValue = model.poll.question
        if let frame = layout.titleFrame { titleLabel.frame = frame.insetBy(dx: -2, dy: 0) }
        while rows.count < model.poll.options.count {
            let row = MacPollOptionRowView()
            addSubview(row)
            rows.append(row)
        }
        for (index, row) in rows.enumerated() {
            guard index < layout.rows.count, index < model.poll.options.count else {
                row.isHidden = true
                continue
            }
            row.isHidden = false
            row.configure(option: model.poll.options[index], row: layout.rows[index], model: model, animated: animated)
        }
        setAccessibilityLabel(model.poll.question)
    }

    func optionID(at point: CGPoint) -> String? {
        rows.first { !$0.isHidden && $0.frame.contains(point) }?.optionID
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        background.fillColor = resolved(MacConversationTheme.incomingBubble, in: self)
    }
}

extension MacMessageRowView {
    func configurePoll(_ model: MacMessageRowModel, layout: MacMessageLayout) {
        guard let pollModel = model.poll, let pollLayout = layout.poll else {
            pollCard.isHidden = true
            addChoiceLabel.isHidden = true
            pollFailedLabel.isHidden = true
            return
        }
        if pollCard.superview == nil {
            addSubview(pollCard, positioned: .below, relativeTo: badge)
            addChoiceLabel.font = MacPollStyle.stampFont
            addChoiceLabel.textColor = MacPollStyle.accent
            addChoiceLabel.setAccessibilityIdentifier("conversation.poll.addChoice")
            addSubview(addChoiceLabel)
            pollFailedLabel.font = .systemFont(ofSize: 10, weight: .semibold)
            pollFailedLabel.textColor = .systemRed
            pollFailedLabel.setAccessibilityIdentifier("conversation.poll.voteFailed")
            addSubview(pollFailedLabel)
        }
        pollCard.isHidden = false
        pollCard.frame = pollLayout.cardFrame
        pollCard.configure(messageID: model.message.id, model: pollModel, layout: pollLayout.card, outgoing: model.isOutgoing, tail: model.showsTail)
        addChoiceLabel.isHidden = pollLayout.addChoiceFrame == nil
        if let frame = pollLayout.addChoiceFrame {
            addChoiceLabel.stringValue = "+ " + String(localized: "conversation.poll.addChoice", defaultValue: "Add Choice", bundle: .module)
            addChoiceLabel.alignment = model.isOutgoing ? .right : .left
            addChoiceLabel.frame = frame.offsetBy(dx: 0, dy: (frame.height - 14) / 2).insetBy(dx: 0, dy: (frame.height - 14) / 2)
        }
        pollFailedLabel.isHidden = pollLayout.failedFrame == nil
        if let frame = pollLayout.failedFrame {
            pollFailedLabel.stringValue = String(localized: "conversation.poll.voteFailed", defaultValue: "Poll vote failed.", bundle: .module)
            pollFailedLabel.alignment = model.isOutgoing ? .right : .left
            pollFailedLabel.frame = frame
        }
    }
}

// MARK: - Controller

extension MacConversationViewController {
    /// Clicks on a poll card, its "Add Choice" stamp, or its failure line.
    func handlePollClick(_ model: MacMessageRowModel, rowView: MacMessageRowView, local: CGPoint) -> Bool {
        guard let pollModel = model.poll, let pollLayout = rowView.rowLayout?.poll else { return false }
        if let frame = pollLayout.failedFrame, frame.insetBy(dx: 0, dy: -4).contains(local) {
            presentPollVoteFailed(messageID: model.message.id)
            return true
        }
        if let frame = pollLayout.addChoiceFrame, frame.contains(local) {
            presentAddChoice(messageID: model.message.id)
            return true
        }
        guard pollLayout.cardFrame.contains(local) else { return false }
        let point = CGPoint(x: local.x - pollLayout.cardFrame.minX, y: local.y - pollLayout.cardFrame.minY)
        guard pollModel.interactive, let optionID = rowView.pollCard.optionID(at: point) else { return false }
        store.togglePollVote(messageID: model.message.id, optionID: optionID)
        return true
    }

    func presentPollComposer() {
        let composer = MacPollComposerController { [weak self] question, choices in
            self?.store.sendPoll(question: question, choices: choices)
        }
        presentAsSheet(composer)
    }

    func presentAddChoice(messageID: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "conversation.poll.addChoice", defaultValue: "Add Choice", bundle: .module)
        let field = NSTextField(frame: CGRect(x: 0, y: 0, width: 240, height: 22))
        field.placeholderString = String(localized: "conversation.poll.addChoice", defaultValue: "Add Choice", bundle: .module)
        field.setAccessibilityIdentifier("conversation.poll.addChoice.field")
        alert.accessoryView = field
        alert.addButton(withTitle: String(localized: "conversation.poll.send", defaultValue: "Send", bundle: .module))
        alert.addButton(withTitle: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module))
        alert.window.initialFirstResponder = field
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            self?.store.addPollChoice(messageID: messageID, text: field.stringValue)
        }
    }

    func presentPollVoteFailed(messageID: String) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "conversation.poll.voteFailed", defaultValue: "Poll vote failed.", bundle: .module)
        alert.informativeText = String(localized: "conversation.poll.voteFailedDescriptionMac", defaultValue: "Your vote was not sent. Click “Try Again” to resend your vote.", bundle: .module)
        alert.addButton(withTitle: String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module))
        alert.addButton(withTitle: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module))
        alert.beginSheetModal(for: window) { [weak self] response in
            if response == .alertFirstButtonReturn {
                self?.store.retryPollVote(messageID: messageID)
            } else {
                self?.store.dismissPollVoteFailure(messageID: messageID)
            }
        }
    }

    func showPollDetails(messageID: String, from view: NSView, rect: CGRect) {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = MacPollDetailsController(store: store, messageID: messageID)
        popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
    }

    func addPollMenuItems(to menu: NSMenu, model: MacMessageRowModel, rowView: MacMessageRowView) {
        guard model.poll != nil else { return }
        let messageID = model.message.id
        let item = MacClosureMenuItem(title: String(localized: "conversation.poll.details", defaultValue: "Poll Details", bundle: .module)) { [weak self, weak rowView] in
            guard let self, let rowView else { return }
            self.showPollDetails(messageID: messageID, from: rowView, rect: rowView.rowLayout?.poll?.cardFrame ?? rowView.bounds)
        }
        item.image = NSImage(systemSymbolName: "chart.bar.doc.horizontal", accessibilityDescription: nil)
        menu.addItem(item)
    }

    func pollsAppsMenuItem() -> NSMenuItem {
        let item = MacClosureMenuItem(title: String(localized: "conversation.apps.polls", defaultValue: "Polls", bundle: .module)) { [weak self] in
            self?.presentPollComposer()
        }
        item.image = NSImage(systemSymbolName: "list.bullet", accessibilityDescription: nil)
        return item
    }

    #if DEBUG
    /// Lab verbs: `poll make <question>|<a>|<b>...`, `poll compose`,
    /// `poll vote <row-match> <choice-index>`, `poll add <row-match> <text>`,
    /// `poll details <row-match>`, `poll failed <row-match>`, `poll state <row-match>`.
    func pollLabCommand(_ argument: String) -> String {
        let parts = argument.split(separator: " ", maxSplits: 1).map(String.init)
        guard let verb = parts.first else { return "error usage poll <verb>" }
        let rest = parts.count > 1 ? parts[1] : ""
        if verb == "make" {
            let fields = rest.split(separator: "|").map(String.init)
            guard fields.count >= 3 else { return "error usage poll make q|a|b" }
            return store.sendPoll(question: fields[0], choices: Array(fields.dropFirst())) == nil ? "error invalid" : "ok"
        }
        if verb == "compose" {
            presentPollComposer()
            return "ok"
        }
        let bits = rest.split(separator: " ", maxSplits: 1).map(String.init)
        let match = bits.first ?? "poll"
        guard let index = rows.indices.reversed().first(where: { index in
            guard let model = messageModel(at: index), model.poll != nil else { return false }
            return match == "poll" || model.message.text.contains(match)
        }), let model = messageModel(at: index), let poll = model.message.poll else { return "error no poll" }
        tableView.scrollRowToVisible(index)
        switch verb {
        case "vote":
            guard bits.count == 2, let choice = Int(bits[1]), poll.options.indices.contains(choice) else { return "error usage poll vote <match> <index>" }
            store.togglePollVote(messageID: model.message.id, optionID: poll.options[choice].id)
            return "ok"
        case "add":
            guard bits.count == 2 else { return "error usage poll add <match> <text>" }
            store.addPollChoice(messageID: model.message.id, text: bits[1])
            return "ok"
        case "details":
            guard let rowView = rowView(at: index) else { return "error not visible" }
            showPollDetails(messageID: model.message.id, from: rowView, rect: rowView.rowLayout?.poll?.cardFrame ?? rowView.bounds)
            return "ok"
        case "failed":
            presentPollVoteFailed(messageID: model.message.id)
            return "ok"
        case "state":
            let options = poll.options.map { option in
                "\(option.text)=\(poll.voteCount(for: option.id))\(model.poll?.isMine(option.id) == true ? "*" : "")"
            }
            return "poll \(model.message.id) failed=\(store.pollVoteFailure(messageID: model.message.id) != nil) " + options.joined(separator: ",")
        default:
            return "error unknown poll verb"
        }
    }
    #endif
}

// MARK: - Composer

/// Question, 2 to 12 choices with remove buttons, Add Choice, Cancel/Send.
final class MacPollComposerController: NSViewController, NSTextFieldDelegate {
    private let onSend: (String, [String]) -> Void
    private let questionField = NSTextField()
    private var choiceFields: [NSTextField] = []
    private let choicesStack = NSStackView()
    private let addButton = NSButton()
    private let sendButton = NSButton()

    init(onSend: @escaping (String, [String]) -> Void) {
        self.onSend = onSend
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "conversation.apps.polls", defaultValue: "Polls", bundle: .module)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 10
        root.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        root.setAccessibilityIdentifier("conversation.poll.composer")
        questionField.placeholderString = String(localized: "conversation.poll.question", defaultValue: "Question", bundle: .module)
        questionField.font = MacPollStyle.titleFont
        questionField.delegate = self
        questionField.setAccessibilityIdentifier("conversation.poll.composer.question")
        root.addArrangedSubview(questionField)
        choicesStack.orientation = .vertical
        choicesStack.alignment = .leading
        choicesStack.spacing = 6
        root.addArrangedSubview(choicesStack)
        addButton.title = String(localized: "conversation.poll.addChoice", defaultValue: "Add Choice", bundle: .module)
        addButton.image = NSImage(systemSymbolName: "plus.circle.fill", accessibilityDescription: nil)
        addButton.imagePosition = .imageLeading
        addButton.isBordered = false
        addButton.contentTintColor = .controlAccentColor
        addButton.target = self
        addButton.action = #selector(addChoice)
        addButton.setAccessibilityIdentifier("conversation.poll.composer.addChoice")
        root.addArrangedSubview(addButton)
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let cancel = NSButton(title: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module), target: self, action: #selector(cancel))
        cancel.keyEquivalent = "\u{1b}"
        sendButton.title = String(localized: "conversation.poll.send", defaultValue: "Send", bundle: .module)
        sendButton.bezelStyle = .push
        sendButton.keyEquivalent = "\r"
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.setAccessibilityIdentifier("conversation.poll.composer.send")
        buttons.addArrangedSubview(spacer)
        buttons.addArrangedSubview(cancel)
        buttons.addArrangedSubview(sendButton)
        root.addArrangedSubview(buttons)
        for view in [questionField, choicesStack, buttons] as [NSView] {
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -40).isActive = true
        }
        root.widthAnchor.constraint(equalToConstant: 360).isActive = true
        view = root
        appendChoice()
        appendChoice()
        update()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(questionField)
    }

    private func appendChoice() {
        let field = NSTextField()
        field.font = MacPollStyle.optionFont
        field.delegate = self
        let remove = NSButton(image: NSImage(systemSymbolName: "minus.circle.fill", accessibilityDescription: String(localized: "conversation.poll.removeChoice", defaultValue: "Remove Choice", bundle: .module))!, target: self, action: #selector(removeChoice(_:)))
        remove.isBordered = false
        remove.contentTintColor = .systemRed
        let row = NSStackView(views: [remove, field])
        row.orientation = .horizontal
        row.spacing = 6
        choicesStack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: choicesStack.widthAnchor).isActive = true
        choiceFields.append(field)
        renumber()
    }

    private func renumber() {
        for (index, field) in choiceFields.enumerated() {
            field.placeholderString = String(format: String(localized: "conversation.poll.choicePlaceholder", defaultValue: "Choice %ld", bundle: .module), index + 1)
            field.setAccessibilityIdentifier("conversation.poll.composer.choice.\(index)")
            (field.superview as? NSStackView)?.views.first?.isHidden = choiceFields.count <= 2
        }
    }

    private var filledChoices: [String] {
        choiceFields.map { $0.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func update() {
        sendButton.isEnabled = filledChoices.count >= 2
        addButton.isHidden = choiceFields.count >= ConversationPoll.maxOptions
    }

    func controlTextDidChange(_ notification: Notification) { update() }

    @objc private func addChoice() {
        guard choiceFields.count < ConversationPoll.maxOptions else { return }
        appendChoice()
        update()
        view.window?.makeFirstResponder(choiceFields.last)
    }

    @objc private func removeChoice(_ sender: NSButton) {
        guard choiceFields.count > 2, let row = sender.superview as? NSStackView,
              let index = choiceFields.firstIndex(where: { $0.superview === row }) else { return }
        choiceFields.remove(at: index)
        row.removeFromSuperview()
        renumber()
        update()
    }

    @objc private func cancel() { dismiss(nil) }

    @objc private func send() {
        guard filledChoices.count >= 2 else { return }
        onSend(questionField.stringValue, choiceFields.map(\.stringValue))
        dismiss(nil)
    }
}

// MARK: - Poll Details

/// Who voted for what, and who has not voted; updates live while open.
final class MacPollDetailsController: NSViewController {
    private let store: ConversationStore
    private let messageID: String
    private let stack = NSStackView()

    init(store: ConversationStore, messageID: String) {
        self.store = store
        self.messageID = messageID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)
        stack.setAccessibilityIdentifier("conversation.poll.details")
        view = stack
        reload()
        store.addObserver { [weak self] change in
            guard let self, self.view.window != nil, case .live = change else { return }
            self.reload()
        }
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let label = makeMacLabel()
        label.stringValue = text
        label.font = font
        label.textColor = color
        label.preferredMaxLayoutWidth = 260
        return label
    }

    private func reload() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let poll = store.message(id: messageID)?.poll, let info = store.info else { return }
        let you = String(localized: "conversation.reaction.you", defaultValue: "You", bundle: .module)
        func name(_ id: String) -> String {
            guard let participant = info.participant(id) else { return id }
            return participant.isMe ? you : participant.name
        }
        stack.addArrangedSubview(label(String(localized: "conversation.poll.details", defaultValue: "Poll Details", bundle: .module), font: .systemFont(ofSize: 13, weight: .bold)))
        if !poll.question.isEmpty {
            stack.addArrangedSubview(label(poll.question, font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        }
        func section(_ title: String, subtitle: String?, names: [String]) {
            let header = label(title, font: .systemFont(ofSize: 12, weight: .semibold))
            stack.addArrangedSubview(header)
            stack.setCustomSpacing(2, after: header)
            if let subtitle { stack.addArrangedSubview(label(subtitle, font: .systemFont(ofSize: 10), color: .secondaryLabelColor)) }
            let body = names.isEmpty
                ? label(String(localized: "conversation.poll.noVotesYet", defaultValue: "No votes yet", bundle: .module), font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
                : label(names.joined(separator: "\n"), font: .systemFont(ofSize: 12))
            stack.addArrangedSubview(body)
            stack.setCustomSpacing(10, after: body)
        }
        for option in poll.options {
            var subtitle = MacPollStyle.votesText(poll.voteCount(for: option.id))
            if let adder = option.addedByID {
                subtitle += " · " + (adder == store.meID
                    ? String(localized: "conversation.poll.addedByYou", defaultValue: "Added by You", bundle: .module)
                    : String(format: String(localized: "conversation.poll.addedBy", defaultValue: "Added by %@", bundle: .module), name(adder)))
            }
            section(option.text, subtitle: subtitle, names: poll.voterIDs(for: option.id).map(name))
        }
        let nonVoters = poll.nonVoterIDs(among: info.participants.map(\.id))
        if !nonVoters.isEmpty {
            section(String(localized: "conversation.poll.noVotes", defaultValue: "No Votes", bundle: .module), subtitle: nil, names: nonVoters.map(name))
        }
    }
}
#endif
