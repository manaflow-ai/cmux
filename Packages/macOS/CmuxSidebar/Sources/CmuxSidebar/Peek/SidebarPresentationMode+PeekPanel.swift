extension SidebarPresentationMode {
    /// Whether the floating sidebar card's window should exist in this mode.
    ///
    /// The card is a second full sidebar list in its own child window. A
    /// docked, visible sidebar can never show it, so it is not mounted there.
    /// It is mounted whenever a card can appear: floating mode, or a hidden
    /// sidebar with peek on (mounted ahead of the reveal, so the edge dwell
    /// and the titlebar hover find it ready).
    ///
    /// - Parameters:
    ///   - sidebarVisible: Whether the sidebar is shown (docked or floating).
    ///   - peekEnabled: Whether hover-reveal is on.
    ///   - peekPresenting: Whether a peek is currently showing the card.
    /// - Returns: True while a card can appear.
    public func needsPeekPanel(
        sidebarVisible: Bool,
        peekEnabled: Bool,
        peekPresenting: Bool
    ) -> Bool {
        let occupiesLayout = sidebarVisible && self == .docked
        guard !occupiesLayout else { return false }
        return sidebarVisible || peekEnabled || peekPresenting
    }
}
