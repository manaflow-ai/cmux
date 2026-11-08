/// Every configurable shortcut must make an explicit Dock-routing decision.
/// The exhaustive switch intentionally has no `default`: adding a new action
/// fails compilation until its ownership is classified.
enum DockShortcutRoutingDisposition {
    /// The action mutates or navigates a surface tree and must check the
    /// focused Dock before using the main TabManager.
    case dockScoped
    /// The action already resolves its target from the event's first
    /// responder or focused panel, which includes Dock-owned panels.
    case focusResolved
    /// The action intentionally targets app, window, workspace, sidebar, or
    /// Canvas state rather than either surface tree.
    case mainContainer
}
