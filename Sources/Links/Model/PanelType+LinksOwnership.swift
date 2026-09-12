extension PanelType {
    /// Whether a panel may leave the workspace that owns its backing model.
    var allowsCrossContainerTransfer: Bool {
        self != .links
    }
}
