/// Which top-level pane the sidebar is currently showing.
///
/// The main window's sidebar switches between the vertical workspace tabs and
/// the notifications list. This is the in-memory selection driving that switch;
/// its persisted counterpart is encoded separately by the session store.
public enum SidebarSelection: Equatable, Sendable {
    /// The vertical workspace tabs list.
    case tabs
    /// The notifications list.
    case notifications
}
