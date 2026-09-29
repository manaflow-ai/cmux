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

    /// `shutdown-daemon end_terminals` on the subscribed control socket gets
    /// its reply while the same connection keeps sending requests (as a
    /// store resync would) during the handoff. cmux-tui d1aa608 closed the
    /// connection on such a request, before the shutdown reply.
    @Test func endTerminalsShutdownRepliesOnTheSubscribedSocket() async throws {
        let binary = try #require(RealBinary.url)
        let id = UUID().uuidString.prefix(8).lowercased()
        let root = URL(fileURLWithPath: "/tmp/cnd-bt-\(id)")
        defer { try? FileManager.default.removeItem(at: root) }
        let base = ProcessInfo.processInfo.environment
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: "cnd-bt-\(id)", stateDirectory: root.appendingPathComponent("state")),
            environment: { LoginEnvironment.daemonEnvironment(login: nil, base: base, overrides: [:]) })
        let ensured = try await launcher.ensure()
        // A fixed endpoint: after the daemon exits, reconnecting fails
        // instead of `server ensure` starting a new daemon.
        let connection = DaemonConnection(endpointProvider: { ensured.endpoint })
        let identity = try await connection.start()
        let store = await DaemonStore()
        let storeTask = Task { await store.run(connection: connection) }
        defer { storeTask.cancel() }
        let workspace = try await connection.createWorkspace(name: "subscribed")
        for _ in 0..<3 {
            _ = try await connection.createTerminal(in: workspace.key, cwd: root.path, size: CellSize(cols: 80, rows: 24))
        }
        let hosts = TerminalHosts.of(daemon: identity.pid)
        #expect(hosts.count == 3)

        let shutdown = Task {
            try await connection.request(ShutdownDaemonRequest(pid: identity.pid, generation: identity.generation, endTerminals: true),
                                         timeout: DaemonConnection.endTerminalsTimeout)
        }
        // Keep requests arriving on the same socket until the reply, without
        // waiting for each (the daemon answers a connection in order, so an
        // awaited request would queue behind the shutdown). Some land while
        // the hosts end; their own outcome does not matter.
        let chatter = Task {
            while !Task.isCancelled {
                Task { _ = try? await connection.listWorkspaces() }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        let reply = await shutdown.result
        chatter.cancel()
        await connection.close()
        if case .failure = reply {
            // Leave nothing running: end the daemon on a fresh socket.
            _ = try? await connection.shutdownDaemon(endTerminals: true)
        }
        let accepted = try reply.get()
        #expect(accepted.accepted == true)
        #expect(accepted.endedTerminals == 3)
        #expect(await TerminalHosts.awaitExit(hosts).isEmpty, "terminal hosts outlived shutdown-daemon end_terminals")
        #expect(await TerminalHosts.awaitExit([identity.pid]).isEmpty, "the daemon outlived shutdown-daemon")
    }
}
