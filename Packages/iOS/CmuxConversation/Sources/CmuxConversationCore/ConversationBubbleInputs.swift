import Foundation

/// Everything a text bubble's attributed text is built from. The transcript
/// row and the off-main pre-build of a live message both take their inputs
/// from here, so the two always agree and the row finds the pre-built text
/// in the shared bubble text cache instead of rebuilding it on the main thread.
public struct ConversationBubbleInputs: Sendable, Hashable {
    public var text: String
    public var outgoing: Bool
    public var mentions: [ConversationMention]
    public var meID: String?
    public var runs: [ConversationTextRun]
    public var links: [ConversationTextLink]

    public init(
        text: String,
        outgoing: Bool,
        mentions: [ConversationMention] = [],
        meID: String? = nil,
        runs: [ConversationTextRun] = [],
        links: [ConversationTextLink] = []
    ) {
        self.text = text
        self.outgoing = outgoing
        self.mentions = mentions
        self.meID = meID
        self.runs = runs
        self.links = links
    }

    /// A text message's bubble: its text, minus a URL a link card took out
    /// (`linkSplit`), with mentions, formatting and links re-based onto what
    /// the bubble shows.
    public init(message: ConversationMessage, outgoing: Bool, meID: String?, linkSplit: ConversationLinkSplit?) {
        let body = linkSplit?.bodyText ?? message.text
        self.init(
            text: body,
            outgoing: outgoing,
            mentions: linkSplit.map { $0.bodyMentions(message.mentions) } ?? message.mentions,
            meID: meID,
            runs: linkSplit.map { $0.bodyRuns(message.textRuns) } ?? message.textRuns,
            links: ConversationTextLink.bubbleLinks(message.links, offset: linkSplit?.bodyOffset ?? 0, bodyLength: body.utf16.count)
        )
    }

    /// A live message's bubble, readied off the main thread before the store
    /// applies it. Nil when the bubble is not the message's own text (empty,
    /// unsent, a link card, a poll or audio): those build in place.
    public static func live(_ message: ConversationMessage, meID: String?) -> ConversationBubbleInputs? {
        guard !message.text.isEmpty, message.linkPreview == nil, message.poll == nil,
              message.audioAttachment == nil, !message.isUnsent else { return nil }
        return ConversationBubbleInputs(message: message, outgoing: message.senderID == meID, meID: meID, linkSplit: nil)
    }
}
