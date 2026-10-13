import CoreGraphics

/// When the transcript's system scroll edge effects should be live.
public enum ConversationScrollEdgePolicy {
    /// Whether transcript content lies under the bottom bar band (the
    /// composer, and the keyboard below it).
    public static func contentUnderBottomBar(contentHeight: CGFloat, offsetY: CGFloat, viewportHeight: CGFloat, bottomInset: CGFloat) -> Bool {
        true
    }
}
