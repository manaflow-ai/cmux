#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

// Messages polls (iOS 26): the poll card in the transcript, the composer
// opened from the + menu, "Add Choice", Poll Details and the vote-failed
// recovery. Geometry and colors are shared with macOS (PollCardGeometry).

struct PollVoter: Hashable {
    var name: String
    var initials: String
    var colorHex: String
    var isMe: Bool
}

/// Everything a poll row renders beyond the message itself.
struct PollRowModel: Hashable {
    var poll: ConversationPoll
    var meID: String?
    var voteFailed: Bool
    /// Votes and new choices need the poll to have reached the server.
    var interactive: Bool
    var participants: [String: PollVoter]
    var participantOrder: [String]

    func isMine(_ optionID: String) -> Bool {
        meID.map { poll.hasVote(participantID: $0, optionID: optionID) } ?? false
    }

    var canAddChoice: Bool { interactive && poll.options.count < ConversationPoll.maxOptions }

    @MainActor
    static func attach(to model: MessageRowModel, store: ConversationStore) -> MessageRowModel {
        guard let poll = model.message.poll, let info = store.info else { return model }
        var model = model
        var participants: [String: PollVoter] = [:]
        for participant in info.participants {
            participants[participant.id] = PollVoter(
                name: participant.name, initials: participant.initials, colorHex: participant.colorHex, isMe: participant.isMe
            )
        }
        model.poll = PollRowModel(
            poll: poll,
            meID: store.meID,
            voteFailed: store.pollVoteFailure(messageID: model.message.id) != nil,
            interactive: store.canInteractWithPoll(model.message),
            participants: participants,
            participantOrder: info.participants.map(\.id)
        )
        return model
    }
}

enum PollStyle {
    static let titleFont = UIFont.systemFont(ofSize: 17, weight: .semibold)
    static let optionFont = UIFont.systemFont(ofSize: 17)
    static let stampFont = UIFont.systemFont(ofSize: 13, weight: .semibold)

    static func color(_ pair: (light: PollCardColors.RGBA, dark: PollCardColors.RGBA)) -> UIColor {
        UIColor { traits in
            let c = traits.userInterfaceStyle == .dark ? pair.dark : pair.light
            return UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
        }
    }

    static func color(_ c: PollCardColors.RGBA) -> UIColor {
        UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a)
    }

    static let selectedBar = color(PollCardColors.selectedBar)
    static let deselectedBar = color(PollCardColors.deselectedBar)
    static let track = color(PollCardColors.track)
    static let accent = color(PollCardColors.accent)

    static func measure(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        )
        return ceil(rect.height)
    }

    static func cardLayout(_ model: PollRowModel, width: CGFloat) -> PollCardGeometry.Layout {
        let poll = model.poll
        let title = poll.question.isEmpty ? nil : measure(poll.question, font: titleFont, width: width - 2 * PollCardGeometry.Metrics.iOS.padding)
        return PollCardGeometry.layout(width: width, titleHeight: title, rows: poll.options.map { option in
            let voters = poll.voteCount(for: option.id)
            let textWidth = PollCardGeometry.textWidth(cardWidth: width, voterCount: voters, .iOS)
            return (max(optionFont.lineHeight.rounded(.up), measure(option.text, font: optionFont, width: textWidth)), voters, CGFloat(poll.barFraction(for: option.id)))
        }, .iOS)
    }

    static func votesText(_ count: Int) -> String {
        count == 1
            ? String(localized: "conversation.poll.oneVote", defaultValue: "1 Vote", bundle: .module)
            : String(format: String(localized: "conversation.poll.votes", defaultValue: "%lld Votes", bundle: .module), Int64(count))
    }
}

/// Where the poll pieces sit in a message cell.
struct PollCellLayout {
    /// Card body (no tail area).
    var cardFrame: CGRect
    var card: PollCardGeometry.Layout
    var addChoiceFrame: CGRect?
    var failedFrame: CGRect?
}

extension MessageCellLayout {
    static func computePoll(model: MessageRowModel, width: CGFloat, margin: CGFloat) -> MessageCellLayout {
        let t = ConversationTheme.self
        let pollModel = model.poll!
        let avatarColumn = model.reservesAvatarColumn ? t.avatarSize + t.avatarGap : 0
        let cardWidth = PollCardGeometry.cardWidth(available: width - 2 * margin - avatarColumn - 24, .iOS)
        var y: CGFloat = 0
        var senderNameFrame: CGRect?
        if model.showsSenderName, model.senderName != nil {
            senderNameFrame = CGRect(x: margin + avatarColumn + 15, y: y, width: cardWidth, height: 16)
            y += 19
        }
        if !model.reactionKinds.isEmpty { y += 18 }
        let card = PollStyle.cardLayout(pollModel, width: cardWidth)
        let cardX = model.isOutgoing ? width - margin - cardWidth : margin + avatarColumn
        let cardFrame = CGRect(x: cardX, y: y, width: cardWidth, height: card.size.height)
        y = cardFrame.maxY
        var content = model.isOutgoing
            ? CGRect(x: cardFrame.minX, y: cardFrame.minY, width: cardWidth + t.tailWidth, height: cardFrame.height)
            : CGRect(x: cardFrame.minX - t.tailWidth, y: cardFrame.minY, width: cardWidth + t.tailWidth, height: cardFrame.height)
        if model.showsTail {
            y += t.tailDrop
            content.size.height += t.tailDrop
        }

        func sideRect(_ y: CGFloat, height: CGFloat) -> CGRect {
            model.isOutgoing
                ? CGRect(x: margin, y: y, width: cardFrame.maxX - 9 - margin, height: height)
                : CGRect(x: cardFrame.minX + 9, y: y, width: width - cardFrame.minX - 9 - margin, height: height)
        }
        var addChoiceFrame: CGRect?
        if pollModel.canAddChoice {
            addChoiceFrame = sideRect(y + 2, height: PollCardGeometry.Metrics.iOS.stampHeight)
            y += 2 + PollCardGeometry.Metrics.iOS.stampHeight
        }
        var failedFrame: CGRect?
        if pollModel.voteFailed {
            failedFrame = sideRect(y + 2, height: 18)
            y += 2 + 18
        }
        var footerFrame: CGRect?
        if model.footer != .none {
            footerFrame = sideRect(y + 5, height: 15)
            y += 5 + 15
        }
        let avatarFrame = model.showsAvatar
            ? CGRect(x: margin, y: cardFrame.maxY - t.avatarSize, width: t.avatarSize, height: t.avatarSize)
            : nil
        let anchor = model.reactionKinds.isEmpty ? nil : (model.isOutgoing
            ? CGPoint(x: cardFrame.minX, y: cardFrame.minY)
            : CGPoint(x: cardFrame.maxX, y: cardFrame.minY))
        return MessageCellLayout(
            height: ceil(y),
            senderNameFrame: senderNameFrame,
            quoteFrame: nil,
            quoteTextFrame: nil,
            threadPath: nil,
            imageFrames: [],
            bubbleFrame: nil,
            textFrame: nil,
            emojiFrame: nil,
            avatarFrame: avatarFrame,
            reactionAnchor: anchor,
            footerFrame: footerFrame,
            editedFrame: nil,
            repliesFrame: nil,
            failedBadgeFrame: nil,
            contentFrame: content,
            poll: PollCellLayout(cardFrame: cardFrame, card: card, addChoiceFrame: addChoiceFrame, failedFrame: failedFrame)
        )
    }
}

// MARK: - Views

/// Empty orange ring, or a filled orange disc with a white checkmark.
final class PollCircleView: UIView {
    private let ring = CAShapeLayer()
    private let check = UIImageView(image: UIImage(systemName: "checkmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .bold)))

    var isChecked = false { didSet { update() } }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        layer.addSublayer(ring)
        ring.lineWidth = PollCardColors.emptyCircleStrokeWidth
        check.tintColor = PollStyle.color(PollCardColors.selectedGlyph)
        check.contentMode = .center
        addSubview(check)
        update()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in self.update() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        ring.frame = bounds
        ring.path = UIBezierPath(ovalIn: bounds.insetBy(dx: 0.75, dy: 0.75)).cgPath
        check.frame = bounds
    }

    private func update() {
        ring.strokeColor = (isChecked ? PollStyle.selectedBar : PollStyle.accent).resolvedColor(with: traitCollection).cgColor
        ring.fillColor = isChecked ? PollStyle.selectedBar.resolvedColor(with: traitCollection).cgColor : UIColor.clear.cgColor
        check.alpha = isChecked ? 1 : 0
    }
}

final class PollOptionRowView: UIView {
    let track = UIView()
    let bar = UIView()
    let circle = PollCircleView()
    let label = UILabel()
    private var avatars: [ConversationAvatarView] = []
    private(set) var optionID = ""

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.layer.cornerRadius = PollCardGeometry.Metrics.iOS.rowCornerRadius
        track.layer.cornerCurve = .continuous
        track.clipsToBounds = true
        track.backgroundColor = PollStyle.track
        track.addSubview(bar)
        addSubview(track)
        addSubview(circle)
        label.font = PollStyle.optionFont
        label.textColor = .label
        label.numberOfLines = 0
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Frames are in the card's coordinates; this view spans the row frame.
    func configure(option: ConversationPollOption, row: PollCardGeometry.Row, model: PollRowModel) {
        optionID = option.id
        let origin = row.frame.origin
        frame = row.frame
        track.frame = bounds
        bar.frame = row.barFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        let mine = model.isMine(option.id)
        bar.backgroundColor = mine ? PollStyle.selectedBar : PollStyle.deselectedBar
        circle.frame = row.circleFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        circle.isChecked = mine
        label.text = option.text
        label.frame = row.textFrame.offsetBy(dx: -origin.x, dy: -origin.y)
        let voterIDs = model.poll.voterIDs(for: option.id)
        while avatars.count < row.avatarFrames.count {
            let avatar = ConversationAvatarView()
            avatar.layer.borderWidth = 1.5
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
            avatar.layer.borderColor = ConversationTheme.incomingBubble.resolvedColor(with: traitCollection).cgColor
            let voter = model.participants[voterIDs[index]]
            avatar.configure(initials: voter?.initials ?? "", colorHex: voter?.colorHex)
        }
        // Later voters sit under earlier ones, as in a Messages avatar stack.
        for avatar in avatars.reversed() { bringSubviewToFront(avatar) }
        accessibilityLabel = option.text
        accessibilityValue = PollStyle.votesText(voterIDs.count)
        accessibilityTraits = mine ? [.button, .selected] : .button
        accessibilityIdentifier = "conversation.poll.option.\(option.id)"
    }
}

/// The poll card: a balloon holding the question and one row per choice.
final class PollCardView: UIView {
    let background = BubbleBackgroundView()
    let titleLabel = UILabel()
    private(set) var rows: [PollOptionRowView] = []
    private var messageID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        addSubview(background)
        titleLabel.font = PollStyle.titleFont
        titleLabel.numberOfLines = 0
        titleLabel.textColor = .label
        addSubview(titleLabel)
        accessibilityIdentifier = "conversation.poll"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(messageID: String, model: PollRowModel, layout: PollCardGeometry.Layout, outgoing: Bool, tail: Bool) {
        // Votes arriving on a poll already on screen glide; a new row snaps.
        let animate = self.messageID == messageID && window != nil
        self.messageID = messageID
        let tailWidth = ConversationTheme.tailWidth
        background.side = outgoing ? .trailing : .leading
        background.hasTail = tail
        background.fillColor = ConversationTheme.incomingBubble
        background.frame = CGRect(x: outgoing ? 0 : -tailWidth, y: 0, width: bounds.width + tailWidth, height: bounds.height)
        titleLabel.isHidden = layout.titleFrame == nil
        titleLabel.text = model.poll.question
        if let frame = layout.titleFrame { titleLabel.frame = frame }
        while rows.count < model.poll.options.count {
            let row = PollOptionRowView()
            addSubview(row)
            rows.append(row)
        }
        let apply = {
            for (index, row) in self.rows.enumerated() {
                guard index < layout.rows.count, index < model.poll.options.count else {
                    row.isHidden = true
                    continue
                }
                row.isHidden = false
                row.configure(option: model.poll.options[index], row: layout.rows[index], model: model)
            }
        }
        if animate {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.86, initialSpringVelocity: 0, options: [.allowUserInteraction, .beginFromCurrentState], animations: apply)
        } else {
            UIView.performWithoutAnimation(apply)
        }
    }

    /// The choice under `point` (in this view's coordinates).
    func optionID(at point: CGPoint) -> String? {
        rows.first { !$0.isHidden && $0.frame.contains(point) }?.optionID
    }

    func row(for optionID: String) -> PollOptionRowView? {
        rows.first { !$0.isHidden && $0.optionID == optionID }
    }
}

extension MessageCell {
    func configurePoll(model: MessageRowModel, layout: MessageCellLayout) {
        guard let pollModel = model.poll, let pollLayout = layout.poll else {
            pollCard.isHidden = true
            addChoiceButton.isHidden = true
            pollFailedLabel.isHidden = true
            return
        }
        if pollCard.superview == nil {
            shiftable.insertSubview(pollCard, belowSubview: reactionBadge)
            addChoiceButton.titleLabel?.font = PollStyle.stampFont
            addChoiceButton.setTitleColor(PollStyle.accent, for: .normal)
            addChoiceButton.setImage(UIImage(systemName: "plus", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)), for: .normal)
            addChoiceButton.tintColor = PollStyle.accent
            addChoiceButton.isUserInteractionEnabled = false
            addChoiceButton.accessibilityIdentifier = "conversation.poll.addChoice"
            shiftable.addSubview(addChoiceButton)
            pollFailedLabel.font = ConversationTheme.footerFont
            pollFailedLabel.textColor = ConversationTheme.notDelivered
            pollFailedLabel.accessibilityIdentifier = "conversation.poll.voteFailed"
            shiftable.addSubview(pollFailedLabel)
        }
        pollCard.isHidden = false
        pollCard.frame = pollLayout.cardFrame
        pollCard.configure(messageID: model.message.id, model: pollModel, layout: pollLayout.card, outgoing: model.isOutgoing, tail: model.showsTail)
        addChoiceButton.isHidden = pollLayout.addChoiceFrame == nil
        if let frame = pollLayout.addChoiceFrame {
            addChoiceButton.setTitle(" " + String(localized: "conversation.poll.addChoice", defaultValue: "Add Choice", bundle: .module), for: .normal)
            addChoiceButton.frame = frame
            addChoiceButton.contentHorizontalAlignment = model.isOutgoing ? .right : .left
        }
        pollFailedLabel.isHidden = pollLayout.failedFrame == nil
        if let frame = pollLayout.failedFrame {
            pollFailedLabel.text = String(localized: "conversation.poll.voteFailed", defaultValue: "Poll vote failed.", bundle: .module)
            pollFailedLabel.frame = frame
            pollFailedLabel.textAlignment = model.isOutgoing ? .right : .left
        }
    }
}

// MARK: - Controller

extension ConversationViewController {
    /// Handles taps on a poll row; returns true when the tap was consumed.
    func handlePollTap(cell: MessageCell, model: MessageRowModel, local: CGPoint) -> Bool {
        guard let pollModel = model.poll, let pollLayout = cell.cellLayout?.poll else { return false }
        let shifted = cell.shiftable.convert(local, from: cell)
        if let frame = pollLayout.failedFrame, frame.insetBy(dx: 0, dy: -6).contains(shifted) {
            presentPollVoteFailed(messageID: model.message.id)
            return true
        }
        if let frame = pollLayout.addChoiceFrame, frame.insetBy(dx: 0, dy: -4).contains(shifted) {
            presentAddChoice(messageID: model.message.id)
            return true
        }
        guard pollLayout.cardFrame.contains(shifted) else { return false }
        guard pollModel.interactive,
              let optionID = cell.pollCard.optionID(at: cell.pollCard.convert(shifted, from: cell.shiftable)) else { return true }
        UISelectionFeedbackGenerator().selectionChanged()
        store.togglePollVote(messageID: model.message.id, optionID: optionID)
        return true
    }

    func presentPollComposer() {
        let composer = PollComposerViewController { [weak self] question, choices in
            self?.store.sendPoll(question: question, choices: choices)
        }
        let nav = UINavigationController(rootViewController: composer)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    func presentAddChoice(messageID: String) {
        let alert = UIAlertController(
            title: String(localized: "conversation.poll.addChoice", defaultValue: "Add Choice", bundle: .module),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { field in
            field.placeholder = String(localized: "conversation.poll.addChoice", defaultValue: "Add Choice", bundle: .module)
            field.autocapitalizationType = .sentences
            field.returnKeyType = .send
        }
        alert.addAction(UIAlertAction(title: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "conversation.poll.send", defaultValue: "Send", bundle: .module), style: .default) { [weak self, weak alert] _ in
            guard let text = alert?.textFields?.first?.text else { return }
            self?.store.addPollChoice(messageID: messageID, text: text)
        })
        present(alert, animated: true)
    }

    func presentPollVoteFailed(messageID: String) {
        let alert = UIAlertController(
            title: String(localized: "conversation.poll.voteFailed", defaultValue: "Poll vote failed.", bundle: .module),
            message: String(localized: "conversation.poll.voteFailedDescription", defaultValue: "Your vote was not sent. Tap “Try Again” to resend your vote.", bundle: .module),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "conversation.retry.cancel", defaultValue: "Cancel", bundle: .module), style: .cancel) { [weak self] _ in
            self?.store.dismissPollVoteFailure(messageID: messageID)
        })
        alert.addAction(UIAlertAction(title: String(localized: "conversation.retry.tryAgain", defaultValue: "Try Again", bundle: .module), style: .default) { [weak self] _ in
            self?.store.retryPollVote(messageID: messageID)
        })
        present(alert, animated: true)
    }

    func presentPollDetails(messageID: String) {
        let details = PollDetailsViewController(store: store, messageID: messageID)
        present(UINavigationController(rootViewController: details), animated: true)
    }

    /// Long-press menu entries for a poll message.
    func pollMenuItems(for model: MessageRowModel) -> [MessageActionOverlay.MenuItem] {
        guard model.poll != nil else { return [] }
        let messageID = model.message.id
        return [.init(title: String(localized: "conversation.poll.details", defaultValue: "Poll Details", bundle: .module), symbol: "chart.bar.doc.horizontal") { [weak self] in
            self?.presentPollDetails(messageID: messageID)
        }]
    }

    func pollsAppsMenuItem() -> AppsMenuOverlay.Item {
        .init(title: String(localized: "conversation.apps.polls", defaultValue: "Polls", bundle: .module), symbol: "list.bullet", color: PollStyle.color(PollCardColors.icon)) { [weak self] in
            self?.presentPollComposer()
        }
    }
}

// MARK: - Composer

/// Question, 2 to 12 choices (add, remove, reorder), Send.
final class PollComposerViewController: UITableViewController, UITextFieldDelegate {
    private var question = ""
    private var choices = ["", ""]
    private let onSend: (String, [String]) -> Void
    private lazy var sendButton = UIBarButtonItem(
        title: String(localized: "conversation.poll.send", defaultValue: "Send", bundle: .module),
        style: .done, target: self, action: #selector(send)
    )

    init(onSend: @escaping (String, [String]) -> Void) {
        self.onSend = onSend
        super.init(style: .insetGrouped)
        title = String(localized: "conversation.apps.polls", defaultValue: "Polls", bundle: .module)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        navigationItem.rightBarButtonItem = sendButton
        tableView.register(PollFieldCell.self, forCellReuseIdentifier: "field")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "add")
        tableView.setEditing(true, animated: false)
        tableView.allowsSelectionDuringEditing = true
        tableView.accessibilityIdentifier = "conversation.poll.composer"
        updateSend()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        (tableView.cellForRow(at: IndexPath(row: 0, section: 0)) as? PollFieldCell)?.field.becomeFirstResponder()
    }

    private var canAddChoice: Bool { choices.count < ConversationPoll.maxOptions }
    private var filledChoices: [String] {
        choices.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func updateSend() {
        sendButton.isEnabled = filledChoices.count >= 2
    }

    @objc private func send() {
        guard filledChoices.count >= 2 else { return }
        view.endEditing(true)
        let question = question
        let choices = choices
        dismiss(animated: true) { [onSend] in onSend(question, choices) }
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 2 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        section == 0 ? 1 : choices.count + (canAddChoice ? 1 : 0)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        if indexPath.section == 1, indexPath.row == choices.count {
            let cell = tableView.dequeueReusableCell(withIdentifier: "add", for: indexPath)
            var content = cell.defaultContentConfiguration()
            content.text = String(localized: "conversation.poll.addChoice", defaultValue: "Add Choice", bundle: .module)
            content.textProperties.color = .tintColor
            cell.contentConfiguration = content
            cell.accessibilityIdentifier = "conversation.poll.composer.addChoice"
            return cell
        }
        let cell = tableView.dequeueReusableCell(withIdentifier: "field", for: indexPath) as! PollFieldCell
        cell.field.delegate = self
        if indexPath.section == 0 {
            cell.field.text = question
            cell.field.placeholder = String(localized: "conversation.poll.question", defaultValue: "Question", bundle: .module)
            cell.field.font = PollStyle.titleFont
            cell.field.accessibilityIdentifier = "conversation.poll.composer.question"
        } else {
            cell.field.text = choices[indexPath.row]
            cell.field.placeholder = String(format: String(localized: "conversation.poll.choicePlaceholder", defaultValue: "Choice %ld", bundle: .module), indexPath.row + 1)
            cell.field.font = PollStyle.optionFont
            cell.field.accessibilityIdentifier = "conversation.poll.composer.choice.\(indexPath.row)"
        }
        cell.onChange = { [weak self, weak cell] text in
            guard let self, let cell, let path = self.tableView.indexPath(for: cell) else { return }
            if path.section == 0 { self.question = text } else if path.row < self.choices.count { self.choices[path.row] = text }
            self.updateSend()
        }
        return cell
    }

    override func tableView(_ tableView: UITableView, canEditRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 1
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        guard indexPath.section == 1 else { return .none }
        if indexPath.row == choices.count { return .insert }
        return choices.count > 2 ? .delete : .none
    }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 1
    }

    override func tableView(_ tableView: UITableView, commit editingStyle: UITableViewCell.EditingStyle, forRowAt indexPath: IndexPath) {
        if editingStyle == .insert {
            addChoice()
        } else if editingStyle == .delete, indexPath.row < choices.count {
            choices.remove(at: indexPath.row)
            tableView.performBatchUpdates {
                tableView.deleteRows(at: [indexPath], with: .automatic)
                if choices.count == ConversationPoll.maxOptions - 1 {
                    tableView.insertRows(at: [IndexPath(row: choices.count, section: 1)], with: .automatic)
                }
            } completion: { _ in
                // Placeholders renumber ("Choice 1", "Choice 2", ...).
                tableView.reloadSections(IndexSet(integer: 1), with: .none)
            }
            updateSend()
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        if indexPath.section == 1, indexPath.row == choices.count { addChoice() }
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        indexPath.section == 1 && indexPath.row < choices.count
    }

    override func tableView(_ tableView: UITableView, targetIndexPathForMoveFromRowAt source: IndexPath, toProposedIndexPath proposed: IndexPath) -> IndexPath {
        guard proposed.section == 1 else { return IndexPath(row: 0, section: 1) }
        return IndexPath(row: min(proposed.row, choices.count - 1), section: 1)
    }

    override func tableView(_ tableView: UITableView, moveRowAt source: IndexPath, to destination: IndexPath) {
        let moved = choices.remove(at: source.row)
        choices.insert(moved, at: destination.row)
        tableView.reloadSections(IndexSet(integer: 1), with: .none)
    }

    private func addChoice() {
        guard canAddChoice else { return }
        choices.append("")
        let path = IndexPath(row: choices.count - 1, section: 1)
        tableView.performBatchUpdates {
            tableView.insertRows(at: [path], with: .automatic)
            if !canAddChoice { tableView.deleteRows(at: [IndexPath(row: choices.count, section: 1)], with: .automatic) }
        } completion: { _ in
            (self.tableView.cellForRow(at: path) as? PollFieldCell)?.field.becomeFirstResponder()
        }
        updateSend()
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        guard let cell = sequence(first: textField as UIView, next: { $0.superview }).first(where: { $0 is PollFieldCell }) as? PollFieldCell,
              let path = tableView.indexPath(for: cell) else { return true }
        let next = path.section == 0 ? IndexPath(row: 0, section: 1) : IndexPath(row: path.row + 1, section: 1)
        if next.row < choices.count {
            (tableView.cellForRow(at: next) as? PollFieldCell)?.field.becomeFirstResponder()
        } else if canAddChoice, !textField.text.isNilOrEmpty {
            addChoice()
        } else {
            textField.resignFirstResponder()
        }
        return false
    }
}

private extension Optional where Wrapped == String {
    var isNilOrEmpty: Bool { self?.isEmpty ?? true }
}

final class PollFieldCell: UITableViewCell {
    let field = UITextField()
    var onChange: ((String) -> Void)?

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        field.translatesAutoresizingMaskIntoConstraints = false
        field.autocapitalizationType = .sentences
        field.returnKeyType = .next
        field.clearButtonMode = .whileEditing
        contentView.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            field.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
            field.topAnchor.constraint(equalTo: contentView.topAnchor),
            field.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        field.addAction(UIAction { [weak self] _ in
            self?.onChange?(self?.field.text ?? "")
        }, for: .editingChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }
}

// MARK: - Poll Details

/// Who voted for what, and who has not voted. Updates live.
final class PollDetailsViewController: UITableViewController {
    private let store: ConversationStore
    private let messageID: String
    private var sections: [(title: String, footer: String?, names: [String])] = []

    init(store: ConversationStore, messageID: String) {
        self.store = store
        self.messageID = messageID
        super.init(style: .insetGrouped)
        title = String(localized: "conversation.poll.details", defaultValue: "Poll Details", bundle: .module)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        navigationItem.rightBarButtonItem = UIBarButtonItem(systemItem: .done, primaryAction: UIAction { [weak self] _ in
            self?.dismiss(animated: true)
        })
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "voter")
        tableView.accessibilityIdentifier = "conversation.poll.details"
        reload()
        store.addObserver { [weak self] change in
            guard let self, self.viewIfLoaded?.window != nil, case .live = change else { return }
            self.reload()
        }
    }

    private func reload() {
        guard let message = store.message(id: messageID), let poll = message.poll, let info = store.info else { return }
        let you = String(localized: "conversation.reaction.you", defaultValue: "You", bundle: .module)
        func name(_ id: String) -> String {
            guard let participant = info.participant(id) else { return id }
            return participant.isMe ? you : participant.name
        }
        navigationItem.prompt = poll.question.isEmpty ? nil : poll.question
        sections = poll.options.map { option in
            let voters = poll.voterIDs(for: option.id)
            var footer = PollStyle.votesText(voters.count)
            if let adder = option.addedByID {
                let added = adder == store.meID
                    ? String(localized: "conversation.poll.addedByYou", defaultValue: "Added by You", bundle: .module)
                    : String(format: String(localized: "conversation.poll.addedBy", defaultValue: "Added by %@", bundle: .module), name(adder))
                footer += " · " + added
            }
            return (option.text, footer, voters.map(name))
        }
        let nonVoters = poll.nonVoterIDs(among: info.participants.map(\.id))
        if !nonVoters.isEmpty {
            sections.append((String(localized: "conversation.poll.noVotes", defaultValue: "No Votes", bundle: .module), nil, nonVoters.map(name)))
        }
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, sections[section].names.count)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sections[section].title
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sections[section].footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "voter", for: indexPath)
        var content = cell.defaultContentConfiguration()
        let names = sections[indexPath.section].names
        if names.isEmpty {
            content.text = String(localized: "conversation.poll.noVotesYet", defaultValue: "No votes yet", bundle: .module)
            content.textProperties.color = .secondaryLabel
        } else {
            content.text = names[indexPath.row]
        }
        cell.contentConfiguration = content
        cell.selectionStyle = .none
        return cell
    }
}
#endif
