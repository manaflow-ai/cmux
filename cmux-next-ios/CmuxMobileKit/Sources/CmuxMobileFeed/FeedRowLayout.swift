#if os(iOS)
import CmuxAgentQuestion
import CmuxMobileAgentChat
import CmuxMobileDesign
import CmuxMobileMarkdown
import UIKit

/// Everything a Feed row draws, measured: each part's frame (in the cell's
/// coordinates) and its text, for one `FeedRowKey`. Built off the main
/// thread (`FeedListController`) and kept until the key changes, so a row
/// that scrolls in only places its reused views (verify/feed-perf-20261022.md).
///
/// The metrics are the SwiftUI cell's (`git show 2ad7671e9166:cmux-next-ios/
/// CmuxMobileKit/Sources/CmuxMobileFeed/FeedCell.swift`): 16 pt sides, 12 pt
/// top and bottom, a 40 pt avatar, a column 12 pt after it with 8 pt between parts.
struct FeedRowLayout: @unchecked Sendable {
    let key: FeedRowKey
    /// The row's height, its divider included.
    let height: CGFloat
    let dividerY: CGFloat
    let column: CGRect
    let avatar: CGRect
    /// The name, source and time line (the time is filled in when the row is shown).
    let header: CGRect
    let menuButton: CGRect
    var quote: Quote?
    var chip: Chip?
    var body: Body
    var answer: Answer
    var error: ErrorPart?
    var replies: Replies?
    /// A terminal agent's reply on its way ("Typing into the terminal…"), with a spinner, trailing.
    var replySending: (text: NSAttributedString, frame: CGRect, spinner: CGRect)?
    var replyFailure: (text: NSAttributedString, frame: CGRect)?
    var composer: CGRect?
    let footer: CGRect
    /// Reply is in the footer (`FeedItem.takesReply`), and whether it is disabled (a terminal reply on its way).
    let footerHasReply: Bool
    let footerReplyEnabled: Bool

    struct Quote {
        var frame: CGRect
        var outgoing: Bool
        var caption: NSAttributedString
        var captionFrame: CGRect
        var bubble: CGRect
        var text: NSAttributedString
        var textFrame: CGRect
        var maxLines: Int
        var thread: CGRect?
    }

    struct Chip {
        var frame: CGRect
        var dot: UIColor?
        var symbol: String?
        var text: NSAttributedString
        var textFrame: CGRect
        var markFrame: CGRect?
    }

    enum BodyContent {
        /// Short inline text (FeedPlainText), drawn as one label.
        case inline(NSAttributedString)
        case native(NativeMarkdownLayout)
        /// Math: the web renderer, once scrolling settles.
        case web(markdown: String, contentHeight: CGFloat, placeholder: NSAttributedString)
    }

    struct Body {
        var content: BodyContent
        /// The visible body (capped while collapsed).
        var frame: CGRect
        var fullHeight: CGFloat
        var overflowing: Bool
        var showMore: (title: NSAttributedString, frame: CGRect)?
    }

    struct CapsuleButton {
        enum Kind { case primary, secondary, destructive }
        var id: String
        var title: NSAttributedString
        var frame: CGRect
        var kind: Kind
        var enabled = true
        /// Opens the event's terminal instead of answering.
        var opensTerminal = false
    }

    struct CommandCard {
        var frame: CGRect
        var title: NSAttributedString
        var code: NSAttributedString
        /// The code inside the horizontal scroll area.
        var codeFrame: CGRect
        var scrollFrame: CGRect
        var capped: Bool
        var showAll: NSAttributedString?
        var showAllFrame: CGRect?
        var fadeFrame: CGRect?
    }

    struct OptionRow {
        var row: Int
        var frame: CGRect
        var label: NSAttributedString
        var labelFrame: CGRect
        var detail: NSAttributedString?
        var detailFrame: CGRect?
        var symbol: String
        var symbolFrame: CGRect
        var chosen: Bool
    }

    struct QuestionCard {
        var frame: CGRect
        var header: NSAttributedString?
        var headerFrame: CGRect?
        var pager: NSAttributedString?
        var pagerFrame: CGRect?
        var prompt: NSAttributedString
        var promptFrame: CGRect
        var hint: NSAttributedString?
        var hintFrame: CGRect?
        var options: [OptionRow]
        /// The "Other…" row: its frame, whether it is a text field now, the draft.
        var other: (frame: CGRect, editing: Bool, draft: String, row: Int)?
        var back: CGRect?
        var buttons: [CapsuleButton]
    }

    struct Bubble {
        var text: NSAttributedString
        var frame: CGRect
        var textFrame: CGRect
    }

    enum Answer {
        case none
        /// A line of secondary text with its symbol (a resolution, "Question cancelled").
        case label(NSAttributedString, CGRect)
        /// An answer on its way ("Waiting for Face ID…"), with a spinner.
        case pending(NSAttributedString, CGRect, spinner: CGRect)
        case terminal(CapsuleButton)
        case permission(card: CommandCard?, buttons: [CapsuleButton])
        /// A question card; for a terminal agent's question, "Open in Terminal" under it.
        case question(QuestionCard, openTerminal: CapsuleButton?)
        case answered(caption: NSAttributedString, captionFrame: CGRect, items: [(header: NSAttributedString, headerFrame: CGRect, bubble: Bubble)])
    }

    struct ErrorPart {
        var text: NSAttributedString
        var frame: CGRect
        var decline: CGRect?
    }

    struct Replies {
        var caption: NSAttributedString
        var captionFrame: CGRect
        var bubbles: [Bubble]
    }
}

// MARK: Building

extension FeedRowLayout {
    static func make(_ key: FeedRowKey, styles: NativeTextStyles, scale: CGFloat) -> FeedRowLayout {
        var builder = FeedRowBuilder(key: key, styles: styles, scale: scale)
        return builder.build()
    }

    /// The column's width for a row `width` points wide.
    static func columnWidth(rowWidth: CGFloat) -> CGFloat { max(rowWidth - 16 - 40 - 12 - 16, 1) }
}

/// Symbols inline with text (SwiftUI `Label`): the symbol at the text's size, then a space.
func symbolText(_ name: String, _ text: String, font: UIFont, color: UIColor, symbolWeight: UIImage.SymbolWeight = .regular,
                symbolSize: CGFloat? = nil, gap: CGFloat? = nil) -> NSAttributedString {
    let output = NSMutableAttributedString()
    let configuration = symbolSize.map { UIImage.SymbolConfiguration(pointSize: $0, weight: symbolWeight) }
        ?? UIImage.SymbolConfiguration(font: font).applying(UIImage.SymbolConfiguration(weight: symbolWeight))
    if let image = UIImage(systemName: name, withConfiguration: configuration)?.withTintColor(color, renderingMode: .alwaysOriginal) {
        let attachment = NSTextAttachment(image: image)
        // Centered on the text's cap height, as an HStack centers an Image beside a Text.
        attachment.bounds = CGRect(x: 0, y: (font.capHeight - image.size.height) / 2, width: image.size.width, height: image.size.height)
        output.append(NSAttributedString(attachment: attachment))
        if let gap {
            output.append(NSAttributedString(string: " ", attributes: [.font: font, .kern: gap - (" " as NSString).size(withAttributes: [.font: font]).width]))
        } else {
            output.append(NSAttributedString(string: "  ", attributes: [.font: font]))
        }
    }
    output.append(NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color]))
    return output
}

private struct FeedRowBuilder {
    let key: FeedRowKey
    let styles: NativeTextStyles
    let scale: CGFloat
    let width: CGFloat
    let columnX: CGFloat = 16 + 40 + 12
    let columnWidth: CGFloat
    var y: CGFloat = 12
    var first = true

    init(key: FeedRowKey, styles: NativeTextStyles, scale: CGFloat) {
        self.key = key
        self.styles = styles
        self.scale = scale
        width = CGFloat(key.width)
        columnWidth = FeedRowLayout.columnWidth(rowWidth: CGFloat(key.width))
    }

    var item: FeedItem { key.item }
    var state: FeedRowState { key.state }

    func attributed(_ text: String, _ font: UIFont, _ color: UIColor = .label, alignment: NSTextAlignment = .natural) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.lineBreakStrategy = .standard
        return NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: paragraph])
    }

    /// The column's next part, `height` tall, 8 pt after the previous one (a VStack's spacing).
    mutating func place(_ height: CGFloat, extra: CGFloat = 0) -> CGFloat {
        if !first { y += 8 }
        first = false
        let top = y
        y += height + extra
        return top
    }

    mutating func build() -> FeedRowLayout {
        let subheadline = styles.font(.subheadline)
        let headerHeight = styles.isAccessibilitySize ? ceil(subheadline.lineHeight) * 2 + 2 : max(ceil(subheadline.lineHeight), 20)
        let headerTop = place(headerHeight)
        let header = CGRect(x: columnX, y: headerTop, width: columnWidth - 44 + 10, height: headerHeight)
        // The 44 pt "…" target, 12 pt above and below the line, 10 pt into the side padding.
        let menu = CGRect(x: columnX + columnWidth - 44 + 10, y: headerTop - 12, width: 44, height: 44)

        let quote = item.quote.map { quoteLayout($0) }
        let chip = chipLayout()
        let body = bodyLayout()
        let answer = answerLayout()
        let error = errorLayout()
        let replies = repliesLayout()
        let sending = item.opensTerminal ? item.pending.map { sendingLayout($0) } : nil
        let failure = state.replyFailure.map { failureLayout($0) }
        let composer = state.replying ? composerFrame() : nil
        // The footer: a 44 pt row drawn 6 pt into its neighbors (32 pt of rhythm).
        let footerTop = place(32)
        let footer = CGRect(x: columnX, y: footerTop - 6, width: columnWidth - 8, height: 44)

        let columnHeight = y - 12
        let contentBottom = 12 + max(40, columnHeight) + 12
        let divider = 1 / max(scale, 1)
        return FeedRowLayout(
            key: key, height: contentBottom + divider, dividerY: contentBottom,
            column: CGRect(x: columnX, y: 12, width: columnWidth, height: columnHeight),
            avatar: CGRect(x: 16, y: 12, width: 40, height: 40),
            header: header, menuButton: menu, quote: quote, chip: chip, body: body, answer: answer, error: error,
            replies: replies, replySending: sending, replyFailure: failure, composer: composer, footer: footer,
            footerHasReply: item.takesReply, footerReplyEnabled: !(item.opensTerminal && item.pending != nil)
        )
    }

    // MARK: Quote bubble

    mutating func quoteLayout(_ quote: FeedItem.Quote) -> FeedRowLayout.Quote {
        let outgoing = quote.author == .you
        let captionFont = styles.font(.caption2, weight: .semibold)
        let caption = symbolText(outgoing ? "arrowshape.turn.up.left.fill" : "sparkle", outgoing ? "You" : "Asked you",
                                 font: captionFont, color: .tertiaryLabel, symbolWeight: .semibold, symbolSize: 9, gap: 4)
        // The caption's line is the text's (an HStack of a 9 pt symbol and caption2 text).
        let captionSize = CGSize(width: nativeTextSize(caption, width: columnWidth - 24).width, height: ceil(captionFont.lineHeight))
        let text = attributed(quote.text, styles.font(.subheadline), .secondaryLabel)
        let maxLines = state.quoteExpanded ? 0 : 3
        let bubbleMax = columnWidth - 28
        let textSize = nativeTextSize(text, width: bubbleMax - 24, maxLines: maxLines)
        let bubbleWidth = min(textSize.width + 24, bubbleMax)
        let bubbleHeight = textSize.height + 16
        let threadHeight: CGFloat = outgoing ? 0 : 12 - 4
        let total = captionSize.height + 3 + bubbleHeight + (outgoing ? 10 : 6) + threadHeight - 4
        let top = place(total)
        let captionX = outgoing ? columnX + columnWidth - 12 - captionSize.width : columnX + 12
        let bubbleX = outgoing ? columnX + columnWidth - bubbleWidth : columnX
        let bubbleY = top + captionSize.height + 3
        let bubble = CGRect(x: bubbleX, y: bubbleY, width: bubbleWidth, height: bubbleHeight)
        return FeedRowLayout.Quote(
            frame: CGRect(x: columnX, y: top, width: columnWidth, height: total), outgoing: outgoing,
            caption: caption, captionFrame: CGRect(x: captionX, y: top, width: captionSize.width, height: captionSize.height),
            bubble: bubble, text: text, textFrame: bubble.insetBy(dx: 12, dy: 8), maxLines: maxLines,
            thread: outgoing ? nil : CGRect(x: columnX, y: bubble.maxY + 6 - 4, width: 14, height: 12)
        )
    }

    // MARK: Status chip

    mutating func chipLayout() -> FeedRowLayout.Chip? {
        let content: (dot: UIColor?, symbol: String?, text: String)?
        switch item.kind {
        case .permission where item.resolution == nil: content = (.cmuxMobileWarning, nil, "Needs permission")
        case .question(let question) where question.isPending: content = (nil, "questionmark.bubble", "Question")
        case .failed: content = (.cmuxMobileDanger, nil, "Failed")
        case .needsInput where item.resolution == nil: content = (.cmuxMobileWarning, nil, "Needs input")
        default: content = nil
        }
        guard let content else { return nil }
        let font = styles.font(.caption1, weight: .semibold)
        let text = attributed(content.text, font)
        let size = nativeTextSize(text, width: columnWidth)
        let markWidth: CGFloat = content.dot != nil ? 7 : (content.symbol != nil ? ceil(styles.font(.caption1).pointSize * 1.2) : 0)
        let inner = (markWidth > 0 ? markWidth + 6 : 0) + size.width
        let height = max(24, size.height + 6)
        let top = place(height)
        let frame = CGRect(x: columnX, y: top, width: inner + 20, height: height)
        let markFrame = markWidth > 0 ? CGRect(x: 10, y: (height - markWidth) / 2, width: markWidth, height: markWidth) : nil
        return FeedRowLayout.Chip(
            frame: frame, dot: content.dot, symbol: content.symbol, text: text,
            textFrame: CGRect(x: 10 + (markWidth > 0 ? markWidth + 6 : 0), y: (height - size.height) / 2, width: size.width, height: size.height),
            markFrame: markFrame
        )
    }

    // MARK: Body

    mutating func bodyLayout() -> FeedRowLayout.Body {
        let cap = styles.scaled(224, relativeTo: .body)
        let content: FeedRowLayout.BodyContent
        let full: CGFloat
        let plain = FeedPlainText(item.markdown)
        if plain.isInline, plain.attributed != nil {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakStrategy = .standard
            let text = NativeMarkdownLayout.inlineText(item.markdown, font: styles.font(.body), color: .label, styles: styles,
                                                       paragraph: paragraph, codeBackground: false)
            content = .inline(text)
            full = nativeTextSize(text, width: columnWidth).height
        } else {
            let native = NativeMarkdownLayout.make(markdown: item.markdown, width: columnWidth, styles: styles)
            if native.needsWeb {
                let height = state.webHeight.map { CGFloat($0) } ?? Self.webEstimate(item.markdown, width: columnWidth)
                let placeholder = attributed(item.markdown.replacingOccurrences(of: "$", with: ""), styles.font(.body))
                content = .web(markdown: item.markdown, contentHeight: height, placeholder: placeholder)
                full = height
            } else {
                content = .native(native)
                full = native.height
            }
        }
        let overflowing = full > cap + 28
        let shown = state.expanded || !overflowing ? full : cap
        let top = place(shown)
        var showMore: (NSAttributedString, CGRect)?
        if overflowing {
            // VStack spacing 6, then the 44 pt button drawn 8 pt into its neighbors (28 pt).
            y += 6 + 28
            showMore = (attributed(state.expanded ? "Show less" : "Show more", styles.font(.subheadline, weight: .semibold)),
                        CGRect(x: columnX, y: top + shown + 6 - 8, width: columnWidth, height: 44))
        }
        return FeedRowLayout.Body(content: content, frame: CGRect(x: columnX, y: top, width: columnWidth, height: shown),
                                  fullHeight: full, overflowing: overflowing, showMore: showMore)
    }

    /// WebMarkdownView's estimate before a body is measured.
    static func webEstimate(_ markdown: String, width: CGFloat) -> CGFloat {
        let chars = CGFloat(markdown.count)
        let perLine = max(width / 9, 30)
        return min(max(27, (chars / perLine).rounded(.up) * 27 + CGFloat(markdown.filter { $0 == "\n" }.count) * 6), 2000)
    }

    // MARK: Inline answer

    func capsule(_ id: String, _ title: NSAttributedString, kind: FeedRowLayout.CapsuleButton.Kind, x: CGFloat, y: CGFloat, width: CGFloat,
                 enabled: Bool = true) -> FeedRowLayout.CapsuleButton {
        FeedRowLayout.CapsuleButton(id: id, title: title, frame: CGRect(x: x, y: y, width: width, height: 44), kind: kind, enabled: enabled)
    }

    func capsuleColor(_ kind: FeedRowLayout.CapsuleButton.Kind, enabled: Bool = true) -> UIColor {
        guard enabled else { return .tertiaryLabel }
        switch kind {
        case .primary: return .cmuxMobileOnAccent
        case .secondary: return .label
        case .destructive: return .cmuxMobileDanger
        }
    }

    mutating func answerLayout() -> FeedRowLayout.Answer {
        let subheadline = styles.font(.subheadline)
        func secondaryLine(_ symbol: String, _ text: String) -> FeedRowLayout.Answer {
            let line = symbolText(symbol, text, font: subheadline, color: .secondaryLabel)
            let size = nativeTextSize(line, width: columnWidth)
            let top = place(size.height)
            return .label(line, CGRect(x: columnX, y: top, width: columnWidth, height: size.height))
        }
        switch item.kind {
        case .question(let question):
            if case .answered(let answer) = question.state { return answeredLayout(question, answer) }
            if question.state == .cancelled { return secondaryLine("xmark.circle", "Question cancelled") }
            let card = questionLayout(question)
            // A terminal agent's question: answered here, or in its terminal.
            guard item.opensTerminal, question.isPending, item.resolution == nil else { return .question(card, openTerminal: nil) }
            let font = styles.font(.headline)
            let title = symbolText("terminal", "Open in Terminal", font: font, color: capsuleColor(.secondary))
            let width = min(columnWidth, nativeTextSize(title, width: columnWidth).width + 24)
            let top = place(44)
            var button = capsule("terminal", title, kind: .secondary, x: columnX, y: top, width: width)
            button.opensTerminal = true
            return .question(card, openTerminal: button)
        case .needsInput:
            if let resolution = item.resolution { return secondaryLine("checkmark.circle", resolution) }
            let font = styles.font(.headline)
            let title = symbolText("terminal", "Answer in Terminal", font: font, color: capsuleColor(.primary))
            let top = place(44)
            var button = capsule("terminal", title, kind: .primary, x: columnX, y: top, width: columnWidth)
            button.opensTerminal = true
            return .terminal(button)
        case .permission(let request):
            if let resolution = item.resolution {
                return secondaryLine(resolution.hasPrefix("Denied") ? "xmark.circle" : "checkmark.circle", resolution)
            }
            if let pending = item.pending {
                let text = attributed(pending, subheadline, .secondaryLabel)
                let size = nativeTextSize(text, width: columnWidth - 28)
                let height = max(size.height, 20)
                let top = place(height)
                return .pending(text, CGRect(x: columnX + 28, y: top + (height - size.height) / 2, width: columnWidth - 28, height: size.height),
                                spinner: CGRect(x: columnX, y: top + (height - 20) / 2, width: 20, height: 20))
            }
            var card: FeedRowLayout.CommandCard?
            var partTop: CGFloat?
            if let command = request.toolCall.command {
                let built = commandCard(command)
                partTop = place(built.frame.height + 8 + 44)
                card = built
                card?.frame.origin = CGPoint(x: columnX, y: partTop ?? 0)
            }
            let buttonsTop = partTop.map { $0 + (card?.frame.height ?? 0) + 8 } ?? place(44)
            let options = request.phoneOptions
            let count = CGFloat(max(options.count, 1))
            let each = (columnWidth - 8 * (count - 1)) / count
            let font = styles.font(.headline)
            let buttons = options.enumerated().map { index, option in
                let kind: FeedRowLayout.CapsuleButton.Kind = option.kind == .allowOnce ? .primary : (option.isAllow ? .secondary : .destructive)
                let title = option.isAllow ? symbolText("faceid", Self.feedTitle(option), font: font, color: capsuleColor(kind))
                    : attributed(Self.feedTitle(option), font, capsuleColor(kind), alignment: .center)
                return capsule(option.id, title, kind: kind, x: columnX + CGFloat(index) * (each + 8), y: buttonsTop, width: each)
            }
            return .permission(card: card, buttons: buttons)
        default:
            return .none
        }
    }

    /// The Mac agent pane's words: "Allow once", "Deny".
    static func feedTitle(_ option: ACPPermissionOption) -> String {
        switch option.kind {
        case .allowOnce: "Allow once"
        case .allowAlways: "Allow for this chat"
        case .rejectOnce, .rejectAlways: "Deny"
        }
    }

    /// CodeCard(language: "bash", title: "Command", maxHeight: 120): a 40 pt header, the
    /// command in monospace that scrolls sideways, capped with "Show all N lines".
    func commandCard(_ command: String) -> FeedRowLayout.CommandCard {
        let codeSize = styles.scaled(13, relativeTo: .footnote)
        let font = styles.mono(size: codeSize)
        let lines = command.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
        let code = NativeMarkdownLayout.codeText(command, language: "bash", font: font, lineHeight: codeSize * 1.46, lineSpacing: codeSize * 0.46)
        let natural = nativeTextSize(code, width: .greatestFiniteMagnitude)
        let capped = !state.codeExpanded && CGFloat(lines) * codeSize * 1.46 + 20 > 120
        let scrollHeight = capped ? 120 - 40 : natural.height + 4 + 16
        let title = attributed("Command", styles.font(.footnote, weight: .medium), .secondaryLabel)
        var card = FeedRowLayout.CommandCard(
            frame: CGRect(x: 0, y: 0, width: columnWidth, height: 40 + scrollHeight), title: title, code: code,
            codeFrame: CGRect(x: 16, y: 4, width: natural.width, height: natural.height),
            scrollFrame: CGRect(x: 0, y: 40, width: columnWidth, height: scrollHeight), capped: capped
        )
        if capped {
            card.showAll = attributed("Show all \(lines) lines", styles.font(.subheadline, weight: .semibold), .label, alignment: .center)
            card.showAllFrame = CGRect(x: 0, y: 40 + scrollHeight - 40, width: columnWidth, height: 40)
            card.fadeFrame = CGRect(x: 0, y: 40 + scrollHeight - 88, width: columnWidth, height: 48)
        }
        return card
    }

    mutating func questionLayout(_ question: AgentQuestion) -> FeedRowLayout.QuestionCard {
        let cardState = state.question ?? AgentQuestionCardState(question: question)
        let item = cardState.item
        let count = question.items.count
        let inner = columnWidth - 32
        var cy: CGFloat = 16
        var card = FeedRowLayout.QuestionCard(frame: .zero, prompt: NSAttributedString(), promptFrame: .zero, options: [], buttons: [])
        if count > 1 {
            let pagerText = attributed("\(cardState.activeItem + 1) of \(count)", UIFont.monospacedDigitSystemFont(ofSize: styles.font(.footnote).pointSize, weight: .regular), .secondaryLabel)
            let pagerSize = nativeTextSize(pagerText, width: inner)
            var rowHeight = pagerSize.height
            if let header = item.header {
                let text = NSAttributedString(string: header.uppercased(), attributes: [
                    .font: styles.font(.caption1, weight: .semibold), .foregroundColor: UIColor.secondaryLabel, .kern: 0.6,
                ])
                let size = nativeTextSize(text, width: inner - pagerSize.width - 8)
                rowHeight = max(rowHeight, size.height)
                card.header = text
                card.headerFrame = CGRect(x: 16, y: cy + (rowHeight - size.height) / 2, width: size.width, height: size.height)
            }
            card.pager = pagerText
            card.pagerFrame = CGRect(x: 16 + inner - pagerSize.width, y: cy + (rowHeight - pagerSize.height) / 2, width: pagerSize.width, height: pagerSize.height)
            cy += rowHeight + 12
        }
        card.prompt = attributed(item.prompt, styles.font(.headline))
        let promptSize = nativeTextSize(card.prompt, width: inner)
        card.promptFrame = CGRect(x: 16, y: cy, width: inner, height: promptSize.height)
        cy += promptSize.height + 12
        if item.multiSelect {
            let hint = attributed("Choose any", styles.font(.footnote), .secondaryLabel)
            let size = nativeTextSize(hint, width: inner)
            card.hint = hint
            card.hintFrame = CGRect(x: 16, y: cy, width: inner, height: size.height)
            cy += size.height + 12
        }
        for (index, option) in item.options.enumerated() {
            let chosen = cardState.isChosen(option, in: item)
            let label = attributed(option.label, styles.font(.body))
            let textWidth = inner - 28 - 8 - 20
            let labelSize = nativeTextSize(label, width: textWidth)
            var detail: NSAttributedString?
            var detailSize = CGSize.zero
            if let text = option.detail {
                detail = attributed(text, styles.font(.footnote), .secondaryLabel)
                detailSize = nativeTextSize(detail ?? NSAttributedString(), width: textWidth)
            }
            let textHeight = labelSize.height + (detail != nil ? 2 + detailSize.height : 0)
            let height = max(48, textHeight + 20)
            let textTop = (height - textHeight) / 2
            card.options.append(FeedRowLayout.OptionRow(
                row: index, frame: CGRect(x: 16, y: cy, width: inner, height: height), label: label,
                labelFrame: CGRect(x: 14, y: textTop, width: textWidth, height: labelSize.height), detail: detail,
                detailFrame: detail.map { _ in CGRect(x: 14, y: textTop + labelSize.height + 2, width: textWidth, height: detailSize.height) },
                symbol: item.multiSelect ? (chosen ? "checkmark.square.fill" : "square") : (chosen ? "checkmark.circle.fill" : "circle"),
                symbolFrame: CGRect(x: inner - 14 - 24, y: (height - 24) / 2, width: 24, height: 24), chosen: chosen
            ))
            cy += height + 6
        }
        if item.allowsOther {
            let draft = cardState.otherDrafts[item.id] ?? ""
            let editing = cardState.editingOther || !draft.isEmpty
            card.other = (CGRect(x: 16, y: cy, width: inner, height: 48), editing, draft, item.options.count)
            cy += 48 + 6
        }
        cy += 12 - 6
        // Back · Next · Answer (SPEC 6.6): Answer on the last page or once every item is answered.
        let font = styles.font(.headline)
        var trailing = 16 + inner
        let needsNext = item.multiSelect || cardState.editingOther || !(cardState.otherDrafts[item.id] ?? "").isEmpty
        if cardState.activeItem == count - 1 || cardState.canSubmit {
            let title = attributed("Answer", font, capsuleColor(.primary, enabled: cardState.canSubmit), alignment: .center)
            let width = nativeTextSize(title, width: inner).width + 40
            trailing -= width
            card.buttons.append(capsule("answer", title, kind: .primary, x: trailing, y: cy, width: width, enabled: cardState.canSubmit))
            trailing -= 8
        }
        if cardState.activeItem < count - 1, needsNext {
            let enabled = cardState.answer.selections[item.id]?.isEmpty == false
            let title = attributed("Next", font, capsuleColor(.secondary, enabled: enabled), alignment: .center)
            let width = nativeTextSize(title, width: inner).width + 40
            trailing -= width
            card.buttons.append(capsule("next", title, kind: .secondary, x: trailing, y: cy, width: width, enabled: enabled))
        }
        if cardState.activeItem > 0 { card.back = CGRect(x: 16, y: cy, width: 60, height: 44) }
        if !card.buttons.isEmpty || card.back != nil { cy += 44 }
        cy += 16
        let top = place(cy)
        card.frame = CGRect(x: columnX, y: top, width: columnWidth, height: cy)
        return card
    }

    mutating func answeredLayout(_ question: AgentQuestion, _ answer: AgentQuestionAnswer) -> FeedRowLayout.Answer {
        let caption = attributed("You answered", styles.font(.footnote), .secondaryLabel, alignment: .right)
        let captionSize = nativeTextSize(caption, width: columnWidth)
        var cy = captionSize.height
        var items: [(NSAttributedString, CGRect, FeedRowLayout.Bubble)] = []
        for entry in question.items {
            let selection = answer.selections[entry.id]
            let labels = entry.options.filter { selection?.optionIDs.contains($0.id) == true }.map(\.label)
                + [selection?.other].compactMap { $0 }.filter { !$0.isEmpty }
            let header = attributed(entry.header ?? entry.prompt, styles.font(.caption1), .secondaryLabel, alignment: .right)
            let headerSize = nativeTextSize(header, width: columnWidth)
            cy += 6
            let headerFrame = CGRect(x: columnX + columnWidth - headerSize.width, y: cy, width: headerSize.width, height: headerSize.height)
            cy += headerSize.height + 2
            let bubble = bubbleLayout(labels.joined(separator: ", "), top: cy, padV: 7)
            cy += bubble.frame.height
            items.append((header, headerFrame, bubble))
        }
        let top = place(cy)
        let shifted = items.map { ($0.0, $0.1.offsetBy(dx: 0, dy: top), FeedRowLayout.Bubble(text: $0.2.text, frame: $0.2.frame.offsetBy(dx: 0, dy: top),
                                                                                                textFrame: $0.2.textFrame.offsetBy(dx: 0, dy: top))) }
        return .answered(caption: caption, captionFrame: CGRect(x: columnX + columnWidth - captionSize.width, y: top, width: captionSize.width, height: captionSize.height),
                         items: shifted.map { (header: $0.0, headerFrame: $0.1, bubble: $0.2) })
    }

    /// A trailing-aligned subheadline bubble (`cmuxMobileBubble`, radius 16), `top` in the row's coordinates.
    func bubbleLayout(_ text: String, top: CGFloat, padV: CGFloat) -> FeedRowLayout.Bubble {
        let attributedText = attributed(text, styles.font(.subheadline))
        let size = nativeTextSize(attributedText, width: columnWidth - 24)
        let frame = CGRect(x: columnX + columnWidth - size.width - 24, y: top, width: size.width + 24, height: size.height + padV * 2)
        return FeedRowLayout.Bubble(text: attributedText, frame: frame, textFrame: frame.insetBy(dx: 12, dy: padV))
    }

    // MARK: Error, replies, composer

    mutating func errorLayout() -> FeedRowLayout.ErrorPart? {
        guard let error = item.error else { return nil }
        let text = symbolText("exclamationmark.circle", error, font: styles.font(.subheadline), color: .secondaryLabel)
        let size = nativeTextSize(text, width: columnWidth)
        let top = place(size.height)
        var part = FeedRowLayout.ErrorPart(text: text, frame: CGRect(x: columnX, y: top, width: columnWidth, height: size.height))
        if case .question(let question) = item.kind, question.isPending {
            let declineTop = place(34)
            part.decline = CGRect(x: columnX, y: declineTop, width: 96, height: 34)
        }
        return part
    }

    mutating func repliesLayout() -> FeedRowLayout.Replies? {
        guard !item.replies.isEmpty else { return nil }
        // A terminal agent's reply went into its terminal on the Mac.
        let caption = attributed(item.opensTerminal ? "Sent to the terminal" : "You replied", styles.font(.caption1), .tertiaryLabel, alignment: .right)
        let captionSize = nativeTextSize(caption, width: columnWidth)
        var cy = captionSize.height
        var bubbles: [FeedRowLayout.Bubble] = []
        for reply in item.replies {
            cy += 4
            let bubble = bubbleLayout(reply, top: cy, padV: 7)
            bubbles.append(bubble)
            cy += bubble.frame.height
        }
        let top = place(cy)
        return FeedRowLayout.Replies(
            caption: caption, captionFrame: CGRect(x: columnX + columnWidth - captionSize.width, y: top, width: captionSize.width, height: captionSize.height),
            bubbles: bubbles.map { FeedRowLayout.Bubble(text: $0.text, frame: $0.frame.offsetBy(dx: 0, dy: top), textFrame: $0.textFrame.offsetBy(dx: 0, dy: top)) }
        )
    }

    mutating func sendingLayout(_ pending: String) -> (NSAttributedString, CGRect, CGRect) {
        let text = attributed(pending, styles.font(.footnote), .secondaryLabel)
        let size = nativeTextSize(text, width: columnWidth - 28)
        let height = max(size.height, 20)
        let top = place(height)
        let textFrame = CGRect(x: columnX + columnWidth - size.width, y: top + (height - size.height) / 2, width: size.width, height: size.height)
        return (text, textFrame, CGRect(x: textFrame.minX - 28, y: top + (height - 20) / 2, width: 20, height: 20))
    }

    mutating func failureLayout(_ failure: String) -> (NSAttributedString, CGRect) {
        let text = attributed(failure, styles.font(.footnote), .systemRed, alignment: .right)
        let size = nativeTextSize(text, width: columnWidth)
        let top = place(size.height)
        return (text, CGRect(x: columnX, y: top, width: columnWidth, height: size.height))
    }

    /// The reply field (1 to 5 lines of body text, 14 and 9 pt insets) and its 40 pt send button.
    mutating func composerFrame() -> CGRect {
        let font = styles.font(.body)
        let field = NSAttributedString(string: state.replyDraft.isEmpty ? " " : state.replyDraft, attributes: [.font: font])
        let lines = min(5, max(1, Int((nativeTextSize(field, width: columnWidth - 28 - 8 - 40).height / font.lineHeight).rounded())))
        let height = max(CGFloat(lines) * ceil(font.lineHeight) + 18, 40)
        let top = place(height)
        return CGRect(x: columnX, y: top, width: columnWidth, height: height)
    }
}
#endif
