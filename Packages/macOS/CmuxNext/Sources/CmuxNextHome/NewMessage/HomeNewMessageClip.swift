public import AppKit

/// The New Message page's content area: flipped, so the conversation's header can sit
/// above its top edge, and clipped, so it never draws over the To: field.
public final class HomeNewMessageClip: NSView {
    nonisolated override public var isFlipped: Bool { true }
}
