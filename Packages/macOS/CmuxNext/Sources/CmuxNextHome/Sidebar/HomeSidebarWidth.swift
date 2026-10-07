public import Foundation

/// The Home sidebar's width: between the sidebar's minimum and half the
/// window, Messages' 300 pt to start, kept per window. The column model's
/// width (the docked column, `column.update`) takes this value over when the
/// daemon owns the column.
public struct HomeSidebarWidth: Sendable {
    public static let minimum: CGFloat = 220
    public static let standard: CGFloat = 300

    /// Red stub.
    public static func clamp(_ width: CGFloat, window: CGFloat) -> CGFloat { width }

    /// Red stub: the pinned grid's columns at `width`.
    public static func gridColumns(width: CGFloat, tileWidth: CGFloat) -> Int { 3 }

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Red stub.
    public func width(window: String) -> CGFloat? { nil }

    /// Red stub.
    public func save(_ width: CGFloat, window: String) {}

    /// Red stub.
    public func reset(window: String) {}
}
