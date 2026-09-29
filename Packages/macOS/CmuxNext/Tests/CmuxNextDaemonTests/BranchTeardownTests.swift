import Foundation
import Testing
@testable import CmuxNextDaemon

/// Test teardown must leave no terminal host (one PTY each; the Mac allows
/// 511). Closing a tab only detaches its terminal, so teardown has to end
/// terminals no tab shows.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the pinned branch cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchTeardownTests {
    /// A closed tab's terminal has no tab to enumerate, so a teardown that
    /// closes only the terminals it sees leaks its host and PTY.
    @Test func teardownEndsDetachedTerminals() async throws {
        let h = try await BranchDaemonHarness.start()
        let hosts: Set<Int32>
        do {
            let (_, pane, _) = try await h.workspaceWithTerminal("teardown")
            let second = try await h.connection.newTab(in: pane).surface
            try await h.connection.closeTab(second)
            hosts = TerminalHosts.of(daemon: h.identity.pid)
            #expect(hosts.count == 2, "expected the placed and the detached host, got \(hosts)")
        } catch {
            await h.stop()
            throw error
        }
        await h.stop()
        let leaked = await TerminalHosts.awaitExit(hosts)
        #expect(leaked.isEmpty, "terminal hosts outlived teardown: \(leaked)")
    }
}
