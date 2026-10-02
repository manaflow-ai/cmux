#if os(macOS)
import AppKit
import CmuxConversationCore

/// One visual row of the macOS transcript.
enum MacConversationRow: Hashable {
    case conversationStart
    case loadingOlder
    case timestamp(id: String, date: Date)
    case message(MacMessageRowModel)
    case typing(participantIDs: [String])

    var id: String {
        switch self {
        case .conversationStart: return "start"
        case .loadingOlder: return "loading"
        case let .timestamp(id, _): return id
        case let .message(model): return model.rowID
        case .typing: return "typing"
        }
    }

    var isMessage: Bool {
        if case .message = self { return true }
        return false
    }
}

struct MacReplyQuote: Hashable {
    var text: String
    var isOutgoing: Bool
    var senderInitials: String
    var senderColorHex: String?
}

enum MacMessageFooter: Hashable {
    case none
    case status(String)
    case notDelivered
}

struct MacMessageRowModel: Hashable {
    var rowID: String
    var message: ConversationMessage
    var isOutgoing: Bool
    var isGroup: Bool
    var senderName: String?
    var senderInitials: String
    var senderColorHex: String?
    var showsSenderName: Bool
    var showsAvatar: Bool
    var showsTail: Bool
    var isFirstInRun: Bool
    var footer: MacMessageFooter
    var replyQuote: MacReplyQuote?
    var isEmojiOnly: Bool
    var reactionKinds: [ConversationReaction]
    var hasMyReaction: Bool
    var myReactions: Set<ConversationReaction> = []
}

/// Builds rows from store state with the shared Messages grouping rules.
@MainActor
enum MacConversationRowBuilder {
    static func rows(store: ConversationStore) -> [MacConversationRow] {
        guard let info = store.info else { return [] }
        var rows: [MacConversationRow] = []
        rows.reserveCapacity(store.messages.count + 4)
        if store.older == .exhausted {
            rows.append(.conversationStart)
        } else if store.hasLoadedNewest, store.older != .idle {
            rows.append(.loadingOlder)
        }
        let isGroup = info.kind == .group
        let meID = store.meID
        let plan = ConversationRunPlan(messages: store.messages, meID: meID, typingParticipantIDs: store.typingParticipantIDs)
        for (index, message) in store.messages.enumerated() {
            let entry = plan.entries[index]
            if entry.showsTimestamp {
                rows.append(.timestamp(id: "ts:\(message.rowID)", date: message.sentAt))
            }
            let isOutgoing = message.senderID == meID
            let sender = info.participant(message.senderID)
            let quote = message.replyToID.flatMap { store.message(id: $0) }.map {
                MacReplyQuote(
                    text: $0.text.isEmpty ? String(localized: "conversation.quote.photo", defaultValue: "Photo", bundle: .module) : $0.text,
                    isOutgoing: $0.senderID == meID,
                    senderInitials: info.participant($0.senderID)?.initials ?? "",
                    senderColorHex: info.participant($0.senderID)?.colorHex
                )
            }
            rows.append(.message(MacMessageRowModel(
                rowID: message.rowID,
                message: message,
                isOutgoing: isOutgoing,
                isGroup: isGroup,
                senderName: sender?.name,
                senderInitials: sender?.initials ?? "",
                senderColorHex: sender?.colorHex,
                showsSenderName: isGroup && !isOutgoing && (entry.isFirstInRun || quote != nil),
                showsAvatar: isGroup && !isOutgoing && entry.isLastInRun,
                showsTail: entry.isLastInRun || quote != nil,
                isFirstInRun: entry.isFirstInRun,
                footer: footer(entry.status, isGroup: isGroup),
                replyQuote: quote,
                isEmojiOnly: message.attachments.isEmpty && isEmojiOnly(message.text),
                reactionKinds: message.reactions.reduce(into: []) { kinds, mark in
                    if !kinds.contains(mark.reaction) { kinds.append(mark.reaction) }
                },
                hasMyReaction: message.reactions.contains { $0.participantID == meID },
                myReactions: Set(message.reactions.filter { $0.participantID == meID }.map(\.reaction))
            )))
        }
        if !store.typingParticipantIDs.isEmpty {
            rows.append(.typing(participantIDs: store.typingParticipantIDs))
        }
        return rows
    }

    private static func footer(_ status: ConversationRunPlan.Status, isGroup: Bool) -> MacMessageFooter {
        switch status {
        case .none: return .none
        case .notDelivered: return .notDelivered
        case .delivered:
            return .status(String(localized: "conversation.status.delivered", defaultValue: "Delivered", bundle: .module))
        case let .read(date):
            guard !isGroup else {
                return .status(String(localized: "conversation.status.delivered", defaultValue: "Delivered", bundle: .module))
            }
            guard let date else {
                return .status(String(localized: "conversation.status.read", defaultValue: "Read", bundle: .module))
            }
            return .status(String(
                format: String(localized: "conversation.status.readAt", defaultValue: "Read %@", bundle: .module),
                date.formatted(date: .omitted, time: .shortened)
            ))
        }
    }

    static func isEmojiOnly(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 3 else { return false }
        return trimmed.allSatisfy { character in
            character.unicodeScalars.contains { $0.properties.isEmojiPresentation }
                || (character.unicodeScalars.first?.properties.isEmoji == true && character.unicodeScalars.count > 1)
        }
    }
}

/// Frames for one message row in a flipped row view.
struct MacMessageLayout {
    var height: CGFloat
    var senderNameFrame: CGRect?
    var quoteFrame: CGRect?
    var quoteTextFrame: CGRect?
    var quoteAvatarFrame: CGRect?
    var threadPath: CGPath?
    var imageFrames: [CGRect]
    var bubbleFrame: CGRect?
    var textFrame: CGRect?
    var emojiFrame: CGRect?
    var avatarFrame: CGRect?
    var reactionAnchor: CGPoint?
    var editedFrame: CGRect?
    var repliesFrame: CGRect?
    var footerFrame: CGRect?
    var failedBadgeFrame: CGRect?
    var contentFrame: CGRect
}

@MainActor
final class MacMessageLayoutCache {
    private var layouts: [String: (MacMessageRowModel, CGFloat, MacMessageLayout)] = [:]
    private var texts: [String: (String, Bool, NSAttributedString)] = [:]

    func layout(_ model: MacMessageRowModel, width: CGFloat) -> MacMessageLayout {
        if let (cachedModel, cachedWidth, layout) = layouts[model.rowID], cachedModel == model, cachedWidth == width {
            return layout
        }
        let layout = MacMessageLayout.compute(model, width: width, text: text(model))
        layouts[model.rowID] = (model, width, layout)
        return layout
    }

    func text(_ model: MacMessageRowModel) -> NSAttributedString {
        if let (text, outgoing, value) = texts[model.rowID], text == model.message.text, outgoing == model.isOutgoing {
            return value
        }
        let value = MacMessageLayout.attributedBody(model.message.text, outgoing: model.isOutgoing)
        texts[model.rowID] = (model.message.text, model.isOutgoing, value)
        return value
    }

    func invalidate() {
        layouts.removeAll()
        texts.removeAll()
    }
}

extension NSAttributedString.Key {
    static let macConversationLink = NSAttributedString.Key("cmuxMacConversationLink")
}

extension MacMessageLayout {
    nonisolated(unsafe) static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributedBody(_ text: String, outgoing: Bool) -> NSAttributedString {
        let t = MacConversationTheme.self
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: t.bodyFont,
            .foregroundColor: outgoing ? t.outgoingText : t.incomingText,
            .paragraphStyle: t.bodyParagraph,
        ])
        linkDetector?.enumerateMatches(in: text, range: NSRange(text.startIndex..., in: text)) { match, _, _ in
            guard let match else { return }
            result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            if let url = match.url { result.addAttribute(.macConversationLink, value: url, range: match.range) }
        }
        return result
    }

    static func measure(_ text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let rect = text.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    static func compute(_ model: MacMessageRowModel, width: CGFloat, text: NSAttributedString) -> MacMessageLayout {
        let t = MacConversationTheme.self
        let margin = t.sideMargin
        let avatarColumn = model.isGroup ? t.avatarSize + t.avatarGap : 0
        let incomingLeading = margin + avatarColumn
        let isFailed = model.footer == .notDelivered
        let outgoingTrailing = width - t.outgoingMargin - (isFailed ? 26 : 0)
        let available = model.isOutgoing ? width : width - avatarColumn
        let maxBubble = min(t.maxBubbleWidth, floor(available * t.maxBubbleWidthFraction))

        func bubbleRect(bodyWidth w: CGFloat, y: CGFloat, height h: CGFloat) -> CGRect {
            model.isOutgoing
                ? CGRect(x: outgoingTrailing - w, y: y, width: w + t.tailWidth, height: h)
                : CGRect(x: incomingLeading - t.tailWidth, y: y, width: w + t.tailWidth, height: h)
        }

        var y: CGFloat = 0
        var quoteFrame: CGRect?
        var quoteTextFrame: CGRect?
        if let quote = model.replyQuote {
            // Measured against Messages: 10 pt text on a 13 pt pitch, up to two
            // lines, 8 pt side and 7 pt vertical insets in an outlined pill.
            let quoteText = NSAttributedString(string: quote.text, attributes: MacConversationTheme.quoteAttributes)
            let size = measure(quoteText, maxWidth: maxBubble - 16)
            let textHeight = min(size.height, MacConversationTheme.quoteLineHeight * 2)
            let bodyWidth = min(maxBubble, size.width + 16)
            let h = textHeight + 14
            let frame = quote.isOutgoing
                ? CGRect(x: width - t.outgoingMargin - bodyWidth, y: y, width: bodyWidth + t.tailWidth, height: h)
                : CGRect(x: incomingLeading - t.tailWidth, y: y, width: bodyWidth + t.tailWidth, height: h)
            quoteFrame = frame
            let bodyMinX = quote.isOutgoing ? frame.minX : frame.minX + t.tailWidth
            quoteTextFrame = CGRect(x: bodyMinX + 8, y: y + 7, width: bodyWidth - 16, height: textHeight)
            y += h + 4
        }

        var senderNameFrame: CGRect?
        if model.showsSenderName, model.senderName != nil {
            senderNameFrame = CGRect(x: incomingLeading + t.senderNameInset, y: y, width: maxBubble, height: 13)
            y += 14
        }

        if !model.reactionKinds.isEmpty { y += 14 }

        var imageFrames: [CGRect] = []
        for attachment in model.message.attachments {
            var w = min(t.maxImageWidth, floor(available * 0.55))
            var h = w / CGFloat(attachment.aspectRatio)
            if h > t.maxImageHeight {
                h = t.maxImageHeight
                w = max(90, h * CGFloat(attachment.aspectRatio))
            }
            imageFrames.append(bubbleRect(bodyWidth: round(w), y: y, height: round(h)))
            y += round(h) + t.groupedSpacing
        }
        if !imageFrames.isEmpty, model.message.text.isEmpty { y -= t.groupedSpacing }

        var bubbleFrame: CGRect?
        var textFrame: CGRect?
        var emojiFrame: CGRect?
        if model.isEmojiOnly {
            let emoji = NSAttributedString(string: model.message.text, attributes: [.font: NSFont.systemFont(ofSize: t.emojiOnlyFontSize)])
            var size = measure(emoji, maxWidth: maxBubble)
            size.width += 6
            size.height += 4
            emojiFrame = CGRect(
                x: model.isOutgoing ? outgoingTrailing - size.width : incomingLeading,
                y: y, width: size.width, height: size.height
            )
            y += size.height
        } else if !model.message.text.isEmpty {
            let size = measure(text, maxWidth: maxBubble - 2 * t.bubbleHorizontalPadding)
            let textHeight = max(size.height, t.lineHeight)
            let bodyWidth = max(size.width + 2 * t.bubbleHorizontalPadding, t.lineHeight + 2 * t.bubbleVerticalPadding)
            let h = textHeight + 2 * t.bubbleVerticalPadding
            let frame = bubbleRect(bodyWidth: bodyWidth, y: y, height: h)
            bubbleFrame = frame
            let bodyMinX = model.isOutgoing ? frame.minX : frame.minX + t.tailWidth
            textFrame = CGRect(x: bodyMinX + (bodyWidth - size.width) / 2, y: y + t.bubbleVerticalPadding - t.bubbleTextLift, width: size.width + 1, height: textHeight)
            y += h
        }

        let primary = bubbleFrame ?? emojiFrame ?? imageFrames.last ?? CGRect(x: incomingLeading, y: y, width: 40, height: 1)
        let first = imageFrames.first ?? bubbleFrame ?? emojiFrame ?? primary
        var firstBody = first
        if bubbleFrame != nil || !imageFrames.isEmpty {
            firstBody.size.width -= t.tailWidth
            if !model.isOutgoing { firstBody.origin.x += t.tailWidth }
        }
        let reactionAnchor: CGPoint? = model.reactionKinds.isEmpty ? nil
            : (model.isOutgoing ? CGPoint(x: firstBody.minX, y: firstBody.minY) : CGPoint(x: firstBody.maxX, y: firstBody.minY))

        // The avatar's bottom lines up with the bottom of the tail.
        let tailBottom = primary.maxY + (model.showsTail && bubbleFrame != nil ? t.tailDrop : 0)
        let avatarFrame: CGRect? = model.showsAvatar
            ? CGRect(x: margin, y: tailBottom - t.avatarSize, width: t.avatarSize, height: t.avatarSize)
            : nil
        let failedBadgeFrame: CGRect? = isFailed
            ? CGRect(x: width - t.outgoingMargin - 18, y: primary.midY - 9, width: 18, height: 18)
            : nil

        let bodyTrailing = model.isOutgoing ? outgoingTrailing : primary.maxX
        let bodyLeading = model.isOutgoing ? primary.minX : incomingLeading
        func footerRect(_ y: CGFloat) -> CGRect {
            model.isOutgoing
                ? CGRect(x: margin, y: y, width: bodyTrailing - 5 - margin, height: 14)
                : CGRect(x: bodyLeading + 5, y: y, width: width - bodyLeading - 5 - margin, height: 14)
        }
        let tailExtra: CGFloat = model.showsTail && bubbleFrame != nil ? t.tailDrop : 0
        y = max(y, primary.maxY + tailExtra)
        var editedFrame: CGRect?
        var repliesFrame: CGRect?
        var footerFrame: CGRect?
        if model.message.editedAt != nil {
            editedFrame = footerRect(y + 2)
            y += 2 + 14
        }
        if model.message.replyCount > 0 {
            repliesFrame = footerRect(y + 2)
            y += 2 + 14
        }
        if model.footer != .none {
            footerFrame = footerRect(y + 2)
            y += 2 + 14
        }

        // Messages: the quoted message's sender gets a tiny avatar beside the
        // quote, and the thread line drops from under it, curving into the reply.
        var threadPath: CGPath?
        var quoteAvatarFrame: CGRect?
        if let quoteFrame, let quote = model.replyQuote {
            let tiny: CGFloat = 16
            // Groups thread through the avatar column; 1:1 chats have none, so
            // the line runs just outside the bubbles' leading edge.
            // A reply to your own message threads down the trailing side.
            let trailingThread = quote.isOutgoing && model.isOutgoing
            let column = trailingThread
                ? width - t.outgoingMargin + 8
                : model.isGroup ? margin + t.avatarSize / 2 : max(4, incomingLeading - 8)
            if !quote.isOutgoing, model.isGroup {
                quoteAvatarFrame = CGRect(x: column - tiny / 2, y: quoteFrame.maxY - tiny + 3, width: tiny, height: tiny)
            }
            let startY = (quoteAvatarFrame?.maxY ?? quoteFrame.midY) + 4
            let endY = model.isOutgoing ? primary.maxY : (avatarFrame?.minY ?? primary.maxY) - 4
            let path = CGMutablePath()
            path.move(to: CGPoint(x: column, y: startY))
            if trailingThread {
                path.addLine(to: CGPoint(x: column, y: max(startY + 6, primary.minY - 4)))
            } else if model.isOutgoing {
                path.addLine(to: CGPoint(x: column, y: max(startY + 10, endY - 10)))
                path.addQuadCurve(to: CGPoint(x: column + 12, y: max(startY + 20, endY)), control: CGPoint(x: column, y: max(startY + 20, endY)))
            } else {
                path.addLine(to: CGPoint(x: column, y: max(startY + 6, endY)))
            }
            threadPath = path
        }

        var content = imageFrames.reduce(bubbleFrame ?? emojiFrame ?? .null) { $0.union($1) }
        if content.isNull { content = primary }
        return MacMessageLayout(
            height: ceil(y),
            senderNameFrame: senderNameFrame,
            quoteFrame: quoteFrame,
            quoteTextFrame: quoteTextFrame,
            quoteAvatarFrame: quoteAvatarFrame,
            threadPath: threadPath,
            imageFrames: imageFrames,
            bubbleFrame: bubbleFrame,
            textFrame: textFrame,
            emojiFrame: emojiFrame,
            avatarFrame: avatarFrame,
            reactionAnchor: reactionAnchor,
            editedFrame: editedFrame,
            repliesFrame: repliesFrame,
            footerFrame: footerFrame,
            failedBadgeFrame: failedBadgeFrame,
            contentFrame: content
        )
    }
}
#endif
