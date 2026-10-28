public import Foundation

/// Which theme applies each item (a terminal surface) has taken, so an apply reaches only what is
/// shown and a parked item catches up when it shows (I5, cx-8w027.12).
///
/// Not generic: a generic `ThemeApplyLedger<Item: AnyObject>` over an `NSMapTable<Item, NSNumber>`
/// crashes the Swift 6.3.3 (Xcode 26.6) optimizer in Release (EarlyPerfInliner on the deinit,
/// `isCallerAndCalleeLayoutConstraintsCompatible`). Keep the table's key type concrete.
public final class ThemeApplyLedger {
    private var revision = 0
    private let taken = NSMapTable<AnyObject, NSNumber>.weakToStrongObjects()

    public init() {}

    /// One apply.
    public func advance() { revision += 1 }

    /// Whether `item` should take the last apply now: it missed it, or it is `fresh` (its surface
    /// was just made or presented). Records it as current.
    public func take(_ item: AnyObject, fresh: Bool) -> Bool {
        guard fresh || (taken.object(forKey: item)?.intValue ?? -1) < revision else { return false }
        taken.setObject(NSNumber(value: revision), forKey: item)
        return true
    }
}
