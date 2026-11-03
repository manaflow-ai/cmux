import Foundation

/// One item the data detectors found in a bubble's text: a link, phone number, address or date.
public struct ConversationDetectedItem: Sendable, Hashable {
    /// The item's UTF-16 range in the text, underlined in the bubble.
    public var range: NSRange
    /// What a tap opens (``ConversationDataDetection/actionURL(for:)``); nil: underlined only.
    public var url: URL?

    /// - Parameters:
    ///   - range: The item's UTF-16 range in the text.
    ///   - url: What a tap opens, or nil.
    public init(range: NSRange, url: URL?) {
        self.range = range
        self.url = url
    }
}
