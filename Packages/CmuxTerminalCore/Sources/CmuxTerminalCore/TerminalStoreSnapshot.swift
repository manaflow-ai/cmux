public import Foundation

/// The persisted snapshot of the terminal store: hosts, workspaces, and the current selection.
public struct TerminalStoreSnapshot: Codable, Equatable, Sendable {
    /// The snapshot schema version.
    public var version = 1
    /// The configured hosts.
    public var hosts: [TerminalHost]
    /// The known workspaces.
    public var workspaces: [TerminalWorkspace]
    /// The currently selected workspace, if any.
    public var selectedWorkspaceID: TerminalWorkspace.ID?

    /// Creates a snapshot.
    /// - Parameters:
    ///   - version: The schema version (defaults to `1`).
    ///   - hosts: The configured hosts.
    ///   - workspaces: The known workspaces.
    ///   - selectedWorkspaceID: The selected workspace, if any.
    public init(
        version: Int = 1,
        hosts: [TerminalHost],
        workspaces: [TerminalWorkspace],
        selectedWorkspaceID: TerminalWorkspace.ID? = nil
    ) {
        self.version = version
        self.hosts = hosts
        self.workspaces = workspaces
        self.selectedWorkspaceID = selectedWorkspaceID
    }

    /// An empty snapshot with no hosts, workspaces, or selection.
    public static func empty() -> Self {
        Self(
            hosts: [],
            workspaces: [],
            selectedWorkspaceID: nil
        )
    }

    /// A seed snapshot containing a single default Mac Mini host and no workspaces.
    public static func seed() -> Self {
        Self(
            hosts: [
                TerminalHost(
                    name: String(
                        localized: "terminal.seed.mac_mini",
                        defaultValue: "Mac Mini"
                    ),
                    hostname: "cmux-macmini",
                    username: "cmux",
                    symbolName: "desktopcomputer",
                    palette: .mint,
                    sortIndex: 0
                )
            ],
            workspaces: [],
            selectedWorkspaceID: nil
        )
    }
}
