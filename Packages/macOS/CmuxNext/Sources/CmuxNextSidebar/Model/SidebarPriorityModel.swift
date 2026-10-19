public import CmuxNextDesign

/// Priority projection accessors live beside the model to keep the main model file at its size cap.
extension SidebarModel {
    /// Whether actionable workspace states are projected ahead of idle rows.
    /// Manual order is retained for rows with the same priority.
    /// With the session tree on, only when this window or `sidebar.rowOrder` chose `.attention`.
    public var priorityOrdering: Bool {
        DesignSettings.shared.sidebarSections.movesRowsOnAttention(DesignSettings.shared.attention, window: rowOrder)
    }

    /// The order this window draws: its own choice, else the setting's.
    public var resolvedRowOrder: SidebarRowOrder { rowOrder ?? DesignSettings.shared.sidebarSections.rowOrder }

    /// The compact high-signal projection for an Agent Priority view.
    public var priorityItems: [SidebarPriorityItem] { SidebarPriority().items(allWorkspaces) }
}
