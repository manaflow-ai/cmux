public import Foundation

/// The Home sidebar's width: between the sidebar's minimum and half the
/// window, Messages' 300 pt to start, kept per window. The column model's
/// width (the docked column, `column.update`) takes this value over when the
/// daemon owns the column.
public struct HomeSidebarWidth: Sendable {
    public static let minimum: CGFloat = 220
    public static let standard: CGFloat = 300

    /// `width` kept between the minimum and half of `window` (a window
    /// narrower than twice the minimum keeps the minimum).
    public static func clamp(_ width: CGFloat, window: CGFloat) -> CGFloat {
        max(minimum, min(width, window / 2))
    }

    /// The pinned grid's columns at `width`: as many tiles as fit, one to three.
    public static func gridColumns(width: CGFloat, tileWidth: CGFloat) -> Int {
        guard tileWidth > 0 else { return 1 }
        return max(1, min(3, Int(width / tileWidth)))
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
