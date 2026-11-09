public import Foundation

/// An agent's widget part (`widget` on the wire; plans/cmux-next/chat-widgets-DESIGN.md):
/// a Mac with the named app draws it natively from the app's `cmux.chat.widget/1` export
/// with ``props``; every other client shows ``fallback``.
public struct ChatWidget: Hashable, Sendable, Codable {
    /// The app id, `publisher/name` (`cmux/pr-card`).
    public var app: String
    /// The interface the app implements (`cmux.chat.widget/1`).
    public var widget: String
    /// The export's input, as the JSON text of an object (data only, at most 16 KiB).
    public var propsJSON: String
    /// Plain text every client without the renderer shows (Copy, VoiceOver, previews).
    public var fallback: String
    /// An optional `https` link (what builds from before widgets show).
    public var url: String?

    public init(app: String, widget: String = "cmux.chat.widget/1", propsJSON: String = "{}", fallback: String,
                url: String? = nil) {
        self.app = app
        self.widget = widget
        self.propsJSON = propsJSON
        self.fallback = fallback
        self.url = url
    }
}
