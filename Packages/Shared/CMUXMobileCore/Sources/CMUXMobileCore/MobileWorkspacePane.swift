/// A leaf pane in a mirrored Mac workspace layout.
public struct MobileWorkspacePane: Codable, Equatable, Identifiable, Sendable {
    /// The stable Bonsplit pane identifier.
    public var id: String
    /// The pane's unit-coordinate rectangle.
    public var frame: MobileWorkspacePaneFrame
    /// Tabs in the Mac's pane-local order.
    public var tabs: [MobileWorkspaceTab]

    /// Creates a mirrored leaf pane.
    /// - Parameters:
    ///   - id: The stable pane identifier.
    ///   - frame: The unit-coordinate pane frame.
    ///   - tabs: The pane-local ordered tabs.
    public init(id: String, frame: MobileWorkspacePaneFrame, tabs: [MobileWorkspaceTab]) {
        self.id = id
        self.frame = frame
        self.tabs = tabs
    }
}
