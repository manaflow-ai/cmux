import AppKit
import CmuxNextDesign

extension ProfileBarView {
    /// One slot for a lone space: the dot at rest, + on hover, with no reserved empty neighbour.
    /// Multiple spaces keep the existing strip; its clipped trailing slot gives way to + on hover.
    func slotRects() -> [NSRect] {
        let leading = min(bounds.width, max(0, leadingInset ?? SidebarStyle.horizontalInset))
        let side = min(Metrics.roomDotSlot, max(0, bounds.width - leading))
        func clamped(_ x: CGFloat) -> NSRect {
            NSRect(x: min(max(leading, x), bounds.width - side), y: 0, width: side, height: bounds.height)
        }
        if model.profiles.count == 1 {
            let slot = clamped((centerX ?? bounds.midX) - side / 2)
            return [slot, slot]
        }
        let strip = strip
        let slots = strip.slots.map { NSRect(x: $0.x, y: 0, width: $0.width, height: bounds.height) }
        return slots + [clamped(strip.plus.x)]
    }

    var plusIsDrawn: Bool { isPointerInside || showsPlusWhenIdle }

    /// Resolve once per draw, not once per profile: long space strips stay linear.
    var drawnDotIndices: [Int] {
        guard showsDotsWhenIdle || isPointerInside else { return [] }
        let rects = slotRects(), plus = rects[model.profiles.count]
        return model.profiles.indices.filter {
            let slot = rects[$0]
            let overlapsPlus = slot.maxX > plus.minX && slot.minX < plus.maxX
            return slot.width > 0 && slot.intersects(bounds) && (!plusIsDrawn || !overlapsPlus)
        }
    }

    func dotIsDrawn(at index: Int) -> Bool { drawnDotIndices.contains(index) }
    var drawnDotCount: Int { drawnDotIndices.count }

    /// The visible + owns a shared slot. Looking up the dot first made + unclickable there.
    func interactionIndex(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        let rects = slotRects()
        if plusIsDrawn, let plus = rects.last, plus.contains(point) { return Self.plusIndex }
        return rects.dropLast().firstIndex { $0.contains(point) }
    }
}
