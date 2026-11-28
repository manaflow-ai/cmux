import Foundation

/// Who owns a vertical drag that starts on the chat composer's text.
///
/// Leo, 2026-11-23: "when i try to scroll in the composer in ios it ... swipes the entire thing
/// down instead of scrolling through the composer." A drag that starts on a draft taller than its
/// field, scrolled below its top, is the text's own scroll for the whole touch; the hosts'
/// swipe-down-to-dismiss leaves it alone. On a draft that fits, or one already at its top, the
/// swipe lowers the keyboard, as in Messages and the ChatGPT and Claude iPhone apps.
enum ChatDraftDragClaim {
    /// - Parameters:
    ///   - contentHeight: the text's laid-out height (`contentSize.height`).
    ///   - visibleHeight: the field's height (`bounds.height`).
    ///   - offsetFromTop: how far the text is scrolled below its top
    ///     (`contentOffset.y + adjustedContentInset.top`).
    static func textOwnsDrag(contentHeight: CGFloat, visibleHeight: CGFloat, offsetFromTop: CGFloat) -> Bool {
        contentHeight > visibleHeight + 0.5 && offsetFromTop > 0.5
    }
}
