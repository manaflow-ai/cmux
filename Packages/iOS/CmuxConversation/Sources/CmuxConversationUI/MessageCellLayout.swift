#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// Precomputed frames for one message row, in cell coordinates. Computing
/// them off the cell keeps layout, the send animation, and the long-press
/// overlay in agreement about where the bubble is.
struct MessageCellLayout {
    var height: CGFloat
    var senderNameFrame: CGRect?
    var quoteFrame: CGRect?
    var quoteTextFrame: CGRect?
    var threadPath: CGPath?
    var imageFrames: [CGRect]
    /// Bubble outline including the tail area.
    var bubbleFrame: CGRect?
    var textFrame: CGRect?
    var emojiFrame: CGRect?
    var avatarFrame: CGRect?
    var reactionAnchor: CGPoint?
    var footerFrame: CGRect?
    var editedFrame: CGRect?
    var repliesFrame: CGRect?
    var failedBadgeFrame: CGRect?
    /// Bottom of the row that only the tail occupies; the gap to the next
    /// row is measured from the body, so the tail hangs into it.
    var tailOverhang: CGFloat
    /// "Replay" under a message sent with an effect.
    var replayFrame: CGRect? = nil
    /// Union of everything that lifts in the long-press preview.
    var contentFrame: CGRect
    /// Audio messages: the play button, waveform and duration row inside the bubble.
    var audioFrame: CGRect? = nil
    /// Audio messages: "Expires in 2m · Keep" (or "Kept") under the bubble.
    var audioExpiryFrame: CGRect? = nil
    /// Rich link balloon (tail area included, like `bubbleFrame`) and its inner layout.
    var linkCardFrame: CGRect? = nil
    var linkCard: ConversationLinkCardLayout? = nil
    /// The card is the last balloon, so it (not the text bubble) carries the tail.
    var linkCardIsLast = false
    /// Poll card, its "Add Choice" stamp and its "Poll vote failed." line.
    var poll: PollCellLayout? = nil
}

@MainActor
final class MessageLayoutCache {
    private struct Key: Hashable {
        var model: MessageRowModel
        var width: CGFloat
        var margin: CGFloat
    }

    private var cache: [String: (Key, MessageCellLayout)] = [:]
    private var attributed: [String: (String, [ConversationMention], [ConversationTextRun], NSAttributedString)] = [:]

    func layout(for model: MessageRowModel, width: CGFloat, margin: CGFloat) -> MessageCellLayout {
        let key = Key(model: model, width: width, margin: margin)
        if let (cachedKey, layout) = cache[model.rowID], cachedKey == key {
            return layout
        }
        let layout = MessageCellLayout.compute(model: model, width: width, margin: margin, text: attributedText(for: model))
        cache[model.rowID] = (key, layout)
        return layout
    }

    func attributedText(for model: MessageRowModel) -> NSAttributedString {
        let cacheKey = model.rowID + (model.isOutgoing ? "o" : "i")
        // Audio bubbles show the transcript; a link card takes its URL out of
        // the text bubble, so mentions and formatting (ranges over the whole
        // `text`) are re-based onto what the bubble shows.
        let isAudio = model.message.audioAttachment != nil
        let body = isAudio ? model.message.bodyText : model.bodyText
        let mentions = isAudio ? [] : model.linkSplit.map { $0.bodyMentions(model.message.mentions) } ?? model.message.mentions
        let runs = isAudio ? [] : model.linkSplit.map { $0.bodyRuns(model.message.textRuns) } ?? model.message.textRuns
        if let (text, cachedMentions, cachedRuns, value) = attributed[cacheKey], text == body,
           cachedMentions == mentions, cachedRuns == runs {
            return value
        }
        let value = MessageCellLayout.attributedBody(body, outgoing: model.isOutgoing, mentions: mentions, meID: model.meID, runs: runs)
        attributed[cacheKey] = (body, mentions, runs, value)
        return value
    }

    func invalidateAll() {
        cache.removeAll()
        attributed.removeAll()
    }
}

extension NSAttributedString.Key {
    /// Link target kept off `.link` so labels draw links in the bubble's text color, underlined.
    static let conversationLink = NSAttributedString.Key("cmuxConversationLink")
}

extension MessageCellLayout {
    nonisolated(unsafe) static let linkDetector = try? NSDataDetector(types: ConversationDataDetection.types)

    static func attributedBody(
        _ text: String,
        outgoing: Bool,
        mentions: [ConversationMention] = [],
        meID: String? = nil,
        runs: [ConversationTextRun] = []
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: ConversationTheme.bubbleFont,
            .foregroundColor: outgoing ? ConversationTheme.outgoingText : ConversationTheme.incomingText,
            .paragraphStyle: ConversationTheme.bubbleParagraph,
        ])
        if !runs.isEmpty {
            ConversationRichText.apply(runs, to: result)
            // Bubbles use the Dynamic Type bubble font with natural leading.
            ConversationRichTextStyler.applyDisplayAttributes(to: result, baseFont: ConversationTheme.bubbleFont, lineHeight: ConversationTheme.bubbleFont.lineHeight)
        }
        let range = NSRange(text.startIndex..., in: text)
        linkDetector?.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            if let url = ConversationDataDetection.actionURL(for: match) { result.addAttribute(.conversationLink, value: url, range: match.range) }
        }
        ConversationMentionStyle.apply(to: result, mentions: mentions, meID: meID, outgoing: outgoing, font: ConversationTheme.bubbleFont)
        return result
    }

    static func measure(_ text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let rect = text.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        return CGSize(width: ceil(rect.width), height: ceil(rect.height))
    }

    /// Emoji in an emoji-only message (one, two, or three).
    static func emojiCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }

    /// `margin` is the system layout margin (16 pt on 402-wide phones, 20 on 440).
    static func compute(model: MessageRowModel, width: CGFloat, margin: CGFloat, text: NSAttributedString) -> MessageCellLayout {
        if model.poll != nil { return computePoll(model: model, width: width, margin: margin) }
        let t = ConversationTheme.self
        let message = model.message
        let avatarColumn = model.reservesAvatarColumn ? t.avatarSize + t.avatarGap : 0
        // Body edges (tails extend tailWidth beyond these).
        let incomingBodyLeading = margin + avatarColumn
        let isFailed = model.footer == .notDelivered
        let outgoingBodyTrailing = width - margin - (isFailed ? 32 : 0)
        // Messages sizes bubbles against the transcript between its margins
        // (314.5 pt on a 402 pt phone); incoming group rows lose the avatar column.
        let maxBubbleWidth = t.maxBubbleWidth(forAvailableWidth: width - 2 * margin - avatarColumn)
        let hasReactions = !model.reactionKinds.isEmpty

        /// Frame (tail area included) for a bubble whose body is `w` wide.
        func bubbleRect(bodyWidth w: CGFloat, y: CGFloat, height h: CGFloat) -> CGRect {
            model.isOutgoing
                ? CGRect(x: outgoingBodyTrailing - w, y: y, width: w + t.tailWidth, height: h)
                : CGRect(x: incomingBodyLeading - t.tailWidth, y: y, width: w + t.tailWidth, height: h)
        }

        var y: CGFloat = 0
        var quoteFrame: CGRect?
        var quoteTextFrame: CGRect?
        if let quote = model.replyQuote {
            let quoteFont = t.quoteFont
            let quoteString = NSAttributedString(string: quote.text, attributes: [.font: quoteFont])
            let size = measure(quoteString, maxWidth: maxBubbleWidth - 24)
            let textHeight = min(size.height, ceil(quoteFont.lineHeight * 2))
            let bodyWidth = min(maxBubbleWidth, size.width + 24)
            let h = textHeight + 14
            // The quote sits on the original sender's side, outline only.
            let quoteLeading = margin + (model.isGroup ? t.avatarSize + t.avatarGap : 0)
            let frame = quote.isOutgoing
                ? CGRect(x: width - margin - bodyWidth, y: y, width: bodyWidth + t.tailWidth, height: h)
                : CGRect(x: quoteLeading - t.tailWidth, y: y, width: bodyWidth + t.tailWidth, height: h)
            quoteFrame = frame
            let bodyMinX = quote.isOutgoing ? frame.minX : frame.minX + t.tailWidth
            quoteTextFrame = CGRect(x: bodyMinX + 12, y: y + 7, width: bodyWidth - 24, height: textHeight)
            y += h + 6
        }

        var senderNameFrame: CGRect?
        if model.showsSenderName, model.senderName != nil {
            let nameHeight = ceil(t.senderNameFont.lineHeight)
            senderNameFrame = CGRect(x: incomingBodyLeading + t.senderNameInset, y: y, width: maxBubbleWidth, height: nameHeight)
            y += nameHeight + 3
        }

        if hasReactions { y += t.reactionRowGrowth }

        // Messages stacks each photo at the full image width, 4 pt apart; a
        // tall photo is capped in height and aspect-fills (it never narrows).
        var imageFrames: [CGRect] = []
        let imageSpacing: CGFloat = 4
        for attachment in message.attachments where attachment.kind == .image {
            let w = floor(width * t.maxImageWidthFraction)
            let h = min(w / CGFloat(attachment.aspectRatio), t.maxImageHeight)
            imageFrames.append(bubbleRect(bodyWidth: round(w), y: y, height: round(h)))
            y += round(h) + imageSpacing
        }
        if !imageFrames.isEmpty {
            y += message.text.isEmpty ? -imageSpacing : t.groupedSpacing - imageSpacing
        }

        var linkCardFrame: CGRect?
        var linkCard: ConversationLinkCardLayout?
        let bodyText = model.bodyText
        /// Messages' rich link width: the preview balloon max for this transcript.
        func placeLinkCard() {
            guard let split = model.linkSplit, let preview = message.linkPreview else { return }
            let reserved = model.isGroup && !model.isOutgoing ? t.avatarSize + t.avatarGap : 0
            let cardMax = 0.85 * (width - 2 * margin - reserved) - 27.83
            let card = ConversationLinkPreviewView.layout(for: preview, maxWidth: cardMax)
            if split.cardFirst == false, !bodyText.isEmpty { y += t.groupedSpacing }
            linkCard = card
            linkCardFrame = bubbleRect(bodyWidth: card.size.width, y: y, height: card.size.height)
            y += card.size.height
            if split.cardFirst, !bodyText.isEmpty { y += t.groupedSpacing }
        }
        if model.linkSplit?.cardFirst == true { placeLinkCard() }

        var bubbleFrame: CGRect?
        var textFrame: CGRect?
        var emojiFrame: CGRect?
        var audioFrame: CGRect?
        if let audio = message.audioAttachment?.audio {
            let audioLayout = AudioBubbleLayout.compute(audio: audio, text: text, maxBubbleWidth: maxBubbleWidth)
            let frame = bubbleRect(bodyWidth: audioLayout.bodyWidth, y: y, height: audioLayout.height)
            bubbleFrame = frame
            let bodyMinX = model.isOutgoing ? frame.minX : frame.minX + t.tailWidth
            audioFrame = audioLayout.row.offsetBy(dx: bodyMinX, dy: y)
            textFrame = audioLayout.transcript?.offsetBy(dx: bodyMinX, dy: y)
            y += audioLayout.height
        } else if model.isEmojiOnly {
            let fontSize = t.emojiOnlyFontSize(count: emojiCount(message.text))
            let emoji = NSAttributedString(string: message.text, attributes: [.font: UIFont.systemFont(ofSize: fontSize)])
            var size = measure(emoji, maxWidth: maxBubbleWidth)
            size.width += ceil(fontSize * 0.25)
            size.height += 6
            emojiFrame = CGRect(
                x: model.isOutgoing ? outgoingBodyTrailing - size.width : incomingBodyLeading,
                y: y, width: size.width, height: size.height
            )
            y += size.height
        } else if !bodyText.isEmpty {
            let hPad = t.bubbleHorizontalPadding, vPad = t.bubbleVerticalPadding
            // Unrounded, as ChatKit sizes balloons ("Hello there" is 110.83 pt wide).
            let size = text.boundingRect(
                with: CGSize(width: maxBubbleWidth - 2 * hPad, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).size
            let textHeight = max(size.height, t.bubbleFont.lineHeight)
            let bodyWidth = max(size.width + 2 * hPad, t.minBubbleWidth)
            let h = textHeight + 2 * vPad
            let frame = bubbleRect(bodyWidth: bodyWidth, y: y, height: h)
            bubbleFrame = frame
            let bodyMinX = model.isOutgoing ? frame.minX : frame.minX + t.tailWidth
            textFrame = CGRect(
                x: bodyMinX + (bodyWidth - size.width) / 2,
                y: frame.minY + vPad,
                width: size.width,
                height: textHeight
            )
            y += h
        }
        if model.linkSplit?.cardFirst == false { placeLinkCard() }
        let linkCardIsLast = linkCardFrame != nil && (model.linkSplit?.cardFirst == false || bubbleFrame == nil)

        let primary = (linkCardIsLast ? linkCardFrame : nil) ?? bubbleFrame ?? emojiFrame ?? imageFrames.last ?? CGRect(x: incomingBodyLeading, y: y, width: 40, height: 1)
        let firstContent = imageFrames.first ?? (model.linkSplit?.cardFirst == true ? linkCardFrame : nil) ?? bubbleFrame ?? linkCardFrame ?? emojiFrame ?? primary
        // Body rect (no tail) of the first content block.
        let firstBody: CGRect = {
            guard bubbleFrame != nil || linkCardFrame != nil || !imageFrames.isEmpty else { return firstContent }
            var body = firstContent
            body.size.width -= t.tailWidth
            if !model.isOutgoing { body.origin.x += t.tailWidth }
            return body
        }()

        var reactionAnchor: CGPoint?
        if hasReactions {
            // The badge hangs off the top corner opposite the tail.
            reactionAnchor = model.isOutgoing
                ? CGPoint(x: firstBody.minX, y: firstBody.minY)
                : CGPoint(x: firstBody.maxX, y: firstBody.minY)
        }

        var avatarFrame: CGRect?
        if model.showsAvatar {
            let bodyBottom = primary.maxY
            avatarFrame = CGRect(x: margin, y: bodyBottom - t.avatarSize, width: t.avatarSize, height: t.avatarSize)
        }

        var failedBadgeFrame: CGRect?
        if isFailed {
            failedBadgeFrame = CGRect(x: width - margin - 24, y: primary.midY - 12, width: 24, height: 24)
        }

        // Footers sit 20 pt inside the body edge on the sender's side.
        let bodyTrailing = model.isOutgoing ? outgoingBodyTrailing : primary.maxX
        let bodyLeading = model.isOutgoing ? primary.minX : incomingBodyLeading
        let footerHeight = t.footerHeight
        let footerInset = t.footerInset
        var editedFrame: CGRect?
        var repliesFrame: CGRect?
        var footerFrame: CGRect?
        func footerRect(_ y: CGFloat, inset: CGFloat = footerInset) -> CGRect {
            model.isOutgoing
                ? CGRect(x: margin, y: y, width: bodyTrailing - inset - margin, height: footerHeight)
                : CGRect(x: bodyLeading + inset, y: y, width: width - bodyLeading - inset - margin, height: footerHeight)
        }
        var audioExpiryFrame: CGRect?
        if let audio = message.audioAttachment?.audio, audio.expiresAt != nil || audio.isKept {
            audioExpiryFrame = footerRect(y + 4)
            y += 4 + footerHeight
        }
        var replayFrame: CGRect?
        if message.effect?.isReplayable == true, bubbleFrame != nil || emojiFrame != nil {
            replayFrame = footerRect(y + 4)
            y += 4 + footerHeight
        }
        if message.editedAt != nil {
            editedFrame = footerRect(y + 4)
            y += 4 + footerHeight
        }
        if message.replyCount > 0 {
            repliesFrame = footerRect(y + 4)
            y += 4 + footerHeight
        }
        if model.footer != .none {
            // Messages ends "Delivered"/"Read" 20 pt inside the bubble edge,
            // 6 pt under the body; "Not Delivered" keeps the 9 pt inset that
            // lines it up beside the failed badge.
            footerFrame = model.footer == .notDelivered
                ? footerRect(y + t.footerGap, inset: 9)
                : footerRect(y + t.footerGap)
            y += t.footerGap + footerHeight
        }

        var threadPath: CGPath?
        if let quoteFrame, let quote = model.replyQuote {
            // A thread line on the leading side joins the quote to the reply.
            let x = margin + t.avatarSize / 2
            let path = UIBezierPath()
            let quoteBodyLeading = quote.isOutgoing ? quoteFrame.minX : quoteFrame.minX + t.tailWidth
            path.move(to: CGPoint(x: min(quoteBodyLeading - 4, x + 14), y: quoteFrame.midY))
            path.addQuadCurve(to: CGPoint(x: x, y: quoteFrame.midY + 14), controlPoint: CGPoint(x: x, y: quoteFrame.midY))
            if model.isOutgoing || !model.reservesAvatarColumn {
                let endY = max(quoteFrame.midY + 28, primary.midY)
                path.addLine(to: CGPoint(x: x, y: endY - 14))
                path.addQuadCurve(to: CGPoint(x: x + 14, y: endY), controlPoint: CGPoint(x: x, y: endY))
            } else {
                path.addLine(to: CGPoint(x: x, y: max(quoteFrame.midY + 16, (avatarFrame?.minY ?? primary.maxY) - 6)))
            }
            threadPath = path.cgPath
        }

        var content = imageFrames.reduce(bubbleFrame ?? emojiFrame ?? .null) { $0.union($1) }
        if let linkCardFrame { content = content.union(linkCardFrame) }
        if content.isNull { content = primary }
        // The tail hangs below the body; reserve it in the row and the lifted preview.
        // A photo-only row (no text bubble, no emoji) tails its last photo; the
        // tail hangs below the full-height photo (Messages), so reserve it.
        let tailedImage = bubbleFrame == nil && emojiFrame == nil && linkCardFrame == nil && !imageFrames.isEmpty
        var tailOverhang: CGFloat = 0
        if model.showsTail, bubbleFrame != nil || linkCardFrame != nil || tailedImage {
            let tailBottom = primary.maxY + t.tailDrop
            tailOverhang = max(0, tailBottom - y)
            y = max(y, tailBottom)
            content.size.height += t.tailDrop
        }

        return MessageCellLayout(
            height: y,
            senderNameFrame: senderNameFrame,
            quoteFrame: quoteFrame,
            quoteTextFrame: quoteTextFrame,
            threadPath: threadPath,
            imageFrames: imageFrames,
            bubbleFrame: bubbleFrame,
            textFrame: textFrame,
            emojiFrame: emojiFrame,
            avatarFrame: avatarFrame,
            reactionAnchor: reactionAnchor,
            footerFrame: footerFrame,
            editedFrame: editedFrame,
            repliesFrame: repliesFrame,
            failedBadgeFrame: failedBadgeFrame,
            tailOverhang: tailOverhang,
            replayFrame: replayFrame,
            contentFrame: content,
            audioFrame: audioFrame,
            audioExpiryFrame: audioExpiryFrame,
            linkCardFrame: linkCardFrame,
            linkCard: linkCard,
            linkCardIsLast: linkCardIsLast
        )
    }
}
#endif
