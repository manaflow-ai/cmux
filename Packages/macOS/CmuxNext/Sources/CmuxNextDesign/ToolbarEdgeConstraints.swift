public import AppKit
public import CmuxNextDesignTokens

/// The two constraint sets that place an omnibar row and the content beside
/// it at the top or at the bottom of a view (`browser.toolbarPosition`); one
/// set is active at a time.
///
/// ```swift
/// edge.top = [bar.topAnchor.constraint(equalTo: topAnchor), page.topAnchor.constraint(equalTo: bar.bottomAnchor)]
/// edge.bottom = [page.topAnchor.constraint(equalTo: topAnchor), bar.topAnchor.constraint(equalTo: page.bottomAnchor)]
/// edge.activate(.bottom)
/// ```
@MainActor
public final class ToolbarEdgeConstraints {
    /// The constraints active while the row is at the top.
    public var top: [NSLayoutConstraint] = []
    /// The constraints active while the row is at the bottom.
    public var bottom: [NSLayoutConstraint] = []

    /// Empty sets; fill ``top`` and ``bottom``, then ``activate(_:)``.
    public init() {}

    /// Ends the other set's constraints, then activates the set for `position`.
    /// - Parameter position: The edge the row sits on.
    public func activate(_ position: ToolbarPosition) {
        NSLayoutConstraint.deactivate(position == .top ? bottom : top)
        NSLayoutConstraint.activate(position == .top ? top : bottom)
    }
}
