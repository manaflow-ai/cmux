/// Publication phase for a pane geometry owned by layout.
extension TerminalPaneGeometry {
    /// Why the host considers this size publishable.
    public enum Phase: Equatable, Sendable {
        /// A window-edge or divider drag is in progress; every tick is visible.
        case interactive
        /// Layout has stopped changing; this is the pane's resting size.
        case settled
    }
}
