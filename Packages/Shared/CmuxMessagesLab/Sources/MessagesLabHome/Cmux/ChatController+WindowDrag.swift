import AppKit

// cmux: the floating Chief's own window moves from a press on the chat's empty space (user 2026-11-09: "it should be
// raycast-type floating window"). The transcript is one view (its document) that takes every press for its
// selection, links, attachments and cards, so it says point by point where nothing of the chat is.
extension ChatController {
    /// Whether a press at `p` (host coordinates) lands on nothing the chat acts on: no message (its text selects; a
    /// card, an attachment or a link is part of one), approval, draft chip, status line, long-text band, message box
    /// or header strip, with no thread view or tapback picker open.
    func isEmptySpace(at p: CGPoint) -> Bool {
        guard let demo, picker == nil, !demo.threadOpen, p.y > host.titlebarHeight else { return false }
        if demo.compose.fieldRect.insetBy(dx: 0, dy: -2).contains(p) || demo.compose.chip(at: p) != nil { return false }
        if demo.statusLineFrame()?.contains(p) == true || demo.longTextBandHit(p) { return false }
        return demo.hit(p) == nil && approvalTarget(at: p) == nil && linkURL(at: p) == nil
    }

    /// Whether a press at `windowPoint` on `hit` moves the window: on the transcript's document (which takes every
    /// press), only on empty space; nil when `hit` is another view (its own rule answers).
    func pressMovesWindow(atWindowPoint windowPoint: CGPoint, hit: NSView) -> Bool? {
        guard hit is TranscriptDocumentView || hit is TranscriptClipView, hit.isDescendant(of: host) else { return nil }
        return isEmptySpace(at: host.convert(windowPoint, from: nil))
    }
}
