/// Stable entity identifiers affected by one topology transaction.
public struct TopologyTargets: Codable, Equatable, Sendable {
    /// The workspaces affected by the transaction.
    public let workspaces: [WorkspaceID]

    /// The screens affected by the transaction.
    public let screens: [ScreenID]

    /// The panes affected by the transaction.
    public let panes: [PaneID]

    /// The surfaces affected by the transaction.
    public let surfaces: [SurfaceID]

    /// Creates a duplicate-free set of topology targets.
    ///
    /// - Parameters:
    ///   - workspaces: The affected workspaces.
    ///   - screens: The affected screens.
    ///   - panes: The affected panes.
    ///   - surfaces: The affected surfaces.
    /// - Throws: ``BackendProtocolError/invalidTopology(_:)`` when any list contains a duplicate.
    public init(
        workspaces: [WorkspaceID] = [],
        screens: [ScreenID] = [],
        panes: [PaneID] = [],
        surfaces: [SurfaceID] = []
    ) throws {
        self.workspaces = workspaces
        self.screens = screens
        self.panes = panes
        self.surfaces = surfaces
        try validate()
    }

    /// Decodes and validates topology targets.
    ///
    /// Missing target lists decode as empty lists.
    ///
    /// - Parameter decoder: The decoder containing the target lists.
    /// - Throws: A decoding error or ``BackendProtocolError/invalidTopology(_:)`` for duplicates.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        workspaces = try container.decodeIfPresent([WorkspaceID].self, forKey: .workspaces) ?? []
        screens = try container.decodeIfPresent([ScreenID].self, forKey: .screens) ?? []
        panes = try container.decodeIfPresent([PaneID].self, forKey: .panes) ?? []
        surfaces = try container.decodeIfPresent([SurfaceID].self, forKey: .surfaces) ?? []
        try validate()
    }

    private func validate() throws {
        guard Set(workspaces).count == workspaces.count,
              Set(screens).count == screens.count,
              Set(panes).count == panes.count,
              Set(surfaces).count == surfaces.count
        else {
            throw BackendProtocolError.invalidTopology("duplicate delta target")
        }
    }
}
