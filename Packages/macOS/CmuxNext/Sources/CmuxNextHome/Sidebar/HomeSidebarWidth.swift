public import Foundation

/// The Home sidebar's width: between the list's minimum (MessagesLab's
/// compact, avatar-only list) and half the window, the list's preferred width
/// to start, kept per window. The column model's
/// width (the docked column, `column.update`) takes this value over when the
/// daemon owns the column. It also keeps whether the list shows at all (``listShown``).
public struct HomeSidebarWidth: Sendable {
    /// MessagesLab's `SidebarController.minimumWidth` and `preferredWidth` (92 and 320) plus the
    /// panel's 8 pt inset from the column's left (`HomeSidebarView.panelInset`): HomeSidebarView
    /// reads them from the list.
    public static let minimum: CGFloat = 100
    public static let standard: CGFloat = 328
    /// The narrowest full list (names and previews): Messages' on macOS 26 is 318 pt, measured at 2x in the
    /// user's recording (2026-11-24: "lets jus copy how apple does it"), plus the 8 pt inset. Messages shows
    /// no width between its 92 pt avatar strip and this: a narrower width snaps to one or the other.
    public static let fullMinimum: CGFloat = 326

    /// The narrowest the transcript beside the list gets while the list can still shrink: about
    /// 30 characters of a bubble. Below it the list drops to its avatar-only minimum first, so a
    /// narrow Home column never wraps its bubbles one word per line (dogfood 2026-10-19).
    public static let transcriptMinimum: CGFloat = 280

    /// `width` kept between `minimum` and the smaller of half of `window` and what leaves the
    /// transcript ``transcriptMinimum`` (a window too narrow for both keeps the list's minimum). A width
    /// under ``fullMinimum`` is the avatar strip (`minimum`), as in Messages: no list between the two.
    public static func clamp(_ width: CGFloat, window: CGFloat, minimum: CGFloat = minimum,
                             fullMinimum: CGFloat = fullMinimum, transcriptMinimum: CGFloat = transcriptMinimum) -> CGFloat {
        let fit = max(minimum, min(width, window / 2, window - transcriptMinimum))
        return fit < fullMinimum ? minimum : fit
    }

    /// How far past the edge the pointer goes before the list snaps to its other width: Messages' 17 pt both ways
    /// (macOS 26, measured on the user's Mac 2026-11-24: a drag of 16.4 pt from the full list's minimum held, 18.3 pt
    /// snapped to the strip; 15.4 pt from the strip held, 17.4 pt snapped to the full list).
    public static let snapResistance: CGFloat = 17

    /// Where a divider drag to `proposed` lands while the list is `current` wide: the full list follows the pointer
    /// down to ``fullMinimum``, holds there, and snaps to the strip (`minimum`) once the pointer is ``snapResistance``
    /// under it; the strip holds until the pointer is ``snapResistance`` past its edge, then snaps to the full list.
    public static func snap(_ proposed: CGFloat, from current: CGFloat, minimum: CGFloat = minimum,
                            fullMinimum: CGFloat = fullMinimum, resistance: CGFloat = snapResistance) -> CGFloat {
        if current < fullMinimum { return proposed > minimum + resistance ? max(proposed, fullMinimum) : minimum }
        return proposed < fullMinimum - resistance ? minimum : max(proposed, fullMinimum)
    }

    /// The narrowest Home column that shows the list at its minimum and the transcript at its own.
    public static func columnMinimum(listMinimum: CGFloat = minimum, divider: CGFloat = 1) -> CGFloat {
        listMinimum + divider + transcriptMinimum
    }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// The width saved for `window`, or nil for the standard width.
    public func width(window: String) -> CGFloat? {
        let value = defaults.double(forKey: Self.key(window))
        return value > 0 ? CGFloat(value) : nil
    }

    public func save(_ width: CGFloat, window: String) {
        defaults.set(Double(width), forKey: Self.key(window))
    }

    /// Back to the standard width (the divider's double-click).
    public func reset(window: String) {
        defaults.removeObject(forKey: Self.key(window))
    }

    /// Whether the conversation list shows beside the Chief's chat (its Chats button). Off until the person shows it:
    /// the Chief replaces Home (the person, 2026-11-20), so its chat fills the page by default. One choice on this Mac,
    /// not per window, so a new window opens the way the person last left it.
    public var listShown: Bool {
        get { defaults.bool(forKey: Self.listShownKey) }
        nonmutating set { defaults.set(newValue, forKey: Self.listShownKey) }
    }

    static let listShownKey = "cmux.home.chatListShown"

    private static func key(_ window: String) -> String { "cmux.home.sidebarWidth.\(window)" }
}
