/// The kinds of stable handle refs the v2 protocol mints for app objects
/// (was `TerminalController.V2HandleKind`).
///
/// Refs are rendered as `<kind.rawValue>:<ordinal>` (e.g. `workspace:3`).
public enum ControlHandleKind: String, CaseIterable, Sendable {
    /// A main window.
    case window
    /// A workspace (tab).
    case workspace
    /// A workspace group.
    case workspaceGroup = "workspace_group"
    /// A top-level workstream (drill-in container).
    case workstream
    /// A split pane.
    case pane
    /// A terminal/browser surface.
    case surface
}
