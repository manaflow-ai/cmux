#if DEBUG || CMUX_BENCH_HOOKS
public import AppKit

extension NSEvent {
    /// A pixel scroll at `base`, a point in `window`'s base coordinates, addressed to `window` like the window server
    /// addresses a real one (`debug.mouse` scrolls: the layout's window or a Chromium page window). `phase` (`began`,
    /// `changed`, `ended`) makes it a trackpad gesture event: continuous (precise deltas) with that scroll phase (R99
    /// swipes). `flags` are the modifier keys held (NSEvent's flag bits are CGEvent's).
    public static func syntheticScroll(atBase base: NSPoint, in window: NSWindow, dx: Double, dy: Double, phase: String? = nil,
                                       flags: NSEvent.ModifierFlags = []) -> NSEvent? {
        guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
                               wheel1: Int32(dy.rounded()), wheel2: Int32(dx.rounded()), wheel3: 0) else { return nil }
        cg.flags = CGEventFlags(rawValue: UInt64(flags.rawValue))
        if let phase, let value = ["began": 1, "changed": 2, "ended": 4][phase] {
            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: Int64(value))
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: dx)
            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis1, value: dy)
        }
        let screen = window.convertPoint(toScreen: base)
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        cg.location = CGPoint(x: screen.x, y: primaryHeight - screen.y)
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointer, value: Int64(window.windowNumber))
        cg.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent, value: Int64(window.windowNumber))
        return NSEvent(cgEvent: cg)
    }
}
#endif
