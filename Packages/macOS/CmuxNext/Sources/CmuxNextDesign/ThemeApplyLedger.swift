public import Foundation

/// Which theme applies each item (a terminal surface) has taken, so an apply reaches only what is
/// shown and a parked item catches up when it shows (I5, cx-8w027.12).
///
/// Each ``advance(forcing:)`` is one apply; a forcing one also re-applies surface configs (a
/// Ghostty config reload reset them). ``take(_:fresh:)`` says whether an item missed an apply and
/// whether it missed a forcing one, and records it as current.
public final class ThemeApplyLedger<Item: AnyObject> {
    private var revision = 0, forced = 0
    private let taken = NSMapTable<Item, NSNumber>.weakToStrongObjects()

    public init() {}

    /// One apply.
    public func advance(forcing: Bool) {
        revision += 1
        if forcing { forced = revision }
    }

    /// Nil when `item` already took the last apply; else whether it missed a forcing one. A `fresh`
    /// item (its surface was just made or presented) always takes the apply and is forced only for a
    /// forcing apply it missed since it was last seen; an item never seen missed them all.
    public func take(_ item: Item, fresh: Bool) -> Bool? {
        let seen = taken.object(forKey: item)?.intValue
        guard fresh || (seen ?? -1) < revision else { return nil }
        taken.setObject(NSNumber(value: revision), forKey: item)
        return (seen ?? (fresh ? .max : -1)) < forced
    }
}
