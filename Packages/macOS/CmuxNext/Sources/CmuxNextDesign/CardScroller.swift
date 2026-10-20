public import AppKit

/// The one scroller of every scrollable card: hover cards, the update card's popover and any
/// floating card that scrolls (2026-10-20: "a super-thin scrollbar", one shared style).
///
/// A ``knobThickness``-wide rounded knob at the trailing edge, on no track, in the label color at
/// low contrast. It is an overlay scroller, so AppKit hides it at rest and shows it while the card
/// scrolls; the fade is AppKit's own and Reduce Motion stills it. Give a card's scroll view this
/// scroller with ``SystemScrollers/followAsCard(_:)``; never style a card scroller by hand.
///
/// ```swift
/// scrollView.hasVerticalScroller = true
/// SystemScrollers.followAsCard(scrollView)
/// ```
public final class CardScroller: NSScroller {
    /// The drawn knob's width, in points.
    public static let knobThickness: CGFloat = 3
    /// The scroller's width (its hit area): the knob plus a little room on each side.
    public static let width: CGFloat = 7

    override public class var isCompatibleWithOverlayScrollers: Bool { true }

    override public class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat {
        width
    }

    /// The knob drawn inside AppKit's knob slot `rect`: ``knobThickness`` wide, against the trailing edge.
    public func knobRect(for rect: CGRect) -> CGRect {
        CGRect(x: rect.maxX - Self.knobThickness - 2, y: rect.minY + 2,
               width: Self.knobThickness, height: max(0, rect.height - 4))
    }

    override public func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}

    override public func drawKnob() {
        let rect = knobRect(for: rect(for: .knob))
        guard rect.height > 0 else { return }
        NSColor.labelColor.withAlphaComponent(0.32).setFill()
        NSBezierPath(roundedRect: rect, xRadius: Self.knobThickness / 2, yRadius: Self.knobThickness / 2).fill()
    }
}
