#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

extension NSCursor {
    /// The name of a standard cursor this one is (`debug.cursor`: a real-pointer journey checks which cursor the app set
    /// where the pointer is, for example the resize cursor at a divider's new place after it moved). "other" for a custom
    /// one. macOS 15's frame-resize cursors may be new objects per call: they are also matched by image size and hot spot.
    public var debugName: String {
        var named: [(String, NSCursor)] = [
            ("arrow", .arrow), ("iBeam", .iBeam), ("pointingHand", .pointingHand), ("crosshair", .crosshair),
            ("openHand", .openHand), ("closedHand", .closedHand), ("resizeLeftRight", .resizeLeftRight),
            ("resizeUpDown", .resizeUpDown), ("operationNotAllowed", .operationNotAllowed),
        ]
        if #available(macOS 15, *) { named += [("columnResize", .columnResize), ("rowResize", .rowResize)] }
        if let hit = named.first(where: { $0.1 === self || $0.1 == self }) { return hit.0 }
        return named.first { $0.1.hotSpot == hotSpot && $0.1.image.size == image.size
            && $0.1.image.tiffRepresentation == image.tiffRepresentation }?.0 ?? "other"
    }
}
#endif
