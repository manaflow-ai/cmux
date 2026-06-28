/// A neutral, `Sendable` projection of one configured new-workspace
/// context-menu item, fed to
/// ``AppMenuCoordinator/planNewWorkspaceContextMenu(items:)``. The app-side
/// witness maps each resolved `CmuxResolvedConfigContextMenuItem` onto one of
/// these before the ordering/separator-collapse decision runs, so the concrete
/// `CmuxButtonIcon` render, the `@objc` action, and `String(localized:)` title
/// resolution stay app-side and the package never touches app types.
///
/// `title`/`tooltip`/`iconSourcePath` are the already-resolved display values;
/// `actionIndex` is the witness's stable handle back to the resolved action
/// (its position in the configured list), used after planning to materialize
/// the icon, `representedObject`, and `target`/`action` for the live
/// `NSMenuItem`.
public enum NewWorkspaceContextMenuItemInput: Sendable, Equatable {
    /// A configured separator.
    case separator

    /// A configured action item.
    case action(title: String, tooltip: String?, iconSourcePath: String?, actionIndex: Int)
}
