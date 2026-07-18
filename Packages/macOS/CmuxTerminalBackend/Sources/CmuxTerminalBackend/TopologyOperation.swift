/// The committed structural operation described by a topology delta.
public enum TopologyOperation: String, Codable, CaseIterable, Sendable {
    /// A workspace was created.
    case workspaceCreated = "workspace-created"

    /// A screen was created.
    case screenCreated = "screen-created"

    /// A pane was split into a new layout branch.
    case paneSplit = "pane-split"

    /// A surface was attached to a pane.
    case surfaceAttached = "surface-attached"

    /// A surface runtime was atomically replaced under the same stable UUID.
    case surfaceReplaced = "surface-replaced"

    /// A surface was closed.
    case surfaceClosed = "surface-closed"

    /// A pane was closed.
    case paneClosed = "pane-closed"

    /// A screen was closed.
    case screenClosed = "screen-closed"

    /// A workspace was closed.
    case workspaceClosed = "workspace-closed"

    /// A workspace name changed.
    case workspaceRenamed = "workspace-renamed"

    /// A screen name changed.
    case screenRenamed = "screen-renamed"

    /// A pane name changed.
    case paneRenamed = "pane-renamed"

    /// A surface name changed.
    case surfaceRenamed = "surface-renamed"

    /// A split ratio changed.
    case splitRatioChanged = "split-ratio-changed"

    /// Two panes exchanged positions.
    case panesSwapped = "panes-swapped"

    /// A complete layout was applied.
    case layoutApplied = "layout-applied"

    /// A tab moved between positions or panes.
    case tabMoved = "tab-moved"

    /// A workspace moved within the canonical ordering.
    case workspaceMoved = "workspace-moved"
}
