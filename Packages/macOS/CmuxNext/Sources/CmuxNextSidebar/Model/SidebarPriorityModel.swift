/// Priority projection accessors live beside the model to keep the main model file at its size cap.
extension SidebarModel {
    /// The compact high-signal projection for an Agent Priority view.
    public var priorityItems: [SidebarPriorityItem] { SidebarPriority().items(allWorkspaces) }
}
