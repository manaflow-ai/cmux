import Foundation
import Testing
@testable import CmuxNextDaemon

/// A pane restored after the daemon restarted stayed on "Restoring…" for good (nightly relaunch,
/// 2026-10-28: 53 attaches failed with `unknown surface 71298…`). Its view kept the attach target
/// it was made with: the old daemon's generation and numeric surface. The new daemon renumbers
/// every surface, and the attach fell back to that old number because the generation differed,
/// so each retry asked for a surface that no longer exists. The terminal's `term_` resource id
/// is the same across the restart, and the daemon resolves it to the terminal's current surface.
@Suite(.enabled(if: RealBinary.isBranchBuild, "needs the same-tree cmux-tui (scripts/cmux-next/pin-cmux-tui.sh fetch)"),
       .timeLimit(.minutes(2)), .liveDaemon)
struct BranchStaleAttachTargetTests {
    @Test func aTargetFromBeforeTheDaemonRestartedAttachesToTheSameTerminal() async throws {
        let h = try await BranchDaemonHarness.start()
        defer { try? FileManager.default.removeItem(at: h.root) }
        guard h.identity.supports("attach-identity-v1"),
              h.identity.supports(DaemonCapability.endTerminalsKeepLayout.rawValue),
              h.identity.supports(DaemonCapability.tabRestartKeptLayout.rawValue) else { return await h.stop() }
        let stale: TerminalAttachment.Target
        let tabResource: String
        let hosts: Set<Int32>
        do {
            let (_, _, surface) = try await h.workspaceWithTerminal("stale")
            let tab = try #require(try await h.tab(surface))
            // What a view made before the restart holds.
            stale = TerminalAttachment.Target(tab: tab, generation: h.identity.generation)
            tabResource = try #require(tab.tabResourceID).rawValue
            hosts = TerminalHosts.of(daemon: h.identity.pid)
        } catch {
            await h.stop()
            throw error
        }
        let terminal = try #require(stale.terminalResourceID)
        let ended = await h.connection.endSessionsAndStop(keepingLayout: true)
        #expect(ended.keptLayout)
        #expect(await TerminalHosts.awaitExit(hosts).isEmpty)
        #expect(await TerminalHosts.awaitExit([h.identity.pid]).isEmpty)

        let binary = try #require(RealBinary.url)
        let base = ProcessInfo.processInfo.environment
        let launcher = DaemonLauncher(
            configuration: .init(binary: binary, session: h.session, stateDirectory: h.root.appendingPathComponent("state")),
            environment: { LoginEnvironment.shared.daemonEnvironment(login: nil, base: base, overrides: [:]) })
        _ = try await launcher.ensure()
        let next = DaemonConnection(configuration: BranchDaemonHarness.configuration(), endpointProvider: launcher.endpointProvider)
        let identity = try await next.start()
        let store = await DaemonStore()
        let storeTask = Task { await store.run(connection: next) }
        defer { storeTask.cancel() }
        do {
            #expect(identity.generation != stale.generation, "the restart kept the generation")
            // The kept shell starts on its workspace's first show (`wakeParkedTabs`: `restart-tab`).
            let kept = try #require(try await next.listWorkspaces().workspaces.flatMap(\.screens).flatMap(\.panes)
                .flatMap(\.tabs).first { $0.tabResourceID?.rawValue == tabResource })
            #expect(kept.dead && kept.relaunch?.onShow == true, "\(kept)")
            _ = try await next.request(RestartTabRequest(surface: kept.surface))
            try await store.waitUntil("the kept tab runs again", timeout: .seconds(20)) {
                store.tab(idOrResource: tabResource).map { !$0.dead && $0.terminalState == .running } ?? false
            }
            let current = try #require(try await next.listWorkspaces().workspaces.flatMap(\.screens).flatMap(\.panes)
                .flatMap(\.tabs).first { $0.terminalResourceID == terminal })
            #expect(current.surface != stale.surface, "the restart kept the numeric surface")
            let endpoint = try #require(await next.endpoint)
            let attachment = try await TerminalAttachment.attach(endpoint: endpoint, target: stale,
                                                                 size: CellSize(cols: 100, rows: 30), claimGeometry: false)
            var events = attachment.events.makeAsyncIterator()
            guard case .replay? = await events.next() else {
                Issue.record("the attach did not start with a replay")
                await attachment.detach()
                await BranchDaemonHarness.shutDown(next)
                return
            }
            // Later commands (resize, input) name the terminal's current surface.
            #expect(attachment.surface == current.surface)
            await attachment.detach()
        } catch {
            await BranchDaemonHarness.shutDown(next)
            throw error
        }
        await BranchDaemonHarness.shutDown(next)
    }
}
