#if canImport(UIKit)
import CmuxConversationCore
import CmuxConversationGeometry
import UIKit

/// Precomputed frames for one message row, in cell coordinates. Computing
/// them off the cell keeps layout, the send animation, and the long-press
/// overlay in agreement about where the bubble is.
struct MessageCellLayout {
    /// Room ChatKit's big-emoji balloon adds around the glyphs (logged from
    /// Messages; one 72 pt emoji is 105 x 85.9 on iOS 27, 77 x 112.8 on
    /// iOS 26): iOS 27 pads 14 pt on each side; iOS 26 sits the glyphs
    /// against the margin, 10 pt below the balloon's top and 16.84 pt above
    /// its bottom (measured against the timestamp above and the next bubble).
    static var emojiGlyphInsets: UIEdgeInsets {
        if #available(iOS 27, *) { return UIEdgeInsets(top: 0, left: 14, bottom: 0, right: 14) }
        return UIEdgeInsets(top: 10, left: 0, bottom: 16.84, right: 0)
    }

    static var emojiBalloonInsets: CGSize {
        let insets = emojiGlyphInsets
        return CGSize(width: insets.left + insets.right, height: insets.top + insets.bottom)
    }

    /// The glyphs' line inside the balloon, trailing-aligned when sent so
    /// they meet the margin on iOS 26.
    static func emojiGlyphFrame(in balloon: CGRect) -> CGRect {
        balloon.inset(by: emojiGlyphInsets)
    }

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
    /// The translation caption ("Show Original") under a translated bubble.
    var translationFrame: CGRect? = nil
    /// Document balloons (tail area excluded, like `bubbleFrame`), one per file.
    var fileFrames: [CGRect] = []
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
        let (body, mentions, runs) = Self.attributedInputs(model)
        if let (text, cachedMentions, cachedRuns, value) = attributed[cacheKey], text == body,
           cachedMentions == mentions, cachedRuns == runs {
            return value
        }
        let value = MessageCellLayout.attributedBody(body, outgoing: model.isOutgoing, mentions: mentions, meID: model.meID, runs: runs)
        attributed[cacheKey] = (body, mentions, runs, value)
        return value
    }

    /// What a bubble's attributed text is built from. Audio bubbles show the
    /// transcript; a link card takes its URL out of the text bubble, so
    /// mentions and formatting (ranges over the whole `text`) are re-based
    /// onto what the bubble shows.
    nonisolated static func attributedInputs(_ model: MessageRowModel) -> (String, [ConversationMention], [ConversationTextRun]) {
        let isAudio = model.message.audioAttachment != nil
        let body = isAudio ? model.message.bodyText : model.bodyText
        let mentions = isAudio ? [] : model.linkSplit.map { $0.bodyMentions(model.message.mentions) } ?? model.message.mentions
        let runs = isAudio ? [] : model.linkSplit.map { $0.bodyRuns(model.message.textRuns) } ?? model.message.textRuns
        return (body, mentions, runs)
    }

    // MARK: Measuring ahead

    /// A row measured away from the main thread.
    struct Measured: @unchecked Sendable {
        var model: MessageRowModel
        var layout: MessageCellLayout
        var text: NSAttributedString
    }

    /// Of `models`, those this cache has no layout for at `width` and
    /// `margin` and that can be measured off the main thread (plain text,
    /// emoji and photo rows; link cards, polls and audio measure here).
    func unmeasured(_ models: [MessageRowModel], width: CGFloat, margin: CGFloat) -> [MessageRowModel] {
        models.filter { model in
            guard Self.measuresOffMain(model) else { return false }
            if let (key, _) = cache[model.rowID], key == Key(model: model, width: width, margin: margin) { return false }
            return true
        }
    }

    nonisolated static func measuresOffMain(_ model: MessageRowModel) -> Bool {
        model.poll == nil && model.linkSplit == nil && model.message.linkPreview == nil && model.message.audioAttachment == nil
    }

    /// Text and layout for `model`, exactly as `layout(for:)` builds them,
    /// for any thread. Run it inside the transcript's traits
    /// (`performAsCurrent`) so text styles resolve to the same fonts.
    nonisolated static func measure(_ model: MessageRowModel, width: CGFloat, margin: CGFloat) -> Measured {
        let (body, mentions, runs) = attributedInputs(model)
        let text = MessageCellLayout.attributedBody(body, outgoing: model.isOutgoing, mentions: mentions, meID: model.meID, runs: runs)
        let layout = MessageCellLayout.compute(model: model, width: width, margin: margin, text: text)
        return Measured(model: model, layout: layout, text: text)
    }

    /// Adopts rows measured ahead, unless the cache moved on meanwhile.
    func adopt(_ measured: [Measured], width: CGFloat, margin: CGFloat) {
        for item in measured {
            let model = item.model
            let key = Key(model: model, width: width, margin: margin)
            if let (cachedKey, _) = cache[model.rowID], cachedKey == key { continue }
            cache[model.rowID] = (key, item.layout)
            let (body, mentions, runs) = Self.attributedInputs(model)
            attributed[model.rowID + (model.isOutgoing ? "o" : "i")] = (body, mentions, runs, item.text)
        }
    }

    /// Drops entries for rows that left the transcript (a trimmed or rebased
    /// window), so the cache tracks the loaded window instead of the session.
    func forget(rowIDs: some Sequence<String>) {
        for rowID in rowIDs {
            cache[rowID] = nil
            attributed[rowID + "o"] = nil
            attributed[rowID + "i"] = nil
        }
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

    /// `value` rounded up to the screen's pixel grid, as ChatKit sizes balloons.
    static func pixelCeil(_ value: CGFloat) -> CGFloat {
        ConversationTranscriptMetrics.ceilToPixel(value, scale: ConversationTheme.displayScale)
    }

    static func measure(_ text: NSAttributedString, maxWidth: CGFloat) -> CGSize {
        let rect = text.boundingRect(
            with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            context: nil
        )
        // Pixel-rounded like ChatKit's balloons: a 72 pt emoji line is 85.92
        // pt, its balloon 86.00 at @3x (whole points would make it 86.00 too,
        // but two 48 pt emoji are 57.28 -> 57.33, not 58).
        return CGSize(width: pixelCeil(rect.width), height: pixelCeil(rect.height))
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
        // Messages sizes every balloon against the transcript between its
        // margins (280.67 pt on a 402 pt phone); its slack already leaves room
        // for a group's avatar column, so incoming group rows share the width.
        let maxBubbleWidth = t.maxBubbleWidth(forAvailableWidth: width - 2 * margin)
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
        // Documents follow the photos as fixed-size balloons (ChatKit's
        // attachmentBalloonSize), 4 pt apart like photos.
        var fileFrames: [CGRect] = []
        for _ in message.fileAttachments {
            if fileFrames.isEmpty, !imageFrames.isEmpty { y += imageSpacing }
            let size = ConversationFileBubbleLayout.size
            fileFrames.append(bubbleRect(bodyWidth: size.width, y: y, height: size.height))
            y += size.height + imageSpacing
        }
        if !fileFrames.isEmpty {
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
            // Like text rows: the balloon is pixel-rounded (86.00), the row
            // advances by the line's own height (85.92).
            let raw = emoji.boundingRect(
                with: CGSize(width: maxBubbleWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).size
            let rowHeight = raw.height + Self.emojiBalloonInsets.height
            let size = CGSize(width: pixelCeil(raw.width) + Self.emojiBalloonInsets.width, height: pixelCeil(rowHeight))
            emojiFrame = CGRect(
                x: model.isOutgoing ? outgoingBodyTrailing - size.width : incomingBodyLeading,
                y: y, width: size.width, height: size.height
            )
            y += rowHeight
        } else if !bodyText.isEmpty {
            let hPad = t.bubbleHorizontalPadding, vPad = t.bubbleVerticalPadding
            let size = text.boundingRect(
                with: CGSize(width: maxBubbleWidth - 2 * hPad, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).size
            let textHeight = max(size.height, t.bubbleFont.lineHeight)
            // ChatKit rounds the balloon up to the pixel grid ("Are we still on
            // for dinner tonight?" is 249.70 pt of text in a 278.00 x 40.33
            // balloon at @3x); the text keeps its 14 pt leading inset and the
            // rounding lands on the trailing side.
            let bodyWidth = max(pixelCeil(size.width + 2 * hPad), t.minBubbleWidth)
            // The row advances by the unrounded height (40.287 pt); the
            // transcript rounds each row's origin to the pixel grid, so rows
            // land where Messages puts them (232.33, 276.67, 321.00, ...).
            let rowHeight = textHeight + 2 * vPad
            let h = pixelCeil(rowHeight)
            let frame = bubbleRect(bodyWidth: bodyWidth, y: y, height: h)
            bubbleFrame = frame
            let bodyMinX = model.isOutgoing ? frame.minX : frame.minX + t.tailWidth
            textFrame = CGRect(
                x: bodyMinX + (bodyWidth > size.width + 2 * hPad + 1 ? (bodyWidth - size.width) / 2 : hPad),
                y: frame.minY + vPad,
                width: size.width,
                height: textHeight
            )
            y += rowHeight
        }
        if model.linkSplit?.cardFirst == false { placeLinkCard() }
        let linkCardIsLast = linkCardFrame != nil && (model.linkSplit?.cardFirst == false || bubbleFrame == nil)

        let primary = (linkCardIsLast ? linkCardFrame : nil) ?? bubbleFrame ?? emojiFrame ?? fileFrames.last ?? imageFrames.last ?? CGRect(x: incomingBodyLeading, y: y, width: 40, height: 1)
        let firstContent = imageFrames.first ?? fileFrames.first ?? (model.linkSplit?.cardFirst == true ? linkCardFrame : nil) ?? bubbleFrame ?? linkCardFrame ?? emojiFrame ?? primary
        // Body rect (no tail) of the first content block.
        let firstBody: CGRect = {
            guard bubbleFrame != nil || linkCardFrame != nil || !imageFrames.isEmpty || !fileFrames.isEmpty else { return firstContent }
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
        var translationFrame: CGRect?
        if model.translation != nil {
            translationFrame = footerRect(y + 4)
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
        content = fileFrames.reduce(content) { $0.union($1) }
        if content.isNull { content = primary }
        // The tail hangs below the body; reserve it in the row and the lifted preview.
        // A photo-only row (no text bubble, no emoji) tails its last photo; the
        // tail hangs below the full-height photo (Messages), so reserve it.
        let tailedImage = bubbleFrame == nil && emojiFrame == nil && linkCardFrame == nil && (!imageFrames.isEmpty || !fileFrames.isEmpty)
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
            linkCardIsLast: linkCardIsLast,
            translationFrame: translationFrame,
            fileFrames: fileFrames
        )
    }
}
#endif
