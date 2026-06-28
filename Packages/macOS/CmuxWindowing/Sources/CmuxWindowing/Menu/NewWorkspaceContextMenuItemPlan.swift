/// One item of the ordered new-workspace context-menu plan returned by
/// ``AppMenuCoordinator/planNewWorkspaceContextMenu(items:)``: the configured
/// items after leading/duplicate-separator suppression and trailing-separator
/// trimming. The app-side witness materializes each plan item, in order, into
/// an `NSMenuItem` (or `NSMenuItem.separator()`), recovering the resolved
/// action via `actionIndex` for the icon render, `representedObject`, and
/// `target`/`action` wiring.
public enum NewWorkspaceContextMenuItemPlan: Sendable, Equatable {
    /// A separator to materialize as `NSMenuItem.separator()`.
    case separator

    /// An action item; `actionIndex` is the witness's handle back to the
    /// resolved action it was projected from.
    case action(title: String, tooltip: String?, iconSourcePath: String?, actionIndex: Int)
}
