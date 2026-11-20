import CoreGraphics

/// When the transcript's system scroll edge effects should be live.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationScrollEdgePolicy {
    /// Whether transcript content lies under the bottom bar band (the
    /// composer, and the keyboard below it). At rest on the newest message
    /// nothing does, and the soft pocket there draws nothing; a live pocket
    /// still makes Core Animation redraw most of the screen whenever any
    /// row animates (a typing indicator, a text effect), so it rests hidden.
    /// Half a point absorbs layout rounding at rest.
    public static func contentUnderBottomBar(contentHeight: CGFloat, offsetY: CGFloat, viewportHeight: CGFloat, bottomInset: CGFloat) -> Bool {
        contentHeight - offsetY > viewportHeight - bottomInset + 0.5
    }
}
