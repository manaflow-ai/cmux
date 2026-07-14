enum TerminalPortalPresentation: Equatable {
    /// This host no longer represents the panel's model-owned pane.
    case detached
    /// The host still represents the pane, but the model says it is not rendered.
    case hidden
    /// A workspace handoff may preserve and lower an existing binding, but cannot acquire one.
    case retained(zPriority: Int)
    /// The model currently authorizes this host to present the surface.
    case visible(isActive: Bool, zPriority: Int)
}
