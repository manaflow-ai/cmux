/// When the floating sidebar card's window should exist at all.
///
/// The card is a second full sidebar list in its own child window. A docked,
/// visible sidebar can never show it, so it is not mounted there. It is
/// mounted whenever a card can appear: floating mode, or a hidden sidebar
/// with peek on (mounted ahead of the reveal, so the edge dwell and the
/// titlebar hover find it ready).
public enum SidebarPeekPanelMount {
    /// Whether the card's window is needed.
    ///
    /// - Parameters:
    ///   - sidebarVisible: Whether the sidebar is shown (docked or floating).
    ///   - presentationMode: The window's docked or floating mode.
    ///   - peekEnabled: Whether hover-reveal is on.
    ///   - peekPresenting: Whether a peek is currently showing the card.
    public static func isNeeded(
        sidebarVisible: Bool,
        presentationMode: SidebarPresentationMode,
        peekEnabled: Bool,
        peekPresenting: Bool
    ) -> Bool {
        let occupiesLayout = sidebarVisible && presentationMode == .docked
        guard !occupiesLayout else { return false }
        return sidebarVisible || peekEnabled || peekPresenting
    }
}
