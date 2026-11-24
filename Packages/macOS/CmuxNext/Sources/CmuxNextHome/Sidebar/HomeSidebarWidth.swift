public import Foundation

/// The Home sidebar's width: between the list's minimum (MessagesLab's
/// compact, avatar-only list) and half the window, the list's preferred width
/// to start, kept per window. The column model's
/// width (the docked column, `column.update`) takes this value over when the
/// daemon owns the column. It also keeps whether the list shows at all (``listShown``).
public struct HomeSidebarWidth: Sendable {
    /// MessagesLab's `SidebarController.minimumWidth` and `preferredWidth`
    /// (HomeSidebarView reads them from the list; these match v1).
    public static let minimum: CGFloat = 76
    public static let standard: CGFloat = 320

    /// The narrowest the transcript beside the list gets while the list can still shrink: about
    /// 30 characters of a bubble. Below it the list drops to its avatar-only minimum first, so a
    /// narrow Home column never wraps its bubbles one word per line (dogfood 2026-10-19).
    public static let transcriptMinimum: CGFloat = 280

    /// `width` kept between `minimum` and the smaller of half of `window` and what leaves the
    /// transcript ``transcriptMinimum`` (a window too narrow for both keeps the list's minimum).
    public static func clamp(_ width: CGFloat, window: CGFloat, minimum: CGFloat = minimum,
                             transcriptMinimum: CGFloat = transcriptMinimum) -> CGFloat {
        max(minimum, min(width, window / 2, window - transcriptMinimum))
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

    /// Whether the conversation list shows beside the Chief's chat. On by default, as in Messages (#48467: the Chats
    /// button that folded it is gone; a new key, so a list folded with it shows again). One choice on this Mac, not
    /// per window.
    public var listShown: Bool {
        get { defaults.object(forKey: Self.listShownKey) as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: Self.listShownKey) }
    }

    /// Shown unless set (#48467: the conversation list beside the Chief's chat, as before f061b0e72c). A
    /// new key, so a list folded with the old Chats button, which is gone now, shows again.
    static let listShownKey = "cmux.home.chatListShown.2"

    private static func key(_ window: String) -> String { "cmux.home.sidebarWidth.\(window)" }
}
