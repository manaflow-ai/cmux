extension GhosttyScrollbar {
    /// Whether the surface has scrollback above the current viewport.
    ///
    /// Embedded Ghostty exposes alternate-screen TUIs to the wrapper as a
    /// viewport with no additional scrollback (`total <= len`). Treating that
    /// as "no scrollback" lets the overlay scrollbar be suppressed so
    /// full-screen apps like nvim/htop do not pin it on top of the rightmost
    /// cell column.
    public var hasScrollback: Bool {
        total > len
    }

    /// Decides whether the terminal overlay scroller should be shown.
    ///
    /// The decision combines the settings gate the caller resolves app-side
    /// with the runtime scrollback geometry:
    ///
    /// - If the scroller is not allowed by settings, it is hidden.
    /// - If no scrollbar packet has arrived yet (`scrollbar == nil`), the
    ///   scroller stays visible. Ghostty reports scrollback asynchronously, so
    ///   keeping it visible until the first packet prevents restored/reattached
    ///   surfaces with existing scrollback from appearing broken.
    /// - Otherwise the scroller follows ``hasScrollback``.
    ///
    /// - Parameters:
    ///   - allowedBySettings: Whether the active scrollbar-visibility settings
    ///     permit showing the scroller. Resolved by the caller because it reads
    ///     app-level settings state.
    ///   - scrollbar: The latest scrollback geometry, or `nil` before the first
    ///     packet arrives.
    /// - Returns: `true` when the overlay scroller should be visible.
    public static func shouldShowScrollBar(
        allowedBySettings: Bool,
        scrollbar: GhosttyScrollbar?
    ) -> Bool {
        guard allowedBySettings else { return false }
        guard let scrollbar else { return true }
        return scrollbar.hasScrollback
    }
}
