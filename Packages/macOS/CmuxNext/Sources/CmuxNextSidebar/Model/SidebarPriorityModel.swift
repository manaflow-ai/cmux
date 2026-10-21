import CmuxNextDesign

/// Priority projection accessors live beside the model to keep the main model file at its size cap.
extension SidebarModel {
    /// Whether actionable workspace states are projected ahead of idle rows.
    /// Manual order is retained for rows with the same priority.
    public var priorityOrdering: Bool { DesignSettings.shared.attention.movesToTop }

    /// The compact high-signal projection for an Agent Priority view.
    public var priorityItems: [SidebarPriorityItem] { SidebarPriority().items(allWorkspaces) }
}
