/// The per-window route a recently-closed history entry takes when it is
/// reopened, as ``ClosedItemReopenRouting`` sees it. The package never inspects
/// the app-target `ClosedItemHistoryEntry`; the host translates each entry into
/// this value, carrying the opaque panel/workspace sub-entries the coordinator
/// threads straight back to the host's restore witnesses.
///
/// The coordinator owns the routing table (panel → `restoreClosedPanel`,
/// workspace → the host's `restoreClosedWorkspace`, window → no-op `false`); the
/// host only maps the concrete enum case to one of these so the package stays
/// free of the app entry type.
public enum ClosedItemReopenRoute<PanelEntry, WorkspaceEntry> {
    /// A closed terminal/browser panel; the coordinator restores it through its
    /// own ``ClosedItemReopenRouting/restoreClosedPanel(_:)`` focus-ordering flow.
    case panel(PanelEntry)
    /// A closed whole workspace; the coordinator forwards it to the host's
    /// `restoreClosedWorkspace` witness unchanged.
    case workspace(WorkspaceEntry)
    /// A closed window; never restorable from the per-window flow (legacy
    /// `case .window: return false`).
    case window
}
