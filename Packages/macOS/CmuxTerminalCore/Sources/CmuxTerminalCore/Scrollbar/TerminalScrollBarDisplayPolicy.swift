/// Resolves visual scrollbar visibility without changing terminal grid layout.
public struct TerminalScrollBarDisplayPolicy: Sendable {
    /// Creates a stateless display policy.
    public init() {}

    /// Returns whether the scrollbar should be visually apparent right now.
    ///
    /// - Parameters:
    ///   - allowedBySettings: Whether terminal scrollbar settings allow a scrollbar.
    ///   - scrollerStyle: The style that lays out the terminal scroll view.
    ///   - hasScrollback: Whether the terminal has scrollback, or `nil` before
    ///     Ghostty publishes its first scrollbar state.
    ///   - preference: The user's macOS scrollbar visibility preference.
    ///   - isPointerOverScrollbar: Whether the pointer is over the scrollbar.
    ///   - isLiveScrolling: Whether a scroll gesture is active.
    /// - Returns: `true` when the scrollbar should be visually apparent.
    public func shouldDisplay(
        allowedBySettings: Bool,
        scrollerStyle: TerminalScrollerStyle,
        hasScrollback: Bool?,
        preference: TerminalScrollBarDisplayPreference,
        isPointerOverScrollbar: Bool,
        isLiveScrolling: Bool
    ) -> Bool {
        let presence = TerminalScrollBarPresencePolicy()
        guard presence.isPresent(
            allowedBySettings: allowedBySettings,
            scrollerStyle: scrollerStyle,
            hasScrollback: hasScrollback
        ) else {
            return false
        }

        // Overlay scrollers own their transient presentation through AppKit.
        guard scrollerStyle == .legacy else { return true }
        switch preference {
        case .always:
            return true
        case .automatic:
            return isPointerOverScrollbar || isLiveScrolling
        case .whenScrolling:
            return isLiveScrolling
        }
    }
}
