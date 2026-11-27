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
        let side = min(Metrics.roomDotSlot, max(0, bounds.width - leading))
        let x = min(max(leading, strip.plus.x), bounds.width - side)
        return slots + [NSRect(x: x, y: 0, width: side, height: bounds.height)]
    }

    /// The "+" shows at rest, not only on hover (Leo 2026-11-03: "I don't want hovering near the row to
    /// also just immediately turn it to a plus"); only a "+" scrolled off the bar is not drawn.
    var plusIsDrawn: Bool {
        guard let plus = slotRects().last else { return false }
        return plus.width > 0 && bounds.contains(NSPoint(x: plus.midX, y: plus.midY))
    }

    /// Resolve once per draw, not once per profile: long space strips stay linear.
    var drawnDotIndices: [Int] {
        let rects = slotRects(), plus = rects[model.profiles.count], showsPlus = plusIsDrawn
        return model.profiles.indices.filter {
            let slot = rects[$0]
            let overlapsPlus = slot.maxX > plus.minX + 0.5 && slot.minX < plus.maxX - 0.5
            return slot.width > 0 && slot.intersects(bounds) && (!showsPlus || !overlapsPlus)
        }
    }

    func dotIsDrawn(at index: Int) -> Bool { drawnDotIndices.contains(index) }
    var drawnDotCount: Int { drawnDotIndices.count }

    /// The visible + owns its slot; a dot scrolled under it is not pressable there.
    func interactionIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let rects = slotRects()
        if plusIsDrawn, let plus = rects.last, plus.contains(point) { return Self.plusIndex }
        return rects.dropLast().firstIndex { $0.contains(point) }
    }
}
