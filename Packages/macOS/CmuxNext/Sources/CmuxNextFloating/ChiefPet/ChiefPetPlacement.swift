import AppKit

/// Where the Chief pet sits on each screen: the origin it was last dragged
/// to there, saved in user defaults by display, and always kept fully on
/// that screen's visible frame.
struct ChiefPetPlacement {
    static let key = "chiefPet.origins"
    /// Its first spot on a screen: the bottom right corner, this far in.
    static let inset: CGFloat = 24
    /// A press that moves less than this is a click, not a drag.
    static let dragSlop: CGFloat = 3

    let defaults: UserDefaults

    /// The origin saved on display `id`, if any.
    func origin(onDisplay id: String) -> CGPoint? {
        guard let saved = (defaults.dictionary(forKey: Self.key) as? [String: String])?[id] else { return nil }
        return NSPointFromString(saved)
    }

    func save(_ origin: CGPoint, onDisplay id: String) {
        var all = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        all[id] = NSStringFromPoint(origin)
        defaults.set(all, forKey: Self.key)
    }

    /// The pet's frame on a screen with `visible` frame: `saved` clamped
    /// inside it, else the bottom right corner `inset` in.
    static func frame(saved: CGPoint?, size: CGSize, in visible: CGRect) -> CGRect {
        let fallback = CGPoint(x: visible.maxX - inset - size.width, y: visible.minY + inset)
        return CGRect(origin: clamped(saved ?? fallback, size: size, in: visible), size: size)
    }

    /// `origin` moved the least needed for a `size` frame to sit inside `visible`.
    static func clamped(_ origin: CGPoint, size: CGSize, in visible: CGRect) -> CGPoint {
        let x = min(max(origin.x, visible.minX), visible.maxX - size.width)
        let y = min(max(origin.y, visible.minY), visible.maxY - size.height)
        return CGPoint(x: x.rounded(), y: y.rounded())
    }

    /// True once a press has moved far enough to be a drag.
    static func isDrag(from start: CGPoint, to point: CGPoint) -> Bool {
        hypot(point.x - start.x, point.y - start.y) >= dragSlop
    }

    /// A screen's key: its display id (`FloatingChatFrames.display`).
    static func display(_ screen: NSScreen) -> String {
        FloatingChatFrames.display(screen)
    }
}
