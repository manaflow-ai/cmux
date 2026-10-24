#if os(iOS)
import CmuxAgentQuestion
import OSLog
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileMarkdown
import SwiftUI
import UIKit

/// What a Feed row asks of its list (`FeedListController`): every action
/// goes through the row's event id, so a recycled cell never acts on the
/// event it showed before.
@MainActor
protocol FeedRowCellDelegate: AnyObject {
    func rowOpen(_ id: String)
    func rowToggleExpanded(_ id: String)
    func rowToggleQuote(_ id: String)
    func rowToggleReply(_ id: String)
    func rowReplyDraft(_ id: String, _ text: String)
    func rowSendReply(_ id: String)
    func rowCopy(_ id: String)
    func rowShare(_ id: String, from source: UIView)
    func rowRespond(_ id: String, optionID: String)
    func rowDecline(_ id: String)
    func rowQuestion(_ id: String, _ input: AgentQuestionCardState.Input)
    func rowCodeExpand(_ id: String)
    func rowCopyCommand(_ id: String)
    func rowMenu(_ id: String) -> UIMenu
    func rowSwipeActions(_ id: String) -> [FeedSwipeAction]
    func rowSwipeBegan(_ id: String)
    func rowSwipeOpenChanged(_ id: String, open: Bool)
    func rowWebHeight(_ id: String, _ height: CGFloat)
    var rowsSettled: Bool { get }
}

/// One Feed row, drawn with UIKit views only: no SwiftUI view tree, no
/// hosting. `apply(_:)` places the reused subviews at a `FeedRowLayout`'s
/// frames; nothing is measured here (verify/feed-perf-20261022.md).
final class FeedRowCell: UICollectionViewCell, UIGestureRecognizerDelegate, UITextViewDelegate, UITextFieldDelegate,
    UIContextMenuInteractionDelegate {
    static let reuseID = "FeedRowCell"

    weak var delegate: FeedRowCellDelegate?
    private(set) var layout: FeedRowLayout?
    private var id: String { layout?.key.item.id ?? "" }

    /// Everything that slides with a swipe.
    private let row = UIView()
    private let divider = UIView()
    private let avatar = UIView()
    private let avatarGlyph = UIImageView()
    private let unread = UIView()
    private let name = UILabel()
    private let source = UILabel()
    private let time = UILabel()
    private let menuButton = UIButton(type: .custom)
    // Parts a row may not show are made when a row first needs them, so a new cell (the list makes
    // one when it needs more mid-scroll) costs its avatar, header, body and footer, not every part.
    private lazy var quote: FeedQuoteView = {
        let view = FeedQuoteView()
        view.onTap = { [weak self] in self.map { $0.delegate?.rowToggleQuote($0.id) } }
        row.addSubview(view)
        made.insert("quote")
        FeedRowCell.drawAsync(view)
        return view
    }()
    private lazy var chip: FeedChipView = {
        let view = FeedChipView()
        row.addSubview(view)
        made.insert("chip")
        FeedRowCell.drawAsync(view)
        return view
    }()
    private var made: Set<String> = []
    private lazy var sendingLabel: UILabel = {
        let label = UILabel()
        label.accessibilityIdentifier = "feed.reply.sending"
        row.addSubview(label)
        made.insert("sending")
        return label
    }()
    private lazy var sendingSpinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        row.addSubview(view)
        return view
    }()
    private let body = UIView()
    private let inlineText = UILabel()
    private lazy var markdown: NativeMarkdownView = {
        let view = NativeMarkdownView()
        body.addSubview(view)
        made.insert("markdown")
        return view
    }()
    private lazy var web: WebMarkdownUIView = {
        let view = WebMarkdownUIView()
        view.onTap = { [weak self] in self.map { $0.delegate?.rowOpen($0.id) } }
        view.onHeight = { [weak self] height in self.map { $0.delegate?.rowWebHeight($0.id, height) } }
        body.addSubview(view)
        made.insert("web")
        return view
    }()
    private lazy var webPlaceholder: UILabel = {
        let label = UILabel()
        label.numberOfLines = 0
        body.addSubview(label)
        made.insert("webPlaceholder")
        FeedRowCell.drawAsync(label)
        return label
    }()
    private lazy var fade: FeedFadeView = {
        let view = FeedFadeView()
        view.isUserInteractionEnabled = false
        row.insertSubview(view, aboveSubview: body)
        made.insert("fade")
        return view
    }()
    private let showMore = UIButton(type: .custom)
    private let answerLabel = UILabel()
    /// Rarely shown parts, made the first time a row needs them: a new cell (the list makes a few
    /// as it first scrolls) costs only what most rows show.
    private lazy var spinner: UIActivityIndicatorView = {
        let view = UIActivityIndicatorView(style: .medium)
        row.addSubview(view)
        return view
    }()
    private var spinnerMade = false
    private lazy var command: FeedCommandCardView = {
        let view = FeedCommandCardView()
        view.onShowAll = { [weak self] in self.map { $0.delegate?.rowCodeExpand($0.id) } }
        view.onCopy = { [weak self] in self.map { $0.delegate?.rowCopyCommand($0.id) } }
        row.addSubview(view)
        made.insert("command")
        FeedRowCell.drawAsync(view)
        return view
    }()
    private var capsules: [FeedCapsuleButton] = []
    private lazy var question: FeedQuestionCardView = {
        let view = FeedQuestionCardView()
        view.onInput = { [weak self] input in self.map { $0.delegate?.rowQuestion($0.id, input) } }
        row.addSubview(view)
        made.insert("question")
        FeedRowCell.drawAsync(view)
        return view
    }()
    private let answeredCaption = UILabel()
    private var answeredHeaders: [UILabel] = []
    private var bubbles: [FeedBubbleLabel] = []
    private let errorLabel = UILabel()
    private lazy var decline: UIButton = {
        var configuration = UIButton.Configuration.bordered()
        configuration.title = "Decline"
        configuration.baseForegroundColor = .systemRed
        let button = UIButton(configuration: configuration)
        button.addAction(UIAction { [weak self] _ in self.map { $0.delegate?.rowDecline($0.id) } }, for: .touchUpInside)
        row.addSubview(button)
        declineMade = true
        return button
    }()
    private var declineMade = false
    private let repliesCaption = UILabel()
    private let failureLabel = UILabel()
    private lazy var composer: UIView = makeComposer()
    private var composerMade = false
    private let composerText = FeedLazyBox<UITextView>()
    private let composerPlaceholder = UILabel()
    private let send = UIButton(type: .custom)
    private var footerButtons: [UIButton] = []
    /// Swipe actions: the strip under the row and its buttons.
    private let strip = UIView()
    private var stripButtons: [FeedSwipeButton] = []
    private var actions: [FeedSwipeAction] = []
    private var offset: CGFloat = 0
    private var dragStart: CGFloat?
    private var armed = false {
        didSet { if armed, !oldValue { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
    }
    private let pan = UIPanGestureRecognizer()
    private let closeTap = UITapGestureRecognizer()

    override init(frame: CGRect) {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { FeedCellTiming.log("init", t0) }
        #endif
        super.init(frame: frame)
        contentView.clipsToBounds = true
        contentView.addSubview(strip)
        contentView.addSubview(row)
        row.backgroundColor = .cmuxMobileBackground
        contentView.addSubview(divider)
        divider.backgroundColor = .separator

        avatar.backgroundColor = .cmuxMobileSurfaceRaised
        avatar.layer.cornerRadius = 20
        avatar.isAccessibilityElement = false
        avatarGlyph.contentMode = .center
        avatarGlyph.tintColor = .label
        avatar.addSubview(avatarGlyph)
        row.addSubview(avatar)
        unread.backgroundColor = .label
        unread.layer.cornerRadius = 4.5
        unread.layer.borderWidth = 2
        unread.isAccessibilityElement = true
        unread.accessibilityLabel = "Unread"
        row.addSubview(unread)

        for label in [name, source, time] {
            label.numberOfLines = 1
            row.addSubview(label)
        }
        name.lineBreakMode = .byTruncatingTail
        source.lineBreakMode = .byTruncatingTail
        menuButton.setImage(UIImage(systemName: "ellipsis", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15)), for: .normal)
        menuButton.tintColor = .secondaryLabel
        menuButton.showsMenuAsPrimaryAction = true
        menuButton.accessibilityLabel = "Event actions"
        menuButton.menu = UIMenu(children: [UIDeferredMenuElement.uncached { [weak self] completion in
            MainActor.assumeIsolated {
                guard let self, let delegate = self.delegate else { return completion([]) }
                completion([delegate.rowMenu(self.id)])
            }
        }])
        row.addSubview(menuButton)


        body.clipsToBounds = true
        inlineText.numberOfLines = 0
        body.addSubview(inlineText)
        body.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(openTapped(_:))))
        row.addSubview(body)
        showMore.contentHorizontalAlignment = .leading
        showMore.addAction(UIAction { [weak self] _ in self.map { $0.delegate?.rowToggleExpanded($0.id) } }, for: .touchUpInside)
        row.addSubview(showMore)

        answerLabel.numberOfLines = 0
        row.addSubview(answerLabel)
        answeredCaption.numberOfLines = 0
        row.addSubview(answeredCaption)
        errorLabel.numberOfLines = 0
        row.addSubview(errorLabel)
        repliesCaption.numberOfLines = 1
        row.addSubview(repliesCaption)
        failureLabel.numberOfLines = 0
        failureLabel.accessibilityIdentifier = "feed.reply.failure"
        row.addSubview(failureLabel)


        for (index, title) in ["Reply", "Open", "Copy", "Share"].enumerated() {
            let button = UIButton(type: .custom)
            button.tag = index
            button.accessibilityLabel = title
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let button else { return }
                self.footerTapped(button.tag, button)
            }, for: .touchUpInside)
            footerButtons.append(button)
            row.addSubview(button)
        }

        let header = UITapGestureRecognizer(target: self, action: #selector(headerTapped(_:)))
        row.addGestureRecognizer(header)
        row.addInteraction(UIContextMenuInteraction(delegate: self))

        pan.name = RowSwipeActions.panName
        pan.delegate = self
        pan.addTarget(self, action: #selector(panned(_:)))
        contentView.addGestureRecognizer(pan)
        closeTap.addTarget(self, action: #selector(closeTapped))
        closeTap.isEnabled = false
        row.addGestureRecognizer(closeTap)

        // Made with the cell: the permission buttons, a reply and an answer, so no row allocates views mid-scroll.
        // Text is drawn on a background thread at commit (the labels' layers draw asynchronously):
        // a row's first draw no longer lands on the main thread's frame.
        FeedRowCell.drawAsync(contentView)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (cell: FeedRowCell, _: UITraitCollection) in
            cell.unread.layer.borderColor = UIColor.cmuxMobileBackground.resolvedColor(with: cell.traitCollection).cgColor
            if cell.made.contains("quote") { cell.quote.updateColors() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func makeComposer() -> UIView {
        let composer = UIView()
        composer.backgroundColor = .cmuxMobileFill
        composer.layer.cornerRadius = 20
        composer.layer.cornerCurve = .continuous
        let text = UITextView()
        text.backgroundColor = .clear
        text.textContainerInset = UIEdgeInsets(top: 9, left: 14, bottom: 9, right: 0)
        text.textContainer.lineFragmentPadding = 0
        text.delegate = self
        composer.addSubview(text)
        composerText.value = text
        composerPlaceholder.textColor = .placeholderText
        composer.addSubview(composerPlaceholder)
        send.layer.cornerRadius = 15
        send.accessibilityLabel = "Send reply"
        send.addAction(UIAction { [weak self] _ in self.map { $0.delegate?.rowSendReply($0.id) } }, for: .touchUpInside)
        composer.addSubview(send)
        row.addSubview(composer)
        composerMade = true
        return composer
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        if offset != 0 { setOffset(0, animated: false) }
        armed = false
        if made.contains("web") { web.release() }
        resignQuestionOther()
        if composerText.value?.isFirstResponder == true { composerText.value?.resignFirstResponder() }
    }

    override func preferredLayoutAttributesFitting(_ attributes: UICollectionViewLayoutAttributes) -> UICollectionViewLayoutAttributes {
        // Heights come from the layout model; the cell never sizes itself.
        attributes
    }

    // MARK: Applying a layout

    /// The event as the store has it now (its read flag and time; the layout key leaves those out).
    private var current: FeedItem?
    /// The read flag the dot shows, and when the time was last drawn (a prefetched cell catches up).
    var shownRead: Bool? { current?.isRead }
    private(set) var timeDrawnAt: CFTimeInterval = 0

    func apply(_ layout: FeedRowLayout, item shown: FeedItem?, settled: Bool) {
        #if DEBUG
        let t0 = CACurrentMediaTime()
        defer { FeedCellTiming.log("apply \(layout.key.item.id)", t0) }
        #endif
        let same = self.layout?.key.item.id == layout.key.item.id
        self.layout = layout
        let item = shown ?? layout.key.item
        current = item
        let width = CGFloat(layout.key.width)
        if !same { setOffset(0, animated: false) }
        row.frame = CGRect(x: offset, y: 0, width: width, height: layout.dividerY)
        // From the text column, as every list's separators (the avatar hangs in the gutter).
        divider.frame = CGRect(x: layout.column.minX, y: layout.dividerY, width: width - layout.column.minX,
                               height: layout.height - layout.dividerY)
        accessibilityIdentifier = "feed.row.\(item.id)"

        avatar.frame = layout.avatar
        avatarGlyph.frame = avatar.bounds
        avatarGlyph.image = UIImage(systemName: Self.avatarSymbol(item.harness),
                                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 40 * 0.42, weight: .medium))
        unread.isHidden = item.isRead
        unread.accessibilityElementsHidden = item.isRead
        unread.frame = CGRect(x: layout.avatar.maxX - 9 + 2, y: layout.avatar.minY - 2, width: 9, height: 9)
        unread.layer.borderColor = UIColor.cmuxMobileBackground.resolvedColor(with: traitCollection).cgColor

        applyHeader(layout)
        menuButton.frame = layout.menuButton

        if let part = layout.quote {
            quote.isHidden = false
            quote.apply(part, origin: layout.column.origin)
        } else if made.contains("quote") {
            quote.isHidden = true
        }
        if let part = layout.chip {
            chip.isHidden = false
            chip.apply(part)
        } else if made.contains("chip") {
            chip.isHidden = true
        }

        applyBody(layout.body, settled: settled)
        applyAnswer(layout)
        applyErrorAndReplies(layout)
        applyComposer(layout)
        applyFooter(layout)
        actions = delegate?.rowSwipeActions(item.id) ?? []
    }

    override var accessibilityCustomActions: [UIAccessibilityCustomAction]? {
        get { actions.map { action in UIAccessibilityCustomAction(name: action.title) { _ in action.action(); return true } } }
        set {}
    }

    /// The minute changed: only the time label moves.
    func refreshTime() {
        guard let layout else { return }
        applyHeader(layout)
    }

    /// The read flag changed (no layout change): the dot and the swipe actions.
    func redraw(_ item: FeedItem) {
        current = item
        unread.isHidden = item.isRead
        unread.accessibilityElementsHidden = item.isRead
        actions = delegate?.rowSwipeActions(item.id) ?? []
    }

    /// The Feed stopped scrolling: web bodies render now.
    func scrollSettled() {
        guard let layout else { return }
        applyBody(layout.body, settled: true)
    }

    private func applyHeader(_ layout: FeedRowLayout) {
        timeDrawnAt = CACurrentMediaTime()
        let item = current ?? layout.key.item
        let styles = NativeTextStyles(category: traitCollection.preferredContentSizeCategory)
        let font = styles.font(.subheadline)
        let semibold = styles.font(.subheadline, weight: .semibold)
        let stamp = Self.relativeTime(item.createdAt, now: Date())
        let frame = layout.header
        if styles.isAccessibilitySize {
            // At accessibility sizes the source wraps under the name instead of truncating.
            name.attributedText = NSAttributedString(string: item.agentName, attributes: [.font: semibold, .foregroundColor: UIColor.label])
            source.attributedText = NSAttributedString(string: "\(item.workspaceTitle) · \(stamp)", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
            time.isHidden = true
            let line = ceil(font.lineHeight)
            name.frame = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: line)
            source.frame = CGRect(x: frame.minX, y: frame.minY + line + 2, width: frame.width, height: line)
            return
        }
        time.isHidden = false
        name.attributedText = NSAttributedString(string: item.agentName, attributes: [.font: semibold, .foregroundColor: UIColor.label])
        source.attributedText = NSAttributedString(string: "· \(item.workspaceTitle)", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        time.attributedText = NSAttributedString(string: "· \(stamp)", attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel])
        // HStack(spacing: 4): the time never truncates, then the name, then the source.
        let timeWidth = ceil(time.intrinsicContentSize.width)
        let available = frame.width - 4 /* Spacer(minLength: 4) */
        let nameWidth = min(ceil(name.intrinsicContentSize.width), max(0, available - timeWidth - 8))
        let sourceWidth = min(ceil(source.intrinsicContentSize.width), max(0, available - timeWidth - nameWidth - 8))
        let line = frame.height
        name.frame = CGRect(x: frame.minX, y: frame.minY, width: nameWidth, height: line)
        source.frame = CGRect(x: name.frame.maxX + 4, y: frame.minY, width: sourceWidth, height: line)
        time.frame = CGRect(x: source.frame.maxX + 4, y: frame.minY, width: timeWidth, height: line)
    }

    private func applyBody(_ part: FeedRowLayout.Body, settled: Bool) {
        body.frame = part.frame
        let full = CGRect(x: 0, y: 0, width: part.frame.width, height: part.fullHeight)
        inlineText.isHidden = true
        if made.contains("markdown") { markdown.isHidden = true }
        if made.contains("web") { web.isHidden = true }
        if made.contains("webPlaceholder") { webPlaceholder.isHidden = true }
        switch part.content {
        case .inline(let text):
            inlineText.isHidden = false
            inlineText.attributedText = text
            inlineText.frame = full
        case .native(let native):
            markdown.isHidden = false
            markdown.frame = full
            markdown.apply(native)
        case .web(let source, let height, let placeholder):
            if settled || (made.contains("web") && web.isShowing) {
                web.frame = full
                web.isHidden = false
                web.show(source, contentHeight: height)
            } else {
                // While the Feed moves, the body's text stands in at the web view's height.
                webPlaceholder.isHidden = false
                webPlaceholder.attributedText = placeholder
                webPlaceholder.frame = full
            }
        }
        let fades = part.overflowing && part.frame.height < part.fullHeight
        if fades || made.contains("fade") {
            fade.isHidden = !fades
            fade.frame = CGRect(x: part.frame.minX, y: part.frame.maxY - 32, width: part.frame.width, height: 32)
        }
        showMore.isHidden = part.showMore == nil
        if let more = part.showMore {
            showMore.setAttributedTitle(more.title, for: .normal)
            showMore.frame = more.frame
        }
    }

    private func capsule(_ index: Int) -> FeedCapsuleButton {
        while capsules.count <= index {
            let button = FeedCapsuleButton()
            FeedRowCell.drawAsync(button)
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let button, let id = button.actionID else { return }
                if button.opensTerminal { self.delegate?.rowOpen(self.id) } else { self.delegate?.rowRespond(self.id, optionID: id) }
            }, for: .touchUpInside)
            capsules.append(button)
            row.addSubview(button)
        }
        return capsules[index]
    }

    private func bubble(_ index: Int) -> FeedBubbleLabel {
        while bubbles.count <= index {
            let view = FeedBubbleLabel()
            FeedRowCell.drawAsync(view)
            bubbles.append(view)
            row.addSubview(view)
        }
        return bubbles[index]
    }

    private func applyAnswer(_ layout: FeedRowLayout) {
        // A reused cell carries no identifier or hint from the event it showed before.
        answerLabel.accessibilityIdentifier = nil
        for button in capsules {
            button.accessibilityIdentifier = nil
            button.accessibilityHint = nil
        }
        answerLabel.isHidden = true
        if spinnerMade {
            spinner.isHidden = true
            spinner.stopAnimating()
        }
        if made.contains("command") { command.isHidden = true }
        if made.contains("question") { question.isHidden = true }
        answeredCaption.isHidden = true
        var used = 0
        var headers = 0
        switch layout.answer {
        case .none:
            break
        case .label(let text, let frame):
            answerLabel.isHidden = false
            answerLabel.attributedText = text
            answerLabel.frame = frame
        case .pending(let text, let frame, let spinnerFrame):
            answerLabel.isHidden = false
            answerLabel.attributedText = text
            answerLabel.frame = frame
            answerLabel.accessibilityIdentifier = "feed.permission.pending"
            spinnerMade = true
            spinner.isHidden = false
            spinner.frame = spinnerFrame
            spinner.startAnimating()
        case .terminal(let button):
            capsule(0).apply(button)
            capsule(0).accessibilityIdentifier = "feed.terminal.open"
            used = 1
        case .permission(let card, let buttons):
            if let card {
                command.isHidden = false
                command.apply(card)
            }
            for (index, button) in buttons.enumerated() {
                capsule(index).apply(button)
                capsule(index).accessibilityHint = button.title.string.contains("Allow") ? "Approve with Face ID" : nil
            }
            used = buttons.count
        case .question(let card, let openTerminal):
            question.isHidden = false
            question.apply(card)
            if let openTerminal {
                capsule(0).apply(openTerminal)
                capsule(0).accessibilityIdentifier = "feed.terminal.open"
                used = 1
            }
        case .answered(let caption, let captionFrame, let items):
            answeredCaption.isHidden = false
            answeredCaption.attributedText = caption
            answeredCaption.frame = captionFrame
            for (index, entry) in items.enumerated() {
                while answeredHeaders.count <= index {
                    let label = UILabel()
                    answeredHeaders.append(label)
                    row.addSubview(label)
                }
                answeredHeaders[index].isHidden = false
                answeredHeaders[index].attributedText = entry.header
                answeredHeaders[index].frame = entry.headerFrame
                bubble(index).apply(entry.bubble)
            }
            headers = items.count
        }
        for button in capsules[used...] { button.isHidden = true }
        for label in answeredHeaders[headers...] { label.isHidden = true }
        bubbleBase = headers
    }

    /// Bubbles before this index belong to the answered summary; replies follow.
    private var bubbleBase = 0

    private func applyErrorAndReplies(_ layout: FeedRowLayout) {
        errorLabel.isHidden = layout.error == nil
        if declineMade || layout.error?.decline != nil { decline.isHidden = layout.error?.decline == nil }
        if let error = layout.error {
            errorLabel.attributedText = error.text
            errorLabel.frame = error.frame
            if let frame = error.decline { decline.frame = frame }
        }
        var next = bubbleBase
        repliesCaption.isHidden = layout.replies == nil
        repliesCaption.accessibilityIdentifier = "feed.reply.sent"
        if let replies = layout.replies {
            repliesCaption.attributedText = replies.caption
            repliesCaption.frame = replies.captionFrame
            for entry in replies.bubbles {
                bubble(next).apply(entry)
                next += 1
            }
        }
        for view in bubbles[next...] { view.isHidden = true }
        if let sending = layout.replySending {
            sendingLabel.isHidden = false
            sendingLabel.attributedText = sending.text
            sendingLabel.frame = sending.frame
            sendingSpinner.isHidden = false
            sendingSpinner.frame = sending.spinner
            sendingSpinner.startAnimating()
        } else if made.contains("sending") {
            sendingLabel.isHidden = true
            sendingSpinner.isHidden = true
            sendingSpinner.stopAnimating()
        }
        failureLabel.isHidden = layout.replyFailure == nil
        if let failure = layout.replyFailure {
            failureLabel.attributedText = failure.text
            failureLabel.frame = failure.frame
        }
    }

    private func applyComposer(_ layout: FeedRowLayout) {
        guard let frame = layout.composer else {
            if composerMade { composer.isHidden = true }
            if composerText.value?.isFirstResponder == true { composerText.value?.resignFirstResponder() }
            return
        }
        let item = layout.key.item
        let styles = NativeTextStyles(category: traitCollection.preferredContentSizeCategory)
        composer.isHidden = false
        composer.frame = frame
        guard let field = composerText.value else { return }
        field.font = styles.font(.body)
        if field.text != layout.key.state.replyDraft { field.text = layout.key.state.replyDraft }
        field.frame = CGRect(x: 0, y: 0, width: frame.width - 40 - 8, height: frame.height)
        composerPlaceholder.font = styles.font(.body)
        composerPlaceholder.text = "Reply to \(item.agentName)"
        composerPlaceholder.isHidden = !layout.key.state.replyDraft.isEmpty
        composerPlaceholder.frame = CGRect(x: 14, y: 9, width: frame.width - 14 - 48, height: ceil(styles.font(.body).lineHeight))
        let empty = layout.key.state.replyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        send.isEnabled = !empty
        send.backgroundColor = empty ? .cmuxMobileFill : .cmuxMobileAccent
        send.setImage(UIImage(systemName: "arrow.up", withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)), for: .normal)
        send.tintColor = empty ? .tertiaryLabel : .cmuxMobileOnAccent
        send.frame = CGRect(x: frame.width - 5 - 30, y: frame.height - 5 - 30, width: 30, height: 30)
    }

    func focusQuestionOther() { if made.contains("question") { question.focusOther() } }
    func resignQuestionOther() { if made.contains("question") { question.resignOther() } }

    /// Opens the reply field's keyboard (the footer's Reply).
    func focusComposer() {
        _ = composer
        composerText.value?.becomeFirstResponder()
    }

    private func applyFooter(_ layout: FeedRowLayout) {
        let styles = NativeTextStyles(category: traitCollection.preferredContentSizeCategory)
        let font = styles.font(.footnote)
        let copied = layout.key.state.copied
        let entries: [(Int, String, String)] = (layout.footerHasReply ? [(0, "bubble.left", "Reply")] : [])
            + [(1, "arrow.up.right.square", "Open"), (2, copied ? "checkmark" : "doc.on.doc", "Copy"), (3, "square.and.arrow.up", "Share")]
        var widths: [CGFloat] = []
        for (tag, symbol, title) in entries {
            let button = footerButtons[tag]
            let text = Self.footerTitle(symbol: symbol, title: title, font: font)
            if button.attributedTitle(for: .normal) !== text { button.setAttributedTitle(text, for: .normal) }
            widths.append(max(44, ceil(text.size().width) + 4))
        }
        // One terminal reply at a time: a second would interleave with the first.
        footerButtons[0].isEnabled = layout.footerReplyEnabled
        footerButtons[0].alpha = layout.footerReplyEnabled ? 1 : 0.4
        for button in footerButtons { button.isHidden = true }
        // HStack with a Spacer between each button: the first at the leading edge, the last at the trailing one.
        let frame = layout.footer
        let gaps = CGFloat(max(entries.count - 1, 1))
        let spacing = max(0, (frame.width - widths.reduce(0, +)) / gaps)
        var x = frame.minX
        for (index, entry) in entries.enumerated() {
            let button = footerButtons[entry.0]
            button.isHidden = false
            button.frame = CGRect(x: x, y: frame.minY, width: widths[index], height: frame.height)
            x += widths[index] + spacing
        }
    }

    // MARK: Taps

    @objc private func openTapped(_ tap: UITapGestureRecognizer) {
        guard offset == 0 else { return }
        // A link in the body: a web link opens in Safari; a file link opens the event, whose chat previews it.
        var url: URL?
        // Only inside the shown body (its hidden overflow under Show more holds links too).
        guard body.bounds.contains(tap.location(in: body)) else { return delegate?.rowOpen(id) ?? () }
        if !inlineText.isHidden { url = NativeMarkdownView.link(in: inlineText, at: tap.location(in: inlineText)) }
        if url == nil, made.contains("markdown"), !markdown.isHidden { url = markdown.link(at: tap.location(in: markdown)) }
        if let url, let scheme = url.scheme?.lowercased(), ["http", "https", "mailto", "tel", "sms", "facetime"].contains(scheme) {
            UIApplication.shared.open(url)
            return
        }
        delegate?.rowOpen(id)
    }

    @objc private func headerTapped(_ tap: UITapGestureRecognizer) {
        guard offset == 0, let layout else { return }
        // Only the header line opens the tab (the answer card, its padding and gaps never navigate).
        let point = tap.location(in: row)
        if layout.header.insetBy(dx: 0, dy: -4).contains(point) { delegate?.rowOpen(id) }
    }

    private func footerTapped(_ tag: Int, _ button: UIButton) {
        switch tag {
        case 0:
            delegate?.rowToggleReply(id)
        case 1:
            delegate?.rowOpen(id)
        case 2:
            delegate?.rowCopy(id)
        default:
            delegate?.rowShare(id, from: button)
        }
    }

    func textViewDidChange(_ textView: UITextView) {
        composerPlaceholder.isHidden = !textView.text.isEmpty
        delegate?.rowReplyDraft(id, textView.text)
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration? {
        guard offset == 0, let delegate else { return nil }
        let id = id
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in delegate.rowMenu(id) }
    }

    // MARK: Swipe actions (Mail conventions, the rounded style of #24202)

    private var width: CGFloat { bounds.width }
    private var style: RowSwipeActionStyle { .standard }
    private var revealWidth: CGFloat { style.revealWidth(count: actions.count) }
    private var fullThreshold: CGFloat { max(width * 0.6, 160, revealWidth + 40) }
    var isOpen: Bool { offset != 0 }

    override func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard recognizer === pan else { return super.gestureRecognizerShouldBegin(recognizer) }
        let velocity = pan.velocity(in: self)
        guard abs(velocity.x) > abs(velocity.y) * 1.3 else { return false }
        // No leading edge: a rightward pan opens the team drawer unless it closes open actions.
        return velocity.x < 0 || isOpen
    }

    @objc private func panned(_ pan: UIPanGestureRecognizer) {
        let translation = pan.translation(in: self).x
        switch pan.state {
        case .began, .changed:
            if dragStart == nil {
                dragStart = offset
                delegate?.rowSwipeBegan(id)
            }
            var next = min((dragStart ?? 0) + translation, 0)
            if actions.isEmpty { next = 0 }
            let limit = width * 0.9
            if abs(next) > limit { next = -(limit + (abs(next) - limit) * 0.25) }
            armed = abs(next) > fullThreshold
            setOffset(next, animated: false)
        case .ended, .cancelled, .failed:
            dragStart = nil
            let velocity = pan.velocity(in: self).x
            if armed, let first = actions.first {
                perform(first)
                return
            }
            let projected = abs(min(offset + velocity * 0.12, 0))
            let open = projected > revealWidth / 2 && (velocity <= 0 || abs(offset) > revealWidth / 2)
            setOffset(open ? -revealWidth : 0, animated: true)
        default:
            break
        }
    }

    @objc private func closeTapped() { close() }

    func close() {
        guard isOpen else { return }
        setOffset(0, animated: true)
    }

    /// Opens the actions (the demo driver).
    func reveal() {
        delegate?.rowSwipeBegan(id)
        setOffset(-revealWidth, animated: true)
    }

    /// A full swipe: the row slides out, the action runs, the row comes back (or leaves).
    func perform(_ action: FeedSwipeAction) {
        armed = true
        setOffset(-width, animated: true)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(220))
            if action.removesRow { action.action() }
            self?.armed = false
            self?.setOffset(0, animated: true)
            guard !action.removesRow else { return }
            try? await Task.sleep(for: .milliseconds(260))
            action.action()
        }
    }

    func perform(actionID: String) {
        if let action = actions.first(where: { $0.id == actionID }) { perform(action) }
    }

    private func setOffset(_ value: CGFloat, animated: Bool) {
        let wasOpen = isOpen
        offset = value
        closeTap.isEnabled = value != 0
        layoutStrip()
        let move = { self.row.frame.origin.x = value; self.layoutStrip() }
        if animated, !UIAccessibility.isReduceMotionEnabled {
            UIView.animate(withDuration: 0.35, delay: 0, usingSpringWithDamping: 0.85, initialSpringVelocity: 0,
                           options: [.allowUserInteraction, .beginFromCurrentState], animations: move)
        } else {
            move()
        }
        if wasOpen != isOpen { delegate?.rowSwipeOpenChanged(id, open: isOpen) }
    }

    /// The trailing strip (RowSwipeActionStyle): capsules that grow together as the row slides;
    /// an armed full swipe gives the outermost one all the room.
    private func layoutStrip() {
        let revealed = abs(offset)
        let height = layout?.dividerY ?? bounds.height
        strip.isHidden = revealed < 0.5
        // A closed row (every row that scrolls in) has nothing to lay out here.
        guard !strip.isHidden || !stripButtons.allSatisfy(\.isHidden) else { return }
        strip.frame = CGRect(x: width - revealed, y: 0, width: revealed, height: height)
        while stripButtons.count < actions.count {
            let button = FeedSwipeButton()
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let id = button?.actionID, let action = self.actions.first(where: { $0.id == id }) else { return }
                self.perform(action)
            }, for: .touchUpInside)
            stripButtons.append(button)
            strip.addSubview(button)
        }
        let each = style.buttonWidth(revealed: revealed, count: actions.count)
        var x = revealed - style.trailingInset
        for (index, button) in stripButtons.enumerated() {
            guard index < actions.count else { button.isHidden = true; continue }
            let action = actions[index]
            let outermost = index == 0
            let buttonWidth = armed ? (outermost ? style.fullSwipeWidth(revealed: revealed) : 0) : each
            x -= buttonWidth
            button.isHidden = false
            button.alpha = armed && !outermost ? 0 : 1
            button.apply(action, width: buttonWidth, rowHeight: height, style: style)
            button.frame = CGRect(x: x, y: 0, width: buttonWidth, height: height)
            button.accessibilityIdentifier = "feed.swipe.\(action.id)"
            x -= armed ? 0 : style.spacing
        }
    }

    // MARK: Helpers

    /// Asynchronous drawing for every label layer under `view` (and those added later reuse it).
    static func drawAsync(_ view: UIView) {
        if view is UILabel { view.layer.drawsAsynchronously = true }
        for subview in view.subviews { drawAsync(subview) }
    }

    /// Footer titles (symbol and word), one per symbol, title and size: built once, not per row.
    private static var footerTitles: [String: NSAttributedString] = [:]

    static func footerTitle(symbol: String, title: String, font: UIFont) -> NSAttributedString {
        let key = "\(symbol)|\(title)|\(font.pointSize)"
        if let hit = footerTitles[key] { return hit }
        let text = NSMutableAttributedString()
        if let image = UIImage(systemName: symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 15))?
            .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal) {
            let attachment = NSTextAttachment(image: image)
            attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
            text.append(NSAttributedString(attachment: attachment))
        }
        text.append(NSAttributedString(string: " " + title, attributes: [.font: font, .foregroundColor: UIColor.secondaryLabel]))
        footerTitles[key] = text
        return text
    }

    static func avatarSymbol(_ harness: String) -> String {
        switch harness {
        case "claude": "asterisk"
        case "codex": "chevron.left.forwardslash.chevron.right"
        case "cursor": "cursorarrow.rays"
        case "gemini": "sparkles"
        case "terminal": "terminal"
        default: "sparkle"
        }
    }

    static func relativeTime(_ date: Date, now: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        switch seconds {
        case ..<45: return "now"
        case ..<3600: return "\(max(1, seconds / 60))m"
        case ..<86_400: return "\(seconds / 3600)h"
        default: return "\(seconds / 86_400)d"
        }
    }
}

// MARK: Parts

/// A view made on first use (a reference, so a lazy builder can fill it in).
final class FeedLazyBox<Value: AnyObject> {
    var value: Value?
}

/// The iMessage-style quote (QuoteBubble): a caption, the bubble with its tail, a thread line for an agent's ask.
final class FeedQuoteView: UIView {
    private let caption = UILabel()
    private let bubble = CAShapeLayer()
    private let text = UILabel()
    private let thread = CAShapeLayer()
    private var outgoing = true
    var onTap: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.addSublayer(bubble)
        layer.addSublayer(thread)
        thread.fillColor = nil
        thread.lineWidth = 1.5
        thread.lineCap = .round
        addSubview(caption)
        text.lineBreakMode = .byTruncatingTail
        addSubview(text)
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func tapped() { onTap?() }

    func apply(_ part: FeedRowLayout.Quote, origin: CGPoint) {
        frame = part.frame
        let shift = CGPoint(x: -part.frame.minX, y: -part.frame.minY)
        caption.attributedText = part.caption
        // A little wider than measured: an attachment's rounding must never truncate "You".
        caption.lineBreakMode = .byClipping
        caption.frame = part.captionFrame.offsetBy(dx: shift.x, dy: shift.y).insetBy(dx: -3, dy: 0)
            .offsetBy(dx: part.outgoing ? -3 : 3, dy: 0)
        text.attributedText = part.text
        text.numberOfLines = part.maxLines
        text.frame = part.textFrame.offsetBy(dx: shift.x, dy: shift.y)
        outgoing = part.outgoing
        let rect = part.bubble.offsetBy(dx: shift.x, dy: shift.y)
        bubble.path = Self.bubblePath(rect, outgoing: part.outgoing)
        if let line = part.thread?.offsetBy(dx: shift.x, dy: shift.y) {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: line.minX + 2, y: line.minY))
            path.addQuadCurve(to: CGPoint(x: line.maxX, y: line.maxY), controlPoint: CGPoint(x: line.minX + 2, y: line.maxY))
            thread.path = path.cgPath
            thread.isHidden = false
        } else {
            thread.isHidden = true
        }
        accessibilityLabel = part.outgoing ? "In reply to your message: \(part.text.string)" : "In reply to: \(part.text.string)"
        updateColors()
    }

    func updateColors() {
        bubble.fillColor = UIColor.cmuxMobileBubble.resolvedColor(with: traitCollection).cgColor
        thread.strokeColor = UIColor.separator.resolvedColor(with: traitCollection).cgColor
    }

    /// A 16 pt rounded rect and the tail (BubbleTail) in one path, the tail at the bottom-leading
    /// corner (bottom-trailing for your own message, mirrored).
    static func bubblePath(_ rect: CGRect, outgoing: Bool) -> CGPath {
        let body = UIBezierPath(roundedRect: rect, cornerRadius: 16).cgPath
        let box = CGRect(x: -6, y: rect.height - 18 + 1, width: 22, height: 18)
        let w = box.width, h = box.height
        let tail = UIBezierPath()
        tail.move(to: CGPoint(x: box.minX + 8, y: box.minY))
        tail.addCurve(to: CGPoint(x: box.minX, y: box.maxY), controlPoint1: CGPoint(x: box.minX + 8, y: box.minY + h * 0.65),
                      controlPoint2: CGPoint(x: box.minX + 4, y: box.maxY - 2))
        tail.addCurve(to: CGPoint(x: box.minX + w, y: box.maxY - 3), controlPoint1: CGPoint(x: box.minX + 7, y: box.maxY + 0.5),
                      controlPoint2: CGPoint(x: box.minX + w * 0.6, y: box.maxY - 1))
        tail.addLine(to: CGPoint(x: box.minX + w, y: box.minY))
        tail.close()
        var transform = outgoing
            ? CGAffineTransform(translationX: rect.maxX, y: rect.minY).scaledBy(x: -1, y: 1)
            : CGAffineTransform(translationX: rect.minX, y: rect.minY)
        let placed = tail.cgPath.copy(using: &transform) ?? tail.cgPath
        return body.union(placed)
    }
}

final class FeedChipView: UIView {
    private let dot = UIView()
    private let symbol = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .cmuxMobileFill
        dot.layer.cornerRadius = 3.5
        addSubview(dot)
        symbol.tintColor = .label
        symbol.contentMode = .center
        addSubview(symbol)
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ part: FeedRowLayout.Chip) {
        frame = part.frame
        layer.cornerRadius = part.frame.height / 2
        label.attributedText = part.text
        label.frame = part.textFrame
        dot.isHidden = part.dot == nil
        dot.backgroundColor = part.dot
        symbol.isHidden = part.symbol == nil
        if let mark = part.markFrame {
            dot.frame = mark
            symbol.frame = mark.insetBy(dx: -2, dy: -2)
        }
        if let name = part.symbol {
            symbol.image = UIImage(systemName: name, withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1))
        }
    }
}

/// The bottom fade over a capped body.
final class FeedFadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: FeedFadeView, _: UITraitCollection) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateColors() {
        let color = UIColor.cmuxMobileBackground.resolvedColor(with: traitCollection)
        (layer as? CAGradientLayer)?.colors = [color.withAlphaComponent(0).cgColor, color.cgColor]
    }
}

/// CmuxMobileCapsuleButtonStyle in UIKit: a 40 pt capsule inside a 44 pt target.
final class FeedCapsuleButton: UIControl {
    private let fill = UIView()
    private let label = UILabel()
    var actionID: String?
    /// The button opens the event's terminal (not an answer: an agent's option id could be anything).
    var opensTerminal = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        fill.isUserInteractionEnabled = false
        addSubview(fill)
        label.textAlignment = .center
        label.numberOfLines = 1
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.85
        addSubview(label)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ button: FeedRowLayout.CapsuleButton) {
        isHidden = false
        actionID = button.id
        opensTerminal = button.opensTerminal
        frame = button.frame
        isEnabled = button.enabled
        fill.frame = bounds.insetBy(dx: 0, dy: 2)
        fill.layer.cornerRadius = fill.bounds.height / 2
        let kind: FeedRowLayout.CapsuleButton.Kind = button.kind
        fill.backgroundColor = !button.enabled ? .cmuxMobileFill : (kind == .primary ? .cmuxMobileAccent : .cmuxMobileFillSelected)
        label.attributedText = button.title
        label.frame = bounds.insetBy(dx: 12, dy: 0)
        accessibilityLabel = button.title.string.trimmingCharacters(in: .whitespaces)
    }

    override var isHighlighted: Bool {
        didSet { fill.alpha = isHighlighted ? 0.85 : 1; transform = isHighlighted ? CGAffineTransform(scaleX: 0.98, y: 0.98) : .identity }
    }
}

/// A trailing bubble (a reply, an answered question's choice).
final class FeedBubbleLabel: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .cmuxMobileBubble
        layer.cornerRadius = 16
        layer.cornerCurve = .continuous
        label.numberOfLines = 0
        addSubview(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ bubble: FeedRowLayout.Bubble) {
        isHidden = false
        frame = bubble.frame
        label.attributedText = bubble.text
        label.frame = bubble.textFrame.offsetBy(dx: -bubble.frame.minX, dy: -bubble.frame.minY)
    }
}

/// The permission card's command (CodeCard, title "Command", capped at 120 pt).
final class FeedCommandCardView: UIView, UIScrollViewDelegate {
    private let icon = UIImageView(image: UIImage(systemName: "terminal", withConfiguration: UIImage.SymbolConfiguration(pointSize: 13)))
    private let title = UILabel()
    private let copy = UIButton(type: .custom)
    private let scroll = UIScrollView()
    private let code = UILabel()
    private let fade = FeedCodeFadeView()
    private let showAll = UIButton(type: .custom)
    var onShowAll: (() -> Void)?
    var onCopy: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .cmuxMobileCodeBackground
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        layer.borderWidth = 0.5
        clipsToBounds = true
        icon.tintColor = .secondaryLabel
        addSubview(icon)
        addSubview(title)
        copy.setImage(UIImage(systemName: "doc.on.doc", withConfiguration: UIImage.SymbolConfiguration(pointSize: 15)), for: .normal)
        copy.tintColor = .secondaryLabel
        copy.accessibilityLabel = "Copy code"
        copy.addAction(UIAction { [weak self] _ in self?.onCopy?() }, for: .touchUpInside)
        addSubview(copy)
        scroll.showsHorizontalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        code.numberOfLines = 0
        scroll.addSubview(code)
        addSubview(scroll)
        fade.isUserInteractionEnabled = false
        addSubview(fade)
        showAll.backgroundColor = .cmuxMobileCodeBackground
        showAll.addAction(UIAction { [weak self] _ in self?.onShowAll?() }, for: .touchUpInside)
        addSubview(showAll)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: FeedCommandCardView, _: UITraitCollection) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateColors() {
        layer.borderColor = UIColor.separator.withAlphaComponent(0.5).resolvedColor(with: traitCollection).cgColor
    }

    func apply(_ card: FeedRowLayout.CommandCard) {
        frame = card.frame
        icon.frame = CGRect(x: 16, y: 0, width: 16, height: 40)
        icon.contentMode = .center
        title.attributedText = card.title
        title.frame = CGRect(x: 16 + 16 + 6, y: 0, width: card.frame.width - 38 - 44, height: 40)
        copy.frame = CGRect(x: card.frame.width - 8 - 38, y: 1, width: 38, height: 38)
        scroll.frame = card.scrollFrame
        code.attributedText = card.code
        code.frame = card.codeFrame
        scroll.contentSize = CGSize(width: card.codeFrame.maxX + 16, height: card.scrollFrame.height)
        fade.isHidden = card.fadeFrame == nil
        if let frame = card.fadeFrame { fade.frame = frame }
        showAll.isHidden = card.showAllFrame == nil
        if let frame = card.showAllFrame {
            showAll.frame = frame
            showAll.setAttributedTitle(card.showAll, for: .normal)
        }
    }
}

final class FeedCodeFadeView: UIView {
    override class var layerClass: AnyClass { CAGradientLayer.self }

    override init(frame: CGRect) {
        super.init(frame: frame)
        updateColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: FeedCodeFadeView, _: UITraitCollection) in view.updateColors() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func updateColors() {
        let color = UIColor.cmuxMobileCodeBackground.resolvedColor(with: traitCollection)
        (layer as? CAGradientLayer)?.colors = [color.withAlphaComponent(0).cgColor, color.cgColor]
    }
}

/// The question card (QuestionCard, SPEC 6.6): prompt, option rows, Other, Back / Next / Answer.
final class FeedQuestionCardView: UIView, UITextFieldDelegate {
    private let header = UILabel()
    private let pager = UILabel()
    private let prompt = UILabel()
    private let hint = UILabel()
    private var rows: [FeedOptionRow] = []
    private let other = UIButton(type: .custom)
    private let otherField = UITextField()
    private let otherIcon = UIImageView(image: UIImage(systemName: "square.and.pencil"))
    private let back = UIButton(type: .custom)
    private var buttons: [FeedCapsuleButton] = []
    private var otherRow = 0
    var onInput: ((AgentQuestionCardState.Input) -> Void)?

    /// The Other field takes the keyboard (only when the person opened it: `.beginOtherEditing`).
    func focusOther() {
        if !otherField.isHidden { otherField.becomeFirstResponder() }
    }

    func resignOther() {
        if otherField.isFirstResponder { otherField.resignFirstResponder() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .cmuxMobileCard
        layer.cornerRadius = 20
        layer.cornerCurve = .continuous
        clipsToBounds = true
        prompt.numberOfLines = 0
        hint.numberOfLines = 0
        for view in [header, pager, prompt, hint] { addSubview(view) }
        other.backgroundColor = .cmuxMobileFill
        other.layer.cornerRadius = 14
        other.layer.cornerCurve = .continuous
        other.contentHorizontalAlignment = .fill
        other.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onInput?(.click(row: self.otherRow))
        }, for: .touchUpInside)
        addSubview(other)
        otherIcon.tintColor = .tertiaryLabel
        otherIcon.contentMode = .center
        otherIcon.isUserInteractionEnabled = false
        other.addSubview(otherIcon)
        otherField.backgroundColor = .cmuxMobileFillSelected
        otherField.layer.cornerRadius = 14
        otherField.placeholder = "Other…"
        otherField.returnKeyType = .done
        otherField.leftView = UIView(frame: CGRect(x: 0, y: 0, width: 14, height: 1))
        otherField.leftViewMode = .always
        otherField.delegate = self
        otherField.addAction(UIAction { [weak self] _ in
            guard let self else { return }
            self.onInput?(.otherText(self.otherField.text ?? ""))
        }, for: .editingChanged)
        addSubview(otherField)
        back.setTitle("Back", for: .normal)
        back.setTitleColor(.secondaryLabel, for: .normal)
        back.addAction(UIAction { [weak self] _ in self?.onInput?(.previousItem) }, for: .touchUpInside)
        addSubview(back)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func prewarm(options: Int) {
        while rows.count < options { addOptionRow() }
    }

    private func addOptionRow() {
        let row = FeedOptionRow()
        row.addAction(UIAction { [weak self, weak row] _ in
            guard let self, let row else { return }
            let before = row.chosen
            self.onInput?(.click(row: row.row))
            // The selection haptic as a row's choice changes (QuestionCard's `.sensoryFeedback(.selection)`).
            if before != row.chosen || !before { UISelectionFeedbackGenerator().selectionChanged() }
        }, for: .touchUpInside)
        row.isHidden = true
        rows.append(row)
        addSubview(row)
    }

    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        textField.resignFirstResponder()
        return true
    }

    func apply(_ card: FeedRowLayout.QuestionCard) {
        frame = card.frame
        let shift = CGPoint(x: 0, y: 0)
        header.isHidden = card.header == nil
        header.attributedText = card.header
        if let frame = card.headerFrame { header.frame = frame.offsetBy(dx: shift.x, dy: shift.y) }
        pager.isHidden = card.pager == nil
        pager.attributedText = card.pager
        if let frame = card.pagerFrame { pager.frame = frame }
        prompt.attributedText = card.prompt
        prompt.frame = card.promptFrame
        hint.isHidden = card.hint == nil
        hint.attributedText = card.hint
        if let frame = card.hintFrame { hint.frame = frame }
        while rows.count < card.options.count { addOptionRow() }
        for (index, row) in rows.enumerated() {
            row.isHidden = index >= card.options.count
            if index < card.options.count { row.apply(card.options[index]) }
        }
        other.isHidden = true
        otherField.isHidden = true
        if let entry = card.other {
            otherRow = entry.row
            if entry.editing {
                otherField.isHidden = false
                otherField.frame = entry.frame
                if otherField.text != entry.draft { otherField.text = entry.draft }
            } else {
                other.isHidden = false
                other.frame = entry.frame
                let title = NSMutableAttributedString(string: "Other…", attributes: [.foregroundColor: UIColor.secondaryLabel,
                                                                                    .font: UIFont.preferredFont(forTextStyle: .body)])
                other.setAttributedTitle(title, for: .normal)
                other.contentEdgeInsets = UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14)
                otherIcon.preferredSymbolConfiguration = UIImage.SymbolConfiguration(textStyle: .body)
                otherIcon.frame = CGRect(x: entry.frame.width - 14 - 24, y: (entry.frame.height - 24) / 2, width: 24, height: 24)
            }
        }
        back.isHidden = card.back == nil
        if let frame = card.back {
            back.frame = frame
            back.titleLabel?.font = UIFont.systemFont(ofSize: UIFont.preferredFont(forTextStyle: .subheadline).pointSize, weight: .semibold)
        }
        while buttons.count < card.buttons.count {
            let button = FeedCapsuleButton()
            button.addAction(UIAction { [weak self, weak button] _ in
                guard let self, let id = button?.actionID else { return }
                if id == "answer" {
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    self.onInput?(.submit)
                } else {
                    self.onInput?(.nextItem)
                }
            }, for: .touchUpInside)
            buttons.append(button)
            addSubview(button)
        }
        for (index, button) in buttons.enumerated() {
            guard index < card.buttons.count else { button.isHidden = true; continue }
            button.apply(card.buttons[index])
        }
    }
}

final class FeedOptionRow: UIControl {
    private let label = UILabel()
    private let detail = UILabel()
    private let symbol = UIImageView()
    private(set) var row = 0
    private(set) var chosen = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        layer.cornerRadius = 14
        layer.cornerCurve = .continuous
        label.numberOfLines = 0
        detail.numberOfLines = 0
        for view in [label, detail, symbol] as [UIView] {
            view.isUserInteractionEnabled = false
            addSubview(view)
        }
        symbol.contentMode = .center
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ option: FeedRowLayout.OptionRow) {
        row = option.row
        chosen = option.chosen
        frame = option.frame
        backgroundColor = option.chosen ? .cmuxMobileFillSelected : .cmuxMobileFill
        label.attributedText = option.label
        label.frame = option.labelFrame
        detail.isHidden = option.detail == nil
        detail.attributedText = option.detail
        if let frame = option.detailFrame { detail.frame = frame }
        symbol.image = UIImage(systemName: option.symbol, withConfiguration: UIImage.SymbolConfiguration(pointSize: 20))
        symbol.tintColor = option.chosen ? .label : .secondaryLabel
        symbol.frame = option.symbolFrame
        accessibilityLabel = option.label.string
        accessibilityTraits = option.chosen ? [.button, .selected] : .button
    }
}

/// One swipe action button (RowSwipeActionButton): a tinted capsule with a white symbol and its title under it.
final class FeedSwipeButton: UIControl {
    private let capsule = UIView()
    private let symbol = UIImageView()
    private let title = UILabel()
    private(set) var actionID: String?

    override init(frame: CGRect) {
        super.init(frame: frame)
        capsule.isUserInteractionEnabled = false
        addSubview(capsule)
        symbol.tintColor = .white
        symbol.contentMode = .center
        capsule.addSubview(symbol)
        title.textAlignment = .center
        title.font = UIFont.preferredFont(forTextStyle: .caption1)
        title.textColor = .secondaryLabel
        addSubview(title)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func apply(_ action: FeedSwipeAction, width: CGFloat, rowHeight: CGFloat, style: RowSwipeActionStyle) {
        actionID = action.id
        accessibilityLabel = action.title
        let showsTitle = rowHeight >= 80
        let height = min(style.buttonHeight, width, showsTitle ? .infinity : max(0, rowHeight - 16))
        let titleHeight: CGFloat = showsTitle ? ceil(title.font.lineHeight) : 0
        let block = height + (showsTitle ? style.titleGap + titleHeight : 0)
        let top = (rowHeight - block) / 2
        capsule.frame = CGRect(x: 0, y: top, width: width, height: height)
        capsule.layer.cornerRadius = height / 2
        capsule.backgroundColor = UIColor(action.tint)
        capsule.alpha = width < 1 ? 0 : 1
        symbol.image = UIImage(systemName: action.systemImage, withConfiguration: UIImage.SymbolConfiguration(textStyle: .title3)
            .applying(UIImage.SymbolConfiguration(weight: .medium)))
        symbol.frame = capsule.bounds
        title.isHidden = !showsTitle
        title.text = action.title
        let shown = width / style.buttonWidth
        title.alpha = shown > 0.8 ? 1 : 0
        let titleWidth = max(ceil(title.intrinsicContentSize.width), width)
        title.frame = CGRect(x: (width - titleWidth) / 2, y: top + height + style.titleGap, width: titleWidth, height: titleHeight)
    }
}
#if DEBUG

/// DEBUG: how long a Feed cell's init and apply take (the rig's long frames).
enum FeedCellTiming {
    static let logger = Logger(subsystem: "dev.cmux.mobile", category: "feed-cell")
    static let enabled = ProcessInfo.processInfo.environment["CMUX_MOBILE_FEED_CELL_TIMING"] == "1"

    static func log(_ what: String, _ start: CFTimeInterval) {
        guard enabled else { return }
        let ms = (CACurrentMediaTime() - start) * 1000
        if ms > 0.8 { logger.notice("FEEDCELL \(what, privacy: .public) \(ms, format: .fixed(precision: 1), privacy: .public) ms") }
    }
}
#endif
#endif
