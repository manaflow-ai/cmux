import Foundation
import Testing
@testable import CmuxNextDaemon

/// Quitting cmux (user decision 2026-09-30): Keep Sessions Running only
/// closes the app's connection, so the daemon and every terminal keep
/// running and a new connection finds the same terminals; End Sessions,
/// Keep Layout and End Everything end every terminal and stop the daemon,
/// and End Everything also deletes the workspaces.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the pinned branch cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct QuitSessionsTests {
    @Test func keepLeavesTheDaemonAndTerminalsForTheNextLaunch() async throws {
        let h = try await BranchDaemonHarness.start()
        do {
            let (_, _, surface) = try await h.workspaceWithTerminal("keep")
            let hosts = TerminalHosts.of(daemon: h.identity.pid)
            #expect(hosts.count == 1)
            await h.connection.close()  // what Keep does at quit
            #expect(TerminalHosts.alive(hosts) == hosts, "Keep ended a terminal host")
            #expect(TerminalHosts.alive([h.identity.pid]) == [h.identity.pid], "Keep stopped the daemon")
            let relaunch = DaemonConnection(endpointProvider: { h.endpoint })
            let identity = try await relaunch.start()
            #expect(identity.pid == h.identity.pid)
            let tabs = try await relaunch.listWorkspaces().workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            #expect(tabs.contains { $0.surface == surface }, "the next launch lost the kept terminal")
            await relaunch.close()
        } catch {
            await h.stop()
            throw error
        }
        await h.stop()
    }

    /// Both end choices end every terminal and stop the daemon. End
    /// Sessions, Keep Layout leaves the workspaces for the next owner (they
    /// reopen with fresh shells); End Everything deletes them.
    @Test(arguments: [false, true])
    func endEndsEveryTerminalAndStopsTheDaemon(deletingWorkspaces: Bool) async throws {
        let h = try await BranchDaemonHarness.start()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let hosts: Set<Int32>
        do {
            let (key, _, _) = try await h.workspaceWithTerminal("end")
            _ = try await h.connection.createTerminal(in: key, cwd: h.root.path, size: CellSize(cols: 80, rows: 24))
            _ = try await h.workspaceWithTerminal("second")
            hosts = TerminalHosts.of(daemon: h.identity.pid)
            #expect(hosts.count == 3)
        } catch {
            await h.stop()
            throw error
        }
        let ended = try await h.connection.endSessionsAndStop(deletingWorkspaces: deletingWorkspaces)
        let leakedHosts = await TerminalHosts.awaitExit(hosts)
        let leakedDaemon = await TerminalHosts.awaitExit([h.identity.pid])
        if !leakedHosts.isEmpty || !leakedDaemon.isEmpty { await h.stop() }
        #expect(ended.endedTerminals == 3)
        #expect(leakedHosts.isEmpty, "terminal hosts outlived End: \(leakedHosts)")
        #expect(leakedDaemon.isEmpty, "the daemon outlived End")

        // The next launch: a new owner on the same session and state.
        let binary = try #require(RealBinary.url)
        let base = ProcessInfo.processInfo.environment
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: h.session, stateDirectory: h.root.appendingPathComponent("state")),
            environment: { LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:]) })
        _ = try await launcher.ensure()
        let next = DaemonConnection(endpointProvider: launcher.endpointProvider)
        _ = try await next.start()
        let workspaces = try await next.listWorkspaces().workspaces
        await BranchDaemonHarness.shutDown(next)
        #expect(workspaces.count == (deletingWorkspaces ? 0 : 2), "\(workspaces.map(\.name))")
        #expect(workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).filter { $0.terminalID != nil }.isEmpty,
                "an ended terminal came back")
    }

    /// End Sessions, Keep Layout on a daemon with
    /// `end-terminals-keep-layout-v1`: every terminal ends, the next owner
    /// keeps both panes and the split ratio with dead tabs, and
    /// `relaunchKeptTabs` restarts a shell in each, in its recorded
    /// directory, without changing the layout. A pinned cmux-tui without the
    /// capability skips the check.
    @Test func endKeepLayoutRestartsEachTabInTheSameSplit() async throws {
        let h = try await BranchDaemonHarness.start()
        defer { try? FileManager.default.removeItem(at: h.root) }
        guard h.identity.supports(DaemonCapabilities.shared.endTerminalsKeepLayout) else { return await h.stop() }
        let other = h.root.appendingPathComponent("other")
        let hosts: Set<Int32>
        let plan: KeptLayoutPlan
        let before: DaemonTree
        do {
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let (_, pane, _) = try await h.workspaceWithTerminal("kept")
            _ = try await h.connection.split(pane, direction: .right, options: SpawnOptions(cwd: other.path))
            before = try await h.tree()
            plan = KeptLayoutPlan(tree: before)
            #expect(plan.tabs.count == 2)
            hosts = TerminalHosts.of(daemon: h.identity.pid)
        } catch {
            await h.stop()
            throw error
        }
        let ended = try await h.connection.endSessionsAndStop(keepingLayout: true)
        #expect(ended.keptLayout && ended.endedTerminals == 2)
        #expect(await TerminalHosts.awaitExit(hosts).isEmpty)
        #expect(await TerminalHosts.awaitExit([h.identity.pid]).isEmpty)

        let binary = try #require(RealBinary.url)
        let base = ProcessInfo.processInfo.environment
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: h.session, stateDirectory: h.root.appendingPathComponent("state")),
            environment: { LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:]) })
        _ = try await launcher.ensure()
        let next = DaemonConnection(endpointProvider: launcher.endpointProvider)
        _ = try await next.start()
        do {
            let kept = try await next.listWorkspaces()
            let keptTabs = kept.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            #expect(keptTabs.count == 2 && keptTabs.allSatisfy(\.dead), "\(keptTabs)")
            #expect(kept.workspaces.first?.screens.first?.layout == before.workspaces.first?.screens.first?.layout)
            #expect(try await next.relaunchKeptTabs(plan) == 2)
            let after = try await next.listWorkspaces()
            #expect(after.workspaces.first?.screens.first?.layout == before.workspaces.first?.screens.first?.layout,
                    "the relaunch changed the layout")
            let tabs = after.workspaces.flatMap(\.screens).flatMap(\.panes).map(\.tabs)
            #expect(tabs.map(\.count) == [1, 1], "\(tabs)")
            #expect(tabs.flatMap { $0 }.allSatisfy { !$0.dead })
            #expect(tabs.last?.first?.cwd?.hasSuffix("/other") == true, "\(String(describing: tabs.last?.first?.cwd))")
        } catch {
            await BranchDaemonHarness.shutDown(next)
            throw error
        }
        await BranchDaemonHarness.shutDown(next)
    }
}
