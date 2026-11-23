import CoreGraphics

/// Who owns a vertical drag that starts inside a composer's text.
///
/// Leo, 2026-11-23: "when i try to scroll in the composer in ios it ... swipes
/// the entire thing down instead of scrolling through the composer." The chat
/// composer's hosts took the keyboard down on any downward drag over the
/// composer, so pulling a long draft back up to read its start dismissed the
/// keyboard instead.
///
/// The rule, as in the ChatGPT and Claude iOS apps: a drag that starts on a
/// draft taller than its field, scrolled away from its top, is the text's own
/// scroll for the whole touch; nothing around the field may treat it as a
/// "swipe down to dismiss". A drag on a draft that fits, or one already at its
/// top, is free for the host (the swipe-down-to-collapse gesture).
public enum ComposerTextDragClaim {
    /// Whether a drag that starts now belongs to the text's own scroll.
    /// - Parameters:
    ///   - contentHeight: the text's laid-out height (`contentSize.height`).
    ///   - visibleHeight: the field's height (`bounds.height`).
    ///   - offsetFromTop: how far the text is scrolled below its top
    ///     (`contentOffset.y + adjustedContentInset.top`).
    public static func textOwnsDrag(contentHeight: CGFloat, visibleHeight: CGFloat, offsetFromTop: CGFloat) -> Bool {
        let overflows = contentHeight > visibleHeight + 0.5
        return overflows && offsetFromTop > 0.5
    }
}

#if os(iOS)
import UIKit

/// The touch now on a composer's text, as `ComposerReturnTextView` saw it begin.
/// A host's swipe-down-to-dismiss asks `isHeld` before it acts.
@MainActor
public enum ComposerTextDragHold {
    /// True from a touch-down on a scrolled long draft until that touch (or the
    /// text's scroll it became) ends.
    public private(set) static var isHeld = false

    static func touchBegan(textOwnsDrag: Bool) { isHeld = textOwnsDrag }
    static func touchEnded() { isHeld = false }
}
#endif
