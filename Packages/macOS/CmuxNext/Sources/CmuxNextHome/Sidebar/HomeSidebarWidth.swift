public import Foundation

/// The Home sidebar's width: between the list's minimum (MessagesLab's
/// compact, avatar-only list) and half the window, the list's preferred width
/// to start, kept per window. The column model's
/// width (the docked column, `column.update`) takes this value over when the
/// daemon owns the column.
public struct HomeSidebarWidth: Sendable {
    /// MessagesLab's `SidebarController.minimumWidth` and `preferredWidth`
    /// (HomeSidebarView reads them from the list; these match v1).
    public static let minimum: CGFloat = 76
    public static let standard: CGFloat = 320

    /// `width` kept between `minimum` and half of `window` (a window
    /// narrower than twice the minimum keeps the minimum).
    public static func clamp(_ width: CGFloat, window: CGFloat, minimum: CGFloat = minimum) -> CGFloat {
        max(minimum, min(width, window / 2))
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

    private static func key(_ window: String) -> String { "cmux.home.sidebarWidth.\(window)" }
}
