public import Foundation
import CmuxNextHomeModel

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
    /// The narrowest list with names: MessagesLab's `compactBelow` (180) plus the 8 pt inset. Between the strip and this
    /// the list shows no width, as Messages' avatar strip (the user, 2026-11-24: a wide strip looked weird; "do what
    /// apple does and shift to the smaller/narrower size"): a width there snaps to one or the other.
    public static let fullMinimum: CGFloat = 188

    /// The narrowest the transcript beside the list gets while the list can still shrink: about
    /// 30 characters of a bubble. Below it the list drops to its avatar-only minimum first, so a
    /// narrow Home column never wraps its bubbles one word per line (dogfood 2026-10-19).
    public static let transcriptMinimum: CGFloat = 280

    /// `width` kept between `minimum` and the smaller of half of `window` and what leaves the
    /// transcript ``transcriptMinimum`` (a window too narrow for both keeps the list's minimum). A width under
    /// ``fullMinimum`` is the strip (`minimum`).
    public static func clamp(_ width: CGFloat, window: CGFloat, minimum: CGFloat = minimum, fullMinimum: CGFloat = fullMinimum,
                             transcriptMinimum: CGFloat = transcriptMinimum) -> CGFloat {
        let request = ClampRequest(width: width, window: window, minimum: minimum, fullMinimum: fullMinimum, transcriptMinimum: transcriptMinimum)
        return CGFloat(HomeInboxRules().call("width_clamp", request, fallback: Double(minimum)))
    }

    /// Where a divider drag to `proposed` puts the list, from the pointer alone (the old snap read the list's width too and
    /// flipped between the two mid-drag): the full list follows the pointer from ``fullMinimum`` to `widest`; under it the
    /// list snaps to the strip or the narrowest full list, whichever is nearer; 0 once the pointer is half way into the
    /// strip, as Finder's sidebar (the user, 2026-11-24: "it's okay to remove the sidebar at a certain point"). Back past
    /// that point in the same drag, the list is back. A window with no room for the full list keeps the strip.
    public static func drag(_ proposed: CGFloat, minimum: CGFloat = minimum, fullMinimum: CGFloat = fullMinimum, widest: CGFloat) -> CGFloat {
        let request = DragRequest(proposed: proposed, widest: widest, minimum: minimum, fullMinimum: fullMinimum)
        return CGFloat(HomeInboxRules().call("width_drag", request, fallback: Double(minimum)))
    }

    /// The narrowest Home column that shows the list at its minimum and the transcript at its own.
    public static func columnMinimum(listMinimum: CGFloat = minimum, divider: CGFloat = 1) -> CGFloat {
        let request = ColumnRequest(listMinimum: listMinimum, divider: divider)
        return CGFloat(HomeInboxRules().call("width_column_minimum", request, fallback: Double(listMinimum + divider + transcriptMinimum)))
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

private nonisolated struct ClampRequest: Encodable {
    var width: Double
    var window: Double
    var minimum: Double
    var fullMinimum: Double
    var transcriptMinimum: Double
}

private nonisolated struct DragRequest: Encodable {
    var proposed: Double
    var widest: Double
    var minimum: Double
    var fullMinimum: Double
}

private nonisolated struct ColumnRequest: Encodable {
    var listMinimum: Double
    var divider: Double
}
