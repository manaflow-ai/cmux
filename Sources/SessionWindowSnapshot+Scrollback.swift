extension SessionWindowSnapshot {
    /// Returns the frozen value at the fidelity requested by the current save.
    func respectingScrollbackInclusion(_ includeScrollback: Bool) -> SessionWindowSnapshot {
        guard !includeScrollback else { return self }

        var snapshot = self
        for workspaceIndex in snapshot.tabManager.workspaces.indices {
            for panelIndex in snapshot.tabManager.workspaces[workspaceIndex].panels.indices {
                snapshot.tabManager.workspaces[workspaceIndex]
                    .panels[panelIndex].terminal?.scrollback = nil
            }
            if var dock = snapshot.tabManager.workspaces[workspaceIndex].dock {
                Self.removeTerminalScrollback(from: &dock)
                snapshot.tabManager.workspaces[workspaceIndex].dock = dock
            }
        }
        if var dock = snapshot.dock {
            Self.removeTerminalScrollback(from: &dock)
            snapshot.dock = dock
        }
        return snapshot
    }

    private static func removeTerminalScrollback(
        from snapshot: inout SessionSplitContainerSnapshot
    ) {
        for panelIndex in snapshot.panels.indices {
            snapshot.panels[panelIndex].terminal?.scrollback = nil
        }
    }
}
