import AppKit
import CmuxNextDesign

extension ProfileBarView {
    /// One slot per space, then the "+" slot, always right after the last space (Leo 2026-11-03).
    /// A scrolled strip pins the "+" to the bar's trailing edge; the dots it covers are not drawn.
    func slotRects() -> [NSRect] {
        let strip = strip
        let slots = strip.slots.map { NSRect(x: $0.x, y: 0, width: $0.width, height: bounds.height) }
        guard !plusRidesContent else {
            return slots + [NSRect(x: strip.plus.x, y: 0, width: strip.plus.width, height: bounds.height)]
        }
        let leading = min(bounds.width, max(0, leadingInset ?? SidebarStyle.horizontalInset))
        let side = min(CGFloat(strip.plus.width), max(0, bounds.width - leading))
        let x = min(max(leading, strip.plus.x), bounds.width - side)
        return slots + [NSRect(x: x, y: 0, width: side, height: bounds.height)]
    }

    /// The "+" shows at rest, not only on hover (Leo 2026-11-03: "I don't want hovering near the row to
    /// also just immediately turn it to a plus"); only a "+" scrolled off the bar is not drawn.
    var plusIsDrawn: Bool {
        slotRects().last.map(plusIsDrawn(in:)) ?? false
    }

    func plusIsDrawn(in plus: NSRect) -> Bool {
        plus.width > 0 && bounds.contains(NSPoint(x: plus.midX, y: plus.midY))
    }

    /// The x range a dot must sit in whole to be drawn: from the strip's leading inset to the bar's trailing edge,
    /// or to the drawn "+" (#32981). A scrolled strip slides dots past both ends; a dot cut by either edge is not drawn.
    func visibleDotRange(plus: NSRect) -> ClosedRange<CGFloat> {
        let leading = min(bounds.width, max(0, leadingInset ?? SidebarStyle.horizontalInset))
        let showsPlus = plusIsDrawn(in: plus)
        let end = showsPlus ? min(bounds.maxX, plus.minX) : bounds.maxX
        return leading...max(leading, end)
    }

    /// Resolve once per draw, not once per profile: long space strips stay linear.
    /// Only a dot fully inside `visibleDotRange` is drawn; nothing else (a click, a hover, a shortcut hint, a drag
    /// layer) acts on a dot that is not drawn (#32981).
    var drawnDotIndices: [Int] { drawnDotIndices(in: slotRects()) }

    func drawnDotIndices(in rects: [NSRect]) -> [Int] {
        let range = visibleDotRange(plus: rects[model.profiles.count])
        return model.profiles.indices.filter {
            dotIsDrawn(in: rects[$0], range: range)
        }
    }

    func dotIsDrawn(in slot: NSRect, range: ClosedRange<CGFloat>) -> Bool {
        slot.width > 0 && slot.minY < bounds.maxY && slot.maxY > bounds.minY
            && slot.minX >= range.lowerBound - 0.5 && slot.maxX <= range.upperBound + 0.5
    }

    func dotIsDrawn(at index: Int) -> Bool {
        guard model.profiles.indices.contains(index) else { return false }
        let rects = slotRects()
        return dotIsDrawn(in: rects[index], range: visibleDotRange(plus: rects[model.profiles.count]))
    }
    var drawnDotCount: Int { drawnDotIndices.count }

    /// The visible + owns its slot; a dot that is not drawn (scrolled under the +, past the bar's edge or into the
    /// leading inset) is not pressable anywhere, not even by the sliver of its slot that shows (#32981).
    func interactionIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let rects = slotRects()
        if let plus = rects.last, plusIsDrawn(in: plus), plus.contains(point) { return Self.plusIndex }
        return drawnDotIndices(in: rects).first { rects[$0].contains(point) }
    }
}
