@testable import CmuxNextApp
import CmuxNextDaemon
import Foundation
import Testing

/// Why an emptied workspace has no pane, from the daemon's terminal
/// registry: only a process end closes it; a lost terminal keeps it.
struct EmptiedWorkspaceCauseTests {
    private let key = WorkspaceKey(rawValue: "0b6c4a52-6d3f-4c55-9d53-8f1f4e0f1a02")

    private func terminal(_ id: String, workspace: String?, outcome: String?, at: UInt64 = 1) -> TerminalRegistryEntry {
        TerminalRegistryEntry(terminalID: id, workspaceKey: workspace, lifecycle: outcome == nil ? "running" : "exited",
                              exit: outcome.map { .init(outcomeKind: $0, exitedAtMs: at) })
    }

    @Test func processEndsCloseLostTerminalsKeep() {
        #expect(EmptiedWorkspaceCause.from([terminal("a", workspace: key.rawValue, outcome: "exit")], workspace: key) == .tabClosed)
        #expect(EmptiedWorkspaceCause.from([terminal("a", workspace: key.rawValue, outcome: "signal")], workspace: key) == .tabClosed)
        #expect(EmptiedWorkspaceCause.from([terminal("a", workspace: key.rawValue, outcome: "unknown")], workspace: key) == .terminalLost)
        // No ended terminal of this workspace: a client closed the tab.
        #expect(EmptiedWorkspaceCause.from([terminal("b", workspace: "other", outcome: "unknown")], workspace: key) == .tabClosed)
        #expect(EmptiedWorkspaceCause.from([], workspace: key) == .tabClosed)
    }

    @Test func theLatestEndDecides() {
        let terminals = [terminal("a", workspace: key.rawValue, outcome: "exit", at: 5),
                         terminal("b", workspace: key.rawValue, outcome: "unknown", at: 9)]
        #expect(EmptiedWorkspaceCause.from(terminals, workspace: key) == .terminalLost)
        let reversed = [terminal("a", workspace: key.rawValue, outcome: "unknown", at: 5),
                        terminal("b", workspace: key.rawValue, outcome: "exit", at: 9)]
        #expect(EmptiedWorkspaceCause.from(reversed, workspace: key) == .tabClosed)
    }

    @Test func registryDecodes() throws {
        let json = #"{"registry_id":"r","generation":"g","terminal_revision":3,"terminals":[{"terminal_id":"t1","workspace_key":"k","terminal_incarnation":null,"lifecycle":"exited","launch_spec":{},"exit":{"outcome":{"kind":"unknown","reason":"host-process-ended-before-adoption"},"exited_at_ms":7}},{"terminal_id":"t2","workspace_key":"k","lifecycle":"running","exit":null}]}"#
        let list = try JSONDecoder().decode(TerminalRegistryList.self, from: Data(json.utf8))
        #expect(list.terminals.map(\.exit?.outcomeKind) == ["unknown", nil])
        #expect(list.terminals.first?.exit?.exitedAtMs == 7)
    }

    /// The registry's own record shape (seen live on tag nxthm): `exited_at`
    /// is a decimal string. A shell's `exit` after an earlier lost terminal
    /// in the same workspace is a closed tab, not a lost terminal.
    @Test func registryExitTimesAreStringsAndTheLatestStillDecides() throws {
        let json = #"{"terminals":[{"terminal_id":"t1","workspace_key":"k","lifecycle":"exited","exit":{"exited_at":"1790821764905","outcome":{"kind":"unknown","reason":"terminal host ended without a durable exit sidecar"},"revision":"301"}},{"terminal_id":"t2","workspace_key":"k","lifecycle":"exited","exit":{"exited_at":"1790821779362","outcome":{"code":0,"kind":"exit"},"revision":"304"}}]}"#
        let list = try JSONDecoder().decode(TerminalRegistryList.self, from: Data(json.utf8))
        #expect(list.terminals.map(\.exit?.exitedAtMs) == [1_790_821_764_905, 1_790_821_779_362])
        #expect(EmptiedWorkspaceCause.from(list.terminals, workspace: WorkspaceKey(rawValue: "k")) == .tabClosed)
    }
}
