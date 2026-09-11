import Foundation

extension CloudVMState {
    static func == (lhs: CloudVMState, rhs: CloudVMState) -> Bool {
        lhs.hasSameModeledContent(as: rhs) && lhs.document == rhs.document
    }

    /// Clients and live terminal titles and dimensions are observations, not
    /// revisioned resources (client.list and public_terminal_snapshot). Keep
    /// them in exports without treating inspection or resize as a conflict.
    func hasSameRevisionedContent(as other: CloudVMState) -> Bool {
        hasSameModeledContent(as: other, includingLiveTerminalMetadata: false)
            && document.values.filter { $0.key != "clients" } == other.document.values.filter { $0.key != "clients" }
            && document.collections.filter { $0.key != "clients" && $0.key != "terminals" }
                == other.document.collections.filter { $0.key != "clients" && $0.key != "terminals" }
            && hasSameTerminalDocument(as: other)
    }

    private var revisionedTerminals: [CloudVMTerminalState] {
        terminals.map {
            var terminal = $0
            terminal.title = ""
            terminal.cols = nil
            terminal.rows = nil
            return terminal
        }
    }

    private func hasSameModeledContent(as other: CloudVMState, includingLiveTerminalMetadata: Bool = true) -> Bool {
        let left = includingLiveTerminalMetadata ? terminals : revisionedTerminals
        let right = includingLiveTerminalMetadata ? other.terminals : other.revisionedTerminals
        return machine == other.machine
            && cursor == other.cursor
            && workspaces == other.workspaces
            && screens == other.screens
            && panes == other.panes
            && tabs == other.tabs
            && left == right
            && browsers == other.browsers
            && agents == other.agents
    }

    /// Identity, launch fields, and unknown fields remain strict. Only the PTY
    /// title and dimensions are live; unchanged rows use their byte cache.
    private func hasSameTerminalDocument(as other: CloudVMState) -> Bool {
        guard let left = document.collections["terminals"] else {
            return other.document.collections["terminals"] == nil
        }
        guard let right = other.document.collections["terminals"], left.order == right.order else { return false }
        for id in left.order {
            guard let a = left.rows[id], let b = right.rows[id] else { return false }
            if a == b { continue }
            guard var lhs = try? JSONSerialization.jsonObject(with: a) as? [String: Any],
                  var rhs = try? JSONSerialization.jsonObject(with: b) as? [String: Any] else { return false }
            for key in ["title", "cols", "rows"] { lhs[key] = nil; rhs[key] = nil }
            guard let lhsData = try? JSONSerialization.data(withJSONObject: lhs, options: [.sortedKeys]),
                  let rhsData = try? JSONSerialization.data(withJSONObject: rhs, options: [.sortedKeys]),
                  lhsData == rhsData else { return false }
        }
        return true
    }
}
