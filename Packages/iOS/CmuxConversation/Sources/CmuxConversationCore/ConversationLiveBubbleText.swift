import Foundation

/// What a live message's text bubble is built from, readied off the main
/// thread before the store applies the message. These inputs must equal the
/// transcript row's own, or the row misses the shared bubble text cache and
/// rebuilds its text on the main thread.
public struct ConversationLiveBubbleText: Sendable, Hashable {
    public var text: String
    public var outgoing: Bool
    public var mentions: [ConversationMention]
    public var meID: String?
    public var runs: [ConversationTextRun]
    public var links: [ConversationTextLink]

    /// Nil for a message whose bubble is not its own plain text: empty,
    /// unsent, a link card, a poll or audio build their text in place.
    public init?(message: ConversationMessage, meID: String?) {
        guard !message.text.isEmpty, message.linkPreview == nil, message.poll == nil,
              message.audioAttachment == nil, !message.isUnsent else { return nil }
        text = message.text
        outgoing = message.senderID == meID
        mentions = message.mentions
        self.meID = meID
        runs = message.textRuns
        links = ConversationTextLink.bubbleLinks(message.links, bodyLength: message.text.utf16.count)
    }
}
