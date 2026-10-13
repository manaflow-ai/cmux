/// Compile-time switches for conversation features that are built but not
/// offered yet. Flip a switch to bring its entry points back; the
/// implementation stays in place either way.
public enum ConversationFeatures {
    /// Custom emoji tapbacks (Messages' "Add custom emoji reaction"): the
    /// smiley circle and its picker, and the recent-emoji slots after the six
    /// classic tapbacks, on iOS and macOS. Off for now. Custom emoji
    /// reactions that arrive from the backend still render as badges, and an
    /// emoji I already gave still shows in the bar so I can remove it.
    public static let customEmojiReactions = false
}
