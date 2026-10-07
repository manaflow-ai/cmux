import CmuxMobileWire

/// The owner events that turn one projected state into the next (a0-rpc.md
/// 5.2). Pure: same inputs, same events.
///
/// - workspace added, or its metadata or pane/tab shape changed: `workspace.upsert` (whole record);
/// - workspace gone: `workspace.remove`;
/// - a tab's title, kind, terminal or url changed in place: `workspace.tab.upsert`;
/// - only a tab's status or unread changed: `workspace.status.set`.
public struct WorkspaceDiff: Sendable {
    public let changes: [WorkspaceChange]

    public init(from old: MobileWorkspaceState, to new: MobileWorkspaceState) {
        var changes: [WorkspaceChange] = []
        let oldByID = Dictionary(old.workspaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newIDs = Set(new.workspaces.map(\.id))
        for workspace in old.workspaces where !newIDs.contains(workspace.id) {
            changes.append(WorkspaceChange(op: "workspace.remove", params: .object(["workspace": .string(workspace.id)])))
        }
        for workspace in new.workspaces {
            guard let before = oldByID[workspace.id] else {
                changes.append(Self.upsert(workspace))
                continue
            }
            if before.shape != workspace.shape || before.name != workspace.name || before.color != workspace.color
                || before.pinned != workspace.pinned || before.order != workspace.order {
                changes.append(Self.upsert(workspace))
                continue
            }
            for (oldPane, newPane) in zip(before.panes, workspace.panes) {
                for (index, (oldTab, newTab)) in zip(oldPane.tabs, newPane.tabs).enumerated() where oldTab != newTab {
                    if oldTab.arrangement != newTab.arrangement {
                        changes.append(WorkspaceChange(op: "workspace.tab.upsert", params: .object([
                            "workspace": .string(workspace.id),
                            "pane": .string(newPane.id),
                            "index": .int(Int64(index)),
                            "tab": (try? JSONValue(encoding: newTab)) ?? .null,
                        ])))
                    } else {
                        changes.append(WorkspaceChange(op: "workspace.status.set", params: .object([
                            "tab": .string(newTab.id),
                            "status": .string((newTab.status ?? .idle).rawValue),
                            "unread": .int(Int64(newTab.unread ?? 0)),
                        ])))
                    }
                }
            }
        }
        self.changes = changes
    }

    private static func upsert(_ workspace: MobileWorkspace) -> WorkspaceChange {
        WorkspaceChange(op: "workspace.upsert", params: .object(["workspace": (try? JSONValue(encoding: workspace)) ?? .null]))
    }
}
