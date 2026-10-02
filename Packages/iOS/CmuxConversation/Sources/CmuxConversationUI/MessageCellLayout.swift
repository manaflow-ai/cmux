#if canImport(UIKit)
import CmuxConversationCore
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
    /// Union of everything that lifts in the long-press preview.
    var contentFrame: CGRect
}

@MainActor
final class MessageLayoutCache {
    private struct Key: Hashable {
        var model: MessageRowModel
        var width: CGFloat
        var margin: CGFloat
    }

    private var cache: [String: (Key, MessageCellLayout)] = [:]
    private var attributed: [String: (String, NSAttributedString)] = [:]

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
        if let (text, value) = attributed[cacheKey], text == model.message.text {
            return value
        }
        let value = MessageCellLayout.attributedBody(model.message.text, outgoing: model.isOutgoing)
        attributed[cacheKey] = (model.message.text, value)
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
    nonisolated(unsafe) static let linkDetector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    static func attributedBody(_ text: String, outgoing: Bool) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text, attributes: [
            .font: ConversationTheme.bodyFont,
            .foregroundColor: outgoing ? ConversationTheme.outgoingText : ConversationTheme.incomingText,
            .paragraphStyle: ConversationTheme.bodyParagraph,
        ])
        let range = NSRange(text.startIndex..., in: text)
        linkDetector?.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match else { return }
            result.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: match.range)
            if let url = match.url { result.addAttribute(.conversationLink, value: url, range: match.range) }
        }
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

    /// `margin` is the system layout margin (16 pt on 402-wide phones, 20 on 440).
    static func compute(model: MessageRowModel, width: CGFloat, margin: CGFloat, text: NSAttributedString) -> MessageCellLayout {
        let t = ConversationTheme.self
        let message = model.message
        let avatarColumn = model.reservesAvatarColumn ? t.avatarSize + t.avatarGap : 0
        // Body edges (tails extend tailWidth beyond these).
        let incomingBodyLeading = margin + avatarColumn
        let isFailed = model.footer == .notDelivered
        let outgoingBodyTrailing = width - margin - (isFailed ? 32 : 0)
        // Outgoing measures against the full width; incoming against the
        // space right of the avatar column (282 pt max on a 440 pt screen).
        let maxBubbleWidth = floor((model.isOutgoing ? width : width - (model.isGroup ? t.avatarSize + t.avatarGap : 0)) * t.maxBubbleWidthFraction)
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
            let quoteFont = UIFont.systemFont(ofSize: 15)
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
            senderNameFrame = CGRect(x: incomingBodyLeading + 15, y: y, width: maxBubbleWidth, height: 16)
            y += 19
        }

        if hasReactions { y += 18 }

        var imageFrames: [CGRect] = []
        for attachment in message.attachments {
            let maxW = floor(width * t.maxImageWidthFraction)
            var w = maxW
            var h = w / CGFloat(attachment.aspectRatio)
            if h > t.maxImageHeight {
                h = t.maxImageHeight
                w = max(120, h * CGFloat(attachment.aspectRatio))
            }
            imageFrames.append(bubbleRect(bodyWidth: round(w), y: y, height: round(h)))
            y += round(h) + t.groupedSpacing
        }
        if !imageFrames.isEmpty, message.text.isEmpty { y -= t.groupedSpacing }

        var bubbleFrame: CGRect?
        var textFrame: CGRect?
        var emojiFrame: CGRect?
        if model.isEmojiOnly {
            let emoji = NSAttributedString(string: message.text, attributes: [.font: UIFont.systemFont(ofSize: t.emojiOnlyFontSize)])
            var size = measure(emoji, maxWidth: maxBubbleWidth)
            size.width += ceil(t.emojiOnlyFontSize * 0.25)
            size.height += 6
            emojiFrame = CGRect(
                x: model.isOutgoing ? outgoingBodyTrailing - size.width : incomingBodyLeading,
                y: y, width: size.width, height: size.height
            )
            y += size.height
        } else if !message.text.isEmpty {
            let maxTextWidth = maxBubbleWidth - 2 * t.bubbleHorizontalPadding
            let size = measure(text, maxWidth: maxTextWidth)
            let textHeight = max(size.height, t.lineHeight)
            let bodyWidth = max(size.width + 2 * t.bubbleHorizontalPadding, t.lineHeight + 2 * t.bubbleVerticalPadding)
            let h = textHeight + 2 * t.bubbleVerticalPadding
            let frame = bubbleRect(bodyWidth: bodyWidth, y: y, height: h)
            bubbleFrame = frame
            let bodyMinX = model.isOutgoing ? frame.minX : frame.minX + t.tailWidth
            textFrame = CGRect(
                x: bodyMinX + (bodyWidth - size.width) / 2,
                y: frame.minY + t.bubbleVerticalPadding - t.bodyGlyphLift,
                width: size.width,
                height: textHeight
            )
            y += h
        }

        let primary = bubbleFrame ?? emojiFrame ?? imageFrames.last ?? CGRect(x: incomingBodyLeading, y: y, width: 40, height: 1)
        let firstContent = imageFrames.first ?? bubbleFrame ?? emojiFrame ?? primary
        // Body rect (no tail) of the first content block.
        let firstBody: CGRect = {
            guard bubbleFrame != nil || !imageFrames.isEmpty else { return firstContent }
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

        // Footers align ~9 pt inside the body edge on the sender's side.
        let bodyTrailing = model.isOutgoing ? outgoingBodyTrailing : primary.maxX
        let bodyLeading = model.isOutgoing ? primary.minX : incomingBodyLeading
        let footerHeight: CGFloat = 15
        var editedFrame: CGRect?
        var repliesFrame: CGRect?
        var footerFrame: CGRect?
        func footerRect(_ y: CGFloat) -> CGRect {
            model.isOutgoing
                ? CGRect(x: margin, y: y, width: bodyTrailing - 9 - margin, height: footerHeight)
                : CGRect(x: bodyLeading + 9, y: y, width: width - bodyLeading - 9 - margin, height: footerHeight)
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
            footerFrame = footerRect(y + 5)
            y += 5 + footerHeight
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
        if content.isNull { content = primary }
        // The tail hangs below the body; reserve it in the row and the lifted preview.
        if model.showsTail, bubbleFrame != nil {
            y = max(y, primary.maxY + t.tailDrop)
            content.size.height += t.tailDrop
        }

        return MessageCellLayout(
            height: ceil(y),
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
            contentFrame: content
        )
    }
}
#endif
