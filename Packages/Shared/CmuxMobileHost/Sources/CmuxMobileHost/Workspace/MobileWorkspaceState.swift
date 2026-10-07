import CmuxMobileWire

/// The snapshot state of `workspace:<host>` (workspace.schema.json `workspace:state`),
/// projected from the daemon's tree. The daemon is the owner; this is a value.
public struct MobileWorkspaceState: Hashable, Sendable, Codable {
    public var host: String
    public var workspaces: [MobileWorkspace]
    /// The host's sidebar groups in order, including empty ones (E3); nil
    /// when the store has none to report.
    public var groups: [MobileWorkspaceGroup]?

    public init(host: String, workspaces: [MobileWorkspace], groups: [MobileWorkspaceGroup]? = nil) {
        self.host = host
        self.workspaces = workspaces
        self.groups = groups
    }

    /// Group `id` as the tree knows it: a listed group or one a workspace is filed in.
    public func group(_ id: String) -> MobileWorkspaceGroup? {
        groups?.first { $0.id == id } ?? workspaces.lazy.compactMap(\.group).first { $0.id == id }
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

    /// The state with every tab's preview sanitized (`MobilePreview`).
    public var sanitized: MobileWorkspaceState {
        var copy = self
        for w in copy.workspaces.indices {
            for p in copy.workspaces[w].panes.indices {
                for t in copy.workspaces[w].panes[p].tabs.indices {
                    copy.workspaces[w].panes[p].tabs[t].preview = MobilePreview(copy.workspaces[w].panes[p].tabs[t].preview).text
                }
            }
        }
        return copy
    }

    public var jsonValue: JSONValue {
        get throws { try JSONValue(encoding: self) }
    }
}
