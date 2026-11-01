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
            let relaunch = DaemonConnection(configuration: BranchDaemonHarness.configuration(), endpointProvider: { h.endpoint })
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
        let ended = await h.connection.endSessionsAndStop(deletingWorkspaces: deletingWorkspaces)
        #expect(ended.failures.isEmpty, "\(ended.failures)")
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
        let next = DaemonConnection(configuration: BranchDaemonHarness.configuration(), endpointProvider: launcher.endpointProvider)
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
        guard h.identity.supports(DaemonCapability.workspaceKind.rawValue) else { return await h.stop() }
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
        let ended = await h.connection.endSessionsAndStop(deletingWorkspaces: true)
        #expect(ended.failures.isEmpty, "Home counted as a failure: \(ended.failures)")
        let leakedHosts = await TerminalHosts.awaitExit(hosts)
        let leakedDaemon = await TerminalHosts.awaitExit([h.identity.pid])
        if !leakedHosts.isEmpty || !leakedDaemon.isEmpty { await h.stop() }
        #expect(ended.endedTerminals == 2)
        #expect(leakedHosts.isEmpty, "terminal hosts outlived End Everything: \(leakedHosts)")
        #expect(leakedDaemon.isEmpty, "the daemon outlived End Everything")

        let binary = try #require(RealBinary.url)
        let base = ProcessInfo.processInfo.environment
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: h.session, stateDirectory: h.root.appendingPathComponent("state")),
            environment: { LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:]) })
        _ = try await launcher.ensure()
        let next = DaemonConnection(configuration: BranchDaemonHarness.configuration(), endpointProvider: launcher.endpointProvider)
        _ = try await next.start()
        let workspaces = try await next.listWorkspaces().workspaces
        await BranchDaemonHarness.shutDown(next)
        #expect(workspaces.map(\.kind) == ["home"], "\(workspaces.map(\.name))")
    }

    /// End Sessions, Keep Layout on a daemon with
    /// `end-terminals-keep-layout-v1`: every terminal ends, the next owner
    /// keeps both panes and the split ratio with dead tabs parked until shown, and
    /// the show restarts a shell in each IN PLACE (`restart-tab`: the
    /// same tab and terminal ids, no tab added, moved or closed), in the
    /// directory the store recorded, without changing the layout. A pinned
    /// cmux-tui without the capabilities skips the check.
    @Test func endKeepLayoutRestartsEachTabInTheSameSplit() async throws {
        let h = try await BranchDaemonHarness.start()
        defer { try? FileManager.default.removeItem(at: h.root) }
        guard h.identity.supports(DaemonCapability.endTerminalsKeepLayout.rawValue),
              h.identity.supports(DaemonCapability.tabRestartKeptLayout.rawValue) else { return await h.stop() }
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
        let ended = await h.connection.endSessionsAndStop(keepingLayout: true)
        #expect(ended.keptLayout && ended.endedTerminals == 2)
        #expect(await TerminalHosts.awaitExit(hosts).isEmpty)
        #expect(await TerminalHosts.awaitExit([h.identity.pid]).isEmpty)

        let binary = try #require(RealBinary.url)
        let base = ProcessInfo.processInfo.environment
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: h.session, stateDirectory: h.root.appendingPathComponent("state")),
            environment: { LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:]) })
        _ = try await launcher.ensure()
        let next = DaemonConnection(configuration: BranchDaemonHarness.configuration(), endpointProvider: launcher.endpointProvider)
        _ = try await next.start()
        // The daemon's event stream drives the store: the test waits on it for the restarted shells.
        let store = await DaemonStore()
        let storeTask = Task { await store.run(connection: next) }
        defer { storeTask.cancel() }
        do {
            let kept = try await next.listWorkspaces()
            let keptTabs = kept.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
            #expect(keptTabs.count == 2 && keptTabs.allSatisfy(\.dead), "\(keptTabs)")
            #expect(keptTabs.allSatisfy { $0.relaunch?.cwd != nil }, "the store's keep-layout records: \(keptTabs.map(\.relaunch))")
            #expect(Self.shape(kept) == Self.shape(before))
            // Kept shells start on their workspace's first show (`relaunch.onShow`), not at
            // connect: a session with hundreds of workspaces nobody opens took a PTY for each (a913).
            #expect(keptTabs.allSatisfy { $0.relaunch?.onShow == true }, "\(keptTabs.map(\.relaunch))")
            let first = try await next.relaunchKeptTabs()
            #expect(first.relaunched == 0 && first.failures.isEmpty, "a kept shell started at connect: \(first.failures)")
            // The show (`DaemonService.wakeParkedTabs`): one `restart-tab` per parked tab.
            for tab in keptTabs { _ = try await next.request(RestartTabRequest(surface: tab.surface)) }
            // `restart-tab` answers when its worker started: attach only once the tree events
            // report both kept tabs running (before that the tab has no surface to attach to).
            let keptIDs = keptTabs.compactMap(\.tabResourceID)
            #expect(keptIDs.count == 2, "\(keptTabs)")
            try await store.waitUntil("both kept tabs run again", timeout: .seconds(20)) {
                keptIDs.allSatisfy { id in
                    store.tab(idOrResource: id.rawValue).map { !$0.dead && $0.terminalState == .running } ?? false
                }
            }
            let after = try await next.listWorkspaces()
            // The shell of the second pane runs, in its recorded directory: it echoes $PWD there.
            let endpoint = try #require(await next.endpoint)
            let generation = await next.identity?.generation
            let second = try #require(after.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs)
                .first { $0.tabResourceID == keptIDs.last })
            // Wait on a marker the shell computes after the echo: the prompt's OSC 7 cwd report
            // also contains "/other", and the typed command line itself contains "kept:".
            let output = try await Self.run(#"echo "kept:$PWD"; echo kept-done-$((40+2))"#, in: second, endpoint: endpoint,
                                            generation: generation, until: "kept-done-42")
            #expect(output.range(of: #"kept:/\S*/other"#, options: .regularExpression) != nil, "\(output)")
            let again = try await next.relaunchKeptTabs()
            #expect(again.relaunched == 0 && again.failures.isEmpty, "a second relaunch restarted a running tab: \(again.failures)")
            #expect(Self.shape(after) == Self.shape(before), "the relaunch changed the layout")
            let tabs = after.workspaces.flatMap(\.screens).flatMap(\.panes).map(\.tabs)
            #expect(tabs.map(\.count) == [1, 1], "\(tabs)")
            // In place: the kept tabs themselves run again (no new tab took their slot).
            #expect(tabs.flatMap { $0 }.map(\.tabResourceID) == keptTabs.map(\.tabResourceID), "\(tabs)")
            // The same terminals as before the quit (a dead kept tab reports none).
            let terminalsBefore = before.workspaces.flatMap(\.screens).flatMap(\.panes).flatMap(\.tabs).map(\.terminalResourceID)
            #expect(tabs.flatMap { $0 }.map(\.terminalResourceID) == terminalsBefore, "\(tabs)")
        } catch {
            await BranchDaemonHarness.shutDown(next)
            throw error
        }
        await BranchDaemonHarness.shutDown(next)
    }

    /// Types `command` into `tab`'s terminal and returns its output up to `sentinel` (bounded: 20 s).
    static func run(_ command: String, in tab: TabSnapshot, endpoint: DaemonEndpoint, generation: DaemonGeneration?,
                    until sentinel: String) async throws -> String {
        let attachment = try await TerminalAttachment.attach(
            endpoint: endpoint, target: .init(tab: tab, generation: generation),
            size: CellSize(cols: 200, rows: 50), claimGeometry: true)
        let watchdog = Task {
            try await Task.sleep(for: .seconds(20))
            await attachment.detach()
        }
        await attachment.write(Data((command + "\r").utf8))
        var output = ""
        for await event in attachment.events {
            guard case .output(let data, _) = event else { continue }
            output += String(decoding: data, as: UTF8.self)
            if output.contains(sentinel) { break }
        }
        watchdog.cancel()
        await attachment.detach()
        return output
    }

    /// The first screen's split kind, direction and ratio and its panes'
    /// resource ids: numeric pane and split handles are per daemon owner.
    static func shape(_ tree: DaemonTree) -> String {
        guard let screen = tree.workspaces.first?.screens.first else { return "none" }
        let panes = screen.panes.map { $0.resourceID?.rawValue ?? "?" }.joined(separator: ",")
        let layout: String = switch screen.layout {
        case .split(_, _, let direction, let ratio, _, _): "split \(direction) \(ratio)"
        default: "leaf"
        }
        return "\(layout) [\(panes)]"
    }
}
