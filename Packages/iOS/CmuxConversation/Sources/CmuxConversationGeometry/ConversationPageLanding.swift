import CoreGraphics

/// When a landed page of older messages waits before it is applied.
///
/// A page landing keeps the reader's place by writing the content offset
/// (the anchor bubble stays where it was on screen). That write holds under
/// a finger dragging the content, which moves the offset by the finger's
/// motion, and under a fling. It does not hold while the scroll indicator
/// is scrubbed: UIKit sets the offset from the thumb's place on every move,
/// so the restored offset was undone and the rows jumped by the page's
/// height (phone, iOS 26.4: two pages landed at offset -592 with the thumb
/// dragged past the top; content grew 6271 and 4793 pt, the offset moved
/// 3 pt). The scrub reports tracking and decelerating together for its
/// whole length (36 frames there); a finger catching a fling reports both
/// for a few frames, which only delays a page that lands then.
///
/// A finger holding the transcript past its top waits too: that is where
/// the scrub ends, and where the spinner is all the reader sees. The page
/// lands as the finger moves back or lifts, the bounce back included.
// lint:allow namespace-type -- vendored CmuxConversation snapshot
public enum ConversationPageLanding {
    public static func waits(isTracking: Bool, isDecelerating: Bool, offsetY: CGFloat, topInset: CGFloat) -> Bool {
        guard isTracking else { return false }
        return isDecelerating || offsetY < -topInset - 0.5
    }
}
