import AppKit
@testable import CmuxNextDesign
import Testing
import CmuxNextDesignTokens

/// Lawrence 2026-10-19: "For hover on tab card there is a gap in between ... such that there is no
/// gap in between." A card at rest touches its target: no empty band for the pointer to cross
/// between a tab and its card, at any display scale and for a target on a fractional point.
/// A sub-pixel overlap is allowed (the touching edge snaps toward the target); a gap is not.
@MainActor @Suite(.serialized) struct HoverCardFlushTests {
    private static func parent() -> NSWindow {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 200, y: 200, width: 700, height: 500), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.orderFrontRegardless()
        return window
    }

    private static func body() -> NSView {
        let body = NSView()
        body.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            body.widthAnchor.constraint(equalToConstant: 240.3),
            body.heightAnchor.constraint(equalToConstant: 90.7),
        ])
        return body
    }

    /// The card's rest frame for `placement` at `anchor` (Reduce Motion: no slide in flight).
    private static func cardFrame(_ placement: HoverCardPlacement, anchor: (NSWindow) -> CGRect) -> (card: CGRect, anchor: CGRect, scale: CGFloat) {
        Motion.reduceMotionOverride = true
        defer { Motion.reduceMotionOverride = nil }
        let parent = parent()
        let panel = HoverCardPanel()
        defer {
            panel.orderOut(nil)
            parent.close()
        }
        let target = anchor(parent)
        panel.present(body: body(), anchor: target, placement: placement, parent: parent, themeAnchor: nil,
                      sliding: false, applyTheme: {})
        return (panel.cardFrame, target, parent.backingScaleFactor)
    }

    /// A tab-sized anchor near the parent's top, offset by a fraction of a point.
    private static func tab(fraction: CGFloat) -> (NSWindow) -> CGRect {
        { parent in CGRect(x: parent.frame.minX + 40.25, y: parent.frame.maxY - 36 + fraction, width: 180, height: 28) }
    }

    @Test(arguments: [0, 0.25, 0.5, 0.75] as [CGFloat])
    func aCardBelowATabTouchesItsBottomEdge(fraction: CGFloat) {
        let r = Self.cardFrame(.below, anchor: Self.tab(fraction: fraction))
        // Positive: empty space between tab and card; negative: the card overlaps the tab.
        let gap = r.anchor.minY - r.card.maxY
        #expect(gap <= 0.001, "a \(gap) pt gap between the tab and its card")
        #expect(gap > -1 / r.scale - 0.001, "the card overlaps its tab by \(-gap) pt, more than a pixel")
    }

    @Test(arguments: [0, 0.25, 0.5, 0.75] as [CGFloat])
    func aCardAboveABottomTabTouchesItsTopEdge(fraction: CGFloat) {
        let r = Self.cardFrame(.above) { parent in
            CGRect(x: parent.frame.minX + 40.25, y: parent.frame.minY + 8 + fraction, width: 180, height: 28)
        }
        let gap = r.card.minY - r.anchor.maxY
        #expect(gap <= 0.001, "a \(gap) pt gap between the tab and its card")
        #expect(gap > -1 / r.scale - 0.001, "the card overlaps its tab by \(-gap) pt, more than a pixel")
    }

    /// A `.beside` card stands one device pixel off its target (the row cards' gap, Lawrence 2026-10-21).
    @Test(arguments: [0, 0.5] as [CGFloat])
    func aCardBesideARowStandsOffItsTrailingEdge(fraction: CGFloat) {
        let r = Self.cardFrame(.beside) { parent in
            CGRect(x: parent.frame.minX + 10, y: parent.frame.maxY - 100, width: 200 + fraction, height: 40)
        }
        let off = r.card.minX - r.anchor.maxX - HoverCardEscapeGeometry.edgeGap(scale: r.scale)
        #expect(off <= 0.001, "the card sits \(off) pt past the row's gap")
        #expect(off > -1 / r.scale - 0.001, "the card sits \(-off) pt inside the row's gap, more than a pixel")
        #expect(abs(r.card.maxY - r.anchor.maxY) < 0.5, "the card is not top-aligned with its row")
    }

    /// The touching edge holds at every display scale, not only the test machine's.
    @Test(arguments: [1, 2, 3] as [CGFloat])
    func theTouchingEdgeSnapsTowardTheTargetAtEveryScale(scale: CGFloat) {
        let size = CGSize(width: 240, height: 91)
        let anchor = CGRect(x: 40.3, y: 600.3, width: 180, height: 28.1)
        let below = HoverCardPanel.origin(for: .below, anchor: anchor, size: size, scale: scale)
        let belowGap = anchor.minY - (below.y + size.height)
        #expect(belowGap <= 0.001 && belowGap > -1 / scale - 0.001, "below at @\(scale)x: \(belowGap) pt")
        let above = HoverCardPanel.origin(for: .above, anchor: anchor, size: size, scale: scale)
        let aboveGap = above.y - anchor.maxY
        #expect(aboveGap <= 0.001 && aboveGap > -1 / scale - 0.001, "above at @\(scale)x: \(aboveGap) pt")
        let beside = HoverCardPanel.origin(for: .beside, anchor: anchor, size: size, scale: scale)
        let besideGap = beside.x - anchor.maxX - HoverCardEscapeGeometry.edgeGap(scale: scale)
        #expect(besideGap <= 0.001 && besideGap > -1 / scale - 0.001, "beside at @\(scale)x: \(besideGap) pt")
    }
}
