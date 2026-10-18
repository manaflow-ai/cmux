public import Foundation

/// Which theme applies each item (a terminal surface) has taken, so an apply reaches only what is
/// shown and a parked item catches up when it shows (I5, cx-8w027.12).
public final class ThemeApplyLedger<Item: AnyObject> {
    private var revision = 0
    private let taken = NSMapTable<Item, NSNumber>.weakToStrongObjects()

    public init() {}

    /// One apply.
    public func advance() { revision += 1 }

    /// Whether `item` should take the last apply now: it missed it, or it is `fresh` (its surface
    /// was just made or presented). Records it as current.
    public func take(_ item: Item, fresh: Bool) -> Bool {
        guard fresh || (taken.object(forKey: item)?.intValue ?? -1) < revision else { return false }
        taken.setObject(NSNumber(value: revision), forKey: item)
        return true
    }
}
