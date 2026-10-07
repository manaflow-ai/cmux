import CmuxMobileWire

/// The snapshot state of `workspace:<host>` (workspace.schema.json `workspace:state`),
/// projected from the daemon's tree. The daemon is the owner; this is a value.
public struct MobileWorkspaceState: Hashable, Sendable, Codable {
    public var host: String
    public var workspaces: [MobileWorkspace]

    public init(host: String, workspaces: [MobileWorkspace]) {
        self.host = host
        self.workspaces = workspaces
    }

    public func workspace(_ id: String) -> MobileWorkspace? {
        workspaces.first { $0.id == id }
    }

    public func tab(_ id: String) -> (workspace: MobileWorkspace, pane: MobilePane, tab: MobileTab)? {
        for workspace in workspaces {
            for pane in workspace.panes {
                if let tab = pane.tabs.first(where: { $0.id == id }) { return (workspace, pane, tab) }
            }
        }
        return nil
    }

    /// The tab that shows terminal `id` (the scope check for terminal channels).
    public func tab(showingTerminal id: String) -> MobileTab? {
        for workspace in workspaces {
            for pane in workspace.panes {
                if let tab = pane.tabs.first(where: { $0.terminal == id }) { return tab }
            }
        }
        return nil
    }

    public var jsonValue: JSONValue {
        get throws { try JSONValue(encoding: self) }
    }
}
