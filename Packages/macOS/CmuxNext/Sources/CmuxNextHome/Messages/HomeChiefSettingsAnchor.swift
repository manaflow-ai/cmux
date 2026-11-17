public import AppKit
public import CmuxNextSettings

/// The box the Chief's settings open under: the page's name pill, which the page reports with each
/// click. It draws nothing and takes no click (the pill under it is the page's).
public final class HomeChiefSettingsAnchor: NSView {
    override public func hitTest(_ point: NSPoint) -> NSView? { nil }
    override public func isAccessibilityElement() -> Bool { false }

    /// The page's box `rect` (top-left origin, page points) in `owner`'s coordinates.
    public static func frame(of rect: CGRect, in owner: NSView) -> CGRect {
        let flipped = owner.isFlipped ? rect : CGRect(x: rect.minX, y: owner.bounds.height - rect.maxY, width: rect.width, height: rect.height)
        return flipped.integral
    }

    /// A box a page sent (`{x, y, width, height}`, page points), each side kept within 1...4096; nil
    /// when a field is missing.
    public static func box(_ value: JSONValue?) -> CGRect? {
        let box = value?.objectValue
        let number = { (key: String) in box?[key]?.doubleValue }
        guard let x = number("x"), let y = number("y"), let width = number("width"), let height = number("height") else { return nil }
        return CGRect(x: x, y: y, width: max(1, min(width, 4096)), height: max(1, min(height, 4096)))
    }
}
