public import CoreGraphics
import Foundation

/// The bubble colours a person chose for one chat (Chat Colors…) or for every chat
/// (`home.bubbleColors.*`): each one nil keeps the bubble style's own colour.
///
/// A fill without a text colour gets a readable text colour picked for it
/// (``HomePalette/applying(_:)``); a text colour the person sets is kept as set.
///
/// ```swift
/// let colors = HomeBubbleColors(sent: HomeColor(hex: "#34C759"))
/// let palette = HomePalette.iMessageStyled(theme).applying(colors)
/// ```
public struct HomeBubbleColors: Hashable, Sendable, Codable {
    /// My bubbles' fill; nil keeps the style's (Messages' blue, or the theme's accent).
    public var sent: HomeColor?
    /// My bubbles' text; nil picks white or black, whichever reads on ``sent``.
    public var sentText: HomeColor?
    /// The other side's bubbles' fill; nil keeps the style's grey.
    public var received: HomeColor?
    /// The other side's text; nil keeps the style's, raised to 4.5:1 on ``received``.
    public var receivedText: HomeColor?

    /// - Parameters:
    ///   - sent: my bubbles' fill (nil: the style's).
    ///   - sentText: my bubbles' text (nil: picked to read on the fill).
    ///   - received: the other side's fill (nil: the style's).
    ///   - receivedText: the other side's text (nil: picked to read on the fill).
    public init(sent: HomeColor? = nil, sentText: HomeColor? = nil, received: HomeColor? = nil, receivedText: HomeColor? = nil) {
        self.sent = sent
        self.sentText = sentText
        self.received = received
        self.receivedText = receivedText
    }

    /// No colour is chosen: the bubble style draws as it does without one.
    public var isEmpty: Bool { sent == nil && sentText == nil && received == nil && receivedText == nil }

    /// Each colour this one leaves unset taken from `fallback` (a chat's colours over the default for every chat).
    /// - Parameter fallback: the colours used where this value has none.
    /// - Returns: the merged colours.
    public func over(_ fallback: HomeBubbleColors) -> HomeBubbleColors {
        HomeBubbleColors(sent: sent ?? fallback.sent, sentText: sentText ?? fallback.sentText,
                         received: received ?? fallback.received, receivedText: receivedText ?? fallback.receivedText)
    }
}
