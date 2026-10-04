import Foundation
import Testing
@testable import CmuxNextDaemon

/// Quitting cmux (user decision 2026-09-30): Keep Sessions Running only
/// closes the app's connection, so the daemon and every terminal keep
/// running and a new connection finds the same terminals; End Sessions,
/// Keep Layout and End Everything end every terminal and stop the daemon,
/// and End Everything also deletes the workspaces.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
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

    /// End Everything with the store's home workspace (`workspace-kind-v1`),
    /// which every close path refuses (`home_not_closable`), as the app
    /// always has it: every other workspace closes, every terminal ends, the
    /// daemon stops, and Home stays without counting as a failure. The live
    /// run on cmux-lawrence-2 (plans/cmux-next/quit-persistence.md 2) stopped
    /// at Home and quit with every terminal still running.
    @Test func endEverythingWithHomeEndsTheRestAndKeepsHome() async throws {
        let h = try await BranchDaemonHarness.start()
        defer { try? FileManager.default.removeItem(at: h.root) }
        guard h.identity.supports(DaemonCapabilities.shared.workspaceKind) else { return await h.stop() }
        let hosts: Set<Int32>
        do {
            _ = try await HomeWorkspaceClient(h.connection).ensureHome()
            _ = try await h.workspaceWithTerminal("end")
            _ = try await h.workspaceWithTerminal("second")
            hosts = TerminalHosts.of(daemon: h.identity.pid)
            #expect(hosts.count == 2)
        } catch {
            await h.stop()
            throw error
        }
        var ended: EndedSessions?
        do {
            ended = try await h.connection.endSessionsAndStop(deletingWorkspaces: true)
        } catch {
            Issue.record("End Everything failed: \(error)")
        }
        let leakedHosts = await TerminalHosts.awaitExit(hosts)
        let leakedDaemon = await TerminalHosts.awaitExit([h.identity.pid])
        if !leakedHosts.isEmpty || !leakedDaemon.isEmpty { await h.stop() }
        #expect(ended?.endedTerminals == 2)
        #expect(leakedHosts.isEmpty, "terminal hosts outlived End Everything: \(leakedHosts)")
        #expect(leakedDaemon.isEmpty, "the daemon outlived End Everything")

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
        #expect(workspaces.map(\.kind) == ["home"], "\(workspaces.map(\.name))")
    }

    /// End Sessions, Keep Layout on a daemon with
    /// `end-terminals-keep-layout-v1`: every terminal ends, the next owner
    /// keeps both panes and the split ratio with dead tabs, and
    /// `relaunchKeptTabs` restarts a shell in each, in the directory the
    /// store recorded, without changing the layout. A pinned cmux-tui without the
    /// capability skips the check.
    @Test func endKeepLayoutRestartsEachTabInTheSameSplit() async throws {
        let h = try await BranchDaemonHarness.start()
        defer { try? FileManager.default.removeItem(at: h.root) }
        guard h.identity.supports(DaemonCapabilities.shared.endTerminalsKeepLayout) else { return await h.stop() }
        let other = h.root.appendingPathComponent("other")
        let hosts: Set<Int32>
        let before: DaemonTree
        do {
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
            let (_, pane, _) = try await h.workspaceWithTerminal("kept")
            _ = try await h.connection.split(pane, direction: .right, options: SpawnOptions(cwd: other.path))
            before = try await h.tree()
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
            #expect(keptTabs.allSatisfy { $0.relaunch?.cwd != nil }, "the store's keep-layout records: \(keptTabs.map(\.relaunch))")
            #expect(Self.shape(kept) == Self.shape(before))
            let first = try await next.relaunchKeptTabs(fallbackCwd: nil)
            #expect(first.relaunched == 2 && first.failures.isEmpty, "\(first.failures)")
            #expect(try await next.relaunchKeptTabs(fallbackCwd: nil).relaunched == 0, "a second relaunch found kept tabs")
            let after = try await next.listWorkspaces()
            #expect(Self.shape(after) == Self.shape(before), "the relaunch changed the layout")
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

    /// The first screen's split kind, direction and ratio and its panes'
    /// resource ids: numeric pane and split handles are per daemon owner.
    static func shape(_ tree: DaemonTree) -> String {
        guard let screen = tree.workspaces.first?.screens.first else { return "none" }
        let panes = screen.panes.map { $0.resourceID?.rawValue ?? "?" }.joined(separator: ",")
        let layout: String = switch screen.layout {
        case .split(_, let direction, let ratio, _, _): "split \(direction) \(ratio)"
        default: "leaf"
        }
        return "\(layout) [\(panes)]"
    }
}
