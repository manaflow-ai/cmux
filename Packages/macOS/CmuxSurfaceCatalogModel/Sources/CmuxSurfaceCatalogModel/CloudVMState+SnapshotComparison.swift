import Foundation

extension CloudVMState {
    public static func == (lhs: CloudVMState, rhs: CloudVMState) -> Bool {
        lhs.hasSameModeledContent(as: rhs) && lhs.document == rhs.document
    }

    /// Clients and live terminal titles and dimensions are observations, not
    /// revisioned resources (client.list and public_terminal_snapshot). Keep
    /// them in exports without treating inspection or resize as a conflict.
    /// Compare resource rows by identity. Positional keys keep unkeyed arrays
    /// strict, and every unknown field inside a row remains part of equality.
    public func hasSameRevisionedContent(as other: CloudVMState) -> Bool {
        hasSameRevisionedModeledContent(as: other)
            && document.values.filter { $0.key != "clients" && $0.key != "session" }
                == other.document.values.filter { $0.key != "clients" && $0.key != "session" }
            && document.collections.filter { $0.key != "clients" && $0.key != "terminals" }
                .mapValues { $0.rows }
                == other.document.collections.filter { $0.key != "clients" && $0.key != "terminals" }
                .mapValues { $0.rows }
            && hasSameTerminalDocument(as: other)
    }

    /// Full snapshots sort resource collections for export, while deltas append
    /// newly discovered rows. Resource IDs and explicit indexes own identity and
    /// placement; transport arrival order must not invalidate the same revision.
    private func hasSameRevisionedModeledContent(as other: CloudVMState) -> Bool {
        machine == other.machine
            && cursor == other.cursor
            && Self.sameEntities(workspaces, other.workspaces, id: \.id)
            && Self.sameEntities(screens, other.screens, id: \.id)
            && Self.sameEntities(revisionedPanes, other.revisionedPanes, id: \.id)
            && Self.sameEntities(tabs, other.tabs, id: \.id)
            && Self.sameEntities(revisionedTerminals, other.revisionedTerminals, id: \.id)
            && Self.sameEntities(browsers, other.browsers, id: \.id)
            && agents.sorted(by: Self.agentPrecedes) == other.agents.sorted(by: Self.agentPrecedes)
    }

    private static func sameEntities<T: Equatable>(_ lhs: [T], _ rhs: [T], id: KeyPath<T, String>) -> Bool {
        lhs.sorted { $0[keyPath: id] < $1[keyPath: id] }
            == rhs.sorted { $0[keyPath: id] < $1[keyPath: id] }
    }

    private static func agentPrecedes(_ lhs: CloudVMAgentState, _ rhs: CloudVMAgentState) -> Bool {
        [lhs.id ?? "", lhs.terminalID, lhs.source ?? "", lhs.state]
            .lexicographicallyPrecedes([rhs.id ?? "", rhs.terminalID, rhs.source ?? "", rhs.state])
    }

    private var revisionedPanes: [CloudVMPaneState] {
        panes.map {
            var pane = $0
            pane.tabIDs.sort()
            return pane
        }
    }

    private var revisionedTerminals: [CloudVMTerminalState] {
        terminals.map {
            var terminal = $0
            terminal.title = ""
            terminal.cols = nil
            terminal.rows = nil
            terminal.tabIDs.sort()
            return terminal
        }
    }

    private func hasSameModeledContent(as other: CloudVMState) -> Bool {
        return machine == other.machine
            && cursor == other.cursor
            && workspaces == other.workspaces
            && screens == other.screens
            && panes == other.panes
            && tabs == other.tabs
            && terminals == other.terminals
            && browsers == other.browsers
            && agents == other.agents
    }

    /// Identity, launch fields, and unknown fields remain strict. Only the PTY
    /// title and dimensions are live; unchanged rows use their byte cache.
    private func hasSameTerminalDocument(as other: CloudVMState) -> Bool {
        guard let left = document.collections["terminals"] else {
            return other.document.collections["terminals"] == nil
        }
        guard let right = other.document.collections["terminals"], left.rows.count == right.rows.count else { return false }
        for (id, a) in left.rows {
            guard let b = right.rows[id] else { return false }
            if a == b { continue }
            guard var lhs = try? JSONSerialization.jsonObject(with: a) as? [String: Any],
                  var rhs = try? JSONSerialization.jsonObject(with: b) as? [String: Any] else { return false }
            for key in ["title", "cols", "rows"] { lhs[key] = nil; rhs[key] = nil }
            // Older daemon deltas omit lifecycle while preserving the durable
            // `running` bit. Full snapshots include the derived lifecycle name.
            // Compare the protocol meaning, not whether that optional spelling
            // was present in one representation.
            if lhs["lifecycle"] == nil, lhs["running"] != nil {
                lhs["lifecycle"] = (lhs["running"] as? Bool) == true ? "running" : "exited"
            }
            if rhs["lifecycle"] == nil, rhs["running"] != nil {
                rhs["lifecycle"] = (rhs["running"] as? Bool) == true ? "running" : "exited"
            }
            guard let lhsData = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
                  let rhsData = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]),
                  lhsData == rhsData else { return false }
        }
        return true
    }
}
