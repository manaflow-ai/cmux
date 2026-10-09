/// Everything that can move the peek state machine.
///
/// Deliberately exhaustive and value-typed: the machine is pure, so every
/// interaction the panel supports has to arrive as one of these rather than as
/// a side effect somewhere in a view.
public enum SidebarPeekEvent: Sendable, Hashable {
    /// The pointer entered the reveal strip along the window's leading edge.
    case pointerEnteredEdge
    /// The pointer left the reveal strip.
    case pointerExitedEdge
    /// The dwell timer finished; the user rested at the edge long enough.
    case dwellElapsed
    /// The grace timer finished with no hold left to keep the panel open.
    case graceElapsed
    /// A hold was acquired (pointer entered the panel, a menu opened, a field
    /// took focus, a drag started).
    case holdAcquired(SidebarPeekHold)
    /// A hold was released.
    case holdReleased(SidebarPeekHold)
    /// A drag carrying content crossed the reveal strip.
    ///
    /// Distinct from a plain pointer entry because a drag skips dwell: someone
    /// dragging a file or a workspace toward a hidden sidebar has already
    /// declared intent, and making them hover through a delay while holding a
    /// drag is the worst version of this interaction.
    case dragEnteredEdge
    /// The user activated a workspace from the panel.
    case workspaceActivated
    /// The user pressed Escape.
    case escapePressed
    /// The sidebar was docked open, so peek has nothing left to do.
    case sidebarDocked
    /// The sidebar was collapsed, arming peek.
    case sidebarCollapsed
}
