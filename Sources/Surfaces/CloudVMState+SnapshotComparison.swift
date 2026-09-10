import Foundation

extension CloudVMState {
    static func == (lhs: CloudVMState, rhs: CloudVMState) -> Bool {
        lhs.hasSameModeledContent(as: rhs) && lhs.document == rhs.document
    }

    /// Control connections and their monotonic ages are snapshot diagnostics,
    /// not revisioned resources (cmux-tui/spec/commands.md, client.list). Keep
    /// them in exports without treating each inspection as a graph conflict.
    func hasSameRevisionedContent(as other: CloudVMState) -> Bool {
        hasSameModeledContent(as: other)
            && document.values.filter { $0.key != "clients" } == other.document.values.filter { $0.key != "clients" }
            && document.collections.filter { $0.key != "clients" } == other.document.collections.filter { $0.key != "clients" }
    }

    private func hasSameModeledContent(as other: CloudVMState) -> Bool {
        machine == other.machine
            && cursor == other.cursor
            && workspaces == other.workspaces
            && screens == other.screens
            && panes == other.panes
            && tabs == other.tabs
            && terminals == other.terminals
            && browsers == other.browsers
            && agents == other.agents
    }
}
