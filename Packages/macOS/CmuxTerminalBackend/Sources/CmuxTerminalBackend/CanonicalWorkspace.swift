/// One canonical workspace containing one or more screens.
public struct CanonicalWorkspace: Codable, Equatable, Sendable {
    /// The daemon-local numeric workspace identifier.
    public let id: UInt64

    /// The stable workspace identifier used across daemon restarts.
    public let uuid: WorkspaceID

    /// The canonical workspace name.
    public let name: String

    /// The canonical screens in workspace order.
    public let screens: [CanonicalScreen]

    /// Creates a canonical workspace.
    ///
    /// - Parameters:
    ///   - id: The daemon-local numeric workspace identifier.
    ///   - uuid: The stable workspace identifier.
    ///   - name: The canonical workspace name.
    ///   - screens: The canonical screens in workspace order.
    public init(
        id: UInt64,
        uuid: WorkspaceID,
        name: String,
        screens: [CanonicalScreen]
    ) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.screens = screens
    }
}
