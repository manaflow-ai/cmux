/// Owns the rule that decides whether a terminal scrollbar is present.
///
/// Presence is a layout input for legacy scrollbars. Keeping that presence
/// independent of the terminal's own scrollback prevents the grid width from
/// changing when a replay temporarily empties history.
public struct TerminalScrollBarPresencePolicy: Sendable {
    /// Creates a stateless scrollbar presence policy.
    public init() {}

    /// Returns whether the terminal scrollbar should remain present.
    ///
    /// - Parameters:
    ///   - allowedBySettings: Whether terminal scrollbar settings allow a scrollbar.
    ///   - scrollerStyle: The style that lays out the terminal scroll view.
    ///   - hasScrollback: Whether the terminal has scrollback, or `nil` before
    ///     Ghostty publishes its first scrollbar state.
    /// - Returns: `true` when the scroll view should keep its scrollbar present.
    public func isPresent(
        allowedBySettings: Bool,
        scrollerStyle: TerminalScrollerStyle,
        hasScrollback: Bool?
    ) -> Bool {
        guard allowedBySettings else { return false }
        // A legacy scroller reserves layout space, so its presence must not
        // follow scrollback or the terminal grid will change width.
        if scrollerStyle == .legacy { return true }
        // Ghostty reports scrollback asynchronously. Keep the overlay present
        // until the first packet so restored surfaces do not appear broken.
        return hasScrollback ?? true
    }
}
